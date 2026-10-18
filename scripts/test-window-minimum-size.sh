#!/bin/zsh
set -euo pipefail
project_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/mycloud-window-minimum.XXXXXX")"
trap 'rm -rf -- "$test_directory"' EXIT
python3 - "$project_root" "$test_directory/test.swift" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
source = (root / "macos/ContentView.swift").read_text()
start = source.index("private struct WindowMinimumSizeController: NSViewRepresentable")
end = source.index("private enum DownloadQueueDisplayRow", start)
controller = source[start:end]
# Instrument only callback boundaries and owned property writes. The code
# under test is extracted from the production file, not copied into this test.
for signature in ["    override func layout() {", "    private func attachToCurrentWindow() {"]:
    assert controller.count(signature) == 1
    controller = controller.replace(signature, signature + "\n        MinimumSizeProbe.callbackDepth += 1\n        defer { MinimumSizeProbe.callbackDepth -= 1 }")
marker = "    ) {\n        nsView.scheduleMinimumSizeReset()"
assert controller.count(marker) == 1
controller = controller.replace(marker, "    ) {\n        MinimumSizeProbe.callbackDepth += 1\n        defer { MinimumSizeProbe.callbackDepth -= 1 }\n        nsView.scheduleMinimumSizeReset()")
marker = "        ) { [weak self] _ in\n            self?.scheduleMinimumSizeReset()"
assert controller.count(marker) == 1
controller = controller.replace(marker, "        ) { [weak self] _ in\n            MainActor.assumeIsolated {\n                MinimumSizeProbe.callbackDepth += 1\n                defer { MinimumSizeProbe.callbackDepth -= 1 }\n                self?.scheduleMinimumSizeReset()\n            }")
marker = "    fileprivate func enforceMinimumSize() {"
assert controller.count(marker) == 1
controller = controller.replace(marker, marker + "\n        MinimumSizeProbe.enforcing = true\n        defer { MinimumSizeProbe.enforcing = false }")
controller = controller.replace("        resetScheduled = true", "        resetScheduled = true\n        MinimumSizeProbe.scheduledTurns += 1")
test = (root / "scripts/WindowMinimumSizeTests.swift").read_text()
Path(sys.argv[2]).write_text("import AppKit\nimport SwiftUI\n" + controller + test)
PY
swiftc -parse-as-library -swift-version 5 "$test_directory/test.swift" -o "$test_directory/test"
"$test_directory/test"
