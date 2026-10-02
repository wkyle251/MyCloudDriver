#!/usr/bin/env python3
"""Regression: GUI descriptor limits must not turn large scans into failures."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import resource
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('resources', type=Path)
parser.add_argument('--helper', type=Path)
args = parser.parse_args()
resources = args.resources.resolve()
helper = (args.helper or resources / 'pikpak').resolve()
spec = importlib.util.spec_from_file_location('fixtures', Path(__file__).with_name('test-similarity-native.py'))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)

with tempfile.TemporaryDirectory(prefix='MyCloudFileHandleTest-') as temporary:
    root = Path(temporary).resolve()
    inputs = root / 'files'
    inputs.mkdir()
    for i in range(60):
        fixtures.png(inputs / f'image-{i}.png', i * 3)
    models = resources / 'FileTwinModels'
    for hard_limit in (False, True):
        run = root / ('hard-limit' if hard_limit else 'soft-limit')
        run.mkdir()
        request = dict(source='local', local_paths=[str(inputs)], cloud_items=[], families=['image'],
                       threshold=0.9, exact_duplicates=True, data_dir=str(run / 'index'), model_dir=str(models),
                       temp_dir=str(run / 'copies'), report_path=str(run / 'report.json'),
                       runtime=dict(worker_path=str(resources / 'filetwin-worker'),
                                    onnxruntime_path=str(models / 'runtime/libonnxruntime.dylib')),
                       resources=dict(workers=52, memory_bytes=64 * 1024**3,
                                      download_memory_bytes=12 * 1024**3))
        request_path = run / 'request.json'
        request_path.write_text(json.dumps(request))
        current_hard = resource.getrlimit(resource.RLIMIT_NOFILE)[1]
        def inherited_gui_limit():
            resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256 if hard_limit else current_hard))
        environment = {k: v for k, v in os.environ.items() if not k.startswith('PIKPAK_')}
        environment['TMPDIR'] = str(run)
        result = subprocess.run([str(helper), 'similarity-scan', '--request-file', str(request_path)],
                                cwd=run, env=environment, capture_output=True, text=True,
                                timeout=60, preexec_fn=inherited_gui_limit)
        assert result.returncode == 0, result.stderr
        report = json.loads(Path(request['report_path']).read_text())
        assert report['analysed_files'] == 60 and report['failed_files'] == 0, report['issue_summary']
        limits = {event['work']['worker_limit'] for line in result.stdout.splitlines()
                  if (event := json.loads(line)).get('work')}
        assert limits == ({10} if hard_limit else {52}), limits
        for line in result.stdout.splitlines():
            if work := json.loads(line).get('work'):
                assert work['original_memory_bytes'] <= work['original_memory_limit'] == 12 * 1024**3
                assert work['analysis_memory_limit'] == 52 * 1024**3
        assert not any(Path(request['temp_dir']).iterdir()), 'Temporary originals must be cleaned'
        peak = max(event['work']['encoding'] for line in result.stdout.splitlines()
                   if (event := json.loads(line)).get('work'))
        print('PASS 60 images, zero failures:', 'hard limit respected with 10 workers' if hard_limit
              else '256 inherited soft limit raised for 52 workers', f'(peak {peak} analysing)')
