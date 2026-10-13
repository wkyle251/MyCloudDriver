#!/usr/bin/env python3
"""Synthetic install/rollback/lock tests; no installed app or native tool is used."""
import fcntl
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zipfile

SCRIPT = Path(__file__).with_name("install-app.py").resolve()
spec = importlib.util.spec_from_file_location("fixture_installer", SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def make_app(path, label):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": installer.APP_ID}))
    binary = path / "Contents/MacOS/PikPakDownloader"
    binary.write_text(label); binary.chmod(0o755)
    (path / "Contents/current").symlink_to("MacOS/PikPakDownloader")


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        (self.root / "dist").mkdir()
        self.source = self.root / "source/MyCloudDriver.app"
        self.destination = self.root / "installed/MyCloudDriver.app"
        make_app(self.source, "new synthetic bytes")
        self.commands = []
        self.fail_registration = False
        self.root_patch = patch.object(installer, "ROOT", self.root)
        self.native_patch = patch.object(installer.subprocess, "run", side_effect=self.native)
        self.process_patch = patch.object(installer, "processes", return_value={})
        for item in [self.root_patch, self.native_patch, self.process_patch]: item.start()

    def tearDown(self):
        for item in [self.process_patch, self.native_patch, self.root_patch]: item.stop()
        self.temporary.cleanup()

    def native(self, command, **kwargs):
        self.commands.append(command)
        if command[0] == "ditto":
            source, target = Path(command[-2]), Path(command[-1])
            if "-c" in command:
                with zipfile.ZipFile(target, "w") as zipped:
                    for path in source.rglob("*"):
                        name = str(path.relative_to(source.parent))
                        if path.is_symlink(): zipped.writestr(name, str(path.readlink()))
                        elif path.is_file(): zipped.write(path, name)
            else: shutil.copytree(source, target, symlinks=True)
        elif command[0] == installer.LSREGISTER:
            if self.fail_registration: raise subprocess.CalledProcessError(1, command)
        elif command[0] not in ("codesign", "open"):
            raise AssertionError(f"No real native command allowed: {command}")

    def test_new_and_identical_install_preserve_inventory_and_skip_restart(self):
        installer.install(self.source, self.destination, launch=False)
        self.assertEqual(installer.inventory(self.source), installer.inventory(self.destination))
        before = (self.destination / "Contents/MacOS/PikPakDownloader").stat().st_mtime_ns
        with patch.object(installer, "backup", side_effect=AssertionError("No identical backup")), patch.object(installer, "quit_app", side_effect=AssertionError("No identical quit")):
            installer.install(self.source, self.destination, launch=False)
        self.assertEqual(before, (self.destination / "Contents/MacOS/PikPakDownloader").stat().st_mtime_ns)
        self.assertFalse(any(command[0] == "open" for command in self.commands))

    def test_corrupt_staged_copy_fails_before_touching_old_app(self):
        make_app(self.destination, "old synthetic bytes")
        expected = installer.inventory(self.destination)
        real_inventory = installer.inventory
        def damaged(bundle):
            result = real_inventory(bundle)
            if bundle.parent.name.startswith(".mycloud-install-"): result["missing"] = {}
            return result
        with patch.object(installer, "inventory", side_effect=damaged), patch.object(installer, "quit_app", side_effect=AssertionError("Staging must validate before quit")):
            with self.assertRaisesRegex(RuntimeError, "Staged app does not match"):
                installer.install(self.source, self.destination, launch=False)
        self.assertEqual(installer.inventory(self.destination), expected)

    def test_registration_failure_restores_old_app_and_verified_backup(self):
        make_app(self.destination, "old synthetic bytes")
        expected = installer.inventory(self.destination)
        self.fail_registration = True
        with self.assertRaises(subprocess.CalledProcessError):
            installer.install(self.source, self.destination, launch=False)
        self.assertEqual(installer.inventory(self.destination), expected)
        archives = list((self.root / "dist").glob("installed-backup-*/*.app.zip"))
        self.assertEqual(len(archives), 1)
        with zipfile.ZipFile(archives[0]) as zipped:
            self.assertEqual(zipped.read("MyCloudDriver.app/Contents/MacOS/PikPakDownloader"), b"old synthetic bytes")
        self.assertFalse(list(self.destination.parent.glob(".mycloud-install-*")))

    def test_symlink_destination_preserves_target_and_never_runs_native_commands(self):
        outside = self.root / "outside/MyCloudDriver.app"; make_app(outside, "outside synthetic bytes")
        self.destination.parent.mkdir(parents=True)
        self.destination.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            installer.install(self.source, self.destination, launch=False)
        self.assertEqual((outside / "Contents/MacOS/PikPakDownloader").read_text(), "outside synthetic bytes")
        self.assertTrue(self.destination.is_symlink())
        self.assertEqual(self.commands, [])

    def test_standalone_install_waits_for_build_and_inherited_child_does_not_deadlock(self):
        # The subprocess replaces install() with a marker writer before main().
        # It cannot invoke native commands or access an actual application.
        (self.root / ".build").mkdir()
        child_code = """import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('locked_installer',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
m.ROOT=pathlib.Path(sys.argv[2]);ready=m.ROOT/'ready';marker=m.ROOT/'installed-marker'
m.install=lambda *args: marker.write_text('synthetic install admitted')
sys.argv=['fixture','--source',str(m.ROOT/'source'),'--destination',str(m.ROOT/'destination'),'--no-launch'];ready.write_text('ready');m.main()
"""
        with (self.root / ".build/app-build.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            environment = dict(os.environ); environment.pop("MYCLOUD_APP_BUILD_LOCK", None)
            child = subprocess.Popen([sys.executable, "-c", child_code, str(SCRIPT), str(self.root)], env=environment)
            try:
                deadline = time.monotonic() + 5
                while not (self.root / "ready").exists() and time.monotonic() < deadline: time.sleep(0.01)
                self.assertTrue((self.root / "ready").exists())
                time.sleep(0.1)
                self.assertIsNone(child.poll())
                self.assertFalse((self.root / "installed-marker").exists())
                fcntl.flock(lock, fcntl.LOCK_UN)
                self.assertEqual(child.wait(timeout=5), 0)
                self.assertTrue((self.root / "installed-marker").exists())
                fcntl.flock(lock, fcntl.LOCK_EX)
                environment["MYCLOUD_APP_BUILD_LOCK"] = str(self.root)
                inherited = subprocess.Popen([sys.executable, "-c", child_code, str(SCRIPT), str(self.root)], env=environment)
                try: self.assertEqual(inherited.wait(timeout=5), 0)
                finally:
                    if inherited.poll() is None: inherited.kill(); inherited.wait()
            finally:
                if child.poll() is None: child.kill(); child.wait()


if __name__ == "__main__":
    unittest.main(verbosity=2)
