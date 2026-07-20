#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SOURCE_DIR="$ROOT_DIR/Vendor/Mole"

if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
    echo "embed-engine.sh must run from an Xcode build phase" >&2
    exit 1
fi

RESOURCES_DIR="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
DESTINATION_DIR="$RESOURCES_DIR/Engine/Mole"

case "$DESTINATION_DIR" in
    "$TARGET_BUILD_DIR"/*/Engine/Mole) ;;
    *)
        echo "Refusing unsafe engine destination: $DESTINATION_DIR" >&2
        exit 1
        ;;
esac

if [[ -e "$DESTINATION_DIR" ]]; then
    /bin/rm -rf -- "$DESTINATION_DIR"
fi

"$ROOT_DIR/Scripts/prepare-engine.sh" "$SOURCE_DIR" "$DESTINATION_DIR"
/usr/bin/install -m 644 "$ROOT_DIR/Engine/UPSTREAM.json" "$RESOURCES_DIR/Engine/UPSTREAM.json"
