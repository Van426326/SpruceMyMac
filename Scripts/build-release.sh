#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/release"
SIGNED=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --unsigned)
            SIGNED=false
            ;;
        --output)
            shift
            [[ $# -gt 0 ]] || { echo "missing --output value" >&2; exit 64; }
            OUTPUT_DIR="$1"
            ;;
        *)
            echo "usage: $0 [--unsigned] [--output directory]" >&2
            exit 64
            ;;
    esac
    shift
done

command -v xcodegen > /dev/null || { echo "xcodegen is required" >&2; exit 69; }
command -v xcodebuild > /dev/null || { echo "Xcode command-line tools are required" >&2; exit 69; }

if [[ "$SIGNED" == "true" ]]; then
    [[ -n "${DEVELOPMENT_TEAM:-}" ]] || {
        echo "DEVELOPMENT_TEAM is required for a signed release" >&2
        exit 64
    }
    [[ -n "${CODE_SIGN_IDENTITY:-}" ]] || {
        echo "CODE_SIGN_IDENTITY must name a Developer ID Application certificate" >&2
        exit 64
    }
fi

DERIVED_DATA="$ROOT_DIR/build/ReleaseDerivedData"
ARCHIVE_PATH="$ROOT_DIR/build/SpruceMyMac.xcarchive"
case "$DERIVED_DATA:$ARCHIVE_PATH" in
    "$ROOT_DIR"/build/*:"$ROOT_DIR"/build/*) ;;
    *) echo "unsafe release build paths" >&2; exit 70 ;;
esac

/bin/rm -rf "$DERIVED_DATA" "$ARCHIVE_PATH"
/bin/mkdir -p "$OUTPUT_DIR"

cd "$ROOT_DIR"
xcodegen generate

build_settings=(
    -project SpruceMyMac.xcodeproj
    -scheme SpruceMyMac
    -configuration Release
    -destination "generic/platform=macOS"
    -derivedDataPath "$DERIVED_DATA"
    -archivePath "$ARCHIVE_PATH"
    ARCHS="arm64 x86_64"
    ONLY_ACTIVE_ARCH=NO
    ENGINE_SIGNING_PUBLIC_KEY="${ENGINE_SIGNING_PUBLIC_KEY:-}"
)

if [[ "$SIGNED" == "true" ]]; then
    xcodebuild archive "${build_settings[@]}" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
        OTHER_CODE_SIGN_FLAGS="--timestamp"
else
    xcodebuild archive "${build_settings[@]}" CODE_SIGNING_ALLOWED=NO
fi

APP_SOURCE="$ARCHIVE_PATH/Products/Applications/SpruceMyMac.app"
APP_DESTINATION="$OUTPUT_DIR/SpruceMyMac.app"
[[ -d "$APP_SOURCE" ]] || { echo "archive did not contain SpruceMyMac.app" >&2; exit 70; }
/bin/rm -rf "$APP_DESTINATION"
/usr/bin/ditto "$APP_SOURCE" "$APP_DESTINATION"

if [[ "$SIGNED" == "true" ]]; then
    "$ROOT_DIR/Scripts/verify-release.sh" "$APP_DESTINATION"
else
    "$ROOT_DIR/Scripts/verify-release.sh" --unsigned "$APP_DESTINATION"
fi

echo "Release app created at $APP_DESTINATION"
