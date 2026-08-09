#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${INFOPLIST_PATH:-}" ]]; then
    echo "embed-engine-update-config.sh must run from an Xcode build phase" >&2
    exit 1
fi

info_plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
[[ -f "$info_plist" ]] || {
    echo "generated Info.plist is unavailable: $info_plist" >&2
    exit 1
}

key="SpruceEngineSigningPublicKey"
value="${ENGINE_SIGNING_PUBLIC_KEY:-}"
if [[ -n "$value" && ! "$value" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "ENGINE_SIGNING_PUBLIC_KEY must be a 32-byte Ed25519 public key encoded as base64" >&2
    exit 78
fi

/usr/libexec/PlistBuddy -c "Delete :$key" "$info_plist" > /dev/null 2>&1 || true
if [[ -n "$value" ]]; then
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$info_plist"
fi
