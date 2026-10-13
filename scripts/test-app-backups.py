#!/usr/bin/env python3
"""Exercise backup containment with generated apps and mocked native commands."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("backup_archiver", ROOT / "scripts/archive-app-backups.py")
archiver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archiver)


def app(path):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.wky.PikPakDownloader", "CFBundleShortVersionString": "fixture"}))
    (path / "Contents/MacOS/PikPakDownloader").write_bytes(b"synthetic app bytes")


def native(command, **kwargs):
    if command[0] == "ditto":
        source, target = Path(command[-2]), Path(command[-1])
        with zipfile.ZipFile(target, "w") as archive:
            for path in source.rglob("*"):
                if path.is_file(): archive.write(path, str(path.relative_to(source.parent)))
    elif command[0] != str(archiver.LSREGISTER):
        raise AssertionError(command)


class BackupTests(unittest.TestCase):
    def test_real_backup_is_verified_and_retired(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            backup = root / "dist/installed-backup-fixture/MyCloudDriver.app"
            app(backup)
            with patch.object(archiver, "ROOT", root), patch.object(archiver, "running_commands", return_value=[]), patch.object(archiver.subprocess, "run", side_effect=native):
                archiver.archive_app(backup)
            self.assertFalse(backup.exists())
            with zipfile.ZipFile(backup.with_suffix(".app.zip")) as archive:
                self.assertEqual(archive.read("MyCloudDriver.app/Contents/MacOS/PikPakDownloader"), b"synthetic app bytes")

    def test_symlink_bundle_or_backup_parent_preserves_outside_app(self):
        for parent_link in (False, True):
            with self.subTest(parent_link=parent_link), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory).resolve(); root = temporary / "workspace"; dist = root / "dist"; dist.mkdir(parents=True)
                outside = temporary / "outside/MyCloudDriver.app"; app(outside)
                backup = dist / "installed-backup-fixture/MyCloudDriver.app"
                if parent_link: backup.parent.symlink_to(outside.parent, target_is_directory=True)
                else:
                    backup.parent.mkdir(); backup.symlink_to(outside, target_is_directory=True)
                with patch.object(archiver, "ROOT", root), patch.object(archiver, "running_commands", return_value=[]), patch.object(archiver.subprocess, "run", side_effect=AssertionError("No native command may run for a symlink backup")):
                    with self.assertRaisesRegex(RuntimeError, "symlink"):
                        archiver.archive_app(backup)
                self.assertTrue(outside.is_dir())
                self.assertFalse(outside.with_suffix(".app.zip").exists())

    def test_running_backup_with_arguments_is_not_retired(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); backup = root / "dist/update-backup-fixture/MyCloudDriver.app"; app(backup)
            command = str(backup / "Contents/MacOS/PikPakDownloader") + " --generated-fixture"
            with patch.object(archiver, "ROOT", root), patch.object(archiver, "running_commands", return_value=[command]), patch.object(archiver.subprocess, "run", side_effect=AssertionError("Running backups must not invoke native commands")):
                with self.assertRaisesRegex(RuntimeError, "Quit"):
                    archiver.archive_app(backup)
            self.assertTrue(backup.is_dir())

    def test_parent_replaced_after_final_validation_cannot_redirect_retirement(self):
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory).resolve(); root = temporary / "workspace"
            backup = root / "dist/installed-backup-fixture/MyCloudDriver.app"; app(backup)
            outside = temporary / "outside/MyCloudDriver.app"; app(outside)
            calls = 0
            def replace_parent(path, commands):
                nonlocal calls
                calls += 1
                if calls == 2:
                    path.parent.rename(path.parent.with_name("retained-original"))
                    path.parent.symlink_to(outside.parent, target_is_directory=True)
                return False
            with patch.object(archiver, "ROOT", root), patch.object(archiver, "is_running", side_effect=replace_parent), patch.object(archiver, "running_commands", return_value=[]), patch.object(archiver.subprocess, "run", side_effect=native):
                with self.assertRaises(OSError): archiver.archive_app(backup)
            self.assertEqual((outside / "Contents/MacOS/PikPakDownloader").read_bytes(), b"synthetic app bytes")
            self.assertTrue(backup.parent.with_name("retained-original").joinpath(backup.name).is_dir())


if __name__ == "__main__":
    unittest.main(verbosity=2)
