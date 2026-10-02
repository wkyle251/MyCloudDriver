#!/usr/bin/env python3
"""Retain Swift's dependency graph and optimized objects between app builds."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def digest(path):
    checksum = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def default_jobs():
    memory = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]))
    # Leave memory for the running app and SDK caches; allow an explicit override.
    return min(12, os.cpu_count() or 2, max(1, (memory // (1024 ** 3) - 4) // 2))


def build(cache, arguments, jobs):
    started = time.monotonic()
    output = Path(arguments[arguments.index("-o") + 1])
    sources = [arg for arg in arguments if arg.endswith(".swift")]
    inputs = sources + [arg for arg in arguments if arg.endswith((".o", ".a"))]
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    configuration = {
        "compiler": compiler,
        "version": subprocess.check_output([compiler, "--version"], text=True, stderr=subprocess.STDOUT),
        "sdk": sdk,
        "sdk_build": subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"], text=True).strip(),
        "arguments": arguments,
        "recipe": digest(__file__),
    }
    hashes = {path: digest(path) for path in inputs}
    stamp = cache / "build.json"
    try:
        previous = json.loads(stamp.read_text())
    except (FileNotFoundError, ValueError):
        previous = {}
    if (previous.get("configuration") == configuration and previous.get("inputs") == hashes
            and output.is_file() and previous.get("executable") == digest(output)):
        print(f"Swift: unchanged; reused optimized executable ({time.monotonic() - started:.2f}s).", flush=True)
        return

    objects = cache / "objects"
    if previous.get("configuration") != configuration and objects.exists():
        shutil.rmtree(objects)
    objects.mkdir(parents=True, exist_ok=True)
    mapping = {"": {"swift-dependencies": str(objects / "main.swiftdeps")}}
    for source in sources:
        name = Path(source).stem + "-" + hashlib.sha256(source.encode()).hexdigest()[:12]
        obj = objects / (name + ".o")
        mapping[source] = {
            "object": str(obj),
            "dependencies": str(objects / (name + ".d")),
            "swift-dependencies": str(objects / (name + ".swiftdeps")),
        }
        # A checkout or editor can preserve timestamps. Force changed content to
        # compile, then let Swift discover every dependent file that needs work.
        if previous.get("inputs", {}).get(source) != hashes[source]:
            obj.unlink(missing_ok=True)
    file_map = cache / "output-file-map.json"
    file_map.write_text(json.dumps(mapping, indent=2) + "\n")
    stamp.unlink(missing_ok=True)  # A failed build must never become a cache hit.
    output.parent.mkdir(parents=True, exist_ok=True)
    before = {path: path.stat().st_mtime_ns for path in objects.glob("*.o")}
    # The driver may skip linking when timestamps look current, even if the
    # binary was damaged or an object changed with its timestamp preserved.
    output.unlink(missing_ok=True)
    print(f"Swift: incremental release build, up to {jobs} compiler jobs…", flush=True)
    subprocess.run([
        compiler, "-incremental", "-enable-batch-mode", "-j", str(jobs),
        "-emit-dependencies", "-output-file-map", str(file_map), "-sdk", sdk,
        *arguments,
    ], check=True)
    rebuilt = sum(before.get(path) != path.stat().st_mtime_ns for path in objects.glob("*.o"))
    stamp.write_text(json.dumps({
        "configuration": configuration, "inputs": hashes, "executable": digest(output),
    }, indent=2) + "\n")
    print(f"Swift: rebuilt {rebuilt}/{len(sources)} files in {time.monotonic() - started:.2f}s.", flush=True)


def main():
    if sys.argv[1:2] == ["--lock-build"]:
        script = Path(sys.argv[2]).resolve()
        root = script.parent.parent
        (root / ".build").mkdir(exist_ok=True)
        with (root / ".build/app-build.lock").open("w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print("Waiting for the current app build/install to finish…", flush=True)
                fcntl.flock(lock, fcntl.LOCK_EX)
            environment = dict(os.environ, MYCLOUD_APP_BUILD_LOCK=str(root))
            raise SystemExit(subprocess.run([str(script), *sys.argv[3:]], env=environment).returncode)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", required=True, type=Path)
    parser.add_argument("--jobs", type=int, default=None)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    if "-o" not in arguments or not any(arg.endswith(".swift") for arg in arguments):
        parser.error("Pass the Swift arguments, all source files and -o <executable> after --.")
    jobs = args.jobs if args.jobs is not None else int(os.environ.get("MYCLOUD_BUILD_JOBS", default_jobs()))
    if jobs < 1:
        parser.error("Compiler jobs must be positive.")
    cache = args.cache_dir.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "build.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        build(cache, arguments, jobs)


if __name__ == "__main__":
    main()
