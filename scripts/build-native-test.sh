#!/bin/zsh
set -euo pipefail
test_entry="${1:?Pass a Swift test entry point}"
test_binary="${2:?Pass the output executable path}"
test_sources=(macos/*.swift)
test_sources=("${(@)test_sources:#macos/PikPakDownloaderApp.swift}")
archive_object="${test_binary}.archive.o"
xcrun clang -target arm64-apple-macos13.0 -O2 -Wall -Wextra -c macos/DriveArchive.c -o "${archive_object}"
disk_temperature_object="${test_binary}.disk-temperature.o"
xcrun clang -target arm64-apple-macos13.0 -O2 -Wall -Wextra -c macos/DiskTemperature.c -o "${disk_temperature_object}"
swiftc -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" -D FINDER_WORKSPACE_TESTS -swift-version 5 -target arm64-apple-macos13.0 \
    -parse-as-library "${test_sources[@]}" "${test_entry}" "${@:3}" "${archive_object}" "${disk_temperature_object}" \
    -framework AVKit -larchive.2 -o "${test_binary}"
rm -- "${archive_object}" "${disk_temperature_object}"
