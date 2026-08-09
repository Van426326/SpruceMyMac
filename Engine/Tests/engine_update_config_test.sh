#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/sprucemymac-engine-config-test.XXXXXX")
cleanup() { /bin/rm -rf "$test_root"; }
trap cleanup EXIT INT TERM

plist="$test_root/Info.plist"
write_plist() {
    cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.fixture</string></dict></plist>
PLIST
}

write_plist
TARGET_BUILD_DIR="$test_root" INFOPLIST_PATH="Info.plist" \
    "$ROOT_DIR/Scripts/embed-engine-update-config.sh"
if /usr/libexec/PlistBuddy -c 'Print :SpruceEngineSigningPublicKey' "$plist" > /dev/null 2>&1; then
    echo "empty signing configuration unexpectedly embedded a key" >&2
    exit 1
fi

public_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
TARGET_BUILD_DIR="$test_root" INFOPLIST_PATH="Info.plist" \
ENGINE_SIGNING_PUBLIC_KEY="$public_key" \
    "$ROOT_DIR/Scripts/embed-engine-update-config.sh"
test "$(/usr/libexec/PlistBuddy -c 'Print :SpruceEngineSigningPublicKey' "$plist")" = "$public_key"

write_plist
if TARGET_BUILD_DIR="$test_root" INFOPLIST_PATH="Info.plist" \
    ENGINE_SIGNING_PUBLIC_KEY='not-base64; Delete :CFBundleIdentifier' \
    "$ROOT_DIR/Scripts/embed-engine-update-config.sh" > /dev/null 2>&1; then
    echo "malformed signing key was accepted" >&2
    exit 1
fi
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "com.example.fixture"

printf 'engine update build configuration test passed\n'
