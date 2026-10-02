#!/usr/bin/env python3
"""Compare torrent status polling CPU using generated, already-complete files.

Uses the isolated libtorrent test environment and loopback only. No live app,
download payload, account or settings are accessed. Reports CPU, not watts.
"""
import argparse
import ctypes
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("torrent_fixture", Path(__file__).with_name("test-libtorrent-engine.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class Usage(ctypes.Structure):
    # macOS rusage_info_v2, from sys/resource.h. CPU times are Mach ticks.
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user", "system", "idle_wakeups", "interrupt_wakeups", "pageins", "wired", "resident",
        "footprint", "start", "exit", "child_user", "child_system", "child_idle_wakeups",
        "child_interrupt_wakeups", "child_pageins", "child_elapsed", "disk_read", "disk_write")]


libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libproc.proc_pid_rusage.restype = ctypes.c_int


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
libsystem.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
libsystem.mach_timebase_info.restype = ctypes.c_int
timebase = Timebase()
if libsystem.mach_timebase_info(ctypes.byref(timebase)) or not timebase.denom:
    raise RuntimeError("Cannot read the Mach clock conversion")


def cpu_seconds(pid):
    usage = Usage()
    if libproc.proc_pid_rusage(pid, 2, ctypes.byref(usage)):
        raise OSError(ctypes.get_errno(), "Cannot measure fixture helper CPU")
    return (usage.user + usage.system) * timebase.numer / timebase.denom / 1e9


def trial(executable, root, payload, metadata, count, seconds, poll, census):
    engine = fixture.Engine(executable, root, lt_focus_pieces="0", lt_enable_utp="false")
    try:
        engine.start()
        gid = engine.add(metadata, payload, selection=f"1-{count}")

        def ready():
            status = engine.status(gid)
            return ("verifyIntegrityPending" not in status
                    and all(f["completedLength"] == f["length"] for f in status["files"]))

        fixture.wait(ready, "generated files verified", seconds=60)
        durations = []
        for _ in range(5):
            start = time.monotonic()
            status = engine.status(gid)
            durations.append(time.monotonic() - start)
            assert len(status["files"]) == count
            assert int(status["completedLength"]) == sum(int(f["completedLength"]) for f in status["files"])
        # Reset checkpoint timing so setup does not distort the polling trial.
        engine.rpc("forcePause", gid)
        engine.rpc("unpause", gid)
        next_poll = next_census = start = time.monotonic()
        initial_cpu = cpu_seconds(engine.process.pid)
        polls = censuses = 0
        while time.monotonic() - start < seconds:
            now = time.monotonic()
            if now >= next_poll:
                engine.rpc("tellStatus", gid, ["status", "completedLength", "downloadSpeed"])
                polls += 1
                next_poll = time.monotonic() + poll
            if now >= next_census:
                engine.status(gid)
                censuses += 1
                next_census = time.monotonic() + census
            time.sleep(min(0.05, max(0, start + seconds - time.monotonic())))
        elapsed = time.monotonic() - start
        cpu = cpu_seconds(engine.process.pid) - initial_cpu
        return {"files": count, "duration_seconds": round(elapsed, 2), "polls": polls,
                "file_censuses": censuses, "cpu_seconds": round(cpu, 3),
                "cpu_percent_one_core": round(cpu / elapsed * 100, 2),
                "median_detailed_status_ms": round(statistics.median(durations) * 1000, 2)}
    finally:
        engine.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--engine", type=Path, default=ROOT / ".build/libtorrent/runtime/bin/mycloud-torrent")
    parser.add_argument("--files", type=int, default=8192)
    parser.add_argument("--seconds", type=float, default=20)
    args = parser.parse_args()
    if not 1 <= args.files <= 200000 or args.seconds <= 0:
        parser.error("Use 1–200000 files and a positive duration")
    with tempfile.TemporaryDirectory(prefix="mycloud-status-benchmark-") as directory:
        root = Path(directory).resolve()
        payload = root / "payload"
        data = bytes(range(256)) * 2
        files = []
        for i in range(args.files):
            parts = [f"group{i // 256:03d}", f"batch{i // 32:04d}", f"file{i:06d}.bin"]
            path = payload / "Generated" / Path(*parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            files.append({"length": len(data), "path": parts})
        piece = 16384
        full_piece = data * (piece // len(data))
        total = len(data) * args.files
        hashes = hashlib.sha1(full_piece).digest() * (total // piece)
        if total % piece:
            hashes += hashlib.sha1(full_piece[:total % piece]).digest()
        metadata = fixture.bencode({"info": {"name": "Generated", "piece length": piece,
                                             "files": files, "pieces": hashes}})
        results = {}
        for label, executable, poll, census in (("before", args.baseline, 1, 5), ("after", args.engine, 10, 30)):
            results[label] = trial(executable.resolve(), root / label, payload, metadata,
                                   args.files, args.seconds, poll, census)
            print(json.dumps({label: results[label]}), flush=True)
        before, after = results["before"], results["after"]
        print(json.dumps({"polling_cpu_reduction_percent": round(
            100 * (1 - after["cpu_percent_one_core"] / before["cpu_percent_one_core"]), 1)}), flush=True)


if __name__ == "__main__":
    main()
