#!/usr/bin/env python3
"""Verify encrypted BitTorrent interoperability and peer status on loopback.

The independent Python peer uses integer modular exponentiation, SHA-1 and RC4
to negotiate MSE. Using two copies of aria2's internal DH implementation would
miss its nonstandard math because both ends make the same mistake. All payloads
are generated; no public peers, trackers, account or saved queue are accessed.
"""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time
import urllib.request
import urllib.error


ROOT = Path(__file__).resolve().parent.parent
PRIME = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA6"
    "3B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
    "E485B576625E7EC6F44C42E9A63A36210000000000090563", 16)


def bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    return b"d" + b"".join(bencode(k) + bencode(value[k]) for k in sorted(value)) + b"e"


class RC4:
    def __init__(self, key):
        self.state = list(range(256))
        j = 0
        for i in range(256):
            j = (j + self.state[i] + key[i % len(key)]) & 255
            self.state[i], self.state[j] = self.state[j], self.state[i]
        self.i = self.j = 0
        self.crypt(bytes(1024))  # MSE discards the initial keystream.

    def crypt(self, data):
        result = bytearray()
        for byte in data:
            self.i = (self.i + 1) & 255
            self.j = (self.j + self.state[self.i]) & 255
            self.state[self.i], self.state[self.j] = self.state[self.j], self.state[self.i]
            result.append(byte ^ self.state[(self.state[self.i] + self.state[self.j]) & 255])
        return bytes(result)


def receive(sock, length):
    result = bytearray()
    while len(result) < length:
        chunk = sock.recv(length - len(result))
        if not chunk:
            raise EOFError("Peer closed the encrypted fixture connection")
        result.extend(chunk)
    return bytes(result)


def wait_for(test, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = test()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("Timed out waiting for the encrypted fixture")


def unused_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, default=ROOT / ".build/torrent-engine/runtime/bin/aria2c")
    args = parser.parse_args()
    payload = os.urandom(2 * 1024 * 1024)
    piece_length = 64 * 1024
    info = {b"name": b"fixture.bin", b"length": len(payload), b"piece length": piece_length,
            b"pieces": b"".join(hashlib.sha1(payload[i:i + piece_length]).digest()
                                 for i in range(0, len(payload), piece_length)), b"private": 1}
    info_hash = hashlib.sha1(bencode(info)).digest()
    listener = socket.create_server(("127.0.0.1", 0))
    listener.settimeout(10)
    port = listener.getsockname()[1]
    pending, allow_handshake, allow_pieces = (threading.Event() for _ in range(3))
    errors = []

    def seed():
        try:
            with listener.accept()[0] as sock:
                sock.settimeout(8)
                public = int.from_bytes(receive(sock, 96), "big")
                assert 1 < public < PRIME - 1, "Invalid Diffie-Hellman public key"
                private = secrets.randbits(160) | 1
                secret = pow(public, private, PRIME).to_bytes(96, "big")
                sock.sendall(pow(2, private, PRIME).to_bytes(96, "big"))
                marker = hashlib.sha1(b"req1" + secret).digest()
                window = bytearray()
                for _ in range(512 + 20):
                    window.extend(receive(sock, 1))
                    if window[-20:] == marker:
                        break
                else:
                    raise AssertionError("Encrypted handshake did not agree on the DH secret")
                expected = bytes(a ^ b for a, b in zip(hashlib.sha1(b"req2" + info_hash).digest(),
                                                      hashlib.sha1(b"req3" + secret).digest()))
                assert receive(sock, 20) == expected, "Wrong encrypted torrent identity"
                incoming = RC4(hashlib.sha1(b"keyA" + secret + info_hash).digest())
                outgoing = RC4(hashlib.sha1(b"keyB" + secret + info_hash).digest())
                header = incoming.crypt(receive(sock, 14))
                assert header[:8] == bytes(8), "Wrong MSE verification constant"
                assert struct.unpack("!I", header[8:12])[0] & 2, "ARC4 was not offered"
                padding = struct.unpack("!H", header[12:14])[0]
                assert padding <= 512
                incoming.crypt(receive(sock, padding))
                initial_length = struct.unpack("!H", incoming.crypt(receive(sock, 2)))[0]
                assert initial_length <= 68
                initial = incoming.crypt(receive(sock, initial_length))
                sock.sendall(outgoing.crypt(bytes(8) + struct.pack("!IH", 2, 0)))
                handshake = initial + incoming.crypt(receive(sock, 68 - len(initial)))
                assert handshake[:20] == b"\x13BitTorrent protocol" and handshake[28:48] == info_hash
                pending.set()
                assert allow_handshake.wait(10), "Pending peer was not observed"
                sock.sendall(outgoing.crypt(b"\x13BitTorrent protocol" + bytes(8) + info_hash + b"-MCTEST-0123456789ab"))
                assert allow_pieces.wait(10), "Completed handshake was not observed"

                def send_message(kind, body=b""):
                    sock.sendall(outgoing.crypt(struct.pack("!IB", len(body) + 1, kind) + body))

                send_message(5, bytes([255]) * (len(payload) // piece_length // 8))
                send_message(1)  # Unchoke.
                sent = set()
                while len(sent) < len(payload) // 16384:
                    length = struct.unpack("!I", incoming.crypt(receive(sock, 4)))[0]
                    assert length <= 64 * 1024
                    if not length:
                        continue
                    message = incoming.crypt(receive(sock, length))
                    if message[0] != 6:
                        continue
                    index, begin, count = struct.unpack("!III", message[1:])
                    offset = index * piece_length + begin
                    assert 0 < count <= 16384 and begin + count <= piece_length and offset + count <= len(payload)
                    send_message(7, struct.pack("!II", index, begin) + payload[offset:offset + count])
                    sent.add((offset, count))
        except Exception as error:
            errors.append(error)
            pending.set()

    class Tracker(BaseHTTPRequestHandler):
        def do_GET(self):
            # The tracker intentionally supplies no peers. Restore a known
            # endpoint via the same bounded RPC used by the app's peer cache.
            body = bencode({b"interval": 5, b"complete": 0, b"incomplete": 1, b"peers": b""})
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    tracker = ThreadingHTTPServer(("127.0.0.1", 0), Tracker)
    threading.Thread(target=tracker.serve_forever, daemon=True).start()
    peer_thread = threading.Thread(target=seed, daemon=True)
    peer_thread.start()
    metadata = bencode({b"info": info, b"announce": f"http://127.0.0.1:{tracker.server_port}/announce".encode()})
    try:
        with tempfile.TemporaryDirectory(prefix="mycloud-encrypted-peer-") as temporary:
            directory = Path(temporary)
            token = secrets.token_hex(24)
            rpc_port = unused_port()
            options = {"enable-rpc": "true", "rpc-listen-all": "false", "rpc-listen-port": str(rpc_port),
                       "rpc-secret": token, "dir": str(directory), "listen-port": str(unused_port()),
                       "enable-dht": "false", "enable-dht6": "false", "enable-peer-exchange": "false",
                       "bt-enable-lpd": "false", "bt-force-encryption": "true", "bt-min-crypto-level": "arc4",
                       "bt-require-crypto": "true", "file-allocation": "none", "seed-time": "0",
                       "all-proxy": "", "http-proxy": "", "https-proxy": "", "summary-interval": "0",
                       "console-log-level": "error", "stop": "40"}
            config = directory / "runtime.conf"
            config.write_text("\n".join(k + "=" + v for k, v in options.items()))
            config.chmod(0o600)
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

            def rpc(method, args=(), expect_error=False):
                data = {"jsonrpc": "2.0", "id": "fixture", "method": "aria2." + method,
                        "params": ["token:" + token] + list(args)}
                request = urllib.request.Request(f"http://127.0.0.1:{rpc_port}/jsonrpc", json.dumps(data).encode(),
                                                 {"Content-Type": "application/json"})
                try:
                    with opener.open(request, timeout=3) as response:
                        reply = json.load(response)
                except urllib.error.HTTPError as error:
                    if not expect_error or error.code != 400:
                        raise
                    reply = json.load(error)
                if expect_error:
                    assert "error" in reply, "Invalid peer hints were accepted"
                    return reply["error"]
                assert "error" not in reply, "Fixture RPC failed"
                return reply["result"]

            process = subprocess.Popen([str(args.engine), "--conf-path=" + str(config)],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       env={"PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"})
            try:
                def ready():
                    try:
                        return rpc("getVersion")
                    except OSError:
                        return False

                wait_for(ready)
                gid = rpc("addTorrent", [base64.b64encode(metadata).decode(), [], {"pause": "false"}])
                wait_for(lambda: rpc("tellStatus", [gid, ["status"]])["status"] == "active")
                endpoint = {"ip": "127.0.0.1", "port": port}
                for invalid in [[endpoint, {"ip": "localhost", "port": port}],
                                [{"ip": "127.0.0.1", "port": 0}],
                                [{"ip": "127.0.0.1", "port": 65536}], [endpoint] * 65]:
                    rpc("addPeers", [gid, invalid], expect_error=True)
                assert not pending.is_set(), "Invalid peer batch partially changed the peer list"
                assert rpc("addPeers", [gid, [endpoint]]) == 1
                assert rpc("addPeers", [gid, [endpoint]]) == 0, "Duplicate hint opened another peer"
                assert pending.wait(12), "Encrypted handshake did not reach the peer protocol"
                if errors:
                    raise errors[0]
                peers = wait_for(lambda: rpc("getPeers", [gid]))
                assert all(p.get("handshakeCompleted") == "false" for p in peers), "Negotiating sockets counted as connected"
                allow_handshake.set()
                wait_for(lambda: any(p.get("handshakeCompleted") == "true" for p in rpc("getPeers", [gid])))
                allow_pieces.set()
                wait_for(lambda: rpc("tellStatus", [gid, ["completedLength"]])["completedLength"] == str(len(payload)), 15)
                assert hashlib.sha256((directory / "fixture.bin").read_bytes()).digest() == hashlib.sha256(payload).digest()
                if errors:
                    raise errors[0]
            finally:
                allow_handshake.set()
                allow_pieces.set()
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                    process.wait(timeout=10)
    finally:
        listener.close()
        tracker.shutdown()
        tracker.server_close()
        peer_thread.join(timeout=10)
    print("PASS encrypted peer: cached endpoint without tracker peers, bounded/atomic hints, independent DH/RC4, SHA-256, handshake census")


if __name__ == "__main__":
    main()
