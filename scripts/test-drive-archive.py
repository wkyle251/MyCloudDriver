#!/usr/bin/env python3
"""Exercise the production archive reader with synthetic, isolated archives."""
import ctypes
from pathlib import Path
import stat
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="myclouddriver-archive-tests-") as temporary:
    work = Path(temporary)
    library = work / "reader.dylib"
    subprocess.run(["xcrun", "clang", "-dynamiclib", "-O2", "-Wall", "-Wextra",
                    str(ROOT / "macos/DriveArchive.c"), "-larchive.2", "-o", str(library)], check=True)
    reader = ctypes.CDLL(str(library)).mcd_archive_extract
    callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_longlong, ctypes.c_char_p)
    reader.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                       callback_type, ctypes.c_char_p, ctypes.c_size_t]
    reader.restype = ctypes.c_int

    def extract(source, destination, password=b"", cancel=False):
        destination.mkdir()
        error = ctypes.create_string_buffer(1024)
        calls = []
        def progress(_, count, name):
            calls.append(count)
            return int(cancel)
        result = reader(bytes(source), bytes(destination), password, None, callback_type(progress), error, len(error))
        return result, calls

    source = work / "normal.zip"
    content = b"Synthetic content\n" * 100_000
    with zipfile.ZipFile(source, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("Documents/", b"")
        archive.writestr("Documents/Readme.txt", content)
        archive.writestr("Unicode/Garden 🌿.txt", b"Garden notes")
    result, calls = extract(source, work / "normal")
    assert result == 0 and len(calls) > 1
    assert (work / "normal/Documents/Readme.txt").read_bytes() == content
    assert (work / "normal/Unicode/Garden 🌿.txt").read_bytes() == b"Garden notes"
    assert stat.S_IMODE((work / "normal/Documents/Readme.txt").stat().st_mode) == 0o600
    print("PASS streamed ZIP extraction, progress, Unicode paths and private permissions")

    for index, name in enumerate(["../escape.txt", "/tmp/myclouddriver-escape.txt", "nested/../../escape.txt"]):
        unsafe = work / f"unsafe-{index}.zip"
        with zipfile.ZipFile(unsafe, "w") as archive:
            archive.writestr(name, b"must never escape")
        assert extract(unsafe, work / f"unsafe-{index}")[0] == 1
    assert not (work / "escape.txt").exists()
    symlink = work / "symlink.zip"
    with zipfile.ZipFile(symlink, "w") as archive:
        entry = zipfile.ZipInfo("outside")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(entry, "../")
        archive.writestr("outside/escape.txt", "blocked")
    assert extract(symlink, work / "symlink")[0] == 1
    print("PASS absolute/traversal paths and archive symlinks are rejected")

    text = work / "secret.txt"
    text.write_text("This password is a synthetic test value, not an account credential.")
    encrypted = work / "protected.zip"
    subprocess.run(["/usr/bin/zip", "-q", "-P", "fixture-password", str(encrypted), text.name], cwd=work, check=True)
    assert extract(encrypted, work / "locked")[0] == 2
    assert extract(encrypted, work / "wrong", b"wrong")[0] == 2
    assert extract(encrypted, work / "unlocked", b"fixture-password")[0] == 0
    assert (work / "unlocked/secret.txt").read_bytes() == text.read_bytes()
    assert extract(source, work / "cancelled", cancel=True)[0] == 3
    print("PASS password-required/retry/success and cooperative cancellation")
