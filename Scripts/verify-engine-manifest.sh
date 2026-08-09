#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="${1:-}"
SIGNATURE_PATH="${2:-}"
PUBLIC_KEY="${3:-${ENGINE_SIGNING_PUBLIC_KEY:-}}"

if [[ -z "$MANIFEST_PATH" || -z "$SIGNATURE_PATH" || -z "$PUBLIC_KEY" || \
      ! -f "$MANIFEST_PATH" || ! -f "$SIGNATURE_PATH" ]]; then
    echo "usage: $0 manifest.json manifest.sig PUBLIC_KEY_BASE64" >&2
    exit 64
fi

xcrun swift "$ROOT_DIR/Scripts/engine-crypto.swift" verify \
    "$PUBLIC_KEY" "$MANIFEST_PATH" "$SIGNATURE_PATH"

jq -e '
  def valid_asset_url:
    type == "string" and
    test("^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/") and
    (test("^https://([A-Za-z0-9-]+\\.)*xn--"; "i") | not);
  . as $root |
  .schemaVersion == 1 and
  (.engineVersion | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) and
  (.publishedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  (.upstreamCommit | type == "string" and test("^[0-9a-f]{40}$")) and
  (.protocolVersions | type == "array" and length > 0 and all(type == "number" and floor == . and . > 0)) and
  ([.protocolVersions[]] | length == (unique | length)) and
  (.minAppBuild | type == "number" and floor == . and . > 0) and
  (.maxAppBuild | type == "number" and floor == . and . >= $root.minAppBuild) and
  (.minMacOS | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) and
  (.architectures | type == "array" and length > 0 and all(. == "arm64" or . == "x86_64")) and
  ([.architectures[]] | length == (unique | length)) and
  (.capabilities | type == "array" and length > 0 and all(type == "string" and test("^[a-z0-9-]{1,64}$"))) and
  ([.capabilities[]] | length == (unique | length)) and
  (["clean-plan", "apply-plan", "app-list", "uninstall-plan", "tool-plan"] - .capabilities | length == 0) and
  (.archive.url | valid_asset_url) and
  (.archive.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.archive.byteSize | type == "number" and floor == . and . > 0 and . <= 268435456) and
  (.source.url | valid_asset_url) and
  (.source.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.source.byteSize | type == "number" and floor == . and . > 0 and . <= 2147483648) and
  (.files | type == "array" and length > 0 and length <= 20000) and
  (.files | all(
    (.path | type == "string" and length > 0 and (startswith("/") | not) and
      (contains("\\") | not) and (explode | all(. >= 32 and . != 127)) and
      (split("/") | all(. != "" and . != "." and . != ".."))) and
    (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.byteSize | type == "number" and floor == . and . >= 0 and . <= 134217728) and
    (.executable | type == "boolean")
  )) and
  ([.files[].path] | length == (unique | length)) and
  (.files == (.files | sort_by(.path))) and
  ([.files[].byteSize] | add <= 2147483648) and
  ([.files[].path] | index("Mole/bin/gui.sh") != null)
' "$MANIFEST_PATH" > /dev/null

published_at=$(jq -r .publishedAt "$MANIFEST_PATH")
canonical_timestamp=$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%SZ' \
    "$published_at" '+%Y-%m-%dT%H:%M:%SZ' 2> /dev/null || true)
[[ "$canonical_timestamp" == "$published_at" ]] || {
    echo "manifest publication timestamp is not a real canonical UTC date" >&2
    exit 65
}
