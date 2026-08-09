#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/release/engine}"
METADATA="$ROOT_DIR/Engine/UPSTREAM.json"
RELEASE_REPOSITORY="${ENGINE_RELEASE_REPOSITORY:-Van426326/SpruceMyMac}"

for command in jq shasum rsync xcrun; do
    command -v "$command" > /dev/null || {
        echo "$command is required" >&2
        exit 69
    }
done

"$ROOT_DIR/Scripts/verify-engine-metadata.sh" "$METADATA"

version=$(jq -r .engineVersion "$METADATA")
upstream_commit=$(jq -r .commit "$METADATA")
actual_commit=$(git -C "$ROOT_DIR/Vendor/Mole" rev-parse HEAD)
[[ "$actual_commit" == "$upstream_commit" ]] || {
    echo "Mole revision mismatch: expected $upstream_commit, got $actual_commit" >&2
    exit 65
}

if [[ -z "${ENGINE_SIGNING_PRIVATE_KEY_FILE:-}" && -z "${ENGINE_SIGNING_PRIVATE_KEY:-}" ]]; then
    echo "engine packaging requires ENGINE_SIGNING_PRIVATE_KEY_FILE or ENGINE_SIGNING_PRIVATE_KEY" >&2
    exit 78
fi

published_at="${ENGINE_PUBLISHED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
release_base="https://github.com/$RELEASE_REPOSITORY/releases/download/engine-v$version"
archive_name="SpruceMyMac-Engine-$version.tar.gz"
source_name="SpruceMyMac-Engine-$version-source.tar.gz"
manifest_name="SpruceMyMac-Engine-$version-manifest.json"
signature_name="SpruceMyMac-Engine-$version-manifest.sig"

work_parent=$(mktemp -d "${TMPDIR:-/tmp}/sprucemymac-engine-package.XXXXXX")
cleanup() { /bin/rm -rf "$work_parent"; }
trap cleanup EXIT INT TERM
payload="$work_parent/payload"
source_payload="$work_parent/SpruceMyMac-Engine-$version-source"
prepared_source="$work_parent/prepared-Mole"
prepared="$payload/Mole"
/bin/mkdir -p "$payload" "$source_payload" "$OUTPUT_DIR"

"$ROOT_DIR/Scripts/prepare-engine.sh" "$ROOT_DIR/Vendor/Mole" "$prepared_source"
# The pinned upstream repository contains documentation convenience symlinks.
# Resolve them while copying so release archives contain regular files only.
rsync -aL "$prepared_source/" "$prepared/"
/usr/bin/install -m 644 "$METADATA" "$payload/UPSTREAM.json"

reject_unsafe_tree() {
    local tree="$1" unsafe
    unsafe=$(find "$tree" ! -type d ! -type f -print -quit)
    [[ -z "$unsafe" ]] || {
        echo "refusing symlink or special file in package tree: $unsafe" >&2
        exit 65
    }
}

reject_unsafe_tree "$payload"

# Include all material required to rebuild this modified GPL engine. The
# versioned source asset is immutable and is linked from the signed manifest.
/bin/mkdir -p "$source_payload/Vendor"
rsync -aL --exclude='.git/' "$ROOT_DIR/Vendor/Mole/" "$source_payload/Vendor/Mole/"
rsync -aL "$ROOT_DIR/Engine/" "$source_payload/Engine/"
rsync -aL "$ROOT_DIR/Scripts/" "$source_payload/Scripts/"
for legal_file in LICENSE NOTICE.md THIRD_PARTY_NOTICES.md README.md project.yml; do
    /usr/bin/install -m 644 "$ROOT_DIR/$legal_file" "$source_payload/$legal_file"
done
reject_unsafe_tree "$source_payload"

# Normalize mtimes and ownership metadata so identical inputs and
# ENGINE_PUBLISHED_AT values produce stable archives.
archive_stamp="${ENGINE_ARCHIVE_TIMESTAMP:-202001010000.00}"
find "$payload" -exec touch -h -t "$archive_stamp" {} +
find "$source_payload" -exec touch -h -t "$archive_stamp" {} +

create_archive() {
    local archive_path="$1" base_dir="$2"
    shift 2
    local tar_path="$work_parent/archive.tar" file_list="$work_parent/archive-files.txt"
    /bin/rm -f "$tar_path" "$archive_path" "$file_list"
    (
        cd "$base_dir"
        find "$@" -print | LC_ALL=C sort > "$file_list"
    )
    COPYFILE_DISABLE=1 /usr/bin/tar --format ustar --uid 0 --gid 0 --uname root --gname wheel \
        --no-xattrs --no-acls --no-fflags --no-mac-metadata --no-recursion \
        -cf "$tar_path" -C "$base_dir" -T "$file_list"
    /usr/bin/gzip -n -9 < "$tar_path" > "$archive_path"
}

archive_path="$OUTPUT_DIR/$archive_name"
source_path="$OUTPUT_DIR/$source_name"
create_archive "$archive_path" "$payload" Mole UPSTREAM.json
create_archive "$source_path" "$work_parent" "$(basename "$source_payload")"

archive_sha=$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')
source_sha=$(/usr/bin/shasum -a 256 "$source_path" | /usr/bin/awk '{print $1}')
archive_size=$(/usr/bin/stat -f '%z' "$archive_path")
source_size=$(/usr/bin/stat -f '%z' "$source_path")

files_ndjson="$work_parent/files.ndjson"
: > "$files_ndjson"
find "$payload" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    relative="${file#"$payload/"}"
    case "$relative" in
        /*|*'/../'*|'../'*|*'/./'*|'./'*|*'//'*)
            echo "unsafe package path: $relative" >&2
            exit 65
            ;;
    esac
    file_sha=$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')
    file_size=$(/usr/bin/stat -f '%z' "$file")
    executable=false
    [[ -x "$file" ]] && executable=true
    jq -cn \
        --arg path "$relative" \
        --arg sha256 "$file_sha" \
        --argjson byteSize "$file_size" \
        --argjson executable "$executable" \
        '{path: $path, sha256: $sha256, byteSize: $byteSize, executable: $executable}' \
        >> "$files_ndjson"
done
files_json=$(jq -sc 'sort_by(.path)' "$files_ndjson")

manifest_path="$OUTPUT_DIR/$manifest_name"
signature_path="$OUTPUT_DIR/$signature_name"
jq -Scn \
    --argjson metadata "$(cat "$METADATA")" \
    --arg publishedAt "$published_at" \
    --arg archiveURL "$release_base/$archive_name" \
    --arg archiveSHA "$archive_sha" \
    --argjson archiveSize "$archive_size" \
    --arg sourceURL "$release_base/$source_name" \
    --arg sourceSHA "$source_sha" \
    --argjson sourceSize "$source_size" \
    --argjson files "$files_json" \
    '{
      schemaVersion: 1,
      engineVersion: $metadata.engineVersion,
      publishedAt: $publishedAt,
      upstreamCommit: $metadata.commit,
      protocolVersions: $metadata.protocolVersions,
      minAppBuild: $metadata.minAppBuild,
      maxAppBuild: $metadata.maxAppBuild,
      minMacOS: $metadata.minMacOS,
      architectures: $metadata.architectures,
      capabilities: $metadata.capabilities,
      archive: {url: $archiveURL, sha256: $archiveSHA, byteSize: $archiveSize},
      source: {url: $sourceURL, sha256: $sourceSHA, byteSize: $sourceSize},
      files: $files
    }' > "$manifest_path"

"$ROOT_DIR/Scripts/sign-engine-manifest.sh" "$manifest_path" "$signature_path"

for asset in "$archive_path" "$source_path" "$manifest_path" "$signature_path"; do
    checksum=$(/usr/bin/shasum -a 256 "$asset" | /usr/bin/awk '{print $1}')
    printf '%s  %s\n' "$checksum" "$(basename "$asset")" > "$asset.sha256"
done

printf 'Engine package %s created in %s\n' "$version" "$OUTPUT_DIR"
printf 'Manifest: %s\n' "$manifest_path"
