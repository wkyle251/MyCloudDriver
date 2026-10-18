#!/usr/bin/env python3
"""Real-process recovery of a paused and forcibly interrupted similarity matrix."""
import argparse
import json
from contextlib import closing, contextmanager
import os
from pathlib import Path
import selectors
import signal
import sqlite3
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('resources', type=Path)
args = parser.parse_args()
resources = args.resources.resolve()
environment = {k: v for k, v in os.environ.items() if not k.startswith('PIKPAK_')}


@contextmanager
def existing_database(path):
    # Product recovery opens existing journals read/write so SQLite can repair
    # hot journals or recreate WAL support files after helper termination.
    # mode=rw and strict resolution still forbid creating a lookalike database.
    path = path.resolve(strict=True)
    assert path.is_file(), 'Expected an existing generated comparison database'
    with closing(sqlite3.connect(path.as_uri() + '?mode=rw', uri=True, timeout=10)) as db:
        yield db


def comparison_database(checkpoint):
    with existing_database(checkpoint / 'checkpoint.sqlite3') as journal:
        generation = journal.execute("SELECT value FROM metadata WHERE key='comparison_directory'").fetchone()
    if generation:
        value = generation[0]
        if isinstance(value, bytes):
            value = value.decode('ascii')
        assert str(uuid.UUID(value)) == value.lower(), 'Invalid generated comparison directory'
        return checkpoint / value / 'matrix.sqlite3'
    # Old checkpoints stored the row matrix directly beside the file journal.
    return checkpoint / 'matrix.sqlite3'


def saved_scores(db):
    """Read schema and its durable count from one consistent SQLite snapshot."""
    own_transaction = not db.in_transaction
    if own_transaction:
        db.execute('BEGIN')
    try:
        tables = {row[0] for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('comparison_progress','scores')")}
        if 'comparison_progress' in tables:
            row = db.execute('SELECT completed FROM comparison_progress WHERE singleton=1').fetchone()
            assert row is not None and row[0] >= 0, 'Missing committed comparison progress'
            return row[0]
        assert 'scores' in tables, 'Selected database has no saved comparison format'
        return db.execute('SELECT COUNT(*) FROM scores').fetchone()[0]
    finally:
        if own_transaction:
            db.rollback()  # End this read snapshot before the next pause sample.

with tempfile.TemporaryDirectory(prefix='mycloud-resume-matrix-') as temporary:
    root = Path(temporary).resolve()
    inputs = root / 'inputs'; inputs.mkdir()
    count = 5000
    text = 'A green garden with trees and flowers, paths and places to enjoy the sunshine. ' * 20
    for index in range(count):
        (inputs / f'{index:04d}.txt').write_text(text)
    checkpoint_id = str(uuid.uuid4())
    models = resources / 'FileTwinModels'
    request = dict(checkpoint_id=checkpoint_id, parent_pid=os.getpid(), source='local', local_paths=[str(inputs)],
        cloud_items=[], families=['text'], threshold=.9, exact_duplicates=True,
        data_dir=str(root / 'data'), model_dir=str(models), temp_dir=str(root / 'temp'), report_path=str(root / 'report.json'),
        runtime=dict(worker_path=str(resources / 'filetwin-worker'), ffmpeg_path='/opt/homebrew/bin/ffmpeg',
            ffprobe_path='/opt/homebrew/bin/ffprobe', onnxruntime_path=str(models / 'runtime/libonnxruntime.dylib'),
            pdfium_path=str(models / 'runtime/libpdfium.dylib')),
        resources=dict(memory_scheduling=True, workers=4, memory_bytes=4 << 30, download_memory_bytes=1 << 30))
    request_file = root / 'request.json'; request_file.write_text(json.dumps(request))
    checkpoint = root / 'data/checkpoints' / checkpoint_id

    def run(interrupt=None, after=0):
        with (root / 'errors.log').open('wb') as errors:
            process = subprocess.Popen([str(resources / 'pikpak'), 'similarity-scan', '--request-file', str(request_file)],
                env=environment, stdout=subprocess.PIPE, stderr=errors)
            selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 150
            buffer = b''; events = []; stopped = False
            try:
                while selector.get_map() and time.monotonic() < deadline:
                    for key, _ in selector.select(.5):
                        data = os.read(key.fd, 65536)
                        if not data:
                            selector.unregister(key.fileobj); continue
                        buffer += data
                        while b'\n' in buffer:
                            line, buffer = buffer.split(b'\n', 1)
                            event = json.loads(line); events.append(event)
                            if (interrupt and not stopped and event.get('stage') == 'comparison'
                                and after < event.get('completed', 0) < event.get('total', 0)):
                                if interrupt == signal.SIGTERM: (checkpoint / 'pause').write_bytes(b'')
                                process.send_signal(interrupt); stopped = True
                assert process.poll() is not None or time.monotonic() < deadline, 'Scan timed out'
                code = process.wait(timeout=10)
                if interrupt:
                    assert stopped, ('No committed comparison interruption', code, (root / 'errors.log').read_text())
                    assert code == (0 if interrupt == signal.SIGTERM else -signal.SIGKILL), (code, (root / 'errors.log').read_text())
                else:
                    assert code == 0, (code, (root / 'errors.log').read_text())
                return events
            finally:
                selector.close()
                if process.poll() is None: process.kill(); process.wait()

    first = run(signal.SIGTERM)
    report = json.loads((root / 'report.json').read_text())
    assert report['status'] == 'paused', report['status']
    with existing_database(comparison_database(checkpoint)) as db:
        paused_scores = saved_scores(db)
    assert 0 < paused_scores < count * (count - 1) // 2
    # Resume still validates fresh scope metadata before/after comparison.
    # Keep that metadata unchanged and prove originals are not read or hashed.
    acquisition_fields = ('bytes_read', 'bytes_hashed')
    first_comparison = next(event for event in first if event.get('stage') == 'comparison')
    acquisition_before = {field: first_comparison['counts'][field] for field in acquisition_fields}
    def input_revisions():
        return [(stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)
                for stat in (path.stat() for path in sorted(inputs.iterdir()))]
    original_revisions = input_revisions()
    def comparison_only(events):
        progress = [event for event in events if event.get('event') == 'progress']
        assert not any(event.get('stage') in {'analysing', 'downloading'} for event in progress)
        comparisons = [event for event in progress if event.get('stage') == 'comparison']
        assert comparisons, 'Resume did not restore comparison progress'
        assert all({field: event['counts'][field] for field in acquisition_fields} == acquisition_before
                   for event in comparisons), 'Resume reread or rehashed original contents'
        return comparisons
    (checkpoint / 'pause').unlink()
    request['resources'] = dict(memory_scheduling=True, workers=1, memory_bytes=1 << 30, download_memory_bytes=256 << 20)
    request_file.write_text(json.dumps(request))
    second = run(signal.SIGKILL, after=paused_scores)
    second_progress = comparison_only(second)
    assert second_progress[0]['completed'] == paused_scores
    with existing_database(comparison_database(checkpoint)) as db:
        crashed_scores = saved_scores(db)
    assert crashed_scores > paused_scores
    request['resources'] = dict(memory_scheduling=True, workers=6, memory_bytes=4 << 30, download_memory_bytes=1 << 30)
    request_file.write_text(json.dumps(request))
    third = run()
    third_progress = comparison_only(third)
    assert input_revisions() == original_revisions, 'Generated original metadata changed'
    assert third_progress[0]['stage'] == 'comparison' and third_progress[0]['completed'] == crashed_scores
    report = json.loads((root / 'report.json').read_text())
    expected = count * (count - 1) // 2
    assert report['status'] == 'completed' and report['scores_retained'] == expected, report
    with existing_database(root / 'data/runs' / (report['run_id'] + '.sqlite3')) as db:
        assert saved_scores(db) == expected
        compact = db.execute("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='score_chunks')").fetchone()[0]
        if compact:
            import struct
            retained = 0
            for n, data in db.execute('SELECT n,data FROM score_chunks'):
                assert 0 < n <= 4096 and len(data) == n * 8
                assert all(score == 1.0 for score in struct.unpack(f'<{n}d', data))
                retained += n
            assert retained == expected
        else:
            assert db.execute('SELECT COUNT(*) FROM scores WHERE score != 1.0').fetchone()[0] == 0
    print(f'PASS Pause/SIGKILL/resume with changed RAM budgets during comparison: {paused_scores:,} → {crashed_scores:,} → {expected:,} scores, without rereading original content')

    # Simulate a GUI that dies while its helper is waiting for more inventory.
    # The helper must stop itself, even though no UI remains to send SIGTERM.
    orphan_id = str(uuid.uuid4())
    inventory = root / 'inventory.jsonl'; inventory.write_text('')
    orphan_request = dict(request, checkpoint_id=orphan_id, local_paths=[], external_source_stream=str(inventory),
        report_path=str(root / 'orphan-report.json'))
    orphan_file = root / 'orphan-request.json'; orphan_file.write_text(json.dumps(orphan_request))
    parent_code = '''
import json, os, pathlib, subprocess, sys, time
request_file=pathlib.Path(sys.argv[1]); request=json.loads(request_file.read_text())
request['parent_pid']=os.getpid(); request_file.write_text(json.dumps(request))
root=request_file.parent
with (root/'orphan-events.jsonl').open('wb') as out, (root/'orphan-errors.log').open('wb') as err:
    child=subprocess.Popen([sys.argv[2],'similarity-scan','--request-file',str(request_file)],stdout=out,stderr=err)
    (root/'orphan.pid').write_text(str(child.pid))
    checkpoint=pathlib.Path(request['data_dir'])/'checkpoints'/request['checkpoint_id']/'checkpoint.sqlite3'
    deadline=time.monotonic()+10
    while not checkpoint.exists() and time.monotonic()<deadline: time.sleep(.02)
    assert checkpoint.exists()
'''
    subprocess.run([os.sys.executable, '-c', parent_code, str(orphan_file), str(resources / 'pikpak')],
        env=environment, check=True, timeout=20)
    deadline = time.monotonic() + 10
    while not (root / 'orphan-report.json').exists() and time.monotonic() < deadline: time.sleep(.05)
    assert (root / 'orphan-report.json').exists(), 'The orphan helper did not stop after losing its GUI parent'
    assert json.loads((root / 'orphan-report.json').read_text())['status'] == 'cancelled'
    assert (root / 'data/checkpoints' / orphan_id / 'checkpoint.sqlite3').exists()
    print('PASS loss of the GUI parent stops the helper and preserves the recovery checkpoint')
