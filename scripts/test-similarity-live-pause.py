#!/usr/bin/env python3
"""Cooperative comparison pause keeps the same helper and committed scores."""
import json
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
with tempfile.TemporaryDirectory(prefix='similarity-live-pause-') as temporary:
    root = Path(temporary).resolve()
    inputs = root / 'inputs'
    inputs.mkdir()
    for index in range(1200):
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
                        with sqlite3.connect(checkpoint / 'matrix.sqlite3') as db:
                            paused_scores = db.execute('SELECT COUNT(*) FROM scores').fetchone()[0]
                            time.sleep(.5)
                            assert db.execute('SELECT COUNT(*) FROM scores').fetchone()[0] == paused_scores
                        assert process.poll() is None, 'Pause exited the RAM-owning helper'
                        (checkpoint / 'pause').unlink()
                        resumed = True
        assert requested and resumed and paused_scores > 0
        assert process.wait(timeout=10) == 0, process.stderr.read().decode()[:500]
        report = json.loads((root / 'report.json').read_text())
        assert report['status'] == 'completed' and report['scores_retained'] == 719400
        print(f'PASS same-helper comparison pause freezes {paused_scores:,} saved scores and resumes to 719,400')
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
            process.wait()
