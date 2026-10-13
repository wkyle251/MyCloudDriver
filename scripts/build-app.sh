#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIRECTORY:h}"
INSTALL_APP=0
CLEAN_SWIFT=0
for option in "$@"; do
    case "${option}" in
        --install) INSTALL_APP=1 ;;
        --clean) CLEAN_SWIFT=1 ;;
        --help|-h)
            print "Usage: $0 [--clean] [--install]"
            print "Reuses optimized Swift objects. --clean resets only the Swift cache."
            print "Set MYCLOUD_BUILD_JOBS to override compiler concurrency."
            exit 0 ;;
        *) print -u2 "Unknown option: ${option}"; exit 2 ;;
    esac
done
if [[ "${MYCLOUD_APP_BUILD_LOCK:-}" != "${PROJECT_ROOT}" ]]; then
    exec python3 "${SCRIPT_DIRECTORY}/build-swift-app.py" --lock-build "$0" "$@"
fi
APP_NAME="MyCloudDriver"
APP_EXECUTABLE="PikPakDownloader"
# Keep developer builds out of Spotlight; ~/Applications holds the installed app.
APP_BUNDLE="${PROJECT_ROOT}/dist/AppBuild.noindex/${APP_NAME}.app"
SWIFT_CACHE="${PROJECT_ROOT}/.build/app-swift"

case "${APP_BUNDLE}" in
    "${PROJECT_ROOT}/dist/AppBuild.noindex/"*.app) ;;
    *)
        print -u2 "Refusing unsafe app output path: ${APP_BUNDLE}"
        exit 1
        ;;
esac

cd "${PROJECT_ROOT}"
if (( CLEAN_SWIFT )); then
    rm -rf -- "${SWIFT_CACHE}"
fi
mkdir -p "${SWIFT_CACHE}" "${APP_BUNDLE:h}"
# Assemble separately so failed builds leave the last signed bundle usable.
STAGING_DIRECTORY="$(mktemp -d "${APP_BUNDLE:h}/.build-XXXXXX")"
STAGED_BUNDLE="${STAGING_DIRECTORY}/${APP_NAME}.app"
CONTENTS="${STAGED_BUNDLE}/Contents"
trap 'rm -rf -- "${STAGING_DIRECTORY}"' EXIT
python3 "${SCRIPT_DIRECTORY}/with-client-credentials.py" cargo build --release --locked
cargo build --release --locked --manifest-path "${PROJECT_ROOT}/vendor/FileTwin/Cargo.toml" -p filetwin-worker
python3 "${SCRIPT_DIRECTORY}/prepare-similarity-assets.py" --verify-only
python3 "${SCRIPT_DIRECTORY}/prepare-torrent-engine.py" --verify-only
python3 "${SCRIPT_DIRECTORY}/prepare-libtorrent-engine.py" --verify-only

mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

ARCHIVE_OBJECT="${SWIFT_CACHE}/DriveArchive.o"
xcrun clang -target arm64-apple-macos13.0 -O2 -Wall -Wextra -c \
    "${PROJECT_ROOT}/macos/DriveArchive.c" -o "${ARCHIVE_OBJECT}"
DISK_TEMPERATURE_OBJECT="${SWIFT_CACHE}/DiskTemperature.o"
xcrun clang -target arm64-apple-macos13.0 -O2 -Wall -Wextra -c \
    "${PROJECT_ROOT}/macos/DiskTemperature.c" -o "${DISK_TEMPERATURE_OBJECT}"

python3 "${SCRIPT_DIRECTORY}/build-swift-app.py" --cache-dir "${SWIFT_CACHE}" -- \
    -swift-version 5 \
    -target arm64-apple-macos13.0 \
    -O \
    -parse-as-library \
    "${PROJECT_ROOT}/macos/AutomaticRecovery.swift" \
    "${PROJECT_ROOT}/macos/ActivityLog.swift" \
    "${PROJECT_ROOT}/macos/DownloadDiagnostics.swift" \
    "${PROJECT_ROOT}/macos/DownloadBufferPolicy.swift" \
    "${PROJECT_ROOT}/macos/DownloadSleepPrevention.swift" \
    "${PROJECT_ROOT}/macos/DownloadBufferDashboard.swift" \
    "${PROJECT_ROOT}/macos/DownloadTransferSection.swift" \
    "${PROJECT_ROOT}/macos/ActivityLogView.swift" \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework AVKit \
    -framework QuickLookUI \
    -framework QuickLookThumbnailing \
    -framework Photos \
    -larchive.2 \
    "${ARCHIVE_OBJECT}" \
    "${DISK_TEMPERATURE_OBJECT}" \
    -framework Security \
    -framework WebKit \
    -framework AuthenticationServices \
    "${PROJECT_ROOT}/macos/LegacyKeychainStore.swift" \
    "${PROJECT_ROOT}/macos/LocalCredentialStore.swift" \
    "${PROJECT_ROOT}/macos/PikPakAccounts.swift" \
    "${PROJECT_ROOT}/macos/PikPakRequestVerification.swift" \
    "${PROJECT_ROOT}/macos/PikPakAccountVerifier.swift" \
    "${PROJECT_ROOT}/macos/PikPakManagement.swift" \
    "${PROJECT_ROOT}/macos/PikPakManagementViews.swift" \
    "${PROJECT_ROOT}/macos/PikPakTransferQuota.swift" \
    "${PROJECT_ROOT}/macos/PikPakTransferQuotaView.swift" \
    "${PROJECT_ROOT}/macos/PikPakConnectionSelector.swift" \
    "${PROJECT_ROOT}/macos/CredentialParser.swift" \
    "${PROJECT_ROOT}/macos/PreviewTransport.swift" \
    "${PROJECT_ROOT}/macos/MediaFileDownload.swift" \
    "${PROJECT_ROOT}/macos/MediaPreviewBufferStatus.swift" \
    "${PROJECT_ROOT}/macos/MemoryRangeBuffer.swift" \
    "${PROJECT_ROOT}/macos/FilePreviewResourceLoader.swift" \
    "${PROJECT_ROOT}/macos/ExternalVolume.swift" \
    "${PROJECT_ROOT}/macos/MountedVolumeIdentity.swift" \
    "${PROJECT_ROOT}/macos/MediaContainer.swift" \
    "${PROJECT_ROOT}/macos/ExternalMediaPlayer.swift" \
    "${PROJECT_ROOT}/macos/CloudDriveTypes.swift" \
    "${PROJECT_ROOT}/macos/LocalFileAccess.swift" \
    "${PROJECT_ROOT}/macos/DiskTrash.swift" \
    "${PROJECT_ROOT}/macos/NativeDiskTrashView.swift" \
    "${PROJECT_ROOT}/macos/DownloadDestinationAccess.swift" \
    "${PROJECT_ROOT}/macos/LocalTorrentEngine.swift" \
    "${PROJECT_ROOT}/macos/LocalTorrentModel.swift" \
    "${PROJECT_ROOT}/macos/LocalTorrentViews.swift" \
    "${PROJECT_ROOT}/macos/LocalTorrentRelay.swift" \
    "${PROJECT_ROOT}/macos/TorrentMetadata.swift" \
    "${PROJECT_ROOT}/macos/TorrentPortMapping.swift" \
    "${PROJECT_ROOT}/macos/TorrentDNSProbe.swift" \
    "${PROJECT_ROOT}/macos/TorrentPeerCache.swift" \
    "${PROJECT_ROOT}/macos/TorrentUPnP.swift" \
    "${PROJECT_ROOT}/macos/TorrentRAMDisk.swift" \
    "${PROJECT_ROOT}/macos/TorrentRelayStorage.swift" \
    "${PROJECT_ROOT}/macos/TorrentRelayDrain.swift" \
    "${PROJECT_ROOT}/macos/TorrentRelayUpload.swift" \
    "${PROJECT_ROOT}/macos/TorrentPaddingCleanup.swift" \
    "${PROJECT_ROOT}/macos/TorrentRelayViews.swift" \
    "${PROJECT_ROOT}/macos/CloudDriveHub.swift" \
    "${PROJECT_ROOT}/macos/ExternalDiskCatalog.swift" \
    "${PROJECT_ROOT}/macos/ICloudDriveProvider.swift" \
    "${PROJECT_ROOT}/macos/ICloudStorage.swift" \
    "${PROJECT_ROOT}/macos/FinderICloudStorage.swift" \
    "${PROJECT_ROOT}/macos/LocalVolumeStorage.swift" \
    "${PROJECT_ROOT}/macos/FinderLocalStorage.swift" \
    "${PROJECT_ROOT}/macos/DownloadReport.swift" \
    "${PROJECT_ROOT}/macos/PhotosDriveProvider.swift" \
    "${PROJECT_ROOT}/macos/PhotosSimilarityPreview.swift" \
    "${PROJECT_ROOT}/macos/NativeDriveModel.swift" \
    "${PROJECT_ROOT}/macos/NativeDriveTree.swift" \
    "${PROJECT_ROOT}/macos/NativeDriveOperations.swift" \
    "${PROJECT_ROOT}/macos/BrowserEmptyFolders.swift" \
    "${PROJECT_ROOT}/macos/NativeDriveDuplicates.swift" \
    "${PROJECT_ROOT}/macos/CrossDriveDuplicates.swift" \
    "${PROJECT_ROOT}/macos/NativeDriveWorkspace.swift" \
    "${PROJECT_ROOT}/macos/NativeMediaThumbnail.swift" \
    "${PROJECT_ROOT}/macos/NativeThumbnailCache.swift" \
    "${PROJECT_ROOT}/macos/ImagePreview.swift" \
    "${PROJECT_ROOT}/macos/FolderThumbnails.swift" \
    "${PROJECT_ROOT}/macos/FinderBookmarks.swift" \
    "${PROJECT_ROOT}/macos/PikPakBookmarks.swift" \
    "${PROJECT_ROOT}/macos/NativeDriveBookmarks.swift" \
    "${PROJECT_ROOT}/macos/WorkspaceSessions.swift" \
    "${PROJECT_ROOT}/macos/SimilarityResources.swift" \
    "${PROJECT_ROOT}/macos/SimilaritySession.swift" \
    "${PROJECT_ROOT}/macos/SimilarityInventoryWriter.swift" \
    "${PROJECT_ROOT}/macos/SimilarityScopePicker.swift" \
    "${PROJECT_ROOT}/macos/FileSimilarity.swift" \
    "${PROJECT_ROOT}/macos/SimilarityProcessingSpeed.swift" \
    "${PROJECT_ROOT}/macos/SimilarityDownloadsView.swift" \
    "${PROJECT_ROOT}/macos/SimilarityDriveRouting.swift" \
    "${PROJECT_ROOT}/macos/FileSimilarityView.swift" \
    "${PROJECT_ROOT}/macos/SimilarityResults.swift" \
    "${PROJECT_ROOT}/macos/SimilarityKeepSmallest.swift" \
    "${PROJECT_ROOT}/macos/SimilarityFileTree.swift" \
    "${PROJECT_ROOT}/macos/SimilarityResultsView.swift" \
    "${PROJECT_ROOT}/macos/SimilarityPreview.swift" \
    "${PROJECT_ROOT}/macos/FileSearch.swift" \
    "${PROJECT_ROOT}/macos/FileSearchView.swift" \
    "${PROJECT_ROOT}/macos/TransferScheduling.swift" \
    "${PROJECT_ROOT}/macos/DownloadSpeedHistory.swift" \
    "${PROJECT_ROOT}/macos/BrowserDragDrop.swift" \
    "${PROJECT_ROOT}/macos/BrowserFolderExpansion.swift" \
    "${PROJECT_ROOT}/macos/BrowserFileFilter.swift" \
    "${PROJECT_ROOT}/macos/BrowserFileFilterViews.swift" \
    "${PROJECT_ROOT}/macos/BrowserContextMenuStyle.swift" \
    "${PROJECT_ROOT}/macos/BrowserNativeContextMenu.swift" \
    "${PROJECT_ROOT}/macos/FinderSettings.swift" \
    "${PROJECT_ROOT}/macos/FinderSymbolImage.swift" \
    "${PROJECT_ROOT}/macos/FinderAppearance.swift" \
    "${PROJECT_ROOT}/macos/FinderFileOpening.swift" \
    "${PROJECT_ROOT}/macos/FinderFileUndo.swift" \
    "${PROJECT_ROOT}/macos/FinderQuickLook.swift" \
    "${PROJECT_ROOT}/macos/FinderSidebar.swift" \
    "${PROJECT_ROOT}/macos/FinderWorkspaceChrome.swift" \
    "${PROJECT_ROOT}/macos/FinderTransferLayout.swift" \
    "${PROJECT_ROOT}/macos/TransferRowPagination.swift" \
    "${PROJECT_ROOT}/macos/FinderPreviewPane.swift" \
    "${PROJECT_ROOT}/macos/MediaPlayback.swift" \
    "${PROJECT_ROOT}/macos/VideoPreviewPreparation.swift" \
    "${PROJECT_ROOT}/macos/MediaPreviewView.swift" \
    "${PROJECT_ROOT}/macos/NativeMediaPreview.swift" \
    "${PROJECT_ROOT}/macos/NativeDriveTransfers.swift" \
    "${PROJECT_ROOT}/macos/NativeDriveFileViews.swift" \
    "${PROJECT_ROOT}/macos/FinderWorkspaceNavigation.swift" \
    "${PROJECT_ROOT}/macos/FinderCommands.swift" \
    "${PROJECT_ROOT}/macos/FinderTaskActivity.swift" \
    "${PROJECT_ROOT}/macos/TaskResourceMonitor.swift" \
    "${PROJECT_ROOT}/macos/DiskResourceMonitor.swift" \
    "${PROJECT_ROOT}/macos/GPUResourceMonitor.swift" \
    "${PROJECT_ROOT}/macos/TransferPersistence.swift" \
    "${PROJECT_ROOT}/macos/SharedLinkInputBar.swift" \
    "${PROJECT_ROOT}/macos/FolderSizeCache.swift" \
    "${PROJECT_ROOT}/macos/CloudExtractionTasks.swift" \
    "${PROJECT_ROOT}/macos/ArchiveExtractionActivity.swift" \
    "${PROJECT_ROOT}/macos/DownloaderModel.swift" \
    "${PROJECT_ROOT}/macos/PikPakLoginView.swift" \
    "${PROJECT_ROOT}/macos/BrowserFileViews.swift" \
    "${PROJECT_ROOT}/macos/BrowserSelectionNavigation.swift" \
    "${PROJECT_ROOT}/macos/DownloadTransferPresentation.swift" \
    "${PROJECT_ROOT}/macos/FilePromiseCancellation.swift" \
    "${PROJECT_ROOT}/macos/FinderBookmarksWorkspace.swift" \
    "${PROJECT_ROOT}/macos/ProcessSupport.swift" \
    "${PROJECT_ROOT}/macos/SafeDisplayNumber.swift" \
    "${PROJECT_ROOT}/macos/SharedLinkIdentity.swift" \
    "${PROJECT_ROOT}/macos/TextPreviewDecoder.swift" \
    "${PROJECT_ROOT}/macos/ContentView.swift" \
    "${PROJECT_ROOT}/macos/PikPakDownloaderApp.swift" \
    -o "${SWIFT_CACHE}/${APP_EXECUTABLE}"

cp "${SWIFT_CACHE}/${APP_EXECUTABLE}" "${CONTENTS}/MacOS/${APP_EXECUTABLE}"
cp "${PROJECT_ROOT}/target/release/pikpak" "${CONTENTS}/Resources/pikpak"
python3 "${SCRIPT_DIRECTORY}/prepare-torrent-engine.py" --verify-only --destination "${CONTENTS}/Resources/TorrentEngine"
python3 "${SCRIPT_DIRECTORY}/prepare-libtorrent-engine.py" --verify-only --destination "${CONTENTS}/Resources/TorrentEngine"
cp "${PROJECT_ROOT}/vendor/FileTwin/target/release/filetwin-worker" "${CONTENTS}/Resources/filetwin-worker"
cp "${PROJECT_ROOT}/vendor/FileTwin/LICENSE" "${CONTENTS}/Resources/FileTwin-LICENSE.txt"
cp "${PROJECT_ROOT}/vendor/FileTwin/THIRD_PARTY_NOTICES.md" "${CONTENTS}/Resources/FileTwin-NOTICES.md"
python3 "${SCRIPT_DIRECTORY}/prepare-similarity-assets.py" --destination "${CONTENTS}/Resources/FileTwinModels"
chmod 755 "${CONTENTS}/Resources/filetwin-worker"
cp "${PROJECT_ROOT}/macos/Assets/AppIcon.icns" "${CONTENTS}/Resources/AppIcon.icns"
cp "${PROJECT_ROOT}/macos/Info.plist" "${CONTENTS}/Info.plist"
python3 "${SCRIPT_DIRECTORY}/with-client-credentials.py" --write-plist "${CONTENTS}/Info.plist"
chmod 755 "${CONTENTS}/MacOS/${APP_EXECUTABLE}" "${CONTENTS}/Resources/pikpak"

plutil -lint "${CONTENTS}/Info.plist"
# Preserve the upstream native-library bytes: FileTwin verifies their pinned
# SHA-256 at runtime. Sign our executables explicitly instead of re-signing
# third-party libraries with --deep.
codesign --force --sign - "${CONTENTS}/Resources/pikpak"
codesign --force --sign - "${CONTENTS}/Resources/filetwin-worker"
codesign --force --sign - "${CONTENTS}/Resources/TorrentEngine/aria2c"
codesign --force --sign - "${CONTENTS}/Resources/TorrentEngine/mycloud-torrent"
codesign --force --sign - "${STAGED_BUNDLE}"
codesign --verify --strict "${STAGED_BUNDLE}"

if [[ -e "${APP_BUNDLE}" ]]; then
    mv -- "${APP_BUNDLE}" "${STAGING_DIRECTORY}/previous.app"
fi
if ! mv -- "${STAGED_BUNDLE}" "${APP_BUNDLE}"; then
    if [[ -e "${STAGING_DIRECTORY}/previous.app" ]]; then
        mv -- "${STAGING_DIRECTORY}/previous.app" "${APP_BUNDLE}"
    fi
    exit 1
fi
print "Built in ${SECONDS}s: ${APP_BUNDLE}"
if (( INSTALL_APP )); then
    python3 "${SCRIPT_DIRECTORY}/install-app.py"
fi
