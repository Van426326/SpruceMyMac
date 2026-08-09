#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
version=$(jq -r .engineVersion "$ROOT_DIR/Engine/UPSTREAM.json")
test_root=$(mktemp -d "${TMPDIR:-/tmp}/sprucemymac-engine-package-test.XXXXXX")
cleanup() { /bin/rm -rf "$test_root"; }
trap cleanup EXIT INT TERM

assert_metadata_rejected() {
    local filter="$1" name="$2" fixture
    fixture="$test_root/metadata-$name.json"
    jq "$filter" "$ROOT_DIR/Engine/UPSTREAM.json" > "$fixture"
    if "$ROOT_DIR/Scripts/verify-engine-metadata.sh" "$fixture" > /dev/null 2>&1; then
        echo "invalid engine metadata was accepted: $name" >&2
        exit 1
    fi
}
assert_metadata_rejected '.protocolVersions = [1, 1]' duplicate-protocol
assert_metadata_rejected '.capabilities -= ["apply-plan"]' missing-capability
assert_metadata_rejected '.engineVersion = "01.0.0"' noncanonical-version
assert_metadata_rejected '.repository = "https://"' hostless-repository
assert_metadata_rejected '.repository = "https://xn--9ca.com/repo"' idn-repository

private_key="$test_root/private-key"
public_key=$("$ROOT_DIR/Scripts/generate-engine-signing-key.sh" "$private_key")
[[ "$(/usr/bin/stat -f '%Lp' "$private_key")" == "600" ]]

package_dir="$test_root/package"
ENGINE_SIGNING_PRIVATE_KEY_FILE="$private_key" \
ENGINE_SIGNING_PUBLIC_KEY="$public_key" \
ENGINE_PUBLISHED_AT="2026-01-01T00:00:00Z" \
    "$ROOT_DIR/Scripts/package-engine.sh" "$package_dir"
"$ROOT_DIR/Scripts/verify-engine-package.sh" "$package_dir" "$public_key"

deterministic_dir="$test_root/deterministic-package"
ENGINE_SIGNING_PRIVATE_KEY_FILE="$private_key" \
ENGINE_SIGNING_PUBLIC_KEY="$public_key" \
ENGINE_PUBLISHED_AT="2026-01-01T00:00:00Z" \
    "$ROOT_DIR/Scripts/package-engine.sh" "$deterministic_dir" > /dev/null
for asset in \
    "SpruceMyMac-Engine-$version.tar.gz" \
    "SpruceMyMac-Engine-$version.tar.gz.sha256" \
    "SpruceMyMac-Engine-$version-source.tar.gz" \
    "SpruceMyMac-Engine-$version-source.tar.gz.sha256" \
    "SpruceMyMac-Engine-$version-manifest.json" \
    "SpruceMyMac-Engine-$version-manifest.json.sha256"; do
    /usr/bin/cmp -s "$package_dir/$asset" "$deterministic_dir/$asset" || {
        echo "engine package is not deterministic: $asset" >&2
        exit 1
    }
done

manifest=$(find "$package_dir" -maxdepth 1 -name '*-manifest.json' -print -quit)
signature=$(find "$package_dir" -maxdepth 1 -name '*-manifest.sig' -print -quit)
make_feed_fixture() {
    local name="$1" filter="$2" output_manifest output_signature
    output_manifest="$test_root/$name.json"
    output_signature="$test_root/$name.sig"
    jq -Sc "$filter" "$manifest" > "$output_manifest"
    ENGINE_SIGNING_PRIVATE_KEY_FILE="$private_key" \
        "$ROOT_DIR/Scripts/sign-engine-manifest.sh" "$output_manifest" "$output_signature"
}
make_feed_fixture older '.engineVersion = "0.9.0"'
make_feed_fixture newer '.engineVersion = "1.1.0"'
make_feed_fixture conflict '.publishedAt = "2026-01-02T00:00:00Z"'
make_feed_fixture invalid_timestamp '.publishedAt = "2026-99-99T99:99:99Z"'
make_feed_fixture hostless_url '.archive.url = "https://?/engine.tar.gz"'
make_feed_fixture idn_url '.archive.url = "https://xn--9ca.com/engine.tar.gz"'
make_feed_fixture control_path '.files[0].path = "Mole/bin/\\u0000gui.sh"'
for invalid_manifest in invalid_timestamp hostless_url idn_url control_path; do
    if "$ROOT_DIR/Scripts/verify-engine-manifest.sh" \
        "$test_root/$invalid_manifest.json" "$test_root/$invalid_manifest.sig" "$public_key" \
        > /dev/null 2>&1; then
        echo "invalid signed manifest was accepted: $invalid_manifest" >&2
        exit 1
    fi
done
test "$("$ROOT_DIR/Scripts/check-engine-feed-update.sh" \
    "$manifest" "$signature" "$manifest" "$signature" "$public_key")" = "retry"
test "$("$ROOT_DIR/Scripts/check-engine-feed-update.sh" \
    "$test_root/older.json" "$test_root/older.sig" "$manifest" "$signature" "$public_key")" = "upgrade"
test "$("$ROOT_DIR/Scripts/check-engine-feed-update.sh" \
    "$test_root/newer.json" "$test_root/newer.sig" "$manifest" "$signature" "$public_key")" = "stale"
test "$("$ROOT_DIR/Scripts/check-engine-feed-update.sh" \
    "$manifest" "$test_root/older.sig" "$manifest" "$signature" "$public_key")" = "repair"
test "$("$ROOT_DIR/Scripts/check-engine-feed-update.sh" \
    "$test_root/older.json" "$signature" "$manifest" "$signature" "$public_key")" = "repair"
if "$ROOT_DIR/Scripts/check-engine-feed-update.sh" \
    "$test_root/older.json" "$test_root/newer.sig" "$manifest" "$signature" "$public_key" \
    > /dev/null 2>&1; then
    echo "unrecognized invalid feed pair was accepted for repair" >&2
    exit 1
fi
if "$ROOT_DIR/Scripts/check-engine-feed-update.sh" \
    "$test_root/conflict.json" "$test_root/conflict.sig" "$manifest" "$signature" "$public_key" \
    > /dev/null 2>&1; then
    echo "conflicting equal-version feed manifest was accepted" >&2
    exit 1
fi

archive=$(find "$package_dir" -maxdepth 1 -name 'SpruceMyMac-Engine-*.tar.gz' \
    ! -name '*-source.tar.gz' -print -quit)
source_archive=$(find "$package_dir" -maxdepth 1 -name 'SpruceMyMac-Engine-*-source.tar.gz' -print -quit)

manifest_tamper="$test_root/manifest-tamper"
/bin/cp -R "$package_dir" "$manifest_tamper"
printf ' ' >> "$manifest_tamper/$(basename "$manifest")"
if "$ROOT_DIR/Scripts/verify-engine-package.sh" "$manifest_tamper" "$public_key" > /dev/null 2>&1; then
    echo "tampered manifest was accepted" >&2
    exit 1
fi

signature_tamper="$test_root/signature-tamper"
/bin/cp -R "$package_dir" "$signature_tamper"
signature_file="$signature_tamper/$(basename "$signature")"
signature_text=$(tr -d '\n' < "$signature_file")
replacement="A"
[[ "${signature_text:0:1}" == "A" ]] && replacement="B"
printf '%s%s\n' "$replacement" "${signature_text:1}" > "$signature_file"
if "$ROOT_DIR/Scripts/verify-engine-package.sh" "$signature_tamper" "$public_key" > /dev/null 2>&1; then
    echo "tampered signature was accepted" >&2
    exit 1
fi

archive_tamper="$test_root/archive-tamper"
/bin/cp -R "$package_dir" "$archive_tamper"
printf 'tampered' >> "$archive_tamper/$(basename "$archive")"
if "$ROOT_DIR/Scripts/verify-engine-package.sh" "$archive_tamper" "$public_key" > /dev/null 2>&1; then
    echo "tampered archive was accepted" >&2
    exit 1
fi

source_tamper="$test_root/source-tamper"
/bin/cp -R "$package_dir" "$source_tamper"
printf 'tampered' >> "$source_tamper/$(basename "$source_archive")"
if "$ROOT_DIR/Scripts/verify-engine-package.sh" "$source_tamper" "$public_key" > /dev/null 2>&1; then
    echo "tampered corresponding source was accepted" >&2
    exit 1
fi

if env -u ENGINE_SIGNING_PRIVATE_KEY_FILE -u ENGINE_SIGNING_PRIVATE_KEY \
    "$ROOT_DIR/Scripts/package-engine.sh" "$test_root/unsigned" > /dev/null 2>&1; then
    echo "unsigned engine packaging was accepted" >&2
    exit 1
fi

printf 'engine package and tamper tests passed\n'
