#!/usr/bin/env python3
"""Measure the bundled pipeline using disposable, synthetic local files only."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--workers', type=int, nargs='+', default=[8, 16, 52])
    args = parser.parse_args()
    resources = args.resources.resolve()
    models = resources / 'FileTwinModels'
    spec = importlib.util.spec_from_file_location('fixtures', Path(__file__).with_name('test-similarity-native.py'))
    fixtures = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixtures)
    results = []
    with tempfile.TemporaryDirectory(prefix='mycloud-pipeline-benchmark-') as directory:
        root = Path(directory).resolve()
        files = root / 'inputs'
        files.mkdir()
        for index in range(40):
            fixtures.png(files / f'image-{index:03}.png', index * 5)
        for index in range(8):
            with (files / f'text-{index:03}.txt').open('w') as file:
                block = f'Sample {index}. A garden with flowers, trees, leaves and a pond. ' * 1024
                for _ in range(128):
                    file.write(block)
        for index in range(4):
            shutil.copyfile(files / f'image-{index:03}.png', files / f'image-{index:03}-copy.png')
        for index in range(4):
            (files / f'binary-{index}.dat').write_bytes(b'\0\xff\x01binary' * 8192)
        fixtures.pdf(files / 'document.pdf')
        subprocess.run(['/opt/homebrew/bin/ffmpeg', '-nostdin', '-v', 'error', '-f', 'lavfi', '-i',
                        'testsrc2=size=160x120:rate=4', '-t', '2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', str(files / 'video.mp4')], check=True, timeout=20)
        total = len(list(files.iterdir()))
        environment = {k: v for k, v in os.environ.items() if not k.startswith('PIKPAK_')}
        environment['TMPDIR'] = str(root)
        for workers in args.workers:
            run = root / f'run-{workers}'
            run.mkdir()
            memory_gb = 16 if workers == 8 else 48
            request = dict(source='local', local_paths=[str(files)], cloud_items=[], families=['text', 'image', 'audio', 'video'],
                           threshold=0.9, exact_duplicates=True, data_dir=str(run / 'index'), model_dir=str(models),
                           temp_dir=str(run / 'temp'), report_path=str(run / 'report/report.json'),
                           runtime=dict(worker_path=str(resources / 'filetwin-worker'), ffmpeg_path='/opt/homebrew/bin/ffmpeg',
                                        ffprobe_path='/opt/homebrew/bin/ffprobe', onnxruntime_path=str(models / 'runtime/libonnxruntime.dylib'),
                                        pdfium_path=str(models / 'runtime/libpdfium.dylib')),
                           resources=dict(workers=workers, memory_bytes=memory_gb * 1024**3, batch_files=128, batch_bytes=4 * 1024**3))
            request_path = run / 'request.json'
            request_path.write_text(json.dumps(request))
            peaks = dict(active=0, fetching=0, reading=0, encoding=0, waiting_memory=0, waiting_reuse=0)
            rss_kib = 0
            started = time.monotonic()
            with (run / 'stderr.log').open('w') as errors:
                process = subprocess.Popen([str(resources / 'pikpak'), 'similarity-scan', '--request-file', str(request_path)],
                                           cwd=run, env=environment, stdout=subprocess.PIPE, stderr=errors, text=True)
                def receive():
                    for line in process.stdout:
                        event = json.loads(line)
                        if event.get('event') != 'progress':
                            continue
                        peaks['active'] = max(peaks['active'], event.get('active', 0))
                        work = event.get('work', {})
                        for key in peaks.keys() - {'active'}:
                            peaks[key] = max(peaks[key], work.get(key, 0))
                reader = threading.Thread(target=receive)
                reader.start()
                try:
                    while process.poll() is None:
                        if time.monotonic() - started > 120:
                            process.terminate()
                            raise TimeoutError('Benchmark exceeded two minutes')
                        rows = [tuple(map(int, row.split())) for row in subprocess.check_output(
                            ['/bin/ps', '-axo', 'pid=,ppid=,rss='], text=True).splitlines() if row.strip()]
                        children = {process.pid}
                        while True:
                            expanded = children | {pid for pid, parent, _ in rows if parent in children}
                            if expanded == children:
                                break
                            children = expanded
                        rss_kib = max(rss_kib, sum(rss for pid, _, rss in rows if pid in children))
                        time.sleep(0.05)
                    assert process.returncode == 0, (run / 'stderr.log').read_text()
                finally:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=10)
                    reader.join(timeout=10)
            elapsed = time.monotonic() - started
            report = json.loads(Path(request['report_path']).read_text())
            assert report['analysed_files'] == total - 4 and report['failed_files'] == 0, report['issues']
            assert report['unsupported_files'] == 4
            assert peaks['active'] <= workers
            # Short phases may finish between the 100 ms progress samples.
            assert peaks['active'] > 1 and peaks['encoding'] > 1, peaks
            assert not list(Path(request['temp_dir']).iterdir()), 'Temporary originals remain'
            result = dict(workers=workers, memory_allowance_gb=memory_gb, files=total, seconds=round(elapsed, 2),
                          files_per_second=round(total / elapsed, 2), peak_process_tree_rss_gb=round(rss_kib / 1024**2, 2),
                          phase_peaks=peaks, analysed=report['analysed_files'], unsupported=report['unsupported_files'], failed=report['failed_files'])
            results.append(result)
            print(json.dumps(result), flush=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(dict(note='Synthetic workload; process-tree RSS sums shared pages and is not physical-memory usage.', results=results), indent=2) + '\n')


if __name__ == '__main__':
    main()
