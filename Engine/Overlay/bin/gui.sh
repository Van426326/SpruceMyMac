#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SpruceMyMac read-only GUI protocol overlay for Mole.

set -euo pipefail

export LC_ALL=C
export LANG=C
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export MO_NO_OPLOG=1
export MOLE_LOG_DIR="${SPRUCE_ENGINE_LOG_DIR:-$HOME/Library/Logs/SpruceMyMac}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Handle the compatibility handshake before loading Mole. common.sh creates a
# temporary working directory, while engine-info must remain strictly read-only.
gui_engine_info_main() {
    [[ $# -eq 3 && "$1" == "engine-info" && "$2" == "--format" && "$3" == "json" ]] || {
        printf '%s\n' '{"error":"invalid_engine_info_request"}' >&2
        return 64
    }

    local metadata_file="$SCRIPT_DIR/../engine-info.json"
    if [[ ! -f "$metadata_file" || -L "$metadata_file" ]]; then
        printf '%s\n' '{"error":"engine_metadata_unavailable"}' >&2
        return 70
    fi
    /bin/cat "$metadata_file"
}

if [[ "${1:-}" == "engine-info" ]]; then
    gui_engine_info_main "$@"
    exit $?
fi

readonly SPRUCE_ENGINE_METADATA_FILE="$SCRIPT_DIR/../engine-info.json"
SPRUCE_ENGINE_PACKAGE_VERSION=$(/usr/bin/awk -F'"' '$2 == "engineVersion" { print $4; exit }' "$SPRUCE_ENGINE_METADATA_FILE" 2> /dev/null || true)
SPRUCE_ENGINE_UPSTREAM_COMMIT=$(/usr/bin/awk -F'"' '$2 == "commit" { print $4; exit }' "$SPRUCE_ENGINE_METADATA_FILE" 2> /dev/null || true)
if [[ ! "$SPRUCE_ENGINE_PACKAGE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ||
      ! "$SPRUCE_ENGINE_UPSTREAM_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s\n' '{"error":"engine_identity_unavailable"}' >&2
    exit 70
fi
readonly SPRUCE_ENGINE_PACKAGE_VERSION
readonly SPRUCE_ENGINE_UPSTREAM_COMMIT

source "$SCRIPT_DIR/../lib/core/common.sh"

readonly SPRUCE_GUI_PROTOCOL_VERSION=1
declare -a SPRUCE_WHITELIST=()

gui_json_escape() {
    local value="${1:-}"
    local LC_ALL=C
    local char code idx

    idx=0
    while [[ "$idx" -lt "${#value}" ]]; do
        char="${value:$idx:1}"
        case "$char" in
            "\\") printf '%s' "\\\\" ;;
            "\"") printf '%s' "\\\"" ;;
            $'\b') printf '%s' "\\b" ;;
            $'\f') printf '%s' "\\f" ;;
            $'\n') printf '%s' "\\n" ;;
            $'\r') printf '%s' "\\r" ;;
            $'\t') printf '%s' "\\t" ;;
            *)
                printf -v code '%d' "'$char"
                if [[ "$code" -lt 0 ]]; then
                    code=$((code + 256))
                fi
                if [[ "$code" -lt 32 ]]; then
                    printf '\\u%04x' "$code"
                else
                    printf '%s' "$char"
                fi
                ;;
        esac
        idx=$((idx + 1))
    done
}

gui_plan_id() {
    if command -v uuidgen > /dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
        return
    fi
    printf 'plan-%s-%s\n' "$(date +%s)" "$$"
}

gui_candidate_id() {
    local identity="$1"
    if command -v shasum > /dev/null 2>&1; then
        printf '%s' "$identity" | shasum -a 256 | awk '{print $1}'
        return
    fi
    printf '%s' "$identity" | cksum | awk '{printf "cksum-%s-%s", $1, $2}'
}

gui_emit_started() {
    local plan_id="$1"
    local expires_at="$2"
    local operation="${3:-clean}"
    printf '{"type":"started","protocol":%d,"operation":"%s","plan_id":"%s","expires_at":%s}\n' \
        "$SPRUCE_GUI_PROTOCOL_VERSION" "$(gui_json_escape "$operation")" \
        "$(gui_json_escape "$plan_id")" "$expires_at"
}

gui_emit_candidate() {
    local plan_id="$1"
    local candidate_id="$2"
    local path="$3"
    local size_bytes="$4"
    local device="$5"
    local inode="$6"
    local modified_at="$7"
    local name="${path##*/}"

    printf '{"type":"candidate","plan_id":"%s","id":"%s","name":"%s","path":"%s","size":%s,"category":"application_cache","risk":"review","requires_root":false,"reversible":false,"device":%s,"inode":%s,"modified_at":%s}\n' \
        "$(gui_json_escape "$plan_id")" \
        "$(gui_json_escape "$candidate_id")" \
        "$(gui_json_escape "$name")" \
        "$(gui_json_escape "$path")" \
        "$size_bytes" "$device" "$inode" "$modified_at"
}

gui_emit_progress() {
    local completed="$1"
    local total="$2"
    printf '{"type":"progress","completed":%s,"total":%s}\n' "$completed" "$total"
}

gui_emit_completed() {
    local plan_id="$1"
    local total_bytes="$2"
    local candidate_count="$3"
    local failed_count="${4:-0}"
    printf '{"type":"completed","plan_id":"%s","freed_bytes":%s,"candidate_count":%s,"failed_count":%s}\n' \
        "$(gui_json_escape "$plan_id")" "$total_bytes" "$candidate_count" "$failed_count"
}

gui_emit_failed() {
    local code="$1"
    local message_key="$2"
    printf '{"type":"failed","code":"%s","message_key":"%s"}\n' \
        "$(gui_json_escape "$code")" "$(gui_json_escape "$message_key")"
}

gui_emit_item_result() {
    local plan_id="$1"
    local candidate_id="$2"
    local status="$3"
    local bytes="$4"
    local error_code="${5:-}"
    printf '{"type":"item_result","plan_id":"%s","id":"%s","status":"%s","bytes":%s,"error_code":"%s"}\n' \
        "$(gui_json_escape "$plan_id")" "$(gui_json_escape "$candidate_id")" \
        "$(gui_json_escape "$status")" "$bytes" "$(gui_json_escape "$error_code")"
}

gui_emit_application() {
    local inventory_id="$1" app_id="$2" name="$3" path="$4" bundle_id="$5"
    local size_bytes="$6" source="$7" protected="$8" device="$9" inode="${10}" modified_at="${11}"
    printf '{"type":"application","inventory_id":"%s","id":"%s","name":"%s","path":"%s","bundle_id":"%s","size":%s,"source":"%s","protected":%s,"device":%s,"inode":%s,"modified_at":%s}\n' \
        "$(gui_json_escape "$inventory_id")" "$(gui_json_escape "$app_id")" \
        "$(gui_json_escape "$name")" "$(gui_json_escape "$path")" \
        "$(gui_json_escape "$bundle_id")" "$size_bytes" "$(gui_json_escape "$source")" \
        "$protected" "$device" "$inode" "$modified_at"
}

gui_emit_uninstall_candidate() {
    local plan_id="$1" candidate_id="$2" name="$3" path="$4" size_bytes="$5"
    local category="$6" risk="$7" default_selected="$8" device="$9" inode="${10}" modified_at="${11}"
    printf '{"type":"uninstall_candidate","plan_id":"%s","id":"%s","name":"%s","path":"%s","size":%s,"category":"%s","risk":"%s","default_selected":%s,"requires_root":false,"reversible":true,"device":%s,"inode":%s,"modified_at":%s}\n' \
        "$(gui_json_escape "$plan_id")" "$(gui_json_escape "$candidate_id")" \
        "$(gui_json_escape "$name")" "$(gui_json_escape "$path")" "$size_bytes" \
        "$(gui_json_escape "$category")" "$(gui_json_escape "$risk")" "$default_selected" \
        "$device" "$inode" "$modified_at"
}

gui_scan_home() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${SPRUCE_ENGINE_TEST_HOME:-}" ]]; then
        printf '%s\n' "$SPRUCE_ENGINE_TEST_HOME"
    else
        get_invoking_home
    fi
}

gui_state_dir() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" && -n "${SPRUCE_ENGINE_STATE_DIR:-}" ]]; then
        printf '%s\n' "${SPRUCE_ENGINE_STATE_DIR%/}"
        return
    fi

    local home
    home=$(gui_scan_home)
    printf '%s/Library/Application Support/SpruceMyMac\n' "${home%/}"
}

gui_prepare_plan_dir() {
    local state_dir plan_dir resolved_dir
    state_dir=$(gui_state_dir)
    plan_dir="$state_dir/Plans"

    if [[ -L "$state_dir" || -L "$plan_dir" ]]; then
        return 1
    fi
    mkdir -p "$plan_dir" 2> /dev/null || return 1
    chmod 700 "$state_dir" "$plan_dir" 2> /dev/null || return 1
    [[ -d "$plan_dir" && ! -L "$plan_dir" && -O "$plan_dir" ]] || return 1

    resolved_dir=$(cd -P "$plan_dir" 2> /dev/null && pwd -P) || return 1
    [[ "$resolved_dir" == "$plan_dir" ]] || return 1
    printf '%s\n' "$plan_dir"
}

gui_load_spruce_whitelist() {
    SPRUCE_WHITELIST=()
    local whitelist_file line
    whitelist_file="$(gui_state_dir)/whitelist"
    [[ -f "$whitelist_file" && ! -L "$whitelist_file" && -O "$whitelist_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "$line" == /* && ! "$line" =~ [[:cntrl:]] ]] || continue
        [[ ! "$line" =~ (^|/)\.\.(\/|$) ]] || continue
        SPRUCE_WHITELIST+=("${line%/}")
    done < "$whitelist_file"
}

gui_is_spruce_whitelisted() {
    local path="${1%/}"
    local protected
    for protected in "${SPRUCE_WHITELIST[@]+"${SPRUCE_WHITELIST[@]}"}"; do
        [[ "$path" == "$protected" || "$path" == "$protected/"* ]] && return 0
    done
    return 1
}

gui_valid_plan_id() {
    local plan_id="$1"
    [[ "${#plan_id}" -eq 36 && "$plan_id" =~ ^[0-9a-f-]+$ ]]
}

gui_valid_candidate_id() {
    local candidate_id="$1"
    [[ "${#candidate_id}" -eq 64 && "$candidate_id" =~ ^[0-9a-f]+$ ]]
}

gui_plist_value() {
    local plist="$1"
    local key="$2"
    [[ -f "$plist" ]] || return 1
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2> /dev/null || return 1
}

gui_clean_plan() {
    local plan_id created_at expires_at home cache_root resolved_cache_root plan_dir
    plan_id=$(gui_plan_id)
    created_at=$(date +%s)
    expires_at=$((created_at + 900))
    gui_emit_started "$plan_id" "$expires_at"

    if ! plan_dir=$(gui_prepare_plan_dir); then
        gui_emit_failed "plan_store_unavailable" "engine.plan_store_unavailable"
        return 1
    fi
    gui_load_spruce_whitelist

    home=$(gui_scan_home)
    home="${home%/}"
    cache_root="$home/Library/Caches"
    if [[ ! -d "$cache_root" || -L "$cache_root" ]]; then
        gui_emit_failed "cache_root_unavailable" "engine.cache_root_unavailable"
        return 1
    fi

    resolved_cache_root=$(cd -P "$cache_root" 2> /dev/null && pwd -P) || resolved_cache_root=""
    if [[ -z "$resolved_cache_root" || "$resolved_cache_root" != "$cache_root" ]]; then
        gui_emit_failed "unsafe_cache_root" "engine.unsafe_cache_root"
        return 1
    fi

    local -a candidates=()
    local path
    while IFS= read -r -d '' path; do
        [[ -e "$path" && ! -L "$path" ]] || continue
        [[ ! "$path" =~ [[:cntrl:]] ]] || continue
        should_protect_path "$path" && continue
        gui_is_spruce_whitelisted "$path" && continue
        validate_path_for_deletion "$path" > /dev/null 2>&1 || continue
        candidates+=("$path")
    done < <(find "$cache_root" -mindepth 1 -maxdepth 1 -print0 2> /dev/null)

    local candidate_count=0
    local total_bytes=0
    local size_kb size_bytes identity candidate_id device inode modified_at
    local -a plan_ids=()
    local -a plan_paths=()
    local -a plan_sizes=()
    local -a plan_devices=()
    local -a plan_inodes=()
    local -a plan_modified=()

    for path in "${candidates[@]+"${candidates[@]}"}"; do
        size_kb=$(get_path_size_kb "$path" 2> /dev/null || echo "0")
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
        size_bytes=$((size_kb * 1024))

        if [[ "$size_bytes" -le 0 ]]; then
            continue
        fi

        identity=$(mole_path_identity "$path")
        device=$(stat -f '%d' "$path" 2> /dev/null || echo "0")
        inode=$(stat -f '%i' "$path" 2> /dev/null || echo "0")
        modified_at=$(stat -f '%m' "$path" 2> /dev/null || echo "0")
        [[ "$device" =~ ^[0-9]+$ ]] || device=0
        [[ "$inode" =~ ^[0-9]+$ ]] || inode=0
        [[ "$modified_at" =~ ^[0-9]+$ ]] || modified_at=0
        candidate_id=$(gui_candidate_id "$identity")

        plan_ids+=("$candidate_id")
        plan_paths+=("$path")
        plan_sizes+=("$size_bytes")
        plan_devices+=("$device")
        plan_inodes+=("$inode")
        plan_modified+=("$modified_at")
        candidate_count=$((candidate_count + 1))
        total_bytes=$((total_bytes + size_bytes))
    done

    local plan_file="$plan_dir/$plan_id.plan"
    local staging_file
    staging_file=$(mktemp "$plan_dir/.$plan_id.XXXXXX") || {
        gui_emit_failed "plan_store_unavailable" "engine.plan_store_unavailable"
        return 1
    }
    chmod 600 "$staging_file" || return 1

    {
        printf 'protocol\t%s\n' "$SPRUCE_GUI_PROTOCOL_VERSION"
        printf 'engine_version\t%s\n' "$SPRUCE_ENGINE_PACKAGE_VERSION"
        printf 'engine_commit\t%s\n' "$SPRUCE_ENGINE_UPSTREAM_COMMIT"
        printf 'plan_id\t%s\n' "$plan_id"
        printf 'scope\tclean\n'
        printf 'created_at\t%s\n' "$created_at"
        printf 'expires_at\t%s\n' "$expires_at"
        local idx
        for ((idx = 0; idx < candidate_count; idx++)); do
            printf 'candidate\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "${plan_ids[$idx]}" "${plan_devices[$idx]}" "${plan_inodes[$idx]}" \
                "${plan_modified[$idx]}" "${plan_sizes[$idx]}" "${plan_paths[$idx]}" "$plan_id"
        done
    } > "$staging_file"

    if [[ -e "$plan_file" || -L "$plan_file" ]] || ! mv "$staging_file" "$plan_file"; then
        safe_remove "$staging_file" true > /dev/null 2>&1 || true
        gui_emit_failed "plan_store_unavailable" "engine.plan_store_unavailable"
        return 1
    fi
    chmod 600 "$plan_file"

    local completed=0
    local idx
    for ((idx = 0; idx < candidate_count; idx++)); do
        gui_emit_candidate "$plan_id" "${plan_ids[$idx]}" "${plan_paths[$idx]}" \
            "${plan_sizes[$idx]}" "${plan_devices[$idx]}" "${plan_inodes[$idx]}" "${plan_modified[$idx]}"
        completed=$((completed + 1))
        gui_emit_progress "$completed" "$candidate_count"
    done

    gui_emit_completed "$plan_id" "$total_bytes" "$candidate_count"
}

gui_app_list() {
    local inventory_id created_at expires_at plan_dir home
    inventory_id=$(gui_plan_id)
    created_at=$(date +%s)
    expires_at=$((created_at + 900))
    gui_emit_started "$inventory_id" "$expires_at" "app_list"

    if ! plan_dir=$(gui_prepare_plan_dir); then
        gui_emit_failed "plan_store_unavailable" "engine.plan_store_unavailable"
        return 1
    fi
    gui_load_spruce_whitelist
    home=$(gui_scan_home)
    home="${home%/}"

    local -a app_ids=() app_names=() app_paths=() app_bundles=() app_sizes=()
    local -a app_sources=() app_protected=() app_devices=() app_inodes=() app_modified=()
    local root path plist name bundle_id size_kb size_bytes source protected identity app_id device inode modified_at
    local -a roots=("/Applications" "$home/Applications")
    if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
        roots=("$home/Applications")
    fi

    for root in "${roots[@]}"; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        while IFS= read -r -d '' path; do
            [[ -d "$path" && ! -L "$path" && ! "$path" =~ [[:cntrl:]] ]] || continue
            plist="$path/Contents/Info.plist"
            bundle_id=$(gui_plist_value "$plist" "CFBundleIdentifier" || echo "")
            [[ -n "$bundle_id" && ! "$bundle_id" =~ [[:cntrl:]] ]] || continue
            name=$(gui_plist_value "$plist" "CFBundleDisplayName" || gui_plist_value "$plist" "CFBundleName" || echo "")
            [[ -n "$name" ]] || name="$(basename "$path" .app)"
            [[ ! "$name" =~ [[:cntrl:]] ]] || continue

            size_kb=$(get_path_size_kb "$path" 2> /dev/null || echo "0")
            [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
            size_bytes=$((size_kb * 1024))
            device=$(stat -f '%d' "$path" 2> /dev/null || echo "0")
            inode=$(stat -f '%i' "$path" 2> /dev/null || echo "0")
            modified_at=$(stat -f '%m' "$path" 2> /dev/null || echo "0")
            [[ "$device" =~ ^[0-9]+$ ]] || device=0
            [[ "$inode" =~ ^[0-9]+$ ]] || inode=0
            [[ "$modified_at" =~ ^[0-9]+$ ]] || modified_at=0
            identity=$(mole_path_identity "$path")
            app_id=$(gui_candidate_id "$identity|$bundle_id")
            source="Application"
            [[ "$path" == "$home/Applications/"* ]] && source="User"
            protected=false
            [[ "$bundle_id" == com.apple.* ]] && protected=true
            should_protect_path "$path" && protected=true
            gui_is_spruce_whitelisted "$path" && protected=true

            app_ids+=("$app_id")
            app_names+=("$name")
            app_paths+=("$path")
            app_bundles+=("$bundle_id")
            app_sizes+=("$size_bytes")
            app_sources+=("$source")
            app_protected+=("$protected")
            app_devices+=("$device")
            app_inodes+=("$inode")
            app_modified+=("$modified_at")
        done < <(find "$root" -mindepth 1 -maxdepth 3 -type d -name '*.app' -prune -print0 2> /dev/null)
    done

    local inventory_file="$plan_dir/app-$inventory_id.inventory"
    local staging_file
    staging_file=$(mktemp "$plan_dir/.app-$inventory_id.XXXXXX") || return 1
    chmod 600 "$staging_file"
    {
        printf 'protocol\t%s\n' "$SPRUCE_GUI_PROTOCOL_VERSION"
        printf 'engine_version\t%s\n' "$SPRUCE_ENGINE_PACKAGE_VERSION"
        printf 'engine_commit\t%s\n' "$SPRUCE_ENGINE_UPSTREAM_COMMIT"
        printf 'inventory_id\t%s\n' "$inventory_id"
        printf 'created_at\t%s\n' "$created_at"
        printf 'expires_at\t%s\n' "$expires_at"
        local idx
        for ((idx = 0; idx < ${#app_ids[@]}; idx++)); do
            printf 'application\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "${app_ids[$idx]}" "${app_devices[$idx]}" "${app_inodes[$idx]}" \
                "${app_modified[$idx]}" "${app_sizes[$idx]}" "${app_protected[$idx]}" \
                "${app_sources[$idx]}" "${app_bundles[$idx]}" "${app_paths[$idx]}" "${app_names[$idx]}"
        done
    } > "$staging_file"
    if [[ -e "$inventory_file" || -L "$inventory_file" ]] || ! mv "$staging_file" "$inventory_file"; then
        safe_remove "$staging_file" true > /dev/null 2>&1 || true
        gui_emit_failed "plan_store_unavailable" "engine.plan_store_unavailable"
        return 1
    fi
    chmod 600 "$inventory_file"

    local idx
    for ((idx = 0; idx < ${#app_ids[@]}; idx++)); do
        gui_emit_application "$inventory_id" "${app_ids[$idx]}" "${app_names[$idx]}" \
            "${app_paths[$idx]}" "${app_bundles[$idx]}" "${app_sizes[$idx]}" \
            "${app_sources[$idx]}" "${app_protected[$idx]}" "${app_devices[$idx]}" \
            "${app_inodes[$idx]}" "${app_modified[$idx]}"
        gui_emit_progress "$((idx + 1))" "${#app_ids[@]}"
    done
    gui_emit_completed "$inventory_id" "0" "${#app_ids[@]}"
}

gui_uninstall_plan() {
    local inventory_id="$1" requested_app_id="$2"
    gui_valid_plan_id "$inventory_id" || {
        gui_emit_failed "invalid_inventory_id" "engine.invalid_inventory_id"
        return 64
    }
    gui_valid_candidate_id "$requested_app_id" || {
        gui_emit_failed "invalid_application_id" "engine.invalid_application_id"
        return 64
    }

    local plan_dir inventory_file
    plan_dir=$(gui_prepare_plan_dir) || return 1
    gui_load_spruce_whitelist
    inventory_file="$plan_dir/app-$inventory_id.inventory"
    [[ -f "$inventory_file" && ! -L "$inventory_file" && -O "$inventory_file" ]] || {
        gui_emit_failed "inventory_not_found" "engine.inventory_not_found"
        return 1
    }
    [[ "$(stat -f '%Lp' "$inventory_file" 2> /dev/null || echo '')" == "600" ]] || {
        gui_emit_failed "unsafe_inventory_file" "engine.unsafe_inventory_file"
        return 1
    }

    local protocol="" stored_inventory_id="" expires_at=""
    local engine_version="" engine_commit=""
    local app_id="" app_device="" app_inode="" app_modified="" app_size="" app_is_protected=""
    local app_source="" bundle_id="" app_path="" app_name=""
    local kind a b c d e f g h i j
    local sibling_count=0
    local requested_bundle=""
    while IFS=$'\t' read -r kind a b c d e f g h i j; do
        case "$kind" in
            protocol) protocol="$a" ;;
            engine_version) engine_version="$a" ;;
            engine_commit) engine_commit="$a" ;;
            inventory_id) stored_inventory_id="$a" ;;
            created_at) ;;
            expires_at) expires_at="$a" ;;
            application)
                if [[ "$a" == "$requested_app_id" ]]; then
                    app_id="$a"; app_device="$b"; app_inode="$c"; app_modified="$d"; app_size="$e"
                    app_is_protected="$f"; app_source="$g"; bundle_id="$h"; app_path="$i"; app_name="$j"
                    requested_bundle="$h"
                fi
                ;;
            *) return 1 ;;
        esac
    done < "$inventory_file"

    if [[ "$engine_version" != "$SPRUCE_ENGINE_PACKAGE_VERSION" ||
        "$engine_commit" != "$SPRUCE_ENGINE_UPSTREAM_COMMIT" ]]; then
        gui_emit_failed "engine_identity_mismatch" "engine.engine_identity_mismatch"
        return 1
    fi
    if [[ "$protocol" != "$SPRUCE_GUI_PROTOCOL_VERSION" || "$stored_inventory_id" != "$inventory_id" ||
        ! "$expires_at" =~ ^[0-9]+$ || "$(date +%s)" -ge "$expires_at" || -z "$app_id" ]]; then
        gui_emit_failed "inventory_expired_or_invalid" "engine.inventory_expired_or_invalid"
        return 1
    fi
    if [[ "$app_is_protected" == "true" || "$bundle_id" == com.apple.* ]]; then
        gui_emit_failed "application_protected" "engine.application_protected"
        return 1
    fi
    gui_is_spruce_whitelisted "$app_path" && {
        gui_emit_failed "application_whitelisted" "engine.application_whitelisted"
        return 1
    }

    local home resolved_app_parent resolved_app_path current_bundle_id
    home=$(gui_scan_home)
    home="${home%/}"
    resolved_app_parent=$(cd -P "$(dirname "$app_path")" 2> /dev/null && pwd -P) || resolved_app_parent=""
    resolved_app_path="$resolved_app_parent/$(basename "$app_path")"
    case "$resolved_app_path" in
        /Applications/*.app | "$home/Applications/"*.app) ;;
        *)
            gui_emit_failed "application_outside_root" "engine.application_outside_root"
            return 1
            ;;
    esac
    validate_path_for_deletion "$app_path" > /dev/null 2>&1 || {
        gui_emit_failed "application_protected" "engine.application_protected"
        return 1
    }
    current_bundle_id=$(gui_plist_value "$app_path/Contents/Info.plist" "CFBundleIdentifier" || echo "")
    [[ "$current_bundle_id" == "$bundle_id" ]] || {
        gui_emit_failed "application_changed" "engine.application_changed"
        return 1
    }

    while IFS=$'\t' read -r kind a _ _ _ _ _ _ h _ _; do
        [[ "$kind" == "application" && "$h" == "$requested_bundle" ]] && sibling_count=$((sibling_count + 1))
    done < "$inventory_file"

    [[ -d "$app_path" && ! -L "$app_path" ]] || {
        gui_emit_failed "application_changed" "engine.application_changed"
        return 1
    }
    if [[ "$(stat -f '%d' "$app_path" 2> /dev/null || echo 0)" != "$app_device" ||
        "$(stat -f '%i' "$app_path" 2> /dev/null || echo 0)" != "$app_inode" ||
        "$(stat -f '%m' "$app_path" 2> /dev/null || echo 0)" != "$app_modified" ]]; then
        gui_emit_failed "application_changed" "engine.application_changed"
        return 1
    fi

    local plan_id created_at plan_expires
    plan_id=$(gui_plan_id)
    created_at=$(date +%s)
    plan_expires=$((created_at + 900))
    gui_emit_started "$plan_id" "$plan_expires" "uninstall_plan"

    local -a target_paths=("$app_path")
    local -a target_categories=("application")
    local -a target_risks=("review")
    local -a target_selected=("true")
    if [[ "$sibling_count" -le 1 ]]; then
        local -a known_paths=(
            "$home/Library/Caches/$bundle_id"
            "$home/Library/Preferences/$bundle_id.plist"
            "$home/Library/Saved Application State/$bundle_id.savedState"
            "$home/Library/HTTPStorages/$bundle_id"
            "$home/Library/WebKit/$bundle_id"
            "$home/Library/Application Support/$bundle_id"
            "$home/Library/Containers/$bundle_id"
        )
        local known
        for known in "${known_paths[@]}"; do
            [[ -e "$known" && ! -L "$known" && ! "$known" =~ [[:cntrl:]] ]] || continue
            should_protect_path "$known" && continue
            gui_is_spruce_whitelisted "$known" && continue
            validate_path_for_deletion "$known" > /dev/null 2>&1 || continue
            target_paths+=("$known")
            case "$known" in
                *"/Caches/"* | *"/HTTPStorages/"* | *"/WebKit/"*)
                    target_categories+=("cache"); target_risks+=("safe"); target_selected+=("true") ;;
                *"/Preferences/"* | *"/Saved Application State/"*)
                    target_categories+=("settings"); target_risks+=("review"); target_selected+=("true") ;;
                *)
                    target_categories+=("user_data"); target_risks+=("high"); target_selected+=("false") ;;
            esac
        done
    fi

    local -a target_ids=() target_sizes=() target_devices=() target_inodes=() target_modified=()
    local path size_kb size_bytes device inode modified identity candidate_id idx
    for ((idx = 0; idx < ${#target_paths[@]}; idx++)); do
        path="${target_paths[$idx]}"
        size_kb=$(get_path_size_kb "$path" 2> /dev/null || echo 0)
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
        size_bytes=$((size_kb * 1024))
        device=$(stat -f '%d' "$path" 2> /dev/null || echo 0)
        inode=$(stat -f '%i' "$path" 2> /dev/null || echo 0)
        modified=$(stat -f '%m' "$path" 2> /dev/null || echo 0)
        identity=$(mole_path_identity "$path")
        candidate_id=$(gui_candidate_id "$identity|uninstall|$bundle_id")
        target_ids+=("$candidate_id"); target_sizes+=("$size_bytes"); target_devices+=("$device")
        target_inodes+=("$inode"); target_modified+=("$modified")
    done

    local plan_file="$plan_dir/$plan_id.plan" staging_file
    staging_file=$(mktemp "$plan_dir/.$plan_id.XXXXXX") || return 1
    chmod 600 "$staging_file"
    {
        printf 'protocol\t%s\nengine_version\t%s\nengine_commit\t%s\nplan_id\t%s\nscope\tuninstall\ncreated_at\t%s\nexpires_at\t%s\n' \
            "$SPRUCE_GUI_PROTOCOL_VERSION" "$SPRUCE_ENGINE_PACKAGE_VERSION" \
            "$SPRUCE_ENGINE_UPSTREAM_COMMIT" "$plan_id" "$created_at" "$plan_expires"
        for ((idx = 0; idx < ${#target_ids[@]}; idx++)); do
            printf 'candidate\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "${target_ids[$idx]}" "${target_devices[$idx]}" "${target_inodes[$idx]}" \
                "${target_modified[$idx]}" "${target_sizes[$idx]}" "${target_paths[$idx]}" "$plan_id"
        done
    } > "$staging_file"
    mv "$staging_file" "$plan_file" || return 1
    chmod 600 "$plan_file"

    for ((idx = 0; idx < ${#target_ids[@]}; idx++)); do
        gui_emit_uninstall_candidate "$plan_id" "${target_ids[$idx]}" "$(basename "${target_paths[$idx]}")" \
            "${target_paths[$idx]}" "${target_sizes[$idx]}" "${target_categories[$idx]}" \
            "${target_risks[$idx]}" "${target_selected[$idx]}" "${target_devices[$idx]}" \
            "${target_inodes[$idx]}" "${target_modified[$idx]}"
        gui_emit_progress "$((idx + 1))" "${#target_ids[@]}"
    done
    gui_emit_completed "$plan_id" "0" "${#target_ids[@]}"
}

gui_tool_plan() {
    local tool="$1"
    [[ "$tool" == "developer" || "$tool" == "installers" ]] || {
        gui_emit_failed "unsupported_tool" "engine.unsupported_tool"
        return 64
    }

    local plan_dir home plan_id created_at expires_at
    plan_dir=$(gui_prepare_plan_dir) || return 1
    gui_load_spruce_whitelist
    home=$(gui_scan_home)
    home="${home%/}"
    plan_id=$(gui_plan_id)
    created_at=$(date +%s)
    expires_at=$((created_at + 900))
    gui_emit_started "$plan_id" "$expires_at" "tool_plan"

    local -a target_paths=() target_categories=() target_risks=() target_selected=()
    local path
    if [[ "$tool" == "developer" ]]; then
        local -a known_paths=(
            "$home/Library/Developer/Xcode/DerivedData"
            "$home/Library/Caches/org.swift.swiftpm"
            "$home/.npm/_cacache"
            "$home/Library/Caches/go-build"
            "$home/Library/Caches/pip"
        )
        for path in "${known_paths[@]}"; do
            [[ -e "$path" && ! -L "$path" && ! "$path" =~ [[:cntrl:]] ]] || continue
            should_protect_path "$path" && continue
            gui_is_spruce_whitelisted "$path" && continue
            validate_path_for_deletion "$path" > /dev/null 2>&1 || continue
            target_paths+=("$path")
            target_categories+=("developer_cache")
            if [[ "$path" == *"/DerivedData" ]]; then
                target_risks+=("review"); target_selected+=("false")
            else
                target_risks+=("safe"); target_selected+=("true")
            fi
        done
    else
        local downloads="$home/Downloads"
        if [[ -d "$downloads" && ! -L "$downloads" ]]; then
            while IFS= read -r -d '' path; do
                [[ -f "$path" && ! -L "$path" && ! "$path" =~ [[:cntrl:]] ]] || continue
                gui_is_spruce_whitelisted "$path" && continue
                validate_path_for_deletion "$path" > /dev/null 2>&1 || continue
                case "${path##*.}" in
                    dmg | pkg | mpkg | iso) ;;
                    *) continue ;;
                esac
                target_paths+=("$path")
                target_categories+=("installer")
                target_risks+=("review")
                target_selected+=("false")
            done < <(find "$downloads" -mindepth 1 -maxdepth 2 -type f -print0 2> /dev/null)
        fi
    fi

    local -a target_ids=() target_sizes=() target_devices=() target_inodes=() target_modified=()
    local size_kb size_bytes device inode modified identity candidate_id idx
    for ((idx = 0; idx < ${#target_paths[@]}; idx++)); do
        path="${target_paths[$idx]}"
        size_kb=$(get_path_size_kb "$path" 2> /dev/null || echo 0)
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
        size_bytes=$((size_kb * 1024))
        device=$(stat -f '%d' "$path" 2> /dev/null || echo 0)
        inode=$(stat -f '%i' "$path" 2> /dev/null || echo 0)
        modified=$(stat -f '%m' "$path" 2> /dev/null || echo 0)
        identity=$(mole_path_identity "$path")
        candidate_id=$(gui_candidate_id "$identity|tool|$tool")
        target_ids+=("$candidate_id"); target_sizes+=("$size_bytes"); target_devices+=("$device")
        target_inodes+=("$inode"); target_modified+=("$modified")
    done

    local plan_file="$plan_dir/$plan_id.plan" staging_file
    staging_file=$(mktemp "$plan_dir/.$plan_id.XXXXXX") || return 1
    chmod 600 "$staging_file"
    {
        printf 'protocol\t%s\nengine_version\t%s\nengine_commit\t%s\nplan_id\t%s\nscope\ttoolbox\ncreated_at\t%s\nexpires_at\t%s\n' \
            "$SPRUCE_GUI_PROTOCOL_VERSION" "$SPRUCE_ENGINE_PACKAGE_VERSION" \
            "$SPRUCE_ENGINE_UPSTREAM_COMMIT" "$plan_id" "$created_at" "$expires_at"
        for ((idx = 0; idx < ${#target_ids[@]}; idx++)); do
            printf 'candidate\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "${target_ids[$idx]}" "${target_devices[$idx]}" "${target_inodes[$idx]}" \
                "${target_modified[$idx]}" "${target_sizes[$idx]}" "${target_paths[$idx]}" "$plan_id"
        done
    } > "$staging_file"
    mv "$staging_file" "$plan_file" || return 1
    chmod 600 "$plan_file"

    for ((idx = 0; idx < ${#target_ids[@]}; idx++)); do
        gui_emit_uninstall_candidate "$plan_id" "${target_ids[$idx]}" "$(basename "${target_paths[$idx]}")" \
            "${target_paths[$idx]}" "${target_sizes[$idx]}" "${target_categories[$idx]}" \
            "${target_risks[$idx]}" "${target_selected[$idx]}" "${target_devices[$idx]}" \
            "${target_inodes[$idx]}" "${target_modified[$idx]}"
        gui_emit_progress "$((idx + 1))" "${#target_ids[@]}"
    done
    gui_emit_completed "$plan_id" "0" "${#target_ids[@]}"
}

gui_apply_plan() {
    local plan_id="$1"
    local items="$2"
    local plan_dir plan_file

    gui_valid_plan_id "$plan_id" || {
        gui_emit_failed "invalid_plan_id" "engine.invalid_plan_id"
        return 64
    }
    [[ -n "$items" && ! "$items" =~ [[:cntrl:]] ]] || {
        gui_emit_failed "invalid_items" "engine.invalid_items"
        return 64
    }
    if ! plan_dir=$(gui_prepare_plan_dir); then
        gui_emit_failed "plan_store_unavailable" "engine.plan_store_unavailable"
        return 1
    fi
    gui_load_spruce_whitelist

    plan_file="$plan_dir/$plan_id.plan"
    if [[ ! -f "$plan_file" || -L "$plan_file" || ! -O "$plan_file" ]]; then
        gui_emit_failed "plan_not_found" "engine.plan_not_found"
        return 1
    fi

    local permissions
    permissions=$(stat -f '%Lp' "$plan_file" 2> /dev/null || echo "")
    if [[ "$permissions" != "600" ]]; then
        gui_emit_failed "unsafe_plan_file" "engine.unsafe_plan_file"
        return 1
    fi

    local -a requested_ids=()
    IFS=',' read -r -a requested_ids <<< "$items"
    if [[ ${#requested_ids[@]} -eq 0 || ${#requested_ids[@]} -gt 500 ]]; then
        gui_emit_failed "invalid_items" "engine.invalid_items"
        return 64
    fi

    local i j
    for ((i = 0; i < ${#requested_ids[@]}; i++)); do
        gui_valid_candidate_id "${requested_ids[$i]}" || {
            gui_emit_failed "invalid_candidate_id" "engine.invalid_candidate_id"
            return 64
        }
        for ((j = i + 1; j < ${#requested_ids[@]}; j++)); do
            if [[ "${requested_ids[$i]}" == "${requested_ids[$j]}" ]]; then
                gui_emit_failed "duplicate_candidate_id" "engine.duplicate_candidate_id"
                return 64
            fi
        done
    done

    local protocol="" stored_plan_id="" scope="" created_at="" expires_at=""
    local engine_version="" engine_commit=""
    local -a plan_ids=()
    local -a plan_devices=()
    local -a plan_inodes=()
    local -a plan_modified=()
    local -a plan_sizes=()
    local -a plan_paths=()
    local kind a b c d e f g
    while IFS=$'\t' read -r kind a b c d e f g; do
        case "$kind" in
            protocol) protocol="$a" ;;
            engine_version) engine_version="$a" ;;
            engine_commit) engine_commit="$a" ;;
            plan_id) stored_plan_id="$a" ;;
            scope) scope="$a" ;;
            created_at) created_at="$a" ;;
            expires_at) expires_at="$a" ;;
            candidate)
                [[ "$g" == "$plan_id" ]] || {
                    gui_emit_failed "corrupt_plan" "engine.corrupt_plan"
                    return 1
                }
                plan_ids+=("$a")
                plan_devices+=("$b")
                plan_inodes+=("$c")
                plan_modified+=("$d")
                plan_sizes+=("$e")
                plan_paths+=("$f")
                ;;
            *)
                gui_emit_failed "corrupt_plan" "engine.corrupt_plan"
                return 1
                ;;
        esac
    done < "$plan_file"

    if [[ "$engine_version" != "$SPRUCE_ENGINE_PACKAGE_VERSION" ||
        "$engine_commit" != "$SPRUCE_ENGINE_UPSTREAM_COMMIT" ]]; then
        gui_emit_failed "engine_identity_mismatch" "engine.engine_identity_mismatch"
        return 1
    fi
    if [[ "$protocol" != "$SPRUCE_GUI_PROTOCOL_VERSION" || "$stored_plan_id" != "$plan_id" ||
        ("$scope" != "clean" && "$scope" != "uninstall" && "$scope" != "toolbox") ||
        ! "$created_at" =~ ^[0-9]+$ || ! "$expires_at" =~ ^[0-9]+$ ]]; then
        gui_emit_failed "corrupt_plan" "engine.corrupt_plan"
        return 1
    fi

    gui_emit_started "$plan_id" "$expires_at" "apply_clean"
    if [[ "$(date +%s)" -ge "$expires_at" ]]; then
        gui_emit_failed "plan_expired" "engine.plan_expired"
        return 1
    fi

    local -a selected_ids=()
    local -a selected_devices=()
    local -a selected_inodes=()
    local -a selected_modified=()
    local -a selected_sizes=()
    local -a selected_paths=()
    local found
    for ((i = 0; i < ${#requested_ids[@]}; i++)); do
        found=false
        for ((j = 0; j < ${#plan_ids[@]}; j++)); do
            if [[ "${requested_ids[$i]}" == "${plan_ids[$j]}" ]]; then
                selected_ids+=("${plan_ids[$j]}")
                selected_devices+=("${plan_devices[$j]}")
                selected_inodes+=("${plan_inodes[$j]}")
                selected_modified+=("${plan_modified[$j]}")
                selected_sizes+=("${plan_sizes[$j]}")
                selected_paths+=("${plan_paths[$j]}")
                found=true
                break
            fi
        done
        if [[ "$found" != "true" ]]; then
            gui_emit_failed "candidate_not_in_plan" "engine.candidate_not_in_plan"
            return 1
        fi
    done

    local home cache_root resolved_cache_root path resolved_parent resolved_path allowed_path
    local current_device current_inode current_modified
    home=$(gui_scan_home)
    home="${home%/}"
    cache_root="$home/Library/Caches"
    resolved_cache_root=""
    if [[ "$scope" == "clean" ]]; then
        [[ -d "$cache_root" && ! -L "$cache_root" ]] || {
            gui_emit_failed "unsafe_cache_root" "engine.unsafe_cache_root"
            return 1
        }
        resolved_cache_root=$(cd -P "$cache_root" 2> /dev/null && pwd -P) || resolved_cache_root=""
        [[ -n "$resolved_cache_root" && "$resolved_cache_root" == "$cache_root" ]] || {
            gui_emit_failed "unsafe_cache_root" "engine.unsafe_cache_root"
            return 1
        }
    fi

    for ((i = 0; i < ${#selected_ids[@]}; i++)); do
        path="${selected_paths[$i]}"
        [[ -e "$path" && ! -L "$path" && ! "$path" =~ [[:cntrl:]] ]] || {
            gui_emit_failed "candidate_changed" "engine.candidate_changed"
            return 1
        }
        resolved_parent=$(cd -P "$(dirname "$path")" 2> /dev/null && pwd -P) || resolved_parent=""
        resolved_path="$resolved_parent/$(basename "$path")"
        allowed_path=false
        if [[ "$scope" == "clean" && "$resolved_path" == "$resolved_cache_root/"* ]]; then
            allowed_path=true
        elif [[ "$scope" == "uninstall" ]]; then
            case "$resolved_path" in
                /Applications/*.app | "$home/Applications/"*.app | \
                    "$home/Library/Caches/"* | "$home/Library/Preferences/"*.plist | \
                    "$home/Library/Saved Application State/"*.savedState | \
                    "$home/Library/HTTPStorages/"* | "$home/Library/WebKit/"* | \
                    "$home/Library/Application Support/"* | "$home/Library/Containers/"*)
                    allowed_path=true
                    ;;
            esac
        elif [[ "$scope" == "toolbox" ]]; then
            case "$resolved_path" in
                "$home/Library/Developer/Xcode/DerivedData" | \
                    "$home/Library/Caches/org.swift.swiftpm" | \
                    "$home/.npm/_cacache" | \
                    "$home/Library/Caches/go-build" | \
                    "$home/Library/Caches/pip")
                    allowed_path=true
                    ;;
                "$home/Downloads/"*)
                    case "${resolved_path##*.}" in
                        dmg | pkg | mpkg | iso) allowed_path=true ;;
                    esac
                    ;;
            esac
        fi
        [[ "$allowed_path" == "true" ]] || {
            gui_emit_failed "candidate_outside_root" "engine.candidate_outside_root"
            return 1
        }
        should_protect_path "$path" && {
            gui_emit_failed "candidate_protected" "engine.candidate_protected"
            return 1
        }
        gui_is_spruce_whitelisted "$path" && {
            gui_emit_failed "candidate_whitelisted" "engine.candidate_whitelisted"
            return 1
        }
        validate_path_for_deletion "$path" > /dev/null 2>&1 || {
            gui_emit_failed "candidate_rejected" "engine.candidate_rejected"
            return 1
        }

        current_device=$(stat -f '%d' "$path" 2> /dev/null || echo "0")
        current_inode=$(stat -f '%i' "$path" 2> /dev/null || echo "0")
        current_modified=$(stat -f '%m' "$path" 2> /dev/null || echo "0")
        if [[ "$current_device" != "${selected_devices[$i]}" ||
            "$current_inode" != "${selected_inodes[$i]}" ||
            "$current_modified" != "${selected_modified[$i]}" ]]; then
            gui_emit_failed "candidate_changed" "engine.candidate_changed"
            return 1
        fi
    done

    local execution_file="$plan_dir/$plan_id.executing"
    if [[ -e "$execution_file" || -L "$execution_file" ]] || ! mv "$plan_file" "$execution_file"; then
        gui_emit_failed "plan_already_used" "engine.plan_already_used"
        return 1
    fi
    chmod 400 "$execution_file" 2> /dev/null || true

    export MOLE_DELETE_MODE=trash
    export MOLE_CURRENT_COMMAND="sprucemymac-$scope"
    export MOLE_DELETE_LOG="$MOLE_LOG_DIR/deletions.log"

    local completed=0 failed_count=0 freed_bytes=0
    for ((i = 0; i < ${#selected_ids[@]}; i++)); do
        path="${selected_paths[$i]}"
        if mole_delete "$path" false > /dev/null 2>&1; then
            freed_bytes=$((freed_bytes + selected_sizes[i]))
            gui_emit_item_result "$plan_id" "${selected_ids[$i]}" "trashed" "${selected_sizes[$i]}"
        else
            failed_count=$((failed_count + 1))
            gui_emit_item_result "$plan_id" "${selected_ids[$i]}" "failed" "0" "trash_unavailable"
        fi
        completed=$((completed + 1))
        gui_emit_progress "$completed" "${#selected_ids[@]}"
    done

    mv "$execution_file" "$plan_dir/$plan_id.done" 2> /dev/null || true
    gui_emit_completed "$plan_id" "$freed_bytes" "${#selected_ids[@]}" "$failed_count"
}

main() {
    local command="${1:-}"
    [[ $# -gt 0 ]] && shift

    local format="ndjson" plan_id="" items="" inventory_id="" app_id="" tool=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format)
                shift
                [[ $# -gt 0 ]] || {
                    gui_emit_failed "missing_format" "engine.missing_format"
                    return 64
                }
                format="$1"
                ;;
            --no-auth)
                ;;
            --plan-id)
                shift
                [[ $# -gt 0 ]] || {
                    gui_emit_failed "missing_plan_id" "engine.missing_plan_id"
                    return 64
                }
                plan_id="$1"
                ;;
            --items)
                shift
                [[ $# -gt 0 ]] || {
                    gui_emit_failed "missing_items" "engine.missing_items"
                    return 64
                }
                items="$1"
                ;;
            --inventory-id)
                shift
                [[ $# -gt 0 ]] || {
                    gui_emit_failed "missing_inventory_id" "engine.missing_inventory_id"
                    return 64
                }
                inventory_id="$1"
                ;;
            --app-id)
                shift
                [[ $# -gt 0 ]] || {
                    gui_emit_failed "missing_application_id" "engine.missing_application_id"
                    return 64
                }
                app_id="$1"
                ;;
            --tool)
                shift
                [[ $# -gt 0 ]] || {
                    gui_emit_failed "missing_tool" "engine.missing_tool"
                    return 64
                }
                tool="$1"
                ;;
            *)
                gui_emit_failed "invalid_argument" "engine.invalid_argument"
                return 64
                ;;
        esac
        shift
    done

    if [[ "$format" != "ndjson" ]]; then
        gui_emit_failed "unsupported_format" "engine.unsupported_format"
        return 64
    fi

    case "$command" in
        clean-plan)
            [[ -z "$plan_id" && -z "$items" && -z "$inventory_id" && -z "$app_id" && -z "$tool" ]] || {
                gui_emit_failed "invalid_argument" "engine.invalid_argument"
                return 64
            }
            gui_clean_plan
            ;;
        app-list)
            [[ -z "$plan_id" && -z "$items" && -z "$inventory_id" && -z "$app_id" && -z "$tool" ]] || {
                gui_emit_failed "invalid_argument" "engine.invalid_argument"
                return 64
            }
            gui_app_list
            ;;
        uninstall-plan)
            [[ -n "$inventory_id" && -n "$app_id" && -z "$plan_id" && -z "$items" && -z "$tool" ]] || {
                gui_emit_failed "missing_uninstall_arguments" "engine.missing_uninstall_arguments"
                return 64
            }
            gui_uninstall_plan "$inventory_id" "$app_id"
            ;;
        tool-plan)
            [[ -n "$tool" && -z "$inventory_id" && -z "$app_id" && -z "$plan_id" && -z "$items" ]] || {
                gui_emit_failed "missing_tool_arguments" "engine.missing_tool_arguments"
                return 64
            }
            gui_tool_plan "$tool"
            ;;
        apply-plan)
            [[ -n "$plan_id" && -n "$items" && -z "$inventory_id" && -z "$app_id" && -z "$tool" ]] || {
                gui_emit_failed "missing_apply_arguments" "engine.missing_apply_arguments"
                return 64
            }
            gui_apply_plan "$plan_id" "$items"
            ;;
        *)
            gui_emit_failed "unsupported_command" "engine.unsupported_command"
            return 64
            ;;
    esac
}

main "$@"
