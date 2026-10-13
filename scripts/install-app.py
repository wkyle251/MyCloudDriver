#!/usr/bin/env python3
"""Install a verified build; leave an identical installed app running."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "MyCloudDriver.app"
APP_ID = "com.wky.PikPakDownloader"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def digest(stream):
    checksum = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        checksum.update(chunk)
    return checksum.hexdigest()


def inventory(bundle):
    result = {}
    for path in sorted(bundle.rglob("*")):
        mode = path.lstat().st_mode
        entry = {"mode": stat.S_IMODE(mode)}
        if path.is_symlink():
            entry["symlink"] = str(path.readlink())
        elif path.is_file():
            with path.open("rb") as stream:
                entry["sha256"] = digest(stream)
        elif not path.is_dir():
            raise RuntimeError(f"Unexpected special file in app: {path}")
        result[str(path.relative_to(bundle))] = entry
    return result


def check_identity(bundle):
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != APP_ID:
        raise RuntimeError(f"Unexpected app identity: {bundle}")


def verify(bundle):
    check_identity(bundle)
    for suffix in ["", "Contents/Resources/pikpak", "Contents/Resources/filetwin-worker",
                   "Contents/Resources/TorrentEngine/aria2c", "Contents/Resources/TorrentEngine/mycloud-torrent"]:
        subprocess.run(["codesign", "--verify", "--strict", str(bundle / suffix)], check=True)


def backup(bundle, expected):
    directory = Path(tempfile.mkdtemp(prefix="installed-backup-" + time.strftime("%Y%m%d-%H%M%S") + "-", dir=ROOT / "dist"))
    archive = directory / (APP_NAME + ".zip")
    temporary = directory / "backup.partial.zip"
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(bundle), str(temporary)], check=True)
    with zipfile.ZipFile(temporary) as zipped:
        for name, entry in expected.items():
            member = bundle.name + "/" + name
            if "sha256" in entry:
                with zipped.open(member) as stream:
                    if digest(stream) != entry["sha256"]:
                        raise RuntimeError(f"Rollback archive verification failed: {name}")
            elif "symlink" in entry and zipped.read(member).decode() != entry["symlink"]:
                raise RuntimeError(f"Rollback symlink verification failed: {name}")
    temporary.rename(archive)
    print(f"Verified rollback backup: {archive}", flush=True)
    return archive


def processes():
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], text=True).splitlines()
    return {int(pid): (int(parent), command) for pid, parent, command in (row.split(None, 2) for row in rows)}


def app_processes(bundle, table):
    prefix = str(bundle) + "/Contents/"
    pids = {pid for pid, (_, command) in table.items() if command.startswith(prefix)}
    while True:
        descendants = {pid for pid, (parent, _) in table.items() if parent in pids}
        if descendants <= pids:
            return pids
        pids |= descendants


def quit_app(bundle):
    tracked = app_processes(bundle, processes())
    if not tracked:
        return False
    print("Quitting the installed app and waiting for its helpers to finish…", flush=True)
    subprocess.run(["osascript", "-e", "on run args", "-e",
                    "tell application (item 1 of args) to quit", "-e", "end run", str(bundle)],
                   check=True, timeout=30)
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        table = processes()
        tracked |= app_processes(bundle, table)
        if not (tracked & table.keys()):
            return True
        time.sleep(0.25)
    raise RuntimeError("The app or its helpers are still running; the installed bundle was not replaced.")


def install(source, destination, launch=True):
    started = time.monotonic()
    if destination.is_symlink():
        raise RuntimeError(f"The installation path is a symlink; choose a real app destination: {destination}")
    verify(source)
    expected = inventory(source)
    if source == destination:
        raise RuntimeError("Build and installation paths must be different.")
    old = None
    if destination.exists():
        check_identity(destination)
        old = inventory(destination)
        if old == expected:
            if launch and not app_processes(destination, processes()):
                subprocess.run(["open", str(destination)], check=True)
            print(f"Already installed; no backup, replacement or restart needed ({time.monotonic() - started:.2f}s).", flush=True)
            return
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".mycloud-install-", suffix=".noindex", dir=destination.parent))
    previous = stage / "previous.app"
    try:
        staged = stage / APP_NAME
        subprocess.run(["ditto", str(source), str(staged)], check=True)
        verify(staged)
        if inventory(staged) != expected:
            raise RuntimeError("Staged app does not match the verified build.")
        # Copy and archive while the old app is still running to keep downtime short.
        archive = backup(destination, old) if old is not None else None
        was_running = quit_app(destination)
        if destination.exists():
            destination.rename(previous)
        try:
            staged.rename(destination)
            verify(destination)
            subprocess.run([LSREGISTER, "-f", str(destination)], check=True)
        except BaseException:
            if destination.exists():
                destination.rename(stage / "failed.app")
            if previous.exists():
                previous.rename(destination)
                if was_running:
                    subprocess.run(["open", str(destination)], check=False)
            raise
        # From here the installation is verified. A launch failure can be retried
        # without restoring or deleting a possibly running app bundle.
        if previous.exists():
            shutil.rmtree(previous)
        if archive:
            archive.with_name("install.json").write_text(json.dumps({
                "source": str(source), "installed": str(destination), "backup": str(archive),
            }, indent=2) + "\n")
        if launch:
            subprocess.run(["open", str(destination)], check=True)
        print(f"Installed{' and launched' if launch else ''} in {time.monotonic() - started:.2f}s: {destination}", flush=True)
    finally:
        # Preserve the old bundle if an exceptional filesystem failure prevented rollback.
        if not previous.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "dist/AppBuild.noindex" / APP_NAME)
    parser.add_argument("--destination", type=Path, default=Path.home() / "Applications" / APP_NAME)
    parser.add_argument("--no-launch", action="store_true", help="Install without launching (also useful for isolated checks).")
    args = parser.parse_args()
    (ROOT / ".build").mkdir(exist_ok=True)
    (ROOT / "dist").mkdir(exist_ok=True)
    # Standalone installs must not inventory/copy a bundle while a build swaps
    # it. A --install child already inherits its parent's held build lock.
    with (ROOT / ".build/app-build.lock").open("a") as build_lock:
        if os.environ.get("MYCLOUD_APP_BUILD_LOCK") != str(ROOT):
            fcntl.flock(build_lock, fcntl.LOCK_EX)
        with (ROOT / ".build/app-install.lock").open("a") as install_lock:
            fcntl.flock(install_lock, fcntl.LOCK_EX)
            install(args.source.resolve(), args.destination.absolute(), not args.no_launch)


if __name__ == "__main__":
    main()
