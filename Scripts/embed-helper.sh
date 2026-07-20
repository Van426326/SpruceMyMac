#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

readonly HELPER_NAME="sprucemymac-helper"
readonly PLIST_NAME="com.van426326.sprucemymac.helper.plist"
readonly APP_CONTENTS="${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents"
readonly HELPER_SOURCE="${BUILT_PRODUCTS_DIR}/${HELPER_NAME}"
readonly PLIST_SOURCE="${SRCROOT}/Helper/Resources/${PLIST_NAME}"
readonly HELPER_DESTINATION="${APP_CONTENTS}/Library/HelperTools/${HELPER_NAME}"
readonly PLIST_DESTINATION="${APP_CONTENTS}/Library/LaunchDaemons/${PLIST_NAME}"

[[ -x "$HELPER_SOURCE" ]] || {
    echo "error: built privileged helper is missing: $HELPER_SOURCE" >&2
    exit 1
}
[[ -f "$PLIST_SOURCE" && ! -L "$PLIST_SOURCE" ]] || {
    echo "error: LaunchDaemon plist is missing or unsafe: $PLIST_SOURCE" >&2
    exit 1
}

/bin/mkdir -p "$(dirname "$HELPER_DESTINATION")" "$(dirname "$PLIST_DESTINATION")"
/usr/bin/install -m 755 "$HELPER_SOURCE" "$HELPER_DESTINATION"
/usr/bin/install -m 644 "$PLIST_SOURCE" "$PLIST_DESTINATION"
/usr/bin/plutil -lint "$PLIST_DESTINATION" > /dev/null
