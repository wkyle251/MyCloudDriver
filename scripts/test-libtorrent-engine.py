#!/usr/bin/env python3
"""Independent TCP/µTP, resume migration and live reclamation integration tests.

Run with Python's libtorrent==2.0.14 wheel in an isolated test environment.
All payloads are generated; discovery is disabled and peers use loopback only.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import tempfile
import time
import urllib.request

import libtorrent as lt

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("cleanup_fixture", Path(__file__).with_name("test-torrent-live-cleanup.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
bencode = fixture.fixtures.bencode
port = fixture.fixtures.unused_port
wait = fixture.wait_for
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class Engine:
    def __init__(self, executable, root, **options):
        self.executable, self.root = executable, root
        root.mkdir(parents=True, exist_ok=True)
        self.secret, self.rpc_port, self.peer_port = secrets.token_hex(24), port(), port()
        self.options = {"enable-rpc": "true", "rpc-listen-all": "false", "rpc-secret": self.secret,
                        "rpc-listen-port": str(self.rpc_port), "listen-port": str(self.peer_port),
                        "lt-listen-interfaces": f"127.0.0.1:{self.peer_port}", "enable-dht": "false",
                        "enable-dht6": "false", "enable-peer-exchange": "false", "bt-enable-lpd": "false",
                        "lt-allow-same-ip": "true", "lt-prefer-rc4": "false", "dir": str(root),
                        "max-overall-download-limit": "256K", "check-integrity": "true",
                        "file-allocation": "none", "console-log-level": "error", "summary-interval": "0"}
        self.options.update({k.replace("_", "-"): str(v) for k, v in options.items()})
        self.process = None

    def start(self):
        config = self.root / "runtime.conf"
        config.write_text("\n".join(f"{k}={v}" for k, v in self.options.items()))
        config.chmod(0o600)
        self.log = (self.root / "process.log").open("ab")
        self.process = subprocess.Popen([str(self.executable), f"--conf-path={config}"],
                                        stdout=self.log, stderr=self.log)
        def ready():
            assert self.process.poll() is None, (self.root / "process.log").read_text()
            try:
                return self.rpc("getVersion")
            except OSError:
                return False
        wait(ready, "helper startup")
        return self

    def rpc(self, method, *args, token=None, error=False):
        body = json.dumps({"jsonrpc": "2.0", "id": "fixture", "method": "aria2." + method,
                           "params": ["token:" + (self.secret if token is None else token), *args]}).encode()
        request = urllib.request.Request(f"http://127.0.0.1:{self.rpc_port}/jsonrpc", data=body,
                                         headers={"Content-Type": "application/json"})
        with opener.open(request, timeout=15) as response:
            result = json.load(response)
        if error:
            assert "error" in result, result
            return result["error"]
        assert "error" not in result, result
        return result["result"]

    def add(self, metadata, payload, selection="1-4", paused=False):
        return self.rpc("addTorrent", base64.b64encode(metadata).decode(), [], {
            "dir": str(payload), "select-file": selection, "pause": "true" if paused else "false",
            "seed-time": "5256000"})

    def status(self, gid):
        return self.rpc("tellStatus", gid)

    def connect(self, gid, target):
        return self.rpc("addPeers", gid, [{"ip": "127.0.0.1", "port": target}])

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=25)
            assert self.process.returncode == 0, (self.root / "process.log").read_text()
        if self.process:
            self.log.close()
        self.process = None


def verified(status, index):
    f = status["files"][index - 1]
    return int(f["completedLength"]) == int(f["length"])


def cleanup_test(executable, root):
    info = {"name": "Generated", "piece length": fixture.PIECE,
            "files": [{"length": n, "path": [f"file{i}"]} for i, n in enumerate(fixture.SIZES)],
            "pieces": b"".join(hashlib.sha1(fixture.PAYLOAD[i:i + fixture.PIECE]).digest()
                                for i in range(0, len(fixture.PAYLOAD), fixture.PIECE))}
    metadata = bencode({"info": info})
    seeder = fixture.Seeder()
    seeder.start(hashlib.sha1(bencode(info)).digest())
    engine = Engine(executable, root / "engine", lt_enable_utp="false", lt_encryption="disabled")
    payload = root / "payload"
    path = lambda i: payload / "Generated" / f"file{i - 1}"
    try:
        engine.start()
        engine.rpc("getVersion", token="incorrect", error=True)
        gid = engine.add(metadata, payload)
        engine.connect(gid, seeder.port)
        wait(lambda: verified(engine.status(gid), 1), "first verified TCP file")
        assert not verified(engine.status(gid), 2)
        assert engine.rpc("releaseFiles", gid, [1], str(payload)) == [], "An unfinished shared neighbor must block release"
        seeder.allow({2})
        wait(lambda: verified(engine.status(gid), 2), "shared neighbor verified")
        peers = engine.rpc("getPeers", gid)
        assert any(p["handshakeCompleted"] == "true" and p["transport"] == "tcp" for p in peers), peers
        connected = seeder.connections
        assert engine.rpc("releaseFiles", gid, [1], str(payload)) == [1]
        assert not path(1).exists()
        assert engine.rpc("releaseFiles", gid, [1], str(payload)) == [1], "Release must be idempotent"
        assert engine.rpc("releaseFiles", gid, [3], str(payload)) == [], "Incomplete data must remain"
        assert verified(engine.status(gid), 2) and path(2).read_bytes() == fixture.DATA[1]
        assert seeder.connections == connected and seeder.disconnections == 0, "Cleanup disconnected the supplying peer"
        with socket.create_connection(("127.0.0.1", engine.peer_port), timeout=5) as probe:
            probe.settimeout(5)
            probe.sendall(fixture.handshake(seeder.info_hash, b"-MCLT01-012345678901"))
            assert fixture.receive(probe, 68)[28:48] == seeder.info_hash
            while True:
                length = struct.unpack("!I", fixture.receive(probe, 4))[0]
                message = fixture.receive(probe, length)
                if message and message[0] == 5:
                    assert message[1] & 0xC0 == 0 and message[1] & 0x20, "Released pieces still advertised"
                    break
        # A changed selection uses the same supplying connection.
        engine.rpc("changeOption", gid, {"select-file": "2-4"})
        seeder.allow(range(fixture.COUNT - 1))
        wait(lambda: verified(engine.status(gid), 3), "continued transfer after live selection")
        assert seeder.connections == connected and seeder.disconnections == 0
        seeder.allow({fixture.COUNT - 1})
        try:
            wait(lambda: verified(engine.status(gid), 4), "remaining TCP payload", seconds=40)
        except AssertionError:
            print({"status": engine.rpc("tellStatus", gid, ["files", "pieceDiagnostics"]), "peers": engine.rpc("getPeers", gid),
                   "seed_connections": seeder.connections, "seed_disconnects": seeder.disconnections,
                   "seed_errors": [str(e) for e in seeder.errors]}, flush=True)
            raise
        assert all(path(i).read_bytes() == fixture.DATA[i - 1] for i in range(2, 5))
        engine.rpc("forcePause", gid)
        engine.stop(); engine.start(); gid = engine.add(metadata, payload, "2-4")
        wait(lambda: verified(engine.status(gid), 4), "cached resume after cleanup")
        assert engine.status(gid)["resumeSource"] == "libtorrent"
        assert verified(engine.status(gid), 2) and not path(1).exists()
        engine.rpc("forcePause", gid)
        before = path(2).stat()
        with path(2).open("r+b") as output:
            output.write(bytes([fixture.DATA[1][0] ^ 0xFF]))
        os.utime(path(2), ns=(before.st_atime_ns, before.st_mtime_ns))
        engine.rpc("unpause", gid); engine.connect(gid, seeder.port)
        wait(lambda: verified(engine.status(gid), 2) and path(2).read_bytes() == fixture.DATA[1],
             "same-size modification checked and repaired", seconds=40)
        assert engine.status(gid)["resumeSource"] == "check"
        engine.rpc("forcePause", gid)
        engine.stop()
        record = next((root / "engine" / "Resume").glob("*.json"))
        saved = json.loads(record.read_text()); saved["complete"] = [0, 1, 2, 3]
        saved["checksum"] = "0" * 64; record.write_text(json.dumps(saved))
        engine.start(); gid = engine.add(metadata, payload, "2-4")
        engine.connect(gid, seeder.port)
        wait(lambda: verified(engine.status(gid), 4), "invalid resume falls back to checking", seconds=40)
        assert engine.status(gid)["resumeSource"] == "check"
        protected = root / "protected"; protected.write_bytes(b"do not delete")
        original = path(2).with_suffix(".original"); path(2).rename(original); path(2).symlink_to(protected)
        engine.rpc("releaseFiles", gid, [2], str(payload), error=True)
        assert protected.read_bytes() == b"do not delete"
        path(2).unlink(); original.rename(path(2))
        assert not seeder.errors, seeder.errors
        print("PASS: TCP, live shared-piece cleanup, same peer retained, selection, resume and corruption/symlink checks", flush=True)
    finally:
        engine.stop(); seeder.close()


def utp_test(executable, root):
    source = root / "seed"; source.mkdir(parents=True)
    content = hashlib.shake_256(b"mycloud-utp-generated").digest(2 * 1024 * 1024)
    (source / "utp.bin").write_bytes(content)
    info = {"name": "utp.bin", "length": len(content), "piece length": 32768,
            "pieces": b"".join(hashlib.sha1(content[i:i + 32768]).digest() for i in range(0, len(content), 32768))}
    metadata = bencode({"info": info})
    seed_port = port()
    session = lt.session({"listen_interfaces": f"127.0.0.1:{seed_port}", "enable_dht": False,
                          "enable_lsd": False, "enable_natpmp": False, "enable_upnp": False,
                          "enable_incoming_tcp": False, "enable_outgoing_tcp": False,
                          "enable_incoming_utp": True, "enable_outgoing_utp": True,
                          "allow_multiple_connections_per_ip": True, "upload_rate_limit": 128 * 1024})
    classes = lt.ip_filter()
    classes.add_rule("0.0.0.0", "255.255.255.255", 1 << lt.session.global_peer_class_id)
    classes.add_rule("::", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", 1 << lt.session.global_peer_class_id)
    session.set_peer_class_filter(classes)
    params = lt.add_torrent_params(); params.ti = lt.torrent_info(lt.bdecode(metadata)); params.save_path = str(source)
    params.flags &= ~(lt.torrent_flags.auto_managed | lt.torrent_flags.paused)
    handle = session.add_torrent(params)
    wait(lambda: handle.status().is_seeding, "independent µTP seed hash check")
    engine = Engine(executable, root / "engine", lt_enable_tcp="false")
    try:
        engine.start(); payload = root / "payload"; gid = engine.add(metadata, payload, "1")
        engine.connect(gid, seed_port); observed = []
        def done():
            peers = engine.rpc("getPeers", gid)
            observed.extend(p for p in peers if p["transport"] == "utp" and int(p["downloadSpeed"]) > 0)
            return verified(engine.status(gid), 1)
        wait(done, "verified µTP transfer", seconds=45)
        assert observed, "No µTP payload observed"
        assert (payload / "utp.bin").read_bytes() == content
        assert engine.rpc("releaseFiles", gid, [1], str(payload)) == [1]
        assert not (payload / "utp.bin").exists()
        assert int(engine.status(gid)["numPieces"]) == 0, "A full seed still advertises reclaimed data"
        print("PASS: independent µTP-only peer delivered 2 MiB with matching SHA-256", flush=True)
    finally:
        engine.stop(); session.pause()


def readmission_test(executable, root):
    info = {"name": "Generated", "piece length": fixture.PIECE,
            "files": [{"length": n, "path": [f"file{i}"]} for i, n in enumerate(fixture.SIZES)],
            "pieces": b"".join(hashlib.sha1(fixture.PAYLOAD[i:i + fixture.PIECE]).digest()
                                for i in range(0, len(fixture.PAYLOAD), fixture.PIECE))}
    metadata = bencode({"info": info}); ih = hashlib.sha1(bencode(info)).digest()
    seeder = fixture.Seeder(); seeder.start(ih)
    engine = Engine(executable, root / "engine", lt_enable_utp="false", lt_encryption="disabled")
    payload = root / "payload"
    try:
        engine.start(); gid = engine.add(metadata, payload, "1"); engine.connect(gid, seeder.port)
        wait(lambda: verified(engine.status(gid), 1), "first rolling selection")
        part = payload / ("." + ih.hex() + ".parts")
        assert part.exists(), "Fixture must exercise the boundary partfile"
        assert engine.rpc("releaseFiles", gid, [2], str(payload)) == [2]
        assert not part.exists(), "Retired boundary slots must be reclaimable"
        engine.rpc("changeOption", gid, {"select-file": "1-2"})
        seeder.allow({2})
        engine.connect(gid, seeder.port)
        wait(lambda: verified(engine.status(gid), 2), "re-admitted boundary file", seconds=40)
        assert (payload / "Generated/file1").read_bytes() == fixture.DATA[1]
        print("PASS: reclaimed unselected boundary data can be admitted later; partfile slots reclaimed", flush=True)
    finally:
        engine.stop(); seeder.close()


def focus_test(executable, root):
    """Completion deadlines must finish files without widening the selection.

    A deadline forces its piece to top priority in libtorrent regardless of the
    file priorities underneath, so a focused set built from anything but the
    live selection would silently fetch files the user never chose. Clearing a
    deadline drops the piece to low priority, so the selection has to be
    restated whenever the focused set moves on.
    """
    info = {"name": "Generated", "piece length": fixture.PIECE,
            "files": [{"length": n, "path": [f"file{i}"]} for i, n in enumerate(fixture.SIZES)],
            "pieces": b"".join(hashlib.sha1(fixture.PAYLOAD[i:i + fixture.PIECE]).digest()
                                for i in range(0, len(fixture.PAYLOAD), fixture.PIECE))}
    metadata = bencode({"info": info}); ih = hashlib.sha1(bencode(info)).digest()
    seeder = fixture.Seeder(); seeder.start(ih); seeder.allow({2, 3})
    # A focused set of four pieces cannot reach the unselected tail by accident.
    engine = Engine(executable, root / "engine", lt_enable_utp="false",
                    lt_encryption="disabled", lt_focus_pieces="4")
    payload = root / "payload"
    unchosen = lambda: int(engine.status(gid)["files"][3]["completedLength"])
    try:
        engine.start(); gid = engine.add(metadata, payload, "1-3"); engine.connect(gid, seeder.port)
        wait(lambda: verified(engine.status(gid), 2), "files reachable before the boundary piece")
        assert not verified(engine.status(gid), 3), "Fixture must leave a focused file unfinished"
        # Outlast a focus pass, which reranks the unfinished selection and is
        # the only moment deadlines are applied.
        time.sleep(25)
        focused = int(engine.status(gid)["focusedPieces"])
        assert 0 < focused <= 4, f"The unfinished selection must be focused, got {focused}"
        assert not verified(engine.status(gid), 4), "A deadline pulled in an unselected file"
        assert unchosen() <= fixture.PIECE, "A deadline fetched beyond the shared boundary piece"
        seeder.allow({4}); engine.connect(gid, seeder.port)
        wait(lambda: verified(engine.status(gid), 3), "focused file still completes", seconds=40)
        assert (payload / "Generated/file2").read_bytes() == fixture.DATA[2]
        time.sleep(25)
        assert not verified(engine.status(gid), 4), "A deadline pulled in an unselected file"
        assert unchosen() <= fixture.PIECE, "A deadline fetched beyond the shared boundary piece"
        print("PASS: completion deadlines finish the selection without reaching unselected files", flush=True)
    finally:
        engine.stop(); seeder.close()


def migration_test(executable, root):
    content = hashlib.shake_256(b"mycloud-aria2-migration").digest(256 * 1024)
    info = {"name": "migration.bin", "length": len(content), "piece length": 65536,
            "pieces": b"".join(hashlib.sha1(content[i:i + 65536]).digest() for i in range(0, len(content), 65536))}
    metadata = bencode({"info": info}); ih = hashlib.sha1(bencode(info)).digest()
    payload = root / "payload"; payload.mkdir(parents=True); path = payload / "migration.bin"
    # The first piece was hash-verified; one block of the second is incomplete.
    path.write_bytes(content[:81920]); s = path.stat()
    # Older checkpoints can claim data beyond EOF. Preserve the real first
    # piece/block, but never promote the absent third piece or second block.
    bits, partial = b"\xa0", b"\xc0"
    n = lambda v: struct.pack("!Q", v)
    fingerprint = (ih + n(65536) + n(len(content)) + n(1) + bits + n(1) + n(1) + n(65536) + n(1) + partial
                   + n(1) + n(len(str(path).encode())) + str(path).encode() + n(1) + n(s.st_dev) + n(s.st_ino)
                   + n(s.st_size) + n(s.st_mtime_ns // 10**9) + n(s.st_mtime_ns % 10**9)
                   + n(s.st_ctime_ns // 10**9) + n(s.st_ctime_ns % 10**9))
    record = (struct.pack("!HII", 1, 1, 20) + ih + struct.pack("!IQQI", 65536, len(content), 0, 1)
              + bits + struct.pack("!IIII", 1, 1, 65536, 1) + partial + b"MCVR0001" + hashlib.sha256(fingerprint).digest())
    (payload / "migration.bin.aria2").write_bytes(record)
    engine = Engine(executable, root / "engine")
    try:
        engine.start(); gid = engine.add(metadata, payload, "1")
        wait(lambda: int(engine.status(gid)["files"][0]["completedLength"]) == 65536, "aria2 verified piece import")
        assert engine.status(gid)["resumeSource"] == "aria2-verified"
        engine.rpc("forcePause", gid)
        saved = json.loads(next((root / "engine" / "Resume").glob("*.json")).read_text())
        resume = lt.read_resume_data(base64.b64decode(saved["resume"]))
        assert resume.have_pieces[0] and not resume.have_pieces[1]
        assert not resume.have_pieces[2], "A cached piece extends beyond the physical file"
        assert resume.unfinished_pieces[1][0], "The partial block was not migrated"
        assert not resume.unfinished_pieces[1][1], "An absent partial block was migrated"
        assert (payload / "migration.bin.aria2").read_bytes() == record, "Original checkpoint was modified"
        print("PASS: aria2 verified-piece and partial-block migration; original checkpoint retained", flush=True)
    finally:
        engine.stop()


def resume_size_test(executable, root):
    """A self-consistent old cache must not make a short file upload-ready."""
    info = {"name": "Generated", "piece length": fixture.PIECE,
            "files": [{"length": n, "path": [f"file{i}"]} for i, n in enumerate(fixture.SIZES)],
            "pieces": b"".join(hashlib.sha1(fixture.PAYLOAD[i:i + fixture.PIECE]).digest()
                                for i in range(0, len(fixture.PAYLOAD), fixture.PIECE))}
    metadata = bencode({"info": info}); ih = hashlib.sha1(bencode(info)).digest()
    payload = root / "payload"; (payload / "Generated").mkdir(parents=True)
    paths = [payload / "Generated" / f"file{i}" for i in range(len(fixture.DATA))]
    for path, data in zip(paths[:2], fixture.DATA[:2]):
        path.write_bytes(data)
    engine = Engine(executable, root / "engine", lt_enable_utp="false", lt_encryption="disabled")
    seeder = fixture.Seeder(); seeder.start(ih)
    try:
        engine.start(); gid = engine.add(metadata, payload)
        wait(lambda: "verifyIntegrityPending" not in engine.status(gid)
             and verified(engine.status(gid), 2), "generated partial download verified")
        engine.rpc("forcePause", gid); engine.stop()
        record = next((root / "engine" / "Resume").glob("*.json"))
        saved = json.loads(record.read_text()); checksum = saved.pop("checksum")
        canonical = lambda value: json.dumps(value, sort_keys=True, ensure_ascii=False,
                                             separators=(",", ":")).replace("/", "\\/").encode()
        assert hashlib.sha256(canonical(saved)).hexdigest() == checksum
        # Model a legacy checkpoint captured with an already short file; merely
        # changing the file without its manifest would test a full recheck.
        paths[0].write_bytes(fixture.DATA[0][:8192])
        n = lambda value: struct.pack("!Q", value)
        manifest = n(len(paths))
        for path in [*paths, payload / ("." + ih.hex() + ".parts")]:
            encoded = str(path).encode(); manifest += n(len(encoded)) + encoded
            if not path.exists():
                manifest += n(0); continue
            s = path.stat()
            manifest += (n(1) + n(s.st_dev) + n(s.st_ino) + n(s.st_size)
                         + n(s.st_mtime_ns // 10**9) + n(s.st_mtime_ns % 10**9)
                         + n(s.st_ctime_ns // 10**9) + n(s.st_ctime_ns % 10**9))
        saved["manifest"] = hashlib.sha256(manifest).hexdigest()
        saved["checksum"] = hashlib.sha256(canonical(saved)).hexdigest()
        record.write_bytes(canonical(saved))
        engine.start(); gid = engine.add(metadata, payload)
        wait(lambda: "verifyIntegrityPending" not in engine.status(gid), "size-only cache recovery")
        status = engine.status(gid)
        assert status["resumeSource"] == "libtorrent", "Valid cached pieces should avoid a full recheck"
        assert not verified(status, 1), "Short file incorrectly offered for upload"
        assert verified(status, 2), "An intact shared neighbor lost its verified-file receipt"
        assert int(status["numPieces"]) == 1, "Only pieces beyond EOF should be withdrawn"
        engine.connect(gid, seeder.port)
        wait(lambda: verified(engine.status(gid), 1), "missing tail downloaded automatically")
        assert paths[0].read_bytes() == fixture.DATA[0]
        assert paths[1].read_bytes() == fixture.DATA[1]
        engine.rpc("forcePause", gid); engine.stop(); engine.start(); gid = engine.add(metadata, payload)
        wait(lambda: verified(engine.status(gid), 1), "repaired cache survives restart")
        assert engine.status(gid)["resumeSource"] == "libtorrent"
        print("PASS: short cached file withheld from uploads, only missing pieces recovered, intact files/resume preserved", flush=True)
    finally:
        engine.stop(); seeder.close()


def padding_test(executable, root):
    first = hashlib.shake_256(b"padding-first-generated").digest(4096)
    second = hashlib.shake_256(b"padding-second-generated").digest(4096)
    piece = 16384; block = first + bytes(12288) + second + bytes(12288)
    info = {"name": "Generated", "piece length": piece,
            "files": [{"length": 4096, "path": ["first"]},
                      {"length": 12288, "path": ["padding"], "attr": "p"},
                      {"length": 4096, "path": ["second"]},
                      {"length": 12288, "path": ["_____padding_file_1"]}],
            "pieces": b"".join(hashlib.sha1(block[i:i + piece]).digest() for i in range(0, len(block), piece))}
    payload = root / "payload"; (payload / "Generated").mkdir(parents=True)
    (payload / "Generated/first").write_bytes(first)
    (payload / "Generated/second").write_bytes(second)
    stub = payload / "Generated/padding"; stub.write_bytes(bytes(128))
    engine = Engine(executable, root / "engine")
    try:
        engine.start(); gid = engine.add(bencode({"info": info}), payload)
        wait(lambda: "verifyIntegrityPending" not in engine.status(gid)
             and verified(engine.status(gid), 3), "generated padding torrent verified")
        status = engine.status(gid)
        assert [f["padding"] for f in status["files"]] == ["false", "true", "false", "true"]
        assert int(status["totalLength"]) == len(first) + len(second)
        assert int(status["completedLength"]) == int(status["totalLength"])
        assert not (payload / "Generated/_____padding_file_1").exists()
        assert engine.rpc("releaseFiles", gid, [2], str(payload)) == [2] and not stub.exists()
        assert int(engine.status(gid)["numPieces"]) == 2, "Deleting a padding stub withdrew real verified pieces"
        engine.rpc("forcePause", gid); engine.stop(); engine.start()
        gid = engine.add(bencode({"info": info}), payload)
        wait(lambda: "verifyIntegrityPending" not in engine.status(gid), "padding cleanup cached resume")
        assert engine.status(gid)["resumeSource"] == "libtorrent"
        assert verified(engine.status(gid), 1) and verified(engine.status(gid), 3)
        print("PASS: explicit and legacy padding flags, payload-only totals, stub cleanup retains real pieces and cached resume", flush=True)
    finally:
        engine.stop()


def redial_test(executable, root):
    """A cached peer hint must earn another dial after libtorrent gives up.

    libtorrent stops dialing an address once it has failed max_failcount
    times and revives it only when a tracker lists it again. A seeder that
    went offline and is not on any tracker can then be reached only through
    the app's peer cache, so a hint has to win it a fresh attempt.
    """
    source = root / "seed"; source.mkdir(parents=True)
    content = hashlib.shake_256(b"mycloud-redial-generated").digest(2 * 1024 * 1024)
    (source / "redial.bin").write_bytes(content)
    info = {"name": "redial.bin", "length": len(content), "piece length": 32768,
            "pieces": b"".join(hashlib.sha1(content[i:i + 32768]).digest() for i in range(0, len(content), 32768))}
    metadata = bencode({"info": info})
    seed_port = port()
    engine = Engine(executable, root / "engine", lt_enable_utp="false", lt_min_reconnect_time="1")
    session = None
    try:
        engine.start(); payload = root / "payload"; gid = engine.add(metadata, payload, "1")
        engine.connect(gid, seed_port)  # Nothing listens yet, so every dial is refused.
        wait(lambda: engine.rpc("tellStatus", gid, ["pieceDiagnostics"])["pieceDiagnostics"]["lastPeerError"],
             "refused first dial")
        # Redials follow about 2 s and 3 s apart; the third refusal writes the
        # address off. The quiet window below fails loudly if it was not.
        time.sleep(12)
        session = lt.session({"listen_interfaces": f"127.0.0.1:{seed_port}", "enable_dht": False,
                              "enable_lsd": False, "enable_natpmp": False, "enable_upnp": False,
                              "enable_incoming_utp": False, "enable_outgoing_utp": False,
                              "allow_multiple_connections_per_ip": True})
        params = lt.add_torrent_params(); params.ti = lt.torrent_info(lt.bdecode(metadata)); params.save_path = str(source)
        params.flags &= ~(lt.torrent_flags.auto_managed | lt.torrent_flags.paused)
        handle = session.add_torrent(params)
        wait(lambda: handle.status().is_seeding, "independent seed hash check")
        # The seeder is back at the same address, but libtorrent has written it off.
        quiet = time.monotonic() + 5
        while time.monotonic() < quiet:
            assert int(engine.status(gid)["connections"]) == 0, "libtorrent redialed an exhausted peer by itself"
            time.sleep(0.5)
        engine.connect(gid, seed_port)
        wait(lambda: verified(engine.status(gid), 1), "transfer from the re-dialed seeder", seconds=45)
        assert (payload / "redial.bin").read_bytes() == content
        print("PASS: a peer hint re-dials a seeder libtorrent had given up on; 2 MiB byte-identical", flush=True)
    finally:
        engine.stop()
        if session:
            session.pause()


def network_diagnostics_test(executable, root):
    """A stalled fixture exposes network counters without content identifiers."""
    name = "diagnostic-name-must-stay-private"
    info = {"name": name, "length": 32768, "piece length": 32768,
            "pieces": hashlib.sha1(bytes(32768)).digest()}
    secret = "tracker-passkey-must-stay-private"
    tracker = f"http://127.0.0.1:{port()}/{secret}/announce?token={secret}"
    metadata = bencode({"announce": tracker, "info": info})
    engine = Engine(executable, root / "engine", lt_enable_utp="false", lt_encryption="disabled")
    try:
        engine.start()
        initial = engine.rpc("getNetworkDiagnostics")
        assert initial["jobs"] == [] and initial["dht"]["enabled"] is False
        gid = engine.add(metadata, root / "payload", "1")
        engine.connect(gid, port())  # An unused loopback port refuses the dial.
        def failed():
            value = engine.rpc("getNetworkDiagnostics")
            assert len(value["jobs"]) == 1 and value["jobs"][0]["gid"] == gid
            return value if value["jobs"][0]["lastPeerError"] and value["jobs"][0]["trackersFailed"] else None
        value = wait(failed, "network diagnostics from refused fixture peers and tracker")
        row = value["jobs"][0]
        assert row["handshaked"] == 0 and row["seeders"] == 0 and row["downloadSpeed"] == 0
        assert row["trackerCount"] == 1 and row["trackersResponding"] == 0
        assert row["trackers"][0]["host"] == "127.0.0.1" and row["trackers"][0]["protocol"] == "http"
        assert row["peerFailures"]
        encoded = json.dumps(value)
        assert name not in encoded and secret not in encoded and str(root) not in encoded
        assert hashlib.sha1(bencode(info)).hexdigest() not in encoded
        assert not any(key in row for key in ("files", "bittorrent", "infoHash", "pieceDiagnostics", "totalLength", "completedLength"))
        print("PASS: network-only diagnostics report refused handshakes and tracker errors; content identifiers and passkeys omitted", flush=True)
    finally:
        engine.stop()


def admission_and_large_focus_test(executable, root):
    engine = Engine(executable, root / "engine", lt_focus_pieces="4", lt_enable_utp="false")
    try:
        engine.start()
        gids = []
        for index in range(4):
            piece = bytes([index + 1]) * 16384
            info = {"name": f"Generated-large-{index}", "piece length": len(piece),
                    "length": len(piece) * 128, "pieces": hashlib.sha1(piece).digest() * 128}
            gids.append(engine.add(bencode({"info": info}), root / f"payload-{index}", "1"))
        wait(lambda: all(engine.status(gid)["status"] == "active" for gid in gids[:3]), "three admitted jobs")
        assert engine.status(gids[3])["status"] == "waiting"
        wait(lambda: all(0 < int(engine.status(gid)["focusedPieces"]) <= 4 for gid in gids[:3]), "bounded large-file focus")
        assert len(engine.rpc("tellActive")) == 3
        engine.rpc("pause", gids[0])
        wait(lambda: engine.status(gids[3])["status"] == "active", "next queued job admitted on pause")
        engine.rpc("unpause", gids[0])
        assert engine.status(gids[0])["status"] == "waiting"
        engine.rpc("pause", gids[0])
        engine.rpc("forceRemove", gids[1])
        assert engine.status(gids[0])["status"] == "paused", "a paused queued job must not be admitted"
        engine.rpc("unpause", gids[0])
        wait(lambda: engine.status(gids[0])["status"] == "active", "explicitly resumed queued job")
        assert len(engine.rpc("tellActive")) == 3
        print("PASS bounded large-file focus, three payload slots, queue admission, and queued pause/resume")
    finally:
        engine.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, default=ROOT / ".build/libtorrent/runtime/bin/mycloud-torrent")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mycloud-libtorrent-tests-") as temp:
        root = Path(temp).resolve()
        admission_and_large_focus_test(args.engine, root / "admission")
        migration_test(args.engine, root / "migration")
        resume_size_test(args.engine, root / "resume-size")
        padding_test(args.engine, root / "padding")
        cleanup_test(args.engine, root / "cleanup")
        readmission_test(args.engine, root / "readmission")
        focus_test(args.engine, root / "focus")
        utp_test(args.engine, root / "utp")
        redial_test(args.engine, root / "redial")
        network_diagnostics_test(args.engine, root / "network-diagnostics")


if __name__ == "__main__":
    main()
