#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RESOURCES_DIR="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"

/bin/mkdir -p "$RESOURCES_DIR"
/usr/bin/ditto "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"
/usr/bin/ditto "$ROOT_DIR/NOTICE.md" "$RESOURCES_DIR/NOTICE.md"
/usr/bin/ditto "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
