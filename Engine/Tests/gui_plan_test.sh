#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: gui_plan_test.sh /path/to/prepared-mole" >&2
    exit 64
fi

engine_root="$1"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
expected_engine_version=$(jq -r .engineVersion "$root_dir/Engine/UPSTREAM.json")
expected_upstream_commit=$(jq -r .commit "$root_dir/Engine/UPSTREAM.json")
engine_info_home=$(mktemp -d "/private/tmp/sprucemymac-engine-info-test.XXXXXX")
engine_info="$(HOME="$engine_info_home" "$engine_root/bin/gui.sh" engine-info --format json)"
test -z "$(find "$engine_info_home" -mindepth 1 -print -quit)"
/bin/rm -rf "$engine_info_home"
engine_info_without_home=$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C LANG=C NO_COLOR=1 \
    "$engine_root/bin/gui.sh" engine-info --format json)
test "$engine_info_without_home" = "$engine_info"
printf '%s\n' "$engine_info" | jq -e \
    --arg version "$expected_engine_version" \
    --arg commit "$expected_upstream_commit" '
    .schemaVersion == 1 and
    .engineVersion == $version and
    .commit == $commit and
    (.protocolVersions | index(1)) != null and
    (.capabilities | index("apply-plan")) != null
' > /dev/null

fixture_root=$(mktemp -d "/private/tmp/sprucemymac-engine-test.XXXXXX")
mkdir -p "$fixture_root/Library/Caches/com.example.first"
mkdir -p "$fixture_root/Library/Caches/com.example.empty"
printf 'safe fixture data\n' > "$fixture_root/Library/Caches/com.example.first/cache.data"

output_file="$fixture_root/events.ndjson"
MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" clean-plan --format ndjson --no-auth > "$output_file"

jq -e 'select(.type == "started" and .protocol == 1 and .operation == "clean")' "$output_file" > /dev/null
jq -e 'select(.type == "candidate" and .category == "application_cache" and .requires_root == false and .size > 0)' "$output_file" > /dev/null
jq -e 'select(.type == "completed" and .candidate_count == 1 and .freed_bytes > 0)' "$output_file" > /dev/null

test -f "$fixture_root/Library/Caches/com.example.first/cache.data"
test "$(cat "$fixture_root/Library/Caches/com.example.first/cache.data")" = "safe fixture data"
test ! -e "$fixture_root/Library/Logs/mole"

plan_id=$(jq -r 'select(.type == "started") | .plan_id' "$output_file")
candidate_id=$(jq -r 'select(.type == "candidate") | .id' "$output_file")
apply_output="$fixture_root/apply.ndjson"
MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    MOLE_TEST_TRASH_DIR="$fixture_root/Trash" \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" apply-plan --plan-id "$plan_id" --items "$candidate_id" --format ndjson --no-auth > "$apply_output"

jq -e 'select(.type == "started" and .operation == "apply_clean")' "$apply_output" > /dev/null
jq -e 'select(.type == "item_result" and .status == "trashed" and .bytes > 0)' "$apply_output" > /dev/null
jq -e 'select(.type == "completed" and .candidate_count == 1 and .failed_count == 0)' "$apply_output" > /dev/null
test ! -e "$fixture_root/Library/Caches/com.example.first"
test -f "$(find "$fixture_root/Trash" -name cache.data -print -quit)"

set +e
MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    MOLE_TEST_TRASH_DIR="$fixture_root/Trash" \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" apply-plan --plan-id "$plan_id" --items "$candidate_id" --format ndjson --no-auth > "$fixture_root/replay.ndjson"
replay_status=$?
set -e
test "$replay_status" -ne 0
jq -e 'select(.type == "failed" and .code == "plan_not_found")' "$fixture_root/replay.ndjson" > /dev/null

mkdir -p "$fixture_root/Library/Caches/com.example.identity-mismatch"
printf 'identity fixture\n' > "$fixture_root/Library/Caches/com.example.identity-mismatch/cache.data"
MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" clean-plan --format ndjson --no-auth > "$fixture_root/identity-plan.ndjson"
identity_plan_id=$(jq -r 'select(.type == "started") | .plan_id' "$fixture_root/identity-plan.ndjson")
identity_candidate_id=$(jq -r 'select(.type == "candidate" and .name == "com.example.identity-mismatch") | .id' "$fixture_root/identity-plan.ndjson")
identity_plan_file="$fixture_root/State/Plans/$identity_plan_id.plan"
/usr/bin/sed -i '' $'s/^engine_version\\t.*/engine_version\\t9.9.9/' "$identity_plan_file"
set +e
MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 MOLE_TEST_TRASH_DIR="$fixture_root/Trash" \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" apply-plan --plan-id "$identity_plan_id" --items "$identity_candidate_id" \
        --format ndjson --no-auth > "$fixture_root/identity-apply.ndjson"
identity_status=$?
set -e
test "$identity_status" -ne 0
jq -e 'select(.type == "failed" and .code == "engine_identity_mismatch")' "$fixture_root/identity-apply.ndjson" > /dev/null
test -f "$fixture_root/Library/Caches/com.example.identity-mismatch/cache.data"
rm -rf "$fixture_root/Library/Caches/com.example.identity-mismatch"

mkdir -p "$fixture_root/Library/Caches/com.example.changed"
printf 'original\n' > "$fixture_root/Library/Caches/com.example.changed/cache.data"
MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" clean-plan --format ndjson --no-auth > "$fixture_root/change-plan.ndjson"
changed_plan_id=$(jq -r 'select(.type == "started") | .plan_id' "$fixture_root/change-plan.ndjson")
changed_candidate_id=$(jq -r 'select(.type == "candidate" and .name == "com.example.changed") | .id' "$fixture_root/change-plan.ndjson")
mv "$fixture_root/Library/Caches/com.example.changed" "$fixture_root/Library/Caches/com.example.changed.replaced"
mkdir -p "$fixture_root/Library/Caches/com.example.changed"
printf 'replacement\n' > "$fixture_root/Library/Caches/com.example.changed/cache.data"

set +e
MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    MOLE_TEST_TRASH_DIR="$fixture_root/Trash" \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" apply-plan --plan-id "$changed_plan_id" --items "$changed_candidate_id" --format ndjson --no-auth > "$fixture_root/changed-apply.ndjson"
changed_status=$?
set -e
test "$changed_status" -ne 0
jq -e 'select(.type == "failed" and .code == "candidate_changed")' "$fixture_root/changed-apply.ndjson" > /dev/null
test -f "$fixture_root/Library/Caches/com.example.changed/cache.data"

app_path="$fixture_root/Applications/Example.app"
mkdir -p "$app_path/Contents"
printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' \
    '<key>CFBundleIdentifier</key><string>com.example.desktop</string>' \
    '<key>CFBundleName</key><string>Example</string>' \
    '</dict></plist>' > "$app_path/Contents/Info.plist"
mkdir -p "$fixture_root/Library/Caches/com.example.desktop"
printf 'cache\n' > "$fixture_root/Library/Caches/com.example.desktop/cache.data"
mkdir -p "$fixture_root/Library/Application Support/com.example.desktop"
printf 'user data\n' > "$fixture_root/Library/Application Support/com.example.desktop/document.data"

app_list_output="$fixture_root/app-list.ndjson"
MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" app-list --format ndjson --no-auth > "$app_list_output"
inventory_id=$(jq -r 'select(.type == "started") | .plan_id' "$app_list_output")
application_id=$(jq -r 'select(.type == "application" and .bundle_id == "com.example.desktop") | .id' "$app_list_output")
jq -e 'select(.type == "application" and .name == "Example" and .protected == false)' "$app_list_output" > /dev/null
inventory_file="$fixture_root/State/Plans/app-$inventory_id.inventory"
cp "$inventory_file" "$fixture_root/inventory.backup"
/usr/bin/sed -i '' $'s/^engine_commit\\t.*/engine_commit\\t0000000000000000000000000000000000000000/' "$inventory_file"
set +e
MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" uninstall-plan --inventory-id "$inventory_id" --app-id "$application_id" \
        --format ndjson --no-auth > "$fixture_root/inventory-mismatch.ndjson"
inventory_mismatch_status=$?
set -e
test "$inventory_mismatch_status" -ne 0
jq -e 'select(.type == "failed" and .code == "engine_identity_mismatch")' "$fixture_root/inventory-mismatch.ndjson" > /dev/null
mv "$fixture_root/inventory.backup" "$inventory_file"

uninstall_plan_output="$fixture_root/uninstall-plan.ndjson"
MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" uninstall-plan --inventory-id "$inventory_id" --app-id "$application_id" --format ndjson --no-auth > "$uninstall_plan_output"
uninstall_plan_id=$(jq -r 'select(.type == "started") | .plan_id' "$uninstall_plan_output")
jq -e 'select(.type == "uninstall_candidate" and .category == "application" and .default_selected == true)' "$uninstall_plan_output" > /dev/null
jq -e 'select(.type == "uninstall_candidate" and .category == "user_data" and .default_selected == false)' "$uninstall_plan_output" > /dev/null
selected_uninstall_ids=$(jq -r 'select(.type == "uninstall_candidate" and .default_selected == true) | .id' "$uninstall_plan_output" | paste -sd, -)

MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    MOLE_TEST_TRASH_DIR="$fixture_root/Trash" \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" apply-plan --plan-id "$uninstall_plan_id" --items "$selected_uninstall_ids" --format ndjson --no-auth > "$fixture_root/uninstall-apply.ndjson"
jq -e 'select(.type == "completed" and .failed_count == 0)' "$fixture_root/uninstall-apply.ndjson" > /dev/null
test ! -e "$app_path"
test ! -e "$fixture_root/Library/Caches/com.example.desktop"
test -f "$fixture_root/Library/Application Support/com.example.desktop/document.data"

for sibling_name in SharedOne SharedTwo; do
    sibling_path="$fixture_root/Applications/$sibling_name.app"
    mkdir -p "$sibling_path/Contents"
    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<plist version="1.0"><dict>' \
        '<key>CFBundleIdentifier</key><string>com.example.shared</string>' \
        "<key>CFBundleName</key><string>$sibling_name</string>" \
        '</dict></plist>' > "$sibling_path/Contents/Info.plist"
done
mkdir -p "$fixture_root/Library/Caches/com.example.shared"
printf 'shared cache\n' > "$fixture_root/Library/Caches/com.example.shared/cache.data"
MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" app-list --format ndjson --no-auth > "$fixture_root/shared-app-list.ndjson"
shared_inventory_id=$(jq -r 'select(.type == "started") | .plan_id' "$fixture_root/shared-app-list.ndjson")
shared_app_id=$(jq -r 'select(.type == "application" and .name == "SharedOne") | .id' "$fixture_root/shared-app-list.ndjson")
MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" uninstall-plan --inventory-id "$shared_inventory_id" --app-id "$shared_app_id" --format ndjson --no-auth > "$fixture_root/shared-uninstall-plan.ndjson"
shared_candidate_count=$(jq -r 'select(.type == "completed") | .candidate_count' "$fixture_root/shared-uninstall-plan.ndjson")
test "$shared_candidate_count" -eq 1

protected_path="$fixture_root/Applications/Protected.app"
mkdir -p "$protected_path/Contents"
printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<plist version="1.0"><dict>' \
    '<key>CFBundleIdentifier</key><string>com.apple.protected-test</string>' \
    '<key>CFBundleName</key><string>Protected</string>' \
    '</dict></plist>' > "$protected_path/Contents/Info.plist"
MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" app-list --format ndjson --no-auth > "$fixture_root/protected-app-list.ndjson"
protected_inventory_id=$(jq -r 'select(.type == "started") | .plan_id' "$fixture_root/protected-app-list.ndjson")
protected_app_id=$(jq -r 'select(.type == "application" and .name == "Protected" and .protected == true) | .id' "$fixture_root/protected-app-list.ndjson")
set +e
MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" uninstall-plan --inventory-id "$protected_inventory_id" --app-id "$protected_app_id" --format ndjson --no-auth > "$fixture_root/protected-uninstall.ndjson"
protected_status=$?
set -e
test "$protected_status" -ne 0
jq -e 'select(.type == "failed" and .code == "application_protected")' "$fixture_root/protected-uninstall.ndjson" > /dev/null

mkdir -p "$fixture_root/Library/Caches/org.swift.swiftpm"
printf 'swift cache\n' > "$fixture_root/Library/Caches/org.swift.swiftpm/cache.data"
mkdir -p "$fixture_root/.npm/_cacache"
printf 'npm cache\n' > "$fixture_root/.npm/_cacache/cache.data"
MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" tool-plan --tool developer --format ndjson --no-auth > "$fixture_root/developer-plan.ndjson"
developer_plan_id=$(jq -r 'select(.type == "started") | .plan_id' "$fixture_root/developer-plan.ndjson")
developer_ids=$(jq -r 'select(.type == "uninstall_candidate" and .default_selected == true) | .id' "$fixture_root/developer-plan.ndjson" | paste -sd, -)
printf '%s\n' "$fixture_root/Library/Caches/org.swift.swiftpm" > "$fixture_root/State/whitelist"

set +e
MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    MOLE_TEST_TRASH_DIR="$fixture_root/Trash" \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" apply-plan --plan-id "$developer_plan_id" --items "$developer_ids" --format ndjson --no-auth > "$fixture_root/developer-blocked.ndjson"
developer_blocked_status=$?
set -e
test "$developer_blocked_status" -ne 0
jq -e 'select(.type == "failed" and .code == "candidate_whitelisted")' "$fixture_root/developer-blocked.ndjson" > /dev/null
test -f "$fixture_root/Library/Caches/org.swift.swiftpm/cache.data"
test -f "$fixture_root/.npm/_cacache/cache.data"

: > "$fixture_root/State/whitelist"
MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" tool-plan --tool developer --format ndjson --no-auth > "$fixture_root/developer-plan-2.ndjson"
developer_plan_id_2=$(jq -r 'select(.type == "started") | .plan_id' "$fixture_root/developer-plan-2.ndjson")
developer_ids_2=$(jq -r 'select(.type == "uninstall_candidate" and .default_selected == true) | .id' "$fixture_root/developer-plan-2.ndjson" | paste -sd, -)
MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    MOLE_TEST_TRASH_DIR="$fixture_root/Trash" \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" apply-plan --plan-id "$developer_plan_id_2" --items "$developer_ids_2" --format ndjson --no-auth > "$fixture_root/developer-apply.ndjson"
test ! -e "$fixture_root/Library/Caches/org.swift.swiftpm"
test ! -e "$fixture_root/.npm/_cacache"

mkdir -p "$fixture_root/Downloads"
printf 'installer\n' > "$fixture_root/Downloads/Example.dmg"
MOLE_TEST_MODE=1 \
    MOLE_TEST_NO_AUTH=1 \
    SPRUCE_ENGINE_TEST_HOME="$fixture_root" \
    SPRUCE_ENGINE_STATE_DIR="$fixture_root/State" \
    SPRUCE_ENGINE_LOG_DIR="$fixture_root/Logs" \
    "$engine_root/bin/gui.sh" tool-plan --tool installers --format ndjson --no-auth > "$fixture_root/installer-plan.ndjson"
jq -e 'select(.type == "uninstall_candidate" and .category == "installer" and .default_selected == false)' "$fixture_root/installer-plan.ndjson" > /dev/null

echo "gui plan protocol test passed"
