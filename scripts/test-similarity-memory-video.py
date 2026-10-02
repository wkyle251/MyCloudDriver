#!/usr/bin/env python3
"""Exercise FFmpeg seeks and completed-result reuse through the app's RAM reader."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import tempfile
import time


def pad_before_index(source, destination):
    # Put a legal, large free box before the trailing MP4 index. The initial
    # HTTP response then cannot fit in a socket buffer; FFmpeg must seek while
    # retaining its previous response. Media offsets stay unchanged.
    data = source.read_bytes()
    offset = 0
    while offset < len(data):
        size, kind = struct.unpack_from('>I4s', data, offset)
        assert 8 <= size <= len(data) - offset
        if kind == b'moov':
            assert offset + size == len(data), 'Fixture index must be the last box'
            padding = 16 * 1024 * 1024
            destination.write_bytes(data[:offset] + struct.pack('>I4s', padding, b'free')
                                    + bytes(padding - 8) + data[offset:])
            return
        offset += size
    raise AssertionError('Fixture has no MP4 index')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', type=Path, required=True)
    args = parser.parse_args()
    resources = args.resources.resolve()
    ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
    ffprobe = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'
    with tempfile.TemporaryDirectory(prefix='mycloud-memory-video-') as temporary:
        root = Path(temporary).resolve()
        inputs = root / 'inputs'
        inputs.mkdir()
        for name, duration in [('short', 4), ('long', 64)]:
            source = inputs / f'{name}.mp4'
            subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-f', 'lavfi', '-i',
                            'testsrc2=size=160x120:rate=4', '-t', str(duration),
                            '-c:v', 'libx264', '-threads', '1', '-preset', 'ultrafast',
                            '-pix_fmt', 'yuv420p', str(source)], check=True, timeout=30)
            pad_before_index(source, inputs / f'{name}-padded.mp4')
        models = resources / 'FileTwinModels'
        request = dict(source='local', local_paths=[str(inputs)], cloud_items=[], families=['video'],
                       threshold=0.05, exact_duplicates=True, include_hidden=False,
                       data_dir=str(root / 'index'), model_dir=str(models), temp_dir=str(root / 'temp'),
                       report_path=str(root / 'report.json'),
                       resources=dict(memory_scheduling=True, workers=2, memory_bytes=2 << 30,
                                      download_memory_bytes=256 << 20, acceleration='cpu'),
                       runtime=dict(worker_path=str(resources / 'filetwin-worker'),
                                    ffmpeg_path=ffmpeg, ffprobe_path=ffprobe,
                                    onnxruntime_path=str(models / 'runtime/libonnxruntime.dylib'),
                                    pdfium_path=str(models / 'runtime/libpdfium.dylib')))
        request_file = root / 'request.json'
        request_file.write_text(json.dumps(request))
        environment = {k: v for k, v in os.environ.items() if not k.startswith('PIKPAK_')}

        def scan():
            result = subprocess.run([str(resources / 'pikpak'), 'similarity-scan', '--request-file',
                                     str(request_file)], env=environment, cwd=root,
                                    capture_output=True, text=True, timeout=120)
            assert result.returncode == 0, result.stderr
            events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            assert events[-1]['event'] == 'finished'
            report = json.loads((root / 'report.json').read_text())
            assert report['analysed_files'] == 4 and report['skipped_files'] == 0, report['issues']
            assert not any((root / 'temp').iterdir()), 'Processing data survived the scan'
            return report, events

        started = time.monotonic()
        report, _ = scan()
        elapsed = time.monotonic() - started
        with sqlite3.connect(root / 'index/runs' / (report['run_id'] + '.sqlite3')) as db:
            records = db.execute('SELECT ordinal, payload, extraction FROM files').fetchall()
            scores = {(a, b): score for a, b, score in db.execute('SELECT a,b,score FROM scores')}
        files = {json.loads(payload)['name']: (ordinal, json.loads(extraction))
                 for ordinal, payload, extraction in records}
        assert len(files) == 4
        for name, strategy in [('short', 'continuous_midpoint_selection'), ('long', 'sparse_midpoint_seeks')]:
            a, original = files[f'{name}.mp4']
            b, padded = files[f'{name}-padded.mp4']
            for extraction in [original, padded]:
                assert extraction['input_storage'] == 'memory'
                assert extraction['decoder_strategy'] == strategy
            assert original['frames'] == padded['frames'], 'Padding changed the sampled video timeline'
            assert scores[tuple(sorted((a, b)))] > 0.99999, 'RAM seeking changed the video vector'
        _, again = scan()
        counts = next(event['counts'] for event in reversed(again) if event.get('stage') == 'finishing')
        assert counts['cache_hits'] == 4 and counts['vectors_encoded'] == 0
        print(f'PASS: four video analyses in {elapsed:.2f}s; short and long MP4 seeks from RAM, '
              'matching frames/vectors, cleanup and four cached results on repeat')


if __name__ == '__main__':
    main()
