#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
recovery_build="${PWD}/.build/auto-recovery"
mkdir -p "${recovery_build}/sources"
python3 - <<'PY'
from pathlib import Path
names = ['AutomaticRecoveryTests', 'LocalTorrentTests', 'NativeTransferFairnessTests',
         'DownloadRetryTests', 'SharedLinkRetryTests', 'TransferControlTests',
         'ImagePreviewTests', 'PreviewTransportTests', 'FolderThumbnailTests',
         'SimilarityTests', 'TransferPersistenceTests', 'BrowserFolderExpansionTests']
root = Path('.build/auto-recovery/sources')
for name in names:
    (root / (name + '.swift')).write_text(Path('scripts', name + '.swift').read_text().replace('@main', '', 1))
(root / 'RecoveryMain.swift').write_text('''import Foundation
@main struct RecoveryMain {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.count == 3 && ["--write", "--read"].contains(CommandLine.arguments[1]) {
            try TransferPersistenceTests.main(); return
        }
        try await AutomaticRecoveryTests.main()
        try DownloadRetryTests.main()
        try SharedLinkRetryTests.main()
        try TransferPersistenceTests.main()
        try await TransferControlTests.main()
        try await NativeTransferFairnessTests.main()
        try await LocalTorrentTests.main()
        PreviewTransportTests.main()
        try await ImagePreviewTests.main()
        try await FolderThumbnailTests.main()
        try await BrowserFolderExpansionTests.main()
        try await SimilarityTests.main()
        print("All automatic recovery regression suites passed.")
    }
}
''')
PY
recovery_sources=(macos/*.swift)
recovery_sources=("${(@)recovery_sources:#macos/PikPakDownloaderApp.swift}")
xcrun clang -target arm64-apple-macos13.0 -O2 -Wall -Wextra -c macos/DriveArchive.c -o "${recovery_build}/archive.o"
swiftc -D FINDER_WORKSPACE_TESTS -D TRANSFER_PERSISTENCE_TESTS -D FOLDER_EXPANSION_TESTS \
    -swift-version 5 -target arm64-apple-macos13.0 -parse-as-library \
    "${recovery_sources[@]}" "${recovery_build}"/sources/*.swift "${recovery_build}/archive.o" \
    -framework AVKit -larchive.2 -o "${recovery_build}/regressions"
"${recovery_build}/regressions" "${1:-${PWD}/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources}"
