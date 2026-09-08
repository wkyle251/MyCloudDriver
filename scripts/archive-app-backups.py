#!/usr/bin/env python3
"""Keep rollback copies without exposing obsolete apps to macOS launchers."""

import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "My PikPak for Mac.app"
LSREGISTER = Path(
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    "LaunchServices.framework/Support/lsregister"
)


def running_commands():
    return subprocess.check_output(["ps", "-axo", "command="], text=True).splitlines()


def archive_app(app):
    """Verify every regular file before retiring a launchable backup bundle."""
    app = app.resolve()
    if str(app / "Contents/MacOS/PikPakDownloader") in running_commands():
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
                    if hashlib.sha256(contents.read(name)).digest() != hashlib.sha256(path.read_bytes()).digest():
                        raise RuntimeError(f"Backup verification failed: {name}")
        archive.rename(destination)
    subprocess.run([str(LSREGISTER), "-u", str(app)], check=True)
    shutil.rmtree(app)
    print(f"Archived {info['CFBundleShortVersionString']}: {destination.relative_to(ROOT)}", flush=True)


def main():
    dist = ROOT / "dist"
    backups = [
        path for pattern in ("installed-backup-*", "update-backup-*")
        for directory in dist.glob(pattern)
        if (path := directory / APP_NAME).is_dir()
    ]
    commands = running_commands()
    for app in backups:
        if str(app / "Contents/MacOS/PikPakDownloader") in commands:
            raise RuntimeError(f"Quit this backup app before archiving it: {app}")
    for app in sorted(backups):
        archive_app(app)
    installed = Path.home() / "Applications" / APP_NAME
    # The build artifact also shares the app identity. Launchers should resolve
    # that identity to the installed copy rather than a distribution directory.
    build = dist / APP_NAME
    if build.exists():
        subprocess.run([str(LSREGISTER), "-u", str(build)], check=True)
    if installed.exists():
        subprocess.run([str(LSREGISTER), "-f", str(installed)], check=True)
    print(f"Registered installed app: {installed}", flush=True)


if __name__ == "__main__":
    main()
