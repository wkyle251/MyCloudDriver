#!/bin/zsh
set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIRECTORY:h}"
MASTER_ICON="${PROJECT_ROOT}/macos/Assets/AppIcon.png"
ICONSET="${PROJECT_ROOT}/macos/Assets/AppIcon.iconset"
OUTPUT_ICON="${PROJECT_ROOT}/macos/Assets/AppIcon.icns"

case "${ICONSET}" in
    "${PROJECT_ROOT}/macos/Assets/"*.iconset) ;;
    *)
        print -u2 "Refusing unsafe iconset path: ${ICONSET}"
        exit 1
        ;;
esac

if [[ ! -f "${MASTER_ICON}" ]]; then
    print -u2 "Missing master icon: ${MASTER_ICON}"
    exit 1
fi

if [[ -e "${ICONSET}" ]]; then
    rm -rf -- "${ICONSET}"
fi
mkdir -p "${ICONSET}"

sips -z 16 16 "${MASTER_ICON}" --out "${ICONSET}/icon_16x16.png" >/dev/null
sips -z 32 32 "${MASTER_ICON}" --out "${ICONSET}/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "${MASTER_ICON}" --out "${ICONSET}/icon_32x32.png" >/dev/null
sips -z 64 64 "${MASTER_ICON}" --out "${ICONSET}/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "${MASTER_ICON}" --out "${ICONSET}/icon_128x128.png" >/dev/null
sips -z 256 256 "${MASTER_ICON}" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "${MASTER_ICON}" --out "${ICONSET}/icon_256x256.png" >/dev/null
sips -z 512 512 "${MASTER_ICON}" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "${MASTER_ICON}" --out "${ICONSET}/icon_512x512.png" >/dev/null
cp "${MASTER_ICON}" "${ICONSET}/icon_512x512@2x.png"

swift "${PROJECT_ROOT}/scripts/pack-icns.swift" "${ICONSET}" "${OUTPUT_ICON}"
rm -rf -- "${ICONSET}"
print "Built: ${OUTPUT_ICON}"
