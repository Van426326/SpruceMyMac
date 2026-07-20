#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNSIGNED=false
if [[ "${1:-}" == "--unsigned" ]]; then
    UNSIGNED=true
    shift
fi
APP_PATH="${1:-}"
[[ -d "$APP_PATH" && "$(basename "$APP_PATH")" == "SpruceMyMac.app" ]] || {
    echo "usage: $0 [--unsigned] /path/to/SpruceMyMac.app" >&2
    exit 64
}

CONTENTS="$APP_PATH/Contents"
MAIN_EXECUTABLE="$CONTENTS/MacOS/SpruceMyMac"
ENGINE="$CONTENTS/Resources/Engine/Mole/bin/gui.sh"
ENGINE_METADATA="$CONTENTS/Resources/Engine/UPSTREAM.json"

[[ -x "$MAIN_EXECUTABLE" && -x "$ENGINE" ]]
[[ -f "$ENGINE_METADATA" ]]
[[ ! -e "$CONTENTS/Library/HelperTools/sprucemymac-helper" ]]
[[ ! -e "$CONTENTS/Library/LaunchDaemons/com.van426326.sprucemymac.helper.plist" ]]
[[ -f "$CONTENTS/Resources/LICENSE" ]]
[[ -f "$CONTENTS/Resources/NOTICE.md" ]]
[[ -f "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md" ]]
[[ -f "$CONTENTS/Resources/AppIcon.icns" || -f "$CONTENTS/Resources/Assets.car" ]]
[[ -f "$CONTENTS/Resources/en.lproj/Localizable.strings" ]]
[[ -f "$CONTENTS/Resources/zh-Hans.lproj/Localizable.strings" ]]
/usr/bin/cmp -s "$ROOT_DIR/LICENSE" "$CONTENTS/Resources/LICENSE"
/usr/bin/cmp -s "$ROOT_DIR/NOTICE.md" "$CONTENTS/Resources/NOTICE.md"
/usr/bin/cmp -s "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md"

main_arches=$(/usr/bin/lipo -archs "$MAIN_EXECUTABLE")
for required_arch in arm64 x86_64; do
    [[ " $main_arches " == *" $required_arch "* ]]
done

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CONTENTS/Info.plist")
[[ "$bundle_id" == "com.van426326.sprucemymac" ]]
[[ "$(/usr/bin/jq -r .commit "$ENGINE_METADATA")" == \
    "$(/usr/bin/jq -r .commit "$ROOT_DIR/Engine/UPSTREAM.json")" ]]

if [[ "$UNSIGNED" == "false" ]]; then
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    signature_info=$(/usr/bin/codesign -dvvv "$APP_PATH" 2>&1)
    [[ "$signature_info" == *"runtime"* && "$signature_info" != *"Signature=adhoc"* ]]
    /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

echo "release verification passed: $main_arches"
