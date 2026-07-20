#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${1:-$ROOT_DIR/Vendor/Mole}"
DESTINATION_DIR="${2:-$ROOT_DIR/build/Engine/Mole}"
PINNED_COMMIT="17683e1ac501b80456c37b23b2895398c1fe6380"

if [[ ! -d "$SOURCE_DIR" ]] || ! git -C "$SOURCE_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    echo "Mole source repository not found: $SOURCE_DIR" >&2
    exit 1
fi

source_commit=$(git -C "$SOURCE_DIR" rev-parse HEAD)
if [[ "$source_commit" != "$PINNED_COMMIT" ]]; then
    echo "Mole revision mismatch: expected $PINNED_COMMIT, got $source_commit" >&2
    exit 1
fi

if [[ -e "$DESTINATION_DIR" ]]; then
    echo "Destination already exists; choose an empty destination: $DESTINATION_DIR" >&2
    exit 1
fi

mkdir -p "$(dirname "$DESTINATION_DIR")"
mkdir -p "$DESTINATION_DIR"
rsync -a --exclude='.git/' "$SOURCE_DIR/" "$DESTINATION_DIR/"

for patch_file in "$ROOT_DIR"/Engine/Patches/*.patch; do
    /usr/bin/patch -d "$DESTINATION_DIR" -p1 -i "$patch_file"
done

ditto "$ROOT_DIR/Engine/Overlay" "$DESTINATION_DIR"
chmod +x "$DESTINATION_DIR/bin/gui.sh"

echo "Prepared SpruceMyMac engine at $DESTINATION_DIR"
