#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURRENT_MANIFEST="${1:-}"
CURRENT_SIGNATURE="${2:-}"
CANDIDATE_MANIFEST="${3:-}"
CANDIDATE_SIGNATURE="${4:-}"
PUBLIC_KEY="${5:-${ENGINE_SIGNING_PUBLIC_KEY:-}}"

if [[ -z "$CURRENT_MANIFEST" || -z "$CURRENT_SIGNATURE" || \
      -z "$CANDIDATE_MANIFEST" || -z "$CANDIDATE_SIGNATURE" || -z "$PUBLIC_KEY" ]]; then
    echo "usage: $0 CURRENT_MANIFEST CURRENT_SIGNATURE CANDIDATE_MANIFEST CANDIDATE_SIGNATURE PUBLIC_KEY_BASE64" >&2
    exit 64
fi

"$ROOT_DIR/Scripts/verify-engine-manifest.sh" \
    "$CANDIDATE_MANIFEST" "$CANDIDATE_SIGNATURE" "$PUBLIC_KEY"

if ! "$ROOT_DIR/Scripts/verify-engine-manifest.sh" \
    "$CURRENT_MANIFEST" "$CURRENT_SIGNATURE" "$PUBLIC_KEY" > /dev/null 2>&1; then
    if /usr/bin/cmp -s "$CURRENT_MANIFEST" "$CANDIDATE_MANIFEST" || \
       /usr/bin/cmp -s "$CURRENT_SIGNATURE" "$CANDIDATE_SIGNATURE"; then
        printf 'repair\n'
        exit 0
    fi
    echo "current feed is invalid and does not match either candidate asset" >&2
    exit 65
fi

current_version=$(jq -r .engineVersion "$CURRENT_MANIFEST")
candidate_version=$(jq -r .engineVersion "$CANDIDATE_MANIFEST")

semver_compare() {
    local lhs="$1" rhs="$2" lmajor lminor lpatch rmajor rminor rpatch
    IFS=. read -r lmajor lminor lpatch <<< "$lhs"
    IFS=. read -r rmajor rminor rpatch <<< "$rhs"
    if ((lmajor != rmajor)); then ((lmajor < rmajor)) && echo -1 || echo 1; return; fi
    if ((lminor != rminor)); then ((lminor < rminor)) && echo -1 || echo 1; return; fi
    if ((lpatch != rpatch)); then ((lpatch < rpatch)) && echo -1 || echo 1; return; fi
    echo 0
}

comparison=$(semver_compare "$candidate_version" "$current_version")
case "$comparison" in
    1)
        printf 'upgrade\n'
        ;;
    0)
        /usr/bin/cmp -s "$CURRENT_MANIFEST" "$CANDIDATE_MANIFEST" || {
            echo "equal engine versions have different signed manifests" >&2
            exit 65
        }
        printf 'retry\n'
        ;;
    -1)
        printf 'stale\n'
        ;;
    *)
        echo "internal semantic-version comparison failure" >&2
        exit 70
        ;;
esac
