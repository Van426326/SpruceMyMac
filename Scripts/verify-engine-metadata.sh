#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METADATA="${1:-$ROOT_DIR/Engine/UPSTREAM.json}"

command -v jq > /dev/null || { echo "jq is required" >&2; exit 69; }
[[ -f "$METADATA" && ! -L "$METADATA" ]] || { echo "engine metadata is unavailable" >&2; exit 65; }

jq -e '
  def valid_repository_url:
    type == "string" and
    test("^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?(/|$)") and
    (test("^https://([A-Za-z0-9-]+\\.)*xn--"; "i") | not);
  . as $root |
  .schemaVersion == 1 and
  (.engineVersion | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) and
  (.repository | valid_repository_url) and
  (.commit | type == "string" and test("^[0-9a-f]{40}$")) and
  (.checkedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and
  .license == "GPL-3.0" and
  (.protocolVersions | type == "array" and length > 0 and all(type == "number" and floor == . and . > 0)) and
  ([.protocolVersions[]] | length == (unique | length)) and
  (.minAppBuild | type == "number" and floor == . and . > 0) and
  (.maxAppBuild | type == "number" and floor == . and . >= $root.minAppBuild) and
  (.minMacOS | type == "string" and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) and
  (.architectures | type == "array" and length > 0 and all(. == "arm64" or . == "x86_64")) and
  ([.architectures[]] | length == (unique | length)) and
  (.capabilities | type == "array" and length > 0 and all(type == "string" and test("^[a-z0-9-]{1,64}$"))) and
  ([.capabilities[]] | length == (unique | length)) and
  (["clean-plan", "apply-plan", "app-list", "uninstall-plan", "tool-plan"] - .capabilities | length == 0)
' "$METADATA" > /dev/null
