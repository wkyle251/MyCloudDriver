#!/usr/bin/env python3
"""Exercise real torrent metadata, selective download and restart on loopback.

All bytes are generated fixtures. No public tracker, DHT, PEX or torrent is used.
Pass a native test executable built from scripts/LocalTorrentTests.swift.
"""
import argparse
import plistlib
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import signal
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parent.parent


def bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, str):
        value = value.encode()
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    return b"d" + b"".join(bencode(key) + bencode(value[key]) for key in sorted(value)) + b"e"


def bdecode(data):
    def read(offset):
        token = data[offset:offset + 1]
        if token == b"i":
            end = data.index(b"e", offset)
            return int(data[offset + 1:end]), end + 1
        if token in (b"l", b"d"):
            values, offset = [], offset + 1
            while data[offset:offset + 1] != b"e":
                value, offset = read(offset)
                values.append(value)
            return (dict(zip(values[::2], values[1::2])) if token == b"d" else values), offset + 1
        end = data.index(b":", offset)
        length = int(data[offset:end])
        return data[end + 1:end + 1 + length], end + 1 + length
    value, offset = read(0)
    if offset != len(data):
        raise ValueError("Trailing bencoded data")
    return value


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def release_fixture_ram(root):
    """Release only RAM devices created inside this invocation's private root."""
    for record in (root / "RAMQueue").glob("*/ram-volume.json"):
        volume = json.loads(record.read_text())
        mount = Path(volume["mount"])
        if not mount.is_relative_to(root) or not volume["image"].startswith("ram://"):
            continue
        marker = mount / ".mycloud-owner"
        if not marker.exists() or marker.read_text() != volume["owner"]:
            continue
        result = subprocess.run(["/usr/sbin/diskutil", "info", "-plist", str(mount)], capture_output=True)
        if result.returncode:
            continue
        info = plistlib.loads(result.stdout)
        if info.get("VolumeUUID") != volume["uuid"] or info.get("DeviceNode") != volume["volumeDevice"]:
            continue
        images = subprocess.run(["/usr/bin/hdiutil", "info", "-plist"], capture_output=True, check=True)
        owned = any(image.get("image-path") == volume["image"] and
                    any(entity.get("dev-entry") == volume["device"] for entity in image.get("system-entities", []))
                    for image in plistlib.loads(images.stdout).get("images", []))
        if owned:
            subprocess.run(["/usr/bin/hdiutil", "detach", volume["device"]], check=True, stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("test_executable", type=Path)
    parser.add_argument("--ram", action="store_true", help="Exercise RAM to PikPak relay with a synthetic upload sink")
    parser.add_argument("--storage", action="store_true", help="Move a partial RAM relay to storage, relaunch and verify upload cleanup")
    parser.add_argument("--upload-outage", action="store_true", help="Keep the upload sink offline until real peers finish downloading to storage")
    parser.add_argument("--rolling", action="store_true", help="Relay generated files larger than the RAM buffer")
    parser.add_argument("--reconnect", action="store_true", help="Disconnect and restart the only seeder twice; require automatic relay recovery")
    parser.add_argument("--grow", action="store_true", help="Grow a live aria2 file selection mid-download")
    parser.add_argument("--dht", action="store_true", help="Discover a trackerless magnet through a loopback DHT bootstrap node and an empty cache")
    parser.add_argument("--engine", type=Path, default=ROOT / ".build/torrent-engine/runtime/bin/aria2c")
    parser.add_argument("--seed-engine", type=Path, default=ROOT / ".build/torrent-engine/runtime/bin/aria2c",
                        help="Independent aria2 seeder when testing the libtorrent app backend")
    args = parser.parse_args()
    if args.upload_outage:
        args.storage = True
    if args.reconnect and (args.rolling or args.storage or args.grow or args.dht):
        parser.error("--reconnect is a separate scenario")
    if args.rolling or args.storage or args.reconnect:
        args.ram = True
    if args.ram and args.dht:
        parser.error("--ram and --dht are separate scenarios")
    root = Path(tempfile.mkdtemp(prefix="mycloud-torrent-loopback-"))
    seed_port, leecher_port = unused_port(), unused_port()
    while seed_port == leecher_port:
        leecher_port = unused_port()
    class Tracker(BaseHTTPRequestHandler):
        def do_GET(self):
            # The fixture advertises only the local seeder; it stores no clients.
            payload = bencode({"interval": 2, "complete": 1, "incomplete": 1,
                               "peers": socket.inet_aton("127.0.0.1") + struct.pack("!H", seed_port)})
            self.send_response(200)
            self.send_header("Content-Type", "application/x-bittorrent")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_):
            pass

    tracker = ThreadingHTTPServer(("127.0.0.1", 0), Tracker)
    threading.Thread(target=tracker.serve_forever, daemon=True).start()
    announce = f"http://127.0.0.1:{tracker.server_port}/announce"
    seed = root / "Seed/FixtureFiles"
    seed.mkdir(parents=True)
    files = [("keep.bin", bytes(range(256)) * 8192 + b"local-fixture-end"),
             ("skip.bin", b"skip-this-file" * 4682),
             ("note.txt", b"Owned local fixture for MyCloudDriver torrent tests.\n")]
    if args.rolling or args.storage:
        files = [(f"rolling-{index}.bin", bytes([index]) * (100 * 1024 * 1024 + 13)) for index in range(1, 4)]
    if args.reconnect:
        files = [("reconnect.bin", bytes(range(256)) * 65536 + b"reconnect-end")]
    for name, content in files:
        (seed / name).write_bytes(content)
    payload = b"".join(content for _, content in files)
    piece = 16 * 1024
    info = {"name": "FixtureFiles", "piece length": piece, "private": 1,
            "pieces": b"".join(hashlib.sha1(payload[index:index + piece]).digest() for index in range(0, len(payload), piece)),
            "files": [{"length": len(content), "path": [name]} for name, content in files]}
    if args.dht:
        del info["private"]
    info_hash = hashlib.sha1(bencode(info)).digest()
    torrent = root / "fixture.torrent"
    torrent.write_bytes(bencode({"info": info} if args.dht else {"announce": announce, "info": info}))
    magnet = "magnet:?xt=urn:btih:" + info_hash.hex() + "&dn=FixtureFiles"
    if not args.dht:
        magnet += "&tr=" + urllib.parse.quote(announce, safe="")
    dht = None
    queries = set()
    fixture_config = {"engine": str(args.engine.resolve()), "magnet": magnet, "leecher_port": leecher_port, "rolling": args.rolling, "storage": args.storage, "upload_outage": args.upload_outage}
    if args.dht:
        node_id = hashlib.sha1(b"MyCloudDriver local DHT fixture").digest()
        class DHT(socketserver.BaseRequestHandler):
            def handle(self):
                data, sock = self.request
                request = bdecode(data)
                if request.get(b"y") != b"q":
                    return
                method = request.get(b"q")
                queries.add(method)
                result = {b"id": node_id}
                if method == b"find_node":
                    result[b"nodes"] = node_id + socket.inet_aton("127.0.0.1") + struct.pack("!H", self.server.server_address[1])
                elif method == b"get_peers":
                    result[b"token"] = b"fixture-token"
                    if request[b"a"][b"info_hash"] == info_hash:
                        result[b"values"] = [socket.inet_aton("127.0.0.1") + struct.pack("!H", seed_port)]
                    else:
                        result[b"nodes"] = b""
                sock.sendto(bencode({b"t": request[b"t"], b"y": b"r", b"r": result}), self.client_address)
        dht = socketserver.UDPServer(("127.0.0.1", 0), DHT)
        threading.Thread(target=dht.serve_forever, daemon=True).start()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind(("127.0.0.1", 0))
            fixture_config["dht_port"] = sock.getsockname()[1]
        fixture_config["dht_bootstrap"] = "127.0.0.1:" + str(dht.server_address[1])
    config = root / "fixture.json"
    config.write_text(json.dumps(fixture_config))
    seeder = None
    test_process = None
    def stop_seeder():
        nonlocal seeder
        if seeder and seeder.poll() is None:
            seeder.send_signal(signal.SIGINT)
            try:
                seeder.wait(timeout=5)
            except subprocess.TimeoutExpired:
                seeder.kill()
                seeder.wait()
        seeder = None

    try:
        with (root / "seeder.log").open("w") as output:
            seed_command = [str(args.seed_engine.resolve()), "--no-conf=true", "--enable-dht=false", "--enable-dht6=false",
                "--enable-peer-exchange=false", "--bt-enable-lpd=false", "--interface=127.0.0.1",
                "--check-integrity=true", "--seed-time=10", "--seed-ratio=100",
                "--max-overall-upload-limit=16M" if args.rolling else "--max-overall-upload-limit=4M", "--bt-tracker-interval=2", "--summary-interval=0",
                f"--listen-port={seed_port}", f"--dir={root / 'Seed'}", str(torrent)]
            def start_seeder():
                nonlocal seeder
                seeder = subprocess.Popen(seed_command, env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"},
                                          stdout=output, stderr=subprocess.STDOUT)
                deadline = time.monotonic() + 15
                while True:
                    if seeder.poll() is not None:
                        raise RuntimeError("Fixture seeder exited; see " + str(root / "seeder.log"))
                    try:
                        with socket.create_connection(("127.0.0.1", seed_port), timeout=0.2):
                            return
                    except OSError:
                        if time.monotonic() > deadline:
                            raise RuntimeError("Fixture seeder did not listen")
                        time.sleep(0.1)
            start_seeder()
            print("Loopback fixture artifacts: " + str(root), flush=True)
            mode = "--reconnect-fixture" if args.reconnect else "--relay-fixture" if args.ram else "--grow-fixture" if args.grow else "--fixture"
            test_command = [str(args.test_executable.resolve()), mode, str(config)]
            if args.reconnect:
                test_process = subprocess.Popen(test_command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                timeout = threading.Timer(300, test_process.kill)
                timeout.daemon = True
                timeout.start()
                events = []
                try:
                    for line in test_process.stdout:
                        print(line, end="", flush=True)
                        event = line.strip()
                        for cycle in (1, 2):
                            if event == f"FIXTURE disconnect seeder {cycle}":
                                stop_seeder()
                                (root / f"seeder-disconnected-{cycle}").touch()
                                events.append(event)
                            elif event == f"FIXTURE reconnect seeder {cycle}":
                                start_seeder()
                                (root / f"seeder-reconnected-{cycle}").touch()
                                events.append(event)
                    code = test_process.wait()
                    if code:
                        raise subprocess.CalledProcessError(code, test_command)
                    assert len(events) == 4, "The fixture must actually disconnect and restart its seeder twice"
                finally:
                    timeout.cancel()
                    test_process.stdout.close()
            else:
                subprocess.run(test_command, check=True, timeout=150)
            if args.dht:
                assert {b"ping", b"find_node", b"get_peers"}.issubset(queries), queries
                print("PASS: empty-cache DHT bootstrap found a seed and fetched a trackerless magnet with no public network requests.", flush=True)
    finally:
        if test_process and test_process.poll() is None:
            test_process.kill()
            test_process.wait()
        stop_seeder()
        if args.ram:
            release_fixture_ram(root)
        tracker.shutdown()
        tracker.server_close()
        if dht:
            dht.shutdown()
            dht.server_close()


if __name__ == "__main__":
    main()
