#!/usr/bin/env python3
"""Inject local OAuth application credentials into builds without logging them."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parent.parent
    source = root / ".local/pikpak-client-credentials.json"
    values = json.loads(source.read_text()) if source.exists() else {}
    environment = os.environ.copy()
    for field, key in [
        ("web_client_secret", "PIKPAK_WEB_CLIENT_SECRET"),
        ("desktop_client_secret", "PIKPAK_DESKTOP_CLIENT_SECRET"),
    ]:
        value = environment.get(key) or values.get(field)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(
                f"Missing {field}. Copy pikpak-client-credentials.example.json to "
                ".local/pikpak-client-credentials.json and configure it locally, "
                f"or set {key} in the build environment."
            )
        environment[key] = value

    if len(sys.argv) == 3 and sys.argv[1] == "--write-plist":
        path = Path(sys.argv[2]).resolve()
        if not path.is_relative_to(root / "dist"):
            raise ValueError("Build credentials may only be written under ignored dist/.")
        info = plistlib.loads(path.read_bytes())
        info["PikPakDesktopClientSecret"] = environment["PIKPAK_DESKTOP_CLIENT_SECRET"]
        path.write_bytes(plistlib.dumps(info, sort_keys=False))
        return 0
    if len(sys.argv) < 2:
        raise ValueError("Supply a build command or --write-plist <dist/Info.plist>.")
    return subprocess.run(sys.argv[1:], env=environment, cwd=root).returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError):
        # Malformed configuration must never echo a secret-bearing file or
        # JSON fragment into shared build logs.
        print("Client credentials are missing or invalid. Configure .local/pikpak-client-credentials.json "
              "from the example, or set PIKPAK_WEB_CLIENT_SECRET and PIKPAK_DESKTOP_CLIENT_SECRET.",
              file=sys.stderr)
        sys.exit(1)
