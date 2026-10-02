#!/usr/bin/env python3
"""Build the pinned native TCP/µTP helper; no Homebrew or Python runtime dependency."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".build/libtorrent"
PATCH = ROOT / "scripts/libtorrent-relay-release.patch"
NATIVE = ROOT / "native/TorrentEngine"
EXECUTABLE = CACHE / "runtime/bin/mycloud-torrent"
STAMP = CACHE / "runtime/build.json"
SOURCES = {
    "libtorrent": ("libtorrent-rasterbar-2.0.14.tar.gz", "libtorrent-rasterbar-2.0.14",
        "https://github.com/arvidn/libtorrent/releases/download/v2.0.14/libtorrent-rasterbar-2.0.14.tar.gz",
        "1b0b21b9755b5fbec23ca9ba2d2d10434ecb6711c39f37f5fc9d5aa25cf369c9"),
    "boost": ("boost_1_88_0.tar.bz2", "boost_1_88_0",
        "https://archives.boost.io/release/1.88.0/source/boost_1_88_0.tar.bz2",
        "46d9d2c06637b219270877c9e16155cbd015b6dc84349af064c088e9b5b12f7b"),
    "openssl": ("openssl-3.6.4.tar.gz", "openssl-3.6.4",
        "https://github.com/openssl/openssl/releases/download/openssl-3.6.4/openssl-3.6.4.tar.gz",
        "9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef"),
}


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def recipe():
    paths = [Path(__file__), PATCH, *sorted(NATIVE.glob("*"))]
    return {str(p.relative_to(ROOT)): digest(p) for p in paths if p.is_file()}


def extract(archive, target, prefix):
    temporary = target.with_name(target.name + ".extracting")
    if temporary.exists():
        shutil.rmtree(temporary)
    temporary.mkdir()
    with tarfile.open(archive) as source:
        for entry in source.getmembers():
            parts = Path(entry.name).parts
            if not parts or parts[0] != prefix or ".." in parts or Path(entry.name).is_absolute():
                raise SystemExit("Unsafe dependency archive path.")
            if entry.issym() or entry.islnk():
                continue  # Build inputs do not need archive links.
            dest = temporary.joinpath(*parts[1:])
            if entry.isdir():
                dest.mkdir(parents=True, exist_ok=True)
            elif entry.isfile():
                dest.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(entry) as data, dest.open("wb") as output:
                    shutil.copyfileobj(data, output)
                dest.chmod(entry.mode & 0o777)
            else:
                raise SystemExit("Unsupported dependency archive entry.")
    if target.exists():
        shutil.rmtree(target)
    temporary.rename(target)


def dependencies():
    CACHE.mkdir(parents=True, exist_ok=True)
    for name, (archive, directory, url, checksum) in SOURCES.items():
        path = CACHE / archive
        if not path.exists():
            print(f"Downloading pinned {name} source…", flush=True)
            temporary = path.with_suffix(".download")
            try:
                with urllib.request.urlopen(url, timeout=60) as source, temporary.open("wb") as out:
                    shutil.copyfileobj(source, out)
                if digest(temporary) != checksum:
                    raise SystemExit(f"{name} checksum mismatch.")
                temporary.rename(path)
            finally:
                temporary.unlink(missing_ok=True)
        if digest(path) != checksum:
            raise SystemExit(f"{name} checksum mismatch.")
        if not (CACHE / directory).exists():
            extract(path, CACHE / directory, directory)


def build():
    dependencies()
    tooling = CACHE / "tools"
    if not (tooling / "bin/cmake").exists() or not (tooling / "bin/ninja").exists():
        subprocess.run([sys.executable, "-m", "venv", str(tooling)], check=True)
        subprocess.run([str(tooling / "bin/python"), "-m", "pip", "install", "cmake==3.31.10", "ninja==1.13.0"], check=True)
    cmake = str(tooling / "bin/cmake")
    source = CACHE / SOURCES["libtorrent"][1]
    patch_stamp = source / ".mycloud-release-patch"
    if not patch_stamp.exists() or patch_stamp.read_text().strip() != digest(PATCH):
        extract(CACHE / SOURCES["libtorrent"][0], source, source.name)
        subprocess.run(["patch", "-p1", "-i", str(PATCH)], cwd=source, check=True)
        patch_stamp.write_text(digest(PATCH) + "\n")
    openssl = CACHE / "openssl-runtime"
    log = CACHE / "prepare-build.log"
    print(f"Building native torrent helper; log: {log}", flush=True)
    with log.open("w") as output:
        def run(command, cwd=ROOT):
            subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, check=True)
        jobs = str(min(8, os.cpu_count() or 2))
        if not (openssl / "lib/libssl.a").exists():
            source_ssl = CACHE / SOURCES["openssl"][1]
            run(["/usr/bin/perl", "Configure", "darwin64-arm64-cc", "no-shared", "no-tests", "no-module",
                 f"--prefix={openssl}", f"--openssldir={openssl / 'ssl'}", "-mmacosx-version-min=13.0"], source_ssl)
            run(["make", "-j" + jobs], source_ssl)
            run(["make", "install_sw"], source_ssl)
        common = ["-G", "Ninja", f"-DCMAKE_MAKE_PROGRAM={tooling / 'bin/ninja'}", "-DCMAKE_BUILD_TYPE=Release",
                  "-DCMAKE_OSX_DEPLOYMENT_TARGET=13.0", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                  "-DBoost_NO_BOOST_CMAKE=ON", f"-DBOOST_ROOT={CACHE / SOURCES['boost'][1]}",
                  f"-DOPENSSL_ROOT_DIR={openssl}", "-DOPENSSL_USE_STATIC_LIBS=TRUE"]
        run([cmake, "-S", str(source), "-B", str(CACHE / "core-build"), *common,
             "-DBUILD_SHARED_LIBS=OFF", "-Dbuild_tests=OFF", "-Dbuild_examples=OFF", "-Dbuild_tools=OFF",
             f"-DCMAKE_INSTALL_PREFIX={CACHE / 'core-runtime'}"])
        run([cmake, "--build", str(CACHE / "core-build"), "-j", jobs])
        run([cmake, "--install", str(CACHE / "core-build")])
        run([cmake, "-S", str(NATIVE), "-B", str(CACHE / "helper-build"), *common,
             f"-DCMAKE_PREFIX_PATH={CACHE / 'core-runtime'}", f"-DCMAKE_INSTALL_PREFIX={CACHE / 'runtime'}"])
        run([cmake, "--build", str(CACHE / "helper-build"), "-j", jobs])
        run([cmake, "--install", str(CACHE / "helper-build")])
    STAMP.write_text(json.dumps({"inputs": recipe(), "executable": digest(EXECUTABLE)}, indent=2) + "\n")


def verify():
    if not EXECUTABLE.is_file() or EXECUTABLE.is_symlink() or not STAMP.is_file():
        raise SystemExit("Missing native torrent helper. Run scripts/prepare-libtorrent-engine.py.")
    expected = json.loads(STAMP.read_text())
    if expected != {"inputs": recipe(), "executable": digest(EXECUTABLE)}:
        raise SystemExit("Native torrent helper is stale. Run scripts/prepare-libtorrent-engine.py.")
    version = subprocess.check_output([str(EXECUTABLE), "--version"], text=True)
    if "libtorrent 2.0.14.0 TCP uTP VerifiedResume LiveRelease" not in version:
        raise SystemExit("Unexpected native torrent engine version or features.")
    libraries = subprocess.check_output(["otool", "-L", str(EXECUTABLE)], text=True).splitlines()[1:]
    if any(not line.strip().startswith(("/usr/lib/", "/System/Library/")) for line in libraries):
        raise SystemExit("Torrent helper has a non-system runtime dependency.")
    architecture = subprocess.check_output(["lipo", "-archs", str(EXECUTABLE)], text=True).strip()
    target = subprocess.check_output(["xcrun", "vtool", "-show-build", str(EXECUTABLE)], text=True)
    if architecture != "arm64" or not re.search(r"\bminos 13\.0\b", target):
        raise SystemExit("Torrent helper must target arm64 macOS 13.0.")
    for archive, directory, _, checksum in SOURCES.values():
        if not (CACHE / archive).is_file() or digest(CACHE / archive) != checksum or not (CACHE / directory).is_dir():
            raise SystemExit("Pinned torrent engine source is missing or changed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--destination", type=Path)
    args = parser.parse_args()
    if not args.verify_only:
        build()
    verify()
    if args.destination:
        args.destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(EXECUTABLE, args.destination / EXECUTABLE.name)
        for name, license_name in [("libtorrent", "LICENSE"), ("boost", "LICENSE_1_0.txt"), ("openssl", "LICENSE.txt")]:
            shutil.copy2(CACHE / SOURCES[name][1] / license_name, args.destination / f"{name}-LICENSE.txt")
        shutil.copy2(PATCH, args.destination / PATCH.name)
        shutil.copy2(Path(__file__), args.destination / Path(__file__).name)
        (args.destination / "LIBTORRENT-BUILD.json").write_text(json.dumps({"dependencies": SOURCES,
            "build": json.loads(STAMP.read_text()), "target": "arm64 macOS 13.0; static OpenSSL; system dylibs only"}, indent=2) + "\n")
    print("Verified libtorrent 2.0.14: TCP + µTP, verified resume, live cleanup, macOS 13+, system dylibs only.")


if __name__ == "__main__":
    main()
