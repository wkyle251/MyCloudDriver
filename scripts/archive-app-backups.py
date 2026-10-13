#!/usr/bin/env python3
"""Keep rollback copies without exposing obsolete apps to macOS launchers."""

import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import stat
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "MyCloudDriver.app"
LEGACY_APP_NAME = "My PikPak for Mac.app"
LSREGISTER = Path(
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    "LaunchServices.framework/Support/lsregister"
)


def running_commands():
    return subprocess.check_output(["ps", "-axo", "command="], text=True).splitlines()


def is_running(app, commands):
    executable = str(app / "Contents/MacOS/PikPakDownloader")
    return any(command == executable or command.startswith(executable + " ") for command in commands)


def validated_backup(app):
    """Only a real bundle directly inside a real dist backup directory is ours."""
    dist = ROOT / "dist"
    if dist.is_symlink() or app.is_symlink() or app.parent.is_symlink():
        raise RuntimeError(f"Refusing a symlink backup path: {app}")
    if app.parent.parent != dist or app.name not in (APP_NAME, LEGACY_APP_NAME) or not (
        app.parent.name.startswith("installed-backup-") or app.parent.name.startswith("update-backup-")
    ):
        raise RuntimeError(f"Unexpected backup path: {app}")
    resolved = app.resolve(strict=True)
    if resolved.parent.parent != dist.resolve(strict=True) or not resolved.is_dir():
        raise RuntimeError(f"Backup is outside the backup directory: {app}")
    return resolved


def stream_digest(stream):
    checksum = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        checksum.update(chunk)
    return checksum.digest()


def remove_backup(app, identity):
    """Hold dist/backup/bundle descriptors through recursive retirement."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    dist = os.open(ROOT / "dist", flags)
    try:
        parent = os.open(app.parent.name, flags, dir_fd=dist)
        try:
            bundle = os.open(app.name, flags, dir_fd=parent)
            try:
                info = os.fstat(bundle)
                if (info.st_dev, info.st_ino) != identity:
                    raise RuntimeError(f"The backup app changed before retirement: {app}")
                def empty(directory):
                    with os.scandir(directory) as entries:
                        for entry in entries:
                            mode = os.stat(entry.name, dir_fd=directory, follow_symlinks=False).st_mode
                            if stat.S_ISDIR(mode):
                                child = os.open(entry.name, flags, dir_fd=directory)
                                try: empty(child)
                                finally: os.close(child)
                                os.rmdir(entry.name, dir_fd=directory)
                            else:
                                os.unlink(entry.name, dir_fd=directory)
                empty(bundle)
            finally:
                os.close(bundle)
            os.rmdir(app.name, dir_fd=parent)
        finally:
            os.close(parent)
    finally:
        os.close(dist)


def archive_app(app):
    """Verify every regular file before retiring a launchable backup bundle."""
    app = validated_backup(app)
    identity = (app.stat().st_dev, app.stat().st_ino)
    if is_running(app, running_commands()):
        raise RuntimeError(f"Quit this backup app before archiving it: {app}")
    destination = app.with_suffix(".app.zip")
    if destination.exists():
        raise FileExistsError(destination)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.wky.PikPakDownloader":
        raise RuntimeError(f"Unexpected backup app identity: {app}")
    with tempfile.TemporaryDirectory(prefix=".archive-", dir=app.parent) as temporary:
        archive = Path(temporary) / destination.name
        subprocess.run(
            ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)],
            check=True,
        )
        with zipfile.ZipFile(archive) as contents:
            bad_member = contents.testzip()
            if bad_member:
                raise RuntimeError(f"Corrupt backup archive member: {bad_member}")
            for path in app.rglob("*"):
                if path.is_file() and not path.is_symlink():
                    name = str(path.relative_to(app.parent))
                    with contents.open(name) as saved, path.open("rb") as original:
                        if stream_digest(saved) != stream_digest(original):
                            raise RuntimeError(f"Backup verification failed: {name}")
        archive.rename(destination)
    subprocess.run([str(LSREGISTER), "-u", str(app)], check=True)
    # Recheck the boundary and directory identity after potentially slow work.
    validated_backup(app)
    if (app.stat().st_dev, app.stat().st_ino) != identity:
        raise RuntimeError(f"The backup app changed during archiving: {app}")
    if is_running(app, running_commands()):
        raise RuntimeError(f"The backup app started during archiving: {app}")
    remove_backup(app, identity)
    print(f"Archived {info['CFBundleShortVersionString']}: {destination.relative_to(ROOT)}", flush=True)


def main():
    dist = ROOT / "dist"
    backups = [
        path for pattern in ("installed-backup-*", "update-backup-*")
        for directory in dist.glob(pattern)
        for name in (APP_NAME, LEGACY_APP_NAME)
        if (path := directory / name).is_dir()
    ]
    commands = running_commands()
    for app in backups:
        if is_running(app, commands):
            raise RuntimeError(f"Quit this backup app before archiving it: {app}")
    for app in sorted(backups):
        archive_app(app)
    installed = Path.home() / "Applications" / APP_NAME
    # The build artifact also shares the app identity. Launchers should resolve
    # that identity to the installed copy rather than a distribution directory.
    for name in (APP_NAME, LEGACY_APP_NAME):
        build = dist / name
        if build.exists():
            subprocess.run([str(LSREGISTER), "-u", str(build)], check=True)
    if installed.exists():
        subprocess.run([str(LSREGISTER), "-f", str(installed)], check=True)
    print(f"Registered installed app: {installed}", flush=True)


if __name__ == "__main__":
    main()
