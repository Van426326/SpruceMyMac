#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="${1:-}"
SIGNATURE_PATH="${2:-}"

if [[ -z "$MANIFEST_PATH" || -z "$SIGNATURE_PATH" || ! -f "$MANIFEST_PATH" ]]; then
    echo "usage: $0 manifest.json manifest.sig" >&2
    exit 64
fi

private_key_path="${ENGINE_SIGNING_PRIVATE_KEY_FILE:-}"
temporary_key=""
cleanup() {
    if [[ -n "$temporary_key" ]]; then
        /bin/rm -f "$temporary_key"
    fi
}
trap cleanup EXIT INT TERM

if [[ -z "$private_key_path" && -n "${ENGINE_SIGNING_PRIVATE_KEY:-}" ]]; then
    temporary_key=$(mktemp "${TMPDIR:-/tmp}/sprucemymac-engine-key.XXXXXX")
    chmod 600 "$temporary_key"
    printf '%s\n' "$ENGINE_SIGNING_PRIVATE_KEY" > "$temporary_key"
    private_key_path="$temporary_key"
fi

if [[ -z "$private_key_path" || ! -f "$private_key_path" || -L "$private_key_path" ]]; then
    echo "ENGINE_SIGNING_PRIVATE_KEY_FILE or ENGINE_SIGNING_PRIVATE_KEY is required" >&2
    exit 78
fi
key_mode=$(/usr/bin/stat -f '%Lp' "$private_key_path")
[[ "$key_mode" == "600" ]] || {
    echo "engine signing private key must have mode 0600" >&2
    exit 78
}

xcrun swift "$ROOT_DIR/Scripts/engine-crypto.swift" sign \
    "$private_key_path" "$MANIFEST_PATH" "$SIGNATURE_PATH"
chmod 644 "$SIGNATURE_PATH"

if [[ -n "${ENGINE_SIGNING_PUBLIC_KEY:-}" ]]; then
    xcrun swift "$ROOT_DIR/Scripts/engine-crypto.swift" verify \
        "$ENGINE_SIGNING_PUBLIC_KEY" "$MANIFEST_PATH" "$SIGNATURE_PATH"
fi
