#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/release/SpruceMyMac.app}"
DMG_PATH="${2:-$ROOT_DIR/release/SpruceMyMac.dmg}"

[[ -d "$APP_PATH" && "$(basename "$APP_PATH")" == "SpruceMyMac.app" ]] || {
    echo "usage: $0 [/path/to/SpruceMyMac.app] [/path/to/SpruceMyMac.dmg]" >&2
    exit 64
}
[[ "$DMG_PATH" == *.dmg ]] || { echo "output must end in .dmg" >&2; exit 64; }

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/SpruceMyMac-dmg.XXXXXX")"
cleanup() { /bin/rm -rf "$STAGING_DIR"; }
trap cleanup EXIT INT TERM

/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/SpruceMyMac.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"
/bin/mkdir -p "$(dirname "$DMG_PATH")"
/bin/rm -f "$DMG_PATH" "$DMG_PATH.sha256"

/usr/bin/hdiutil create \
    -volname "SpruceMyMac" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$DMG_PATH"

if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    /usr/bin/codesign --force --timestamp --sign "$CODE_SIGN_IDENTITY" "$DMG_PATH"
fi

checksum=$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')
printf '%s  %s\n' "$checksum" "$(basename "$DMG_PATH")" > "$DMG_PATH.sha256"
echo "DMG created at $DMG_PATH"
