#!/usr/bin/env python3
"""Generated cloud videos: seek original ranges and preserve the full-input vector."""
import argparse
import json
import os
import sys
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit



def linked_dependencies(repo, library, deps, args):
    explicit = {'serde_json': args.serde_json, 'tokio': args.tokio}
    if any(explicit.values()):
        if not all(explicit.values()):
            raise ValueError('Provide both --serde-json and --tokio for explicit fixture linkage')
        result = {crate: path.resolve() for crate, path in explicit.items()}
        if not all(path.is_file() for path in result.values()):
            raise ValueError('An explicit fixture dependency does not exist')
        return result
    if args.library is not None or args.deps is not None:
        raise ValueError('Custom --library/--deps require --serde-json and --tokio from that Cargo build')
    # A filename glob, version or modification time cannot identify Cargo's
    # unified feature graph. Ask the same release build that produced pikpak
    # for its exact artifacts, including when everything is already cached.
    build = subprocess.run(
        [sys.executable, str(repo / 'scripts/with-client-credentials.py'),
         'cargo', 'build', '--release', '--locked', '--offline', '--message-format=json'],
        cwd=repo, capture_output=True, text=True, timeout=600)
    if build.returncode != 0:
        raise RuntimeError('Cargo could not resolve the release fixture artifacts')
    artifacts = []
    for line in build.stdout.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get('reason') == 'compiler-artifact':
            artifacts.append(event)
    selected = [event for event in artifacts
                if event['target']['name'] == 'pikpak' and 'lib' in event['target']['kind']
                and library in [Path(name).resolve() for name in event['filenames']]]
    if len(selected) != 1:
        raise RuntimeError('Cargo did not identify the selected pikpak release library')
    profile = selected[0]['profile']
    result = {}
    for crate in explicit:
        candidates = {Path(name).resolve() for event in artifacts
                      if event['target']['name'] == crate and 'lib' in event['target']['kind']
                      and event['profile'] == profile
                      for name in event['filenames'] if name.endswith('.rlib')
                      and Path(name).resolve().parent == deps}
        if len(candidates) != 1:
            raise RuntimeError(f'Cargo linkage for {crate} is ambiguous; provide --serde-json and --tokio explicitly')
        result[crate] = candidates.pop()
    return result


def padded(source, destination, padding):
    data = source.read_bytes()
    offset = 0
    while offset < len(data):
        size, kind = struct.unpack_from('>I4s', data, offset)
        assert 8 <= size <= len(data) - offset
        if kind == b'moov':
            assert offset + size == len(data)
            with destination.open('wb') as output:
                output.write(data[:offset])
                output.write(struct.pack('>I4s', padding, b'free'))
                output.seek(padding - 8, 1)  # Generated sparse padding, no user files.
                output.write(data[offset:])
            return
        offset += size
    raise AssertionError('Generated MP4 has no trailing index')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--worker', type=Path)
    parser.add_argument('--library', type=Path)
    parser.add_argument('--deps', type=Path)
    parser.add_argument('--serde-json', type=Path, help='Exact serde_json rlib for a custom --library build')
    parser.add_argument('--tokio', type=Path, help='Exact tokio rlib for a custom --library build')
    parser.add_argument('--pause-seconds', type=float, default=0)
    args = parser.parse_args()
    resources = args.resources.resolve()
    repo = Path(__file__).resolve().parents[1]
    library = (args.library or repo / 'target/release/libpikpak.rlib').resolve()
    deps = (args.deps or library.parent / 'deps').resolve()
    worker = (args.worker or resources / 'filetwin-worker').resolve()
    linked = linked_dependencies(repo, library, deps, args)
    ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
    ffprobe = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'
    with tempfile.TemporaryDirectory(prefix='mycloud-generated-cloud-video-') as temporary:
        root = Path(temporary).resolve()
        reference = root / 'reference.bin'
        source = root / 'source.mp4'
        ranged = root / 'ranged.mp4'
        subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-f', 'lavfi', '-i',
                        'testsrc2=size=160x120:rate=4', '-t', '64', '-c:v', 'libx264',
                        '-threads', '1', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
                        str(source)], check=True, timeout=30)
        shutil.copyfile(source, reference)
        padded(source, ranged, 512 << 20)
        originals = {'reference.bin': reference, 'ranged.mp4': ranged}
        hashes = {'reference.bin': '1' * 40, 'ranged.mp4': '2' * 40}
        lock = threading.Lock()
        wire = {name: 0 for name in originals}
        full = {name: 0 for name in originals}
        ranges = {name: 0 for name in originals}
        pause_started = False
        checkpoint = '12345678-1234-1234-1234-123456789abc'

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def reply(self, status, body, headers=None):
                self.send_response(status)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Connection', 'close')
                for key, value in (headers or {}).items():
                    self.send_header(key, value)
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_GET(self):
                nonlocal pause_started
                path = urlsplit(self.path).path
                if path.startswith('/drive/v1/files/'):
                    name = path.rsplit('/', 1)[1]
                    original = originals[name]
                    body = dict(id=name, name=name, kind='drive#file', size=str(original.stat().st_size),
                                hash=hashes[name], web_content_link=f'http://127.0.0.1:{self.server.server_port}/body/{name}')
                    self.reply(200, json.dumps(body).encode())
                elif path.startswith('/body/'):
                    assert 'Authorization' not in self.headers
                    name = path.rsplit('/', 1)[1]
                    original = originals[name]
                    size = original.stat().st_size
                    wanted = self.headers.get('Range')
                    headers = {'ETag': f'"{hashes[name]}"', 'Accept-Ranges': 'bytes'}
                    if wanted:
                        start, end = map(int, wanted.removeprefix('bytes=').split('-'))
                        assert 0 <= start <= end < size and end - start < 1 << 20
                        headers['Content-Range'] = f'bytes {start}-{end}/{size}'
                        if name == 'ranged.mp4' and start > 0 and args.pause_seconds > 0:
                            with lock:
                                start_pause = not pause_started
                                pause_started = True
                            if start_pause:
                                marker = root / 'index/checkpoints' / checkpoint / 'pause'
                                marker.write_bytes(b'')
                                def resume():
                                    time.sleep(args.pause_seconds)
                                    marker.unlink(missing_ok=True)
                                threading.Thread(target=resume, daemon=True).start()
                                time.sleep(.15)
                        with original.open('rb') as stream:
                            stream.seek(start)
                            body = stream.read(end - start + 1)
                        with lock:
                            ranges[name] += 1
                            wire[name] += len(body)
                        self.reply(206, body, headers)
                    else:
                        with lock:
                            full[name] += 1
                            wire[name] += size
                        assert size < 16 << 20, 'A ranged original was downloaded completely'
                        self.reply(200, original.read_bytes(), headers)
                elif path == '/v1/user/me':
                    self.reply(200, b'{"sub":"generated-account"}')
                else:
                    self.reply(404, b'generated route absent')

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        models = resources / 'FileTwinModels'
        request = dict(checkpoint_id=checkpoint, source='cloud', local_paths=[], cloud_items=[
            dict(id=name, name=name, path='/' + name, is_folder=False,
                 size=path.stat().st_size, ancestors=[], revision=hashes[name])
            for name, path in originals.items()], families=['video'], threshold=.05,
            exact_duplicates=True, include_hidden=False, data_dir=str(root / 'index'),
            model_dir=str(models), temp_dir=str(root / 'temp'), report_path=str(root / 'report.json'),
            resources=dict(automatic_memory=True, workers=2, acceleration='cpu'),
            runtime=dict(worker_path=str(worker), ffmpeg_path=ffmpeg, ffprobe_path=ffprobe,
                         onnxruntime_path=str(models / 'runtime/libonnxruntime.dylib'),
                         pdfium_path=str(models / 'runtime/libpdfium.dylib')))
        request_file = root / 'request.json'
        request_file.write_text(json.dumps(request))
        rust = root / 'driver.rs'
        rust.write_text('''
use std::sync::{Arc, atomic::AtomicBool};
fn main() {
 let args: Vec<String> = std::env::args().collect();
 let data=std::fs::read(&args[2]).unwrap();
 if args[1]=="scores" {
  let result=pikpak::similarity::score_row(serde_json::from_slice(&data).unwrap(), &AtomicBool::new(false)).unwrap();
  println!("{}",result); return;
 }
 assert!(args[3].starts_with("http://127.0.0.1:"));
 let client=pikpak::Client::builder().personal_access_token("generated-token").device_id("generated-device")
  .api_base_url(&args[3]).auth_base_url(&args[3]).build().unwrap();
 tokio::runtime::Runtime::new().unwrap().block_on(pikpak::similarity::scan(
  serde_json::from_slice(&data).unwrap(),Some(&client),Arc::new(AtomicBool::new(false)))).unwrap();
}
''')
        driver = root / 'driver'
        compile_args = ['rustc', '--edition=2021', '-C', 'lto=thin', '-C', 'opt-level=2', str(rust), '-L', f'dependency={deps}',
                        '--extern', f'pikpak={library}']
        for crate, compiled in linked.items():
            compile_args += ['--extern', f'{crate}={compiled}']
        subprocess.run(compile_args + ['-o', str(driver)], check=True, timeout=120)
        environment = {k: v for k, v in os.environ.items() if not k.startswith('PIKPAK_')}
        try:
            result = subprocess.run([str(driver), 'scan', str(request_file), f'http://127.0.0.1:{server.server_port}'],
                                    cwd=root, env=environment, capture_output=True, text=True, timeout=240)
            assert result.returncode == 0, result.stderr
            report = json.loads((root / 'report.json').read_text())
            assert report['analysed_files'] == 2 and report['failed_files'] == 0, report['issues']
            assert full['ranged.mp4'] == 0 and ranges['ranged.mp4'] > 0
            assert args.pause_seconds == 0 or pause_started, 'Long pause was not exercised'
            assert wire['ranged.mp4'] < 32 << 20, wire
            assert full['reference.bin'] == 1
            score_request = dict(data_dir=str(root / 'index'), run_id=report['run_id'],
                                 result_revision=report['result_revision'], file_id=report['files'][0]['id'], row_offset=0)
            score_file = root / 'scores.json'
            score_file.write_text(json.dumps(score_request))
            scores = subprocess.run([str(driver), 'scores', str(score_file)], cwd=root, env=environment,
                                    capture_output=True, text=True, check=True, timeout=30)
            scores = json.loads(scores.stdout)
            assert len(scores['entries']) == 1 and scores['entries'][0]['score'] > .999999, scores
            assert not any((root / 'temp').iterdir()), 'Original RAM transport left temporary content'
            print(json.dumps(dict(pass_=True, ranged_original_bytes=ranged.stat().st_size,
                                  ranged_wire_bytes=wire['ranged.mp4'], ranged_requests=ranges['ranged.mp4'],
                                  full_reference_bytes=wire['reference.bin'], score=scores['entries'][0]['score'],
                                  pause_seconds=args.pause_seconds)))
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
