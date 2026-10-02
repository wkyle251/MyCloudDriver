#!/usr/bin/env python3
"""Verify password skipping against a local PikPak fixture with encrypted ZIPs and RARs."""
import argparse
import base64
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import sqlite3
import struct
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlsplit
import zipfile
import zlib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', type=Path, required=True)
    args = parser.parse_args()
    resources = args.resources.resolve()
    with tempfile.TemporaryDirectory(prefix='mycloud-password-test-') as temporary:
        root = Path(temporary).resolve()
        secret = root / 'protected.txt'
        secret.write_bytes(b'Synthetic archive contents.\n' * 160000)
        locked = root / 'locked.zip'
        subprocess.run(['/usr/bin/zip', '-q', '-0', '-j', '-P', 'fixture-password', str(locked), str(secret)], check=True)
        public = root / 'public.txt'
        public.write_bytes(b'Unencrypted first entry.\n' * 180000)
        mixed = root / 'mixed.zip'
        subprocess.run(['/usr/bin/zip', '-q', '-0', '-j', str(mixed), str(public)], check=True)
        secret.write_text('A second entry requiring a password.')
        subprocess.run(['/usr/bin/zip', '-q', '-0', '-j', '-P', 'fixture-password', str(mixed), str(secret)], check=True)
        # A sparse, valid ZIP64 archive reproduces a >4 GiB directory offset
        # with an unencrypted first entry, without allocating/downloading GiBs.
        mixed_bytes = mixed.read_bytes()
        end = mixed_bytes.rfind(b'PK\x05\x06')
        _, _, _, entries, _, directory_bytes, directory_start, _ = struct.unpack_from('<4s4H2IH', mixed_bytes, end)
        def zip64(name, comment=b''):
            path = root / name
            start = 5 << 30
            with path.open('wb') as stream:
                stream.write(mixed_bytes[:directory_start])
                stream.seek(start)
                stream.write(mixed_bytes[directory_start:directory_start + directory_bytes])
                record = stream.tell()
                stream.write(struct.pack('<4sQ2H2I4Q', b'PK\x06\x06', 44, 45, 45, 0, 0,
                    entries, entries, directory_bytes, start))
                stream.write(struct.pack('<4sIQI', b'PK\x06\x07', 0, record, 1))
                stream.write(struct.pack('<4s4H2IH', b'PK\x05\x06', 0, 0, entries, entries,
                    directory_bytes, 0xffffffff, len(comment)))
                stream.write(comment)
            return path
        document = io.BytesIO()
        with zipfile.ZipFile(document, 'w') as archive:
            archive.writestr('[Content_Types].xml', '<Types/>')
            archive.writestr('word/document.xml', '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>A garden with flowers, trees and a pond.</w:t></w:r></w:p></w:body></w:document>')
        plain = document.getvalue()
        bodies = {'new.zip': locked.read_bytes(), 'mixed.zip': mixed.read_bytes(),
                  'no-ranges.zip': locked.read_bytes(), 'invalid-range.zip': locked.read_bytes(),
                  'large.zip': zip64('large.zip'), 'long-comment.zip': zip64('long-comment.zip', b'x' * 65535),
                  'slow.zip': locked.read_bytes(), 'retry.zip': locked.read_bytes(),
                  'plain.docx': plain, 'broken.zip': b'PK\x03\x04' + bytes(100)}
        fixtures = Path(__file__).resolve().parent / 'fixtures/similarity-rar'
        rar = {path.name.removesuffix('.b64'): base64.b64decode(path.read_bytes())
               for path in fixtures.glob('*.rar.b64')}
        assert len(rar) == 6
        bodies.update(rar)
        bodies['volume.part002.RAR'] = rar['rar5-data.rar']
        bodies['volume.r00'] = rar['rar4-data.rar']
        bodies['renamed-rar.zip'] = rar['rar5-header.rar']
        corrupted = bytearray(rar['rar5-data.rar'])
        corrupted[8] ^= 1  # Invalid main-header CRC cannot prove encryption.
        bodies['corrupt.rar'] = bytes(corrupted)

        def vint(value):
            encoded = bytearray()
            while value >= 128:
                encoded.append((value & 127) | 128)
                value >>= 7
            return bytes(encoded + bytes([value]))

        def rar5_header(body):
            header = vint(len(body)) + body
            return struct.pack('<I', zlib.crc32(header)) + header

        # Seek past a large public entry to a later encrypted file header.
        # Both sparse fixtures occupy only a few KiB on disk, including RAR4's
        # split high/low packed sizes and RAR5's variable-length 64-bit sizes.
        for version in (4, 5):
            sample = rar[f'rar{version}-data.rar']
            signature = 7 if version == 4 else 8
            if version == 4:
                main_end = signature + struct.unpack_from('<H', sample, signature + 5)[0]
                main_header = sample[signature:main_end]
                header = bytearray(41)
                struct.pack_into('<BHHII', header, 2, 0x74, 0x8100, len(header), 1 << 30, 1 << 30)
                header[24:28] = bytes([29, 0x30, 1, 0])  # Version, stored method, name length.
                struct.pack_into('<II', header, 32, 1, 1)
                header[40] = ord('x')
                struct.pack_into('<H', header, 0, zlib.crc32(header[2:]) & 0xffff)
                header = bytes(header)
            else:
                # Generated fixture's main header uses a one-byte size.
                assert sample[signature + 4] < 128
                main_end = signature + 5 + sample[signature + 4]
                main_header = rar5_header(bytes([1, 0, 0]))
                header = rar5_header(bytes([2, 2]) + vint(5 << 30)
                    + b'\0' + vint(5 << 30) + bytes([0, 0, 1, 1]) + b'x')
            path = root / f'large-rar{version}.rar'
            with path.open('wb') as stream:
                stream.write(sample[:signature] + main_header + header)
                stream.seek(5 << 30, io.SEEK_CUR)
                stream.write(sample[main_end:])
            bodies[path.name] = path
        protected = set(bodies) - {'plain.docx', 'broken.zip', 'rar5-plain.rar', 'corrupt.rar'}
        excluded = protected | {'rar5-plain.rar', 'corrupt.rar'}
        def size(body):
            return body.stat().st_size if isinstance(body, Path) else len(body)
        revisions = {name: 1 for name in bodies}
        requests, full_gets, range_bytes = Counter(), Counter(), Counter()
        routes = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, body, headers=None):
                self.send_response(status)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Connection', 'close')
                for key, value in (headers or {}).items():
                    self.send_header(key, value)
                self.end_headers()
                try:
                    for offset in range(0, len(body), 65536):
                        self.wfile.write(body[offset:offset + 65536])
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_POST(self):
                routes.append(('POST', self.path))
                self.rfile.read(int(self.headers.get('Content-Length', 0)))
                value = {'access_token': 'fixture-access', 'refresh_token': 'fixture-refresh',
                         'expires_in': 3600, 'sub': 'fixture-user'} if urlsplit(self.path).path.endswith('/auth/token') else {
                             'captcha_token': 'fixture-captcha', 'expires_in': 3600}
                self.reply(200, json.dumps(value).encode(), {'Content-Type': 'application/json'})

            def do_GET(self):
                routes.append(('GET', self.path))
                path = urlsplit(self.path).path
                name = path.rsplit('/', 1)[-1]
                body = bodies[name]
                if not path.startswith('/content/'):
                    self.reply(200, json.dumps({'id': name, 'name': name, 'size': str(size(body)),
                        'hash': f'revision-{revisions[name]}',
                        'web_content_link': f'http://127.0.0.1:{self.server.server_port}/content/{name}'}).encode(),
                        {'Content-Type': 'application/json'})
                    return
                requests[name] += 1
                wanted = self.headers.get('Range')
                headers = {'ETag': f'"revision-{revisions[name]}"'}
                if name == 'slow.zip' and wanted == 'bytes=0-29':
                    time.sleep(6)  # The old five-second probe downloaded it all.
                if name == 'retry.zip' and requests[name] == 1:
                    self.close_connection = True
                    self.connection.close()
                    return
                if not wanted:
                    full_gets[name] += 1
                    if isinstance(body, Path):
                        self.reply(400, b'A protected archive must not be downloaded')
                        return
                    self.reply(200, body, headers)
                elif name == 'no-ranges.zip':
                    self.reply(200, body, headers)
                else:
                    start, end = map(int, wanted.removeprefix('bytes=').split('-'))
                    headers['Content-Range'] = f'bytes {start + (name == "invalid-range.zip")}-{end}/{size(body)}'
                    if isinstance(body, Path):
                        assert 0 <= start <= end < size(body) and end - start < 1 << 20
                        with body.open('rb') as stream:
                            stream.seek(start); payload = stream.read(end - start + 1)
                    else:
                        payload = body[start:end + 1]
                    range_bytes[name] += len(payload)
                    self.reply(206, payload, headers)

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        models = resources / 'FileTwinModels'
        request = dict(source='cloud', local_paths=[], cloud_items=[dict(id=name, name=name, path='/' + name,
            is_folder=False, size=size(body), ancestors=[]) for name, body in bodies.items()],
            families=['text'], threshold=.05, exact_duplicates=True, include_hidden=False,
            data_dir=str(root / 'index'), model_dir=str(models), temp_dir=str(root / 'temp'),
            report_path=str(root / 'report.json'), resources=dict(workers=2, memory_bytes=1 << 30,
            download_memory_bytes=128 << 20, acceleration='cpu'), runtime=dict(
            worker_path=str(resources / 'filetwin-worker'), ffmpeg_path='/opt/homebrew/bin/ffmpeg',
            ffprobe_path='/opt/homebrew/bin/ffprobe', onnxruntime_path=str(models / 'runtime/libonnxruntime.dylib'),
            pdfium_path=str(models / 'runtime/libpdfium.dylib')))
        request_file = root / 'request.json'
        request_file.write_text(json.dumps(request))
        # The shipping CLI deliberately has no API-host override. Link a tiny
        # fixture driver to the same release library so all requests stay local.
        repo = Path(__file__).resolve().parents[1]
        deps = repo / 'target/release/deps'
        source = root / 'driver.rs'
        source.write_text('''
use std::sync::{Arc, atomic::AtomicBool};
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let request = serde_json::from_slice(&std::fs::read(&args[1]).unwrap()).unwrap();
    assert!(args[2].starts_with("http://127.0.0.1:"));
    let client = pikpak::Client::builder().refresh_token("fixture-refresh").device_id("fixture-device")
        .api_base_url(&args[2]).auth_base_url(&args[2]).build().unwrap();
    tokio::runtime::Runtime::new().unwrap().block_on(
        pikpak::similarity::scan(request, Some(&client), Arc::new(AtomicBool::new(false)))).unwrap();
}
''')
        driver = root / 'scan-fixture'
        compile_args = ['rustc', '--edition=2021', '-C', 'lto=thin', '-C', 'opt-level=2',
                        str(source), '-L', f'dependency={deps}',
                        '--extern', f'pikpak={repo / "target/release/libpikpak.rlib"}']
        for crate in ['serde_json', 'tokio']:
            library = max(deps.glob(f'lib{crate}-*.rlib'), key=lambda p: p.stat().st_mtime)
            compile_args += ['--extern', f'{crate}={library}']
        subprocess.run(compile_args + ['-o', str(driver)], check=True)
        environment = {k: v for k, v in os.environ.items() if not k.startswith('PIKPAK_')}

        def scan():
            result = subprocess.run([str(driver), str(request_file), f'http://127.0.0.1:{server.server_port}'],
                cwd=root, env=environment, capture_output=True, text=True, timeout=60)
            assert result.returncode == 0, result.stderr
            report = json.loads((root / 'report.json').read_text())
            assert not any((root / 'temp').iterdir())
            return report

        try:
            first = scan()
            assert first['analysed_files'] == 1 and first['unsupported_files'] == len(excluded) and first['failed_files'] == 1, (first['issues'], routes)
            assert all(full_gets[name] == 0 for name in protected - {'invalid-range.zip'}), full_gets
            assert full_gets['invalid-range.zip'] == 1, 'Malformed ranges must not prove encryption'
            assert all(full_gets[name] == 1 for name in ['rar5-plain.rar', 'corrupt.rar']), full_gets
            assert all(range_bytes[f'large-rar{version}.rar'] < 8192 for version in (4, 5)), range_bytes
            assert first['downloaded_bytes'] < 6 << 20, first['downloaded_bytes']
            with sqlite3.connect(root / 'index/filetwin-sources.sqlite3') as db:
                assert db.execute("SELECT count(*) FROM outcomes WHERE reader='password-v1'").fetchone()[0] == len(protected)
            previous = requests.copy()
            second = scan()
            assert second['failed_files'] == 1 and second['unsupported_files'] == len(excluded)
            assert all(requests[name] == previous[name] for name in bodies if name != 'broken.zip'), (previous, requests)
            assert requests['broken.zip'] > previous['broken.zip'], 'Decode failures must remain retryable'
            bodies['new.zip'] = plain
            revisions['new.zip'] += 1
            third = scan()
            assert third['analysed_files'] == 2 and third['unsupported_files'] == len(excluded) - 1 and third['failed_files'] == 1, third['issues']
            assert full_gets['new.zip'] == 1, 'A changed/decrypted source must be rechecked'
            print('PASS: new and mixed encrypted ZIPs skipped before full download; ignored and malformed ranges handled')
            print('PASS: ZIP64 >4 GiB, unencrypted first entries, long comments, slow checks and connection retries skip before full download')
            print('PASS: encrypted RAR4/RAR5 data and filenames, mixed entries, multipart names and disguised ZIP names skip before full download')
            print('PASS: RAR4 and RAR5 seek over 5 GiB public members using less than 8 KiB of header reads; plain and corrupt RARs are not password exclusions')
            print(f'PASS: {len(protected)} password exclusions cached; zero content GETs on repeat; changed files rechecked and decode errors retried')
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
