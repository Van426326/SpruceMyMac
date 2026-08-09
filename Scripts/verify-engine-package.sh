#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${1:-}"
PUBLIC_KEY="${2:-${ENGINE_SIGNING_PUBLIC_KEY:-}}"

if [[ -z "$PACKAGE_DIR" || -z "$PUBLIC_KEY" || ! -d "$PACKAGE_DIR" ]]; then
    echo "usage: $0 PACKAGE_DIRECTORY PUBLIC_KEY_BASE64" >&2
    exit 64
fi

manifest_path=$(find "$PACKAGE_DIR" -maxdepth 1 -type f -name 'SpruceMyMac-Engine-*-manifest.json' -print)
signature_path=$(find "$PACKAGE_DIR" -maxdepth 1 -type f -name 'SpruceMyMac-Engine-*-manifest.sig' -print)
[[ "$(printf '%s\n' "$manifest_path" | grep -c .)" -eq 1 && \
   "$(printf '%s\n' "$signature_path" | grep -c .)" -eq 1 ]] || {
    echo "package directory must contain exactly one manifest and signature" >&2
    exit 65
}

"$ROOT_DIR/Scripts/verify-engine-manifest.sh" \
    "$manifest_path" "$signature_path" "$PUBLIC_KEY"

version=$(jq -r .engineVersion "$manifest_path")
archive_path="$PACKAGE_DIR/SpruceMyMac-Engine-$version.tar.gz"
source_path="$PACKAGE_DIR/SpruceMyMac-Engine-$version-source.tar.gz"
[[ -f "$archive_path" && -f "$source_path" ]] || {
    echo "engine or corresponding-source archive missing" >&2
    exit 65
}

verify_descriptor() {
    local asset="$1" descriptor="$2" expected_url expected_sha expected_size actual_sha actual_size
    expected_url=$(jq -r "$descriptor.url" "$manifest_path")
    expected_sha=$(jq -r "$descriptor.sha256" "$manifest_path")
    expected_size=$(jq -r "$descriptor.byteSize" "$manifest_path")
    [[ "$expected_url" == https://*"/$(basename "$asset")" ]] || {
        echo "manifest URL does not identify $(basename "$asset")" >&2
        return 1
    }
    actual_sha=$(/usr/bin/shasum -a 256 "$asset" | /usr/bin/awk '{print $1}')
    actual_size=$(/usr/bin/stat -f '%z' "$asset")
    [[ "$actual_sha" == "$expected_sha" && "$actual_size" == "$expected_size" ]] || {
        echo "manifest hash or size mismatch for $(basename "$asset")" >&2
        return 1
    }
}
verify_descriptor "$archive_path" '.archive'
verify_descriptor "$source_path" '.source'

validate_archive_paths() {
    local archive="$1" entry component
    while IFS= read -r entry; do
        entry="${entry%/}"
        [[ -z "$entry" ]] && continue
        [[ "$entry" != /* && "$entry" != *'\\'* ]] || {
            echo "unsafe archive path: $entry" >&2
            return 1
        }
        IFS='/' read -r -a components <<< "$entry"
        for component in "${components[@]}"; do
            [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || {
                echo "unsafe archive path component: $entry" >&2
                return 1
            }
        done
    done < <(/usr/bin/tar -tzf "$archive")
}
validate_archive_paths "$archive_path"
validate_archive_paths "$source_path"

work_parent=$(mktemp -d "${TMPDIR:-/tmp}/sprucemymac-engine-verify.XXXXXX")
cleanup() { /bin/rm -rf "$work_parent"; }
trap cleanup EXIT INT TERM
engine_root="$work_parent/engine"
source_root="$work_parent/source"
/bin/mkdir -m 700 "$engine_root" "$source_root"
COPYFILE_DISABLE=1 /usr/bin/tar -xzf "$archive_path" -C "$engine_root"
COPYFILE_DISABLE=1 /usr/bin/tar -xzf "$source_path" -C "$source_root"

unsafe=$(find "$engine_root" ! -type d ! -type f -print -quit)
[[ -z "$unsafe" ]] || {
    echo "engine archive contains a symlink or special file: $unsafe" >&2
    exit 65
}
unsafe=$(find "$source_root" ! -type d ! -type f -print -quit)
[[ -z "$unsafe" ]] || {
    echo "source archive contains a symlink or special file: $unsafe" >&2
    exit 65
}

actual_ndjson="$work_parent/actual.ndjson"
: > "$actual_ndjson"
find "$engine_root" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    relative="${file#"$engine_root/"}"
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
        >> "$actual_ndjson"
done
jq -Ssc 'sort_by(.path)' "$actual_ndjson" > "$work_parent/actual.json"
jq -Sc '.files | sort_by(.path)' "$manifest_path" > "$work_parent/expected.json"
/usr/bin/cmp -s "$work_parent/actual.json" "$work_parent/expected.json" || {
    echo "extracted engine file list does not match signed manifest" >&2
    exit 65
}

engine_info="$work_parent/engine-info.json"
"$engine_root/Mole/bin/gui.sh" engine-info --format json > "$engine_info"
jq -e --arg version "$version" --arg commit "$(jq -r .upstreamCommit "$manifest_path")" '
  .engineVersion == $version and .commit == $commit
' "$engine_info" > /dev/null
jq -e --slurpfile info "$engine_info" '
  .protocolVersions == $info[0].protocolVersions and
  .minAppBuild == $info[0].minAppBuild and
  .maxAppBuild == $info[0].maxAppBuild and
  .minMacOS == $info[0].minMacOS and
  .architectures == $info[0].architectures and
  .capabilities == $info[0].capabilities
' "$manifest_path" > /dev/null

source_prefix="SpruceMyMac-Engine-$version-source"
for required in \
    "$source_prefix/Vendor/Mole/LICENSE" \
    "$source_prefix/Engine/UPSTREAM.json" \
    "$source_prefix/Engine/Overlay/bin/gui.sh" \
    "$source_prefix/Engine/Patches/0001-configurable-log-directory.patch" \
    "$source_prefix/Scripts/prepare-engine.sh" \
    "$source_prefix/Scripts/package-engine.sh" \
    "$source_prefix/LICENSE"; do
    [[ -f "$source_root/$required" ]] || {
        echo "corresponding source is incomplete: $required" >&2
        exit 65
    }
done

printf 'Engine package %s verified\n' "$version"
