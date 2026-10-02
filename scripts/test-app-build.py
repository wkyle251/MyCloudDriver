#!/usr/bin/env python3
"""Exercise real Swift cache invalidation and installation without opening the app."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("app_install", ROOT / "scripts/install-app.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class BuildTests(unittest.TestCase):
    def test_incremental_compilation(self):
        with tempfile.TemporaryDirectory(prefix="mycloud-swift-build-") as directory:
            root = Path(directory)
            cache = root / "cache"
            value = root / "Value.swift"
            main = root / "Entry.swift"
            unrelated = root / "Unrelated.swift"
            binary = root / "Example"
            value.write_text("func value() -> Int { 7 }\n")
            main.write_text("""@main struct Entry {
    static func main() {
        let result: Int = value()
        #if ALTERNATE
        print(result + 100)
        #else
        print(result)
        #endif
    }
}
""")
            unrelated.write_text("func unrelated() -> Int { 123 }\n")
            command = [sys.executable, str(ROOT / "scripts/build-swift-app.py"),
                       "--cache-dir", str(cache), "--jobs", "2", "--", "-O",
                       "-swift-version", "5", "-parse-as-library", str(value),
                       str(main), str(unrelated), "-o", str(binary)]

            def build(extra=(), success=True):
                result = subprocess.run([*command, *extra], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.assertEqual(result.returncode == 0, success, result.stdout)
                return result.stdout

            def output():
                return subprocess.check_output([str(binary)], text=True).strip()

            build()
            self.assertEqual(output(), "7")
            original_time = binary.stat().st_mtime_ns
            object_times = {p: p.stat().st_mtime_ns for p in (cache / "objects").glob("*.o")}
            self.assertIn("unchanged", build())
            self.assertEqual(binary.stat().st_mtime_ns, original_time)
            self.assertEqual(object_times, {p: p.stat().st_mtime_ns for p in object_times})

            times = value.stat()
            value.write_text("func value() -> Int { 9 }\n")
            os.utime(value, ns=(times.st_atime_ns, times.st_mtime_ns))
            build()
            self.assertEqual(output(), "9", "Content changes with preserved timestamps must compile")
            unrelated_object = next((cache / "objects").glob("Unrelated-*.o"))
            self.assertEqual(unrelated_object.stat().st_mtime_ns, object_times[unrelated_object])

            value.write_text('func value() -> String { "wrong type" }\n')
            build(success=False)  # Must recheck the dependent Entry.swift, not silently reuse it.
            self.assertFalse((cache / "build.json").exists())
            value.write_text("func value() -> Int { 12 }\n")
            build()
            self.assertEqual(output(), "12")
            build(["-D", "ALTERNATE"])
            self.assertEqual(output(), "112", "Compiler flag changes must invalidate the cache")
            binary.write_bytes(b"damaged executable")
            build(["-D", "ALTERNATE"])
            self.assertEqual(output(), "112", "Damaged output must be rebuilt")
            command.remove(str(unrelated))
            build()
            self.assertEqual(output(), "12")
            self.assertEqual(len(list((cache / "objects").glob("*.o"))), 2)

    def test_installation_and_unchanged_skip(self):
        source = ROOT / "dist/AppBuild.noindex/MyCloudDriver.app"
        self.assertTrue(source.is_dir(), "Build the app before running this integration test")
        with tempfile.TemporaryDirectory(prefix="mycloud-install-test-", suffix=".noindex") as directory:
            destination = Path(directory) / source.name
            installer.install(source, destination, launch=False)
            self.assertEqual(installer.inventory(source), installer.inventory(destination))
            main = destination / "Contents/MacOS/PikPakDownloader"
            before = main.stat().st_mtime_ns
            with patch.object(installer, "backup", side_effect=AssertionError("Unchanged install must not back up")), \
                 patch.object(installer, "quit_app", side_effect=AssertionError("Unchanged install must not quit")):
                installer.install(source, destination, launch=False)
            self.assertEqual(main.stat().st_mtime_ns, before)
            # A broken staged copy must fail before touching the installed app.
            expected = installer.inventory(destination)
            real_inventory = installer.inventory

            def wrong_stage(bundle):
                result = real_inventory(bundle)
                if bundle.parent.name.startswith(".mycloud-install-"):
                    result["missing"] = {}
                return result

            with patch.object(installer, "inventory", side_effect=wrong_stage), \
                 patch.object(installer, "quit_app", side_effect=AssertionError("Invalid staging must not quit")):
                # Force a changed install without altering signed resources.
                (destination / "unexpected.txt").write_text("stale resource")
                with self.assertRaisesRegex(RuntimeError, "Staged app does not match"):
                    installer.install(source, destination, launch=False)
            (destination / "unexpected.txt").unlink()
            self.assertEqual(installer.inventory(destination), expected)
            subprocess.run([installer.LSREGISTER, "-u", str(destination)], check=False, stdout=subprocess.DEVNULL)

    def test_install_rollback(self):
        source = ROOT / "dist/AppBuild.noindex/MyCloudDriver.app"
        with tempfile.TemporaryDirectory(prefix="mycloud-rollback-test-", suffix=".noindex") as directory:
            root = Path(directory)
            (root / "dist").mkdir()
            destination = root / source.name
            subprocess.run(["ditto", str(source), str(destination)], check=True)
            (destination / "old-resource.txt").write_text("previous build")
            expected = installer.inventory(destination)
            run = subprocess.run

            def fail_registration(command, **kwargs):
                if command[0] == installer.LSREGISTER and "-f" in command:
                    raise subprocess.CalledProcessError(1, command)
                return run(command, **kwargs)

            with patch.object(installer, "ROOT", root), \
                 patch.object(installer.subprocess, "run", side_effect=fail_registration):
                with self.assertRaises(subprocess.CalledProcessError):
                    installer.install(source, destination, launch=False)
            self.assertEqual(installer.inventory(destination), expected)
            self.assertEqual(len(list((root / "dist").glob("installed-backup-*/*.app.zip"))), 1)
            self.assertFalse(list(root.glob(".mycloud-install-*")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
