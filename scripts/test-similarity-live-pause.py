#!/usr/bin/env python3
"""Cooperative comparison pause keeps the same helper and committed scores."""
import json
from contextlib import closing, contextmanager
import os
from pathlib import Path
import selectors
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

resources = Path(sys.argv[1]).resolve()

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

with tempfile.TemporaryDirectory(prefix='similarity-live-pause-') as temporary:
    root = Path(temporary).resolve()
    inputs = root / 'inputs'
    inputs.mkdir()
    count = 5000
    expected = count * (count - 1) // 2
    for index in range(count):
        (inputs / f'{index}.txt').write_text('A garden with flowers and trees. ' * 25)
    identifier = str(uuid.uuid4())
    checkpoint = root / 'data/checkpoints' / identifier
    request = dict(checkpoint_id=identifier, parent_pid=os.getpid(), source='local',
        local_paths=[str(inputs)], families=['text'], threshold=.9, exact_duplicates=True,
        data_dir=str(root / 'data'), model_dir=str(resources / 'FileTwinModels'),
        temp_dir=str(root / 'temporary'), report_path=str(root / 'report.json'), runtime={},
        resources=dict(memory_scheduling=True, memory_bytes=1 << 30, download_memory_bytes=256 << 20))
    path = root / 'request.json'
    path.write_text(json.dumps(request))
    process = subprocess.Popen([str(resources / 'pikpak'), 'similarity-scan', '--request-file', str(path)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    buffer = b''
    requested = resumed = False
    paused_scores = 0
    deadline = time.monotonic() + 90
    try:
        while selector.get_map() and time.monotonic() < deadline:
            for key, _ in selector.select(.1):
                data = os.read(key.fd, 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                buffer += data
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    event = json.loads(line)
                    if not requested and event.get('stage') == 'comparison' and 0 < event.get('completed', 0) < event.get('total', 0):
                        (checkpoint / 'pause').write_bytes(b'')
                        requested = True
                    if event.get('event') == 'pause_state' and event.get('paused'):
                        time.sleep(.2)  # Finish the coordinator's current pair/transaction.
                        with existing_database(comparison_database(checkpoint)) as db:
                            paused_scores = saved_scores(db)
                            time.sleep(.5)
                            assert saved_scores(db) == paused_scores
                        assert process.poll() is None, 'Pause exited the RAM-owning helper'
                        (checkpoint / 'pause').unlink()
                        resumed = True
        assert requested and resumed and paused_scores > 0
        assert process.wait(timeout=10) == 0, process.stderr.read().decode()[:500]
        report = json.loads((root / 'report.json').read_text())
        assert report['status'] == 'completed' and report['scores_retained'] == expected
        print(f'PASS same-helper comparison pause freezes {paused_scores:,} saved scores and resumes to {expected:,}')
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
            process.wait()
