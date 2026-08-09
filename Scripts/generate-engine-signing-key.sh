#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIVATE_KEY_PATH="${1:-}"

if [[ -z "$PRIVATE_KEY_PATH" ]]; then
    echo "usage: $0 /secure/path/engine-signing-private-key" >&2
    exit 64
fi
if [[ -e "$PRIVATE_KEY_PATH" ]]; then
    echo "refusing to overwrite existing private key: $PRIVATE_KEY_PATH" >&2
    exit 73
fi

umask 077
/bin/mkdir -p "$(dirname "$PRIVATE_KEY_PATH")"
public_key=$(xcrun swift "$ROOT_DIR/Scripts/engine-crypto.swift" generate "$PRIVATE_KEY_PATH")

printf 'Private key written with mode 0600: %s\n' "$PRIVATE_KEY_PATH" >&2
printf '%s\n' "$public_key"
