#!/usr/bin/env python3
"""Measure synthetic loopback transfers without a cloud account or user files."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
# Keep comparisons with older builds reproducible even from a proxied shell.
# This changes only the benchmark child process, never macOS/app preferences.
environment = {key: value for key, value in os.environ.items() if "proxy" not in key.lower()}
raise SystemExit(subprocess.run([
    sys.executable, str(root / "scripts/with-client-credentials.py"),
    "cargo", "test", "--release", "--locked", "--bin", "pikpak",
    "download_speed_tests::download_speed_benchmark", "--", "--ignored",
    "--nocapture", "--test-threads=1",
], cwd=root, env=environment).returncode)
