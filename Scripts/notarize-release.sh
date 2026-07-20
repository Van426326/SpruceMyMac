#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

DMG_PATH="${1:-}"
[[ -f "$DMG_PATH" && "$DMG_PATH" == *.dmg ]] || {
    echo "usage: NOTARYTOOL_PROFILE=profile $0 /path/to/SpruceMyMac.dmg" >&2
    exit 64
}
[[ -n "${NOTARYTOOL_PROFILE:-}" ]] || {
    echo "NOTARYTOOL_PROFILE must name a keychain profile created with notarytool store-credentials" >&2
    exit 64
}

/usr/bin/xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
/usr/bin/xcrun stapler staple "$DMG_PATH"
/usr/bin/xcrun stapler validate "$DMG_PATH"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

checksum=$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')
printf '%s  %s\n' "$checksum" "$(basename "$DMG_PATH")" > "$DMG_PATH.sha256"
echo "Notarization and stapling completed for $DMG_PATH"
