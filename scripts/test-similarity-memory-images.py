#!/usr/bin/env python3
"""Exercise RAM-only JPEG/HEIC/AVIF native readers using synthetic images."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('resources', type=Path)
args = parser.parse_args()
resources = args.resources.resolve()
spec = importlib.util.spec_from_file_location('fixtures', Path(__file__).with_name('test-similarity-native.py'))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
with tempfile.TemporaryDirectory(prefix='mycloud-memory-images-') as temporary:
    root = Path(temporary).resolve()
    source = root / 'synthetic.png'
    fixtures.png(source)
    inputs = root / 'inputs'; inputs.mkdir()
    for kind in ['jpeg', 'heic', 'avif']:
        subprocess.run(['/usr/bin/sips', '-s', 'format', kind, str(source), '--out', str(inputs / ('picture.' + kind))],
                       check=True, capture_output=True, timeout=20)
    ffmpeg = '/opt/homebrew/bin/ffmpeg'; ffprobe = '/opt/homebrew/bin/ffprobe'
    models = resources / 'FileTwinModels'
    request = dict(source='local', local_paths=[str(inputs)], cloud_items=[], families=['image'], threshold=.05,
                   exact_duplicates=True, include_hidden=False, data_dir=str(root / 'index'),
                   model_dir=str(models), temp_dir=str(root / 'temp'), report_path=str(root / 'report.json'),
                   resources=dict(memory_scheduling=True, workers=1, memory_bytes=4 << 30,
                                  download_memory_bytes=1 << 30),
                   runtime=dict(worker_path=str(resources / 'filetwin-worker'), ffmpeg_path=ffmpeg,
                                ffprobe_path=ffprobe, onnxruntime_path=str(models / 'runtime/libonnxruntime.dylib'),
                                pdfium_path=str(models / 'runtime/libpdfium.dylib')))
    request_file = root / 'request.json'; request_file.write_text(json.dumps(request))
    environment = {k:v for k,v in os.environ.items() if not k.startswith('PIKPAK_')}
    run = subprocess.run([str(resources / 'pikpak'), 'similarity-scan', '--request-file', str(request_file)],
                         env=environment, cwd=root, capture_output=True, text=True, timeout=60)
    assert run.returncode == 0, run.stderr
    report = json.loads((root / 'report.json').read_text())
    assert report['analysed_files'] == 3 and report['skipped_files'] == 0, report['issues']
    with sqlite3.connect(root / 'index/runs' / (report['run_id'] + '.sqlite3')) as db:
        details = [json.loads(row[0]) for row in db.execute('SELECT extraction FROM files')]
    assert len(details) == 3 and all(e['input_storage'] == 'memory' for e in details)
    assert not any((root / 'temp').iterdir())
    print('PASS memory-admitted JPEG, HEIC and AVIF decoded from RAM; no failures or leftover processing data')
