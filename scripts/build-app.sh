#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIRECTORY:h}"
APP_NAME="MyCloudDriver"
APP_EXECUTABLE="PikPakDownloader"
APP_BUNDLE="${PROJECT_ROOT}/dist/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"

case "${APP_BUNDLE}" in
    "${PROJECT_ROOT}/dist/"*.app) ;;
    *)
        print -u2 "Refusing unsafe app output path: ${APP_BUNDLE}"
        exit 1
        ;;
esac

cd "${PROJECT_ROOT}"
python3 "${SCRIPT_DIRECTORY}/with-client-credentials.py" cargo build --release --locked
cargo build --release --locked --manifest-path "${PROJECT_ROOT}/vendor/FileTwin/Cargo.toml" -p filetwin-worker
python3 "${SCRIPT_DIRECTORY}/prepare-similarity-assets.py" --verify-only

if [[ -e "${APP_BUNDLE}" ]]; then
    rm -rf -- "${APP_BUNDLE}"
fi

mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

ARCHIVE_OBJECT="${PROJECT_ROOT}/dist/DriveArchive.o"
xcrun clang -target arm64-apple-macos13.0 -O2 -Wall -Wextra -c \
    "${PROJECT_ROOT}/macos/DriveArchive.c" -o "${ARCHIVE_OBJECT}"

swiftc \
    -swift-version 5 \
    -target arm64-apple-macos13.0 \
    -O \
    -parse-as-library \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework AVKit \
    -framework QuickLookUI \
    -framework QuickLookThumbnailing \
    -framework Photos \
    -larchive.2 \
    "${ARCHIVE_OBJECT}" \
    -framework Security \
    -framework WebKit \
    "${PROJECT_ROOT}/macos/LegacyKeychainStore.swift" \
    "${PROJECT_ROOT}/macos/LocalCredentialStore.swift" \
    "${PROJECT_ROOT}/macos/PikPakAccounts.swift" \
    "${PROJECT_ROOT}/macos/PikPakAccountVerifier.swift" \
    "${PROJECT_ROOT}/macos/CredentialParser.swift" \
    "${PROJECT_ROOT}/macos/PreviewTransport.swift" \
    "${PROJECT_ROOT}/macos/CloudDriveTypes.swift" \
    "${PROJECT_ROOT}/macos/CloudDriveHub.swift" \
    "${PROJECT_ROOT}/macos/ICloudDriveProvider.swift" \
    "${PROJECT_ROOT}/macos/PhotosDriveProvider.swift" \
    "${PROJECT_ROOT}/macos/NativeDriveModel.swift" \
    "${PROJECT_ROOT}/macos/NativeDriveOperations.swift" \
    "${PROJECT_ROOT}/macos/NativeDriveDuplicates.swift" \
    "${PROJECT_ROOT}/macos/NativeDriveWorkspace.swift" \
    "${PROJECT_ROOT}/macos/NativeMediaThumbnail.swift" \
    "${PROJECT_ROOT}/macos/ImagePreview.swift" \
    "${PROJECT_ROOT}/macos/FileSimilarity.swift" \
    "${PROJECT_ROOT}/macos/FileSimilarityView.swift" \
    "${PROJECT_ROOT}/macos/FileSearch.swift" \
    "${PROJECT_ROOT}/macos/FileSearchView.swift" \
    "${PROJECT_ROOT}/macos/TransferScheduling.swift" \
    "${PROJECT_ROOT}/macos/BrowserDragDrop.swift" \
    "${PROJECT_ROOT}/macos/BrowserFolderExpansion.swift" \
    "${PROJECT_ROOT}/macos/BrowserContextMenuStyle.swift" \
    "${PROJECT_ROOT}/macos/FinderSettings.swift" \
    "${PROJECT_ROOT}/macos/FinderAppearance.swift" \
    "${PROJECT_ROOT}/macos/FinderFileOpening.swift" \
    "${PROJECT_ROOT}/macos/FinderFileUndo.swift" \
    "${PROJECT_ROOT}/macos/FinderQuickLook.swift" \
    "${PROJECT_ROOT}/macos/FinderSidebar.swift" \
    "${PROJECT_ROOT}/macos/FinderWorkspaceNavigation.swift" \
    "${PROJECT_ROOT}/macos/FinderCommands.swift" \
    "${PROJECT_ROOT}/macos/FinderTaskActivity.swift" \
    "${PROJECT_ROOT}/macos/TaskResourceMonitor.swift" \
    "${PROJECT_ROOT}/macos/TransferPersistence.swift" \
    "${PROJECT_ROOT}/macos/SharedLinkInputBar.swift" \
    "${PROJECT_ROOT}/macos/FolderSizeCache.swift" \
    "${PROJECT_ROOT}/macos/CloudExtractionTasks.swift" \
    "${PROJECT_ROOT}/macos/ArchiveExtractionActivity.swift" \
    "${PROJECT_ROOT}/macos/DownloaderModel.swift" \
    "${PROJECT_ROOT}/macos/PikPakLoginView.swift" \
    "${PROJECT_ROOT}/macos/ContentView.swift" \
    "${PROJECT_ROOT}/macos/PikPakDownloaderApp.swift" \
    -o "${CONTENTS}/MacOS/${APP_EXECUTABLE}"

cp "${PROJECT_ROOT}/target/release/pikpak" "${CONTENTS}/Resources/pikpak"
cp "${PROJECT_ROOT}/vendor/FileTwin/target/release/filetwin-worker" "${CONTENTS}/Resources/filetwin-worker"
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
codesign --force --sign - "${APP_BUNDLE}"

print "Built: ${APP_BUNDLE}"
