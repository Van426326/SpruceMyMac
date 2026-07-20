#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${1:-$ROOT_DIR/release/SpruceMyMac-source.tar.gz}"

git -C "$ROOT_DIR" rev-parse --verify HEAD > /dev/null || {
    echo "source archives require a committed repository" >&2
    exit 65
}
git -C "$ROOT_DIR/Vendor/Mole" rev-parse --verify HEAD > /dev/null || {
    echo "Mole submodule is unavailable" >&2
    exit 65
}
[[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || {
    echo "source archives require a clean worktree" >&2
    exit 65
}

STAGING_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/SpruceMyMac-source.XXXXXX")"
STAGING_DIR="$STAGING_PARENT/SpruceMyMac"
cleanup() { /bin/rm -rf "$STAGING_PARENT"; }
trap cleanup EXIT INT TERM
/bin/mkdir -p "$STAGING_DIR/Vendor/Mole" "$(dirname "$OUTPUT_PATH")"

git -C "$ROOT_DIR" archive --format=tar HEAD | /usr/bin/tar -xf - -C "$STAGING_DIR"
/bin/mkdir -p "$STAGING_DIR/Vendor/Mole"
git -C "$ROOT_DIR/Vendor/Mole" archive --format=tar HEAD | /usr/bin/tar -xf - -C "$STAGING_DIR/Vendor/Mole"

root_commit=$(git -C "$ROOT_DIR" rev-parse HEAD)
mole_commit=$(git -C "$ROOT_DIR/Vendor/Mole" rev-parse HEAD)
version=$(/usr/bin/awk '/MARKETING_VERSION:/ {print $2; exit}' "$ROOT_DIR/project.yml")
printf '{\n  "project": "SpruceMyMac",\n  "version": "%s",\n  "rootCommit": "%s",\n  "moleCommit": "%s",\n  "license": "GPL-3.0-only"\n}\n' \
    "$version" "$root_commit" "$mole_commit" > "$STAGING_DIR/SOURCE-MANIFEST.json"

COPYFILE_DISABLE=1 /usr/bin/tar -czf "$OUTPUT_PATH" -C "$STAGING_PARENT" SpruceMyMac
checksum=$(/usr/bin/shasum -a 256 "$OUTPUT_PATH" | /usr/bin/awk '{print $1}')
printf '%s  %s\n' "$checksum" "$(basename "$OUTPUT_PATH")" > "$OUTPUT_PATH.sha256"
echo "Source archive created at $OUTPUT_PATH"
