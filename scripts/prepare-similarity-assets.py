#!/usr/bin/env python3
"""Verify explicitly provisioned FileTwin assets and copy them into an app.

Never downloads anything during a build or at application runtime. Provision
with vendor/FileTwin/scripts/setup-native.py first; see README.md.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def verify(directory):
    profile = (ROOT / "vendor/FileTwin/crates/filetwin-core/src/profile.rs").read_text()
    model_hash = re.search(r'pub const SSCD_MODEL_SHA256: &str =\s*"([0-9a-f]{64})"', profile).group(1)
    artifacts = json.loads((ROOT / "vendor/FileTwin/crates/filetwin-worker/runtime-artifacts.json").read_text())
    expected = {"sscd_disc_mixup.onnx": model_hash}
    for component in ["onnxruntime", "pdfium"]:
        expected[f"runtime/lib{component}.dylib"] = artifacts[component]["macos-aarch64"]["library_sha256"]
    for name, checksum in expected.items():
        path = directory / name
        if not path.is_file() or path.is_symlink() or digest(path) != checksum:
            raise SystemExit("Missing or mismatched FileTwin native asset: " + name +
                             ". Provision .local/filetwin-models as described in README.md.")
    if not (directory / "notices/THIRD_PARTY_NOTICES.md").is_file():
        raise SystemExit("The FileTwin native asset notices are missing. Run setup-native.py again.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--destination", type=Path)
    args = parser.parse_args()
    source = Path(os.environ.get("FILETWIN_MODEL_DIR", ROOT / ".local/filetwin-models")).resolve()
    verify(source)
    if args.destination:
        if args.destination.exists():
            raise SystemExit("Refusing to replace an existing FileTwin model directory.")
        args.destination.mkdir(parents=True)
        for name in ["sscd_disc_mixup.onnx", "runtime", "notices", "installed-artifacts.json"]:
            path = source / name
            if path.is_dir():
                shutil.copytree(path, args.destination / name)
            else:
                shutil.copy2(path, args.destination / name)
        verify(args.destination)
    print("Verified FileTwin model, ONNX Runtime, PDFium and component notices.")


if __name__ == "__main__":
    main()
