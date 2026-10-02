#!/usr/bin/env python3
"""Build pinned aria2 with Apple TLS and static GMP for macOS 13+.

The app runs this as a separate process. No runtime Homebrew installation is
required. --verify-only never downloads or builds anything.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
VERSION = "1.37.0"
SHA256 = "60a420ad7085eb616cb6e2bdf0a7206d68ff3d37fb5a956dc44242eb2f79b66b"
SOURCE_URL = f"https://github.com/aria2/aria2/releases/download/release-{VERSION}/aria2-{VERSION}.tar.xz"
CACHE = ROOT / ".build/torrent-engine"
ARCHIVE = CACHE / f"aria2-{VERSION}.tar.xz"
PATCH = ROOT / "scripts/aria2-relay-release.patch"
PATCH_SHA256 = hashlib.sha256(PATCH.read_bytes()).hexdigest()
RECIPE_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
SOURCE = CACHE / f"aria2-{VERSION}-relay-{PATCH_SHA256[:12]}-{RECIPE_SHA256[:8]}"
PREFIX = CACHE / "runtime"
EXECUTABLE = PREFIX / "bin/aria2c"
BUILD_STAMP = PREFIX / "relay-release-build.sha256"
RECIPE_STAMP = PREFIX / "build-recipe.sha256"
GMP_VERSION = "6.3.0"
GMP_SHA256 = "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898"
GMP_URL = f"https://ftp.gnu.org/gnu/gmp/gmp-{GMP_VERSION}.tar.xz"
GMP_ARCHIVE = CACHE / f"gmp-{GMP_VERSION}.tar.xz"
GMP_SOURCE = CACHE / f"gmp-{GMP_VERSION}"
GMP_PREFIX = CACHE / f"gmp-{GMP_VERSION}-runtime"
GMP_LIBRARY = GMP_PREFIX / "lib/libgmp.a"
GMP_STAMP = GMP_PREFIX / "build.sha256"
GMP_CONFIGURE = ["--disable-shared", "--enable-static", "--with-pic", "--disable-assembly",
                 "CC=clang", "CFLAGS=-O2 -mmacosx-version-min=13.0",
                 "LDFLAGS=-mmacosx-version-min=13.0"]
CONFIGURE = ["--disable-nls", "--without-gnutls", "--without-libnettle", "--with-libgmp",
             "--without-libgcrypt", "--without-openssl", "--without-sqlite3",
             "--without-libxml2", "--without-libexpat", "--without-libcares", "--without-libssh2",
             "CXX=clang++", "CC=clang", "CXXFLAGS=-O2 -mmacosx-version-min=13.0",
             "CFLAGS=-O2 -mmacosx-version-min=13.0", f"CPPFLAGS=-I{GMP_PREFIX / 'include'}",
             f"LDFLAGS=-L{GMP_PREFIX / 'lib'} -mmacosx-version-min=13.0"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify():
    expected = PATCH_SHA256 + " " + (digest(EXECUTABLE) if EXECUTABLE.is_file() else "")
    if not BUILD_STAMP.is_file() or BUILD_STAMP.read_text().strip() != expected:
        raise SystemExit("Torrent engine needs the relay release patch. Run scripts/prepare-torrent-engine.py.")
    if not RECIPE_STAMP.is_file() or RECIPE_STAMP.read_text().strip() != RECIPE_SHA256:
        raise SystemExit("Torrent engine build recipe changed. Run scripts/prepare-torrent-engine.py.")
    if not EXECUTABLE.is_file() or EXECUTABLE.is_symlink() or not os.access(EXECUTABLE, os.X_OK):
        raise SystemExit("Missing local torrent engine. Run scripts/prepare-torrent-engine.py first.")
    version = subprocess.check_output([str(EXECUTABLE), "--version"], text=True)
    if (f"aria2 version {VERSION}" not in version or "BitTorrent" not in version or
            "AppleTLS" not in version or f"GMP/{GMP_VERSION}" not in version):
        raise SystemExit("Torrent engine version or required features do not match.")
    libraries = subprocess.check_output(["otool", "-L", str(EXECUTABLE)], text=True)
    if any(not line.strip().startswith(("/usr/lib/", "/System/Library/")) for line in libraries.splitlines()[1:]):
        raise SystemExit("Torrent engine depends on non-system libraries; rebuild using this script.")
    build = subprocess.check_output(["xcrun", "vtool", "-show-build", str(EXECUTABLE)], text=True)
    if not re.search(r"\bminos 13\.0\b", build):
        raise SystemExit("Torrent engine must target macOS 13.0.")
    architecture = subprocess.check_output(["lipo", "-archs", str(EXECUTABLE)], text=True).strip()
    if architecture != "arm64":
        raise SystemExit("The app currently requires an arm64 torrent engine.")
    if not ARCHIVE.is_file() or digest(ARCHIVE) != SHA256 or not (SOURCE / "COPYING").is_file():
        raise SystemExit("The pinned corresponding aria2 source or license is missing.")
    if not GMP_ARCHIVE.is_file() or digest(GMP_ARCHIVE) != GMP_SHA256 or not (GMP_SOURCE / "COPYINGv2").is_file():
        raise SystemExit("The pinned corresponding GMP source or license is missing.")


def build_gmp():
    # aria2's internal DH fallback uses modular multiplication instead of
    # exponentiation and cannot interoperate with standard encrypted peers.
    # Use its supported GMP backend, linked statically so installed apps still
    # need only macOS libraries. Do not pick up a Homebrew dylib by accident.
    if not GMP_ARCHIVE.exists():
        print(f"Downloading official GMP {GMP_VERSION} source…", flush=True)
        temporary = GMP_ARCHIVE.with_suffix(".download")
        try:
            with urllib.request.urlopen(GMP_URL, timeout=60) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            if digest(temporary) != GMP_SHA256:
                raise SystemExit("GMP source checksum mismatch.")
            temporary.rename(GMP_ARCHIVE)
        finally:
            temporary.unlink(missing_ok=True)
    if digest(GMP_ARCHIVE) != GMP_SHA256:
        raise SystemExit("GMP source checksum mismatch.")
    if not GMP_SOURCE.exists():
        with tarfile.open(GMP_ARCHIVE) as archive:
            for entry in archive.getmembers():
                parts = Path(entry.name).parts
                if not parts or parts[0] != f"gmp-{GMP_VERSION}" or ".." in parts:
                    raise SystemExit("Unsafe path in GMP source archive.")
                path = GMP_SOURCE.joinpath(*parts[1:]).resolve()
                if not (entry.isfile() or entry.isdir()) or GMP_SOURCE.resolve() not in (path, *path.parents):
                    raise SystemExit("Unsafe path in GMP source archive.")
                if entry.isdir():
                    path.mkdir(parents=True, exist_ok=True)
                else:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(entry) as source, path.open("wb") as output:
                        shutil.copyfileobj(source, output)
                    path.chmod(entry.mode & 0o777)
    expected = GMP_SHA256 + " " + RECIPE_SHA256 + " " + (digest(GMP_LIBRARY) if GMP_LIBRARY.is_file() else "")
    if not GMP_STAMP.is_file() or GMP_STAMP.read_text().strip() != expected:
        log = CACHE / "gmp-build.log"
        print(f"Building and testing static GMP; log: {log}", flush=True)
        with log.open("w") as output:
            jobs = f"-j{min(8, os.cpu_count() or 2)}"
            for command in [["./configure", f"--prefix={GMP_PREFIX}"] + GMP_CONFIGURE,
                            ["make", jobs], ["make", jobs, "check"], ["make", "install"]]:
                subprocess.run(command, cwd=GMP_SOURCE, stdout=output, stderr=subprocess.STDOUT, check=True)
        GMP_STAMP.write_text(GMP_SHA256 + " " + RECIPE_SHA256 + " " + digest(GMP_LIBRARY) + "\n")


def build():
    CACHE.mkdir(parents=True, exist_ok=True)
    build_gmp()
    if not ARCHIVE.exists():
        print(f"Downloading official aria2 {VERSION} source…", flush=True)
        temporary = ARCHIVE.with_suffix(".download")
        try:
            with urllib.request.urlopen(SOURCE_URL, timeout=60) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            if digest(temporary) != SHA256:
                raise SystemExit("aria2 source checksum mismatch.")
            temporary.rename(ARCHIVE)
        finally:
            temporary.unlink(missing_ok=True)
    if digest(ARCHIVE) != SHA256:
        raise SystemExit("aria2 source checksum mismatch.")
    if not SOURCE.exists():
        with tarfile.open(ARCHIVE) as archive:
            for entry in archive.getmembers():
                parts = Path(entry.name).parts
                if not parts or parts[0] != f"aria2-{VERSION}" or ".." in parts:
                    raise SystemExit("Unsafe path in aria2 source archive.")
                path = SOURCE.joinpath(*parts[1:]).resolve()
                if not (entry.isfile() or entry.isdir()) or SOURCE.resolve() not in (path, *path.parents):
                    raise SystemExit("Unsafe path in aria2 source archive.")
                if entry.isdir():
                    path.mkdir(parents=True, exist_ok=True)
                else:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(entry) as source, path.open("wb") as output:
                        shutil.copyfileobj(source, output)
                    path.chmod(entry.mode & 0o777)
    patch_stamp = SOURCE / ".mycloud-release-patch"
    if not patch_stamp.exists():
        subprocess.run(["patch", "--batch", "-p1", "-i", str(PATCH)], cwd=SOURCE, check=True)
        patch_stamp.write_text(PATCH_SHA256)
    if patch_stamp.read_text() != PATCH_SHA256:
        raise SystemExit("Unexpected torrent source patch version.")
    expected = PATCH_SHA256 + " " + (digest(EXECUTABLE) if EXECUTABLE.is_file() else "")
    if (not BUILD_STAMP.is_file() or BUILD_STAMP.read_text().strip() != expected or
            not RECIPE_STAMP.is_file() or RECIPE_STAMP.read_text().strip() != RECIPE_SHA256):
        log = CACHE / "build.log"
        print(f"Building portable torrent engine; log: {log}", flush=True)
        with log.open("w") as output:
            for command in [["./configure", f"--prefix={PREFIX}"] + CONFIGURE,
                            ["make", f"-j{min(8, os.cpu_count() or 2)}"], ["make", "install-strip"]]:
                subprocess.run(command, cwd=SOURCE, stdout=output, stderr=subprocess.STDOUT, check=True)
        BUILD_STAMP.write_text(PATCH_SHA256 + " " + digest(EXECUTABLE) + "\n")
        RECIPE_STAMP.write_text(RECIPE_SHA256 + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--destination", type=Path)
    args = parser.parse_args()
    if not args.verify_only:
        build()
    verify()
    if args.destination:
        args.destination.mkdir(parents=True, exist_ok=False)
        shutil.copy2(EXECUTABLE, args.destination / "aria2c")
        shutil.copy2(SOURCE / "COPYING", args.destination / "COPYING.txt")
        # Ship the exact corresponding source alongside the GPL executable.
        shutil.copy2(ARCHIVE, args.destination / ARCHIVE.name)
        shutil.copy2(GMP_ARCHIVE, args.destination / GMP_ARCHIVE.name)
        shutil.copy2(GMP_SOURCE / "COPYINGv2", args.destination / "GMP-COPYING.txt")
        shutil.copy2(PATCH, args.destination / PATCH.name)
        shutil.copy2(ROOT / "docs/LOCAL_TORRENTS.md", args.destination / "README.md")
        shutil.copy2(Path(__file__), args.destination / "prepare-torrent-engine.py")
        (args.destination / "BUILD.txt").write_text(
            f"aria2 {VERSION}, GPL-2.0-or-later; separate executable.\n"
            f"Official source: {SOURCE_URL}\nSHA-256: {SHA256}\n"
            f"MyCloudDriver live relay release patch SHA-256: {PATCH_SHA256}\n"
            f"Static GMP {GMP_VERSION}, GPL-2.0-or-later; source: {GMP_URL}\nSHA-256: {GMP_SHA256}\n"
            "Build on an Apple Silicon Mac with Xcode command-line tools:\n"
            f"tar xf gmp-{GMP_VERSION}.tar.xz\ncd gmp-{GMP_VERSION}\n"
            "./configure --prefix=\"$PWD/runtime\" " + " ".join("'" + item + "'" for item in GMP_CONFIGURE) +
            "\nmake -j8\nmake -j8 check\nmake install\n"
            "export TORRENT_GMP_PREFIX=\"$PWD/runtime\"\ncd ..\n"
            f"tar xf aria2-{VERSION}.tar.xz\ncd aria2-{VERSION}\n"
            "patch -p1 < ../aria2-relay-release.patch\n"
            "./configure --prefix=\"$PWD/runtime\" " + " ".join("'" + item + "'" for item in CONFIGURE
                if not item.startswith(("CPPFLAGS=", "LDFLAGS="))) +
            ' "CPPFLAGS=-I$TORRENT_GMP_PREFIX/include" "LDFLAGS=-L$TORRENT_GMP_PREFIX/lib -mmacosx-version-min=13.0"' +
            "\nmake -j8\nmake install-strip\n", encoding="utf-8")
    print(f"Verified aria2 {VERSION}: arm64, macOS 13+, BitTorrent, Apple TLS, static GMP; system dylibs only.")


if __name__ == "__main__":
    main()
