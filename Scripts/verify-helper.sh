#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

app_path="${1:-}"
[[ -d "$app_path" ]] || {
    echo "usage: $0 /path/to/SpruceMyMac.app" >&2
    exit 64
}

readonly contents="$app_path/Contents"
readonly helper="$contents/Library/HelperTools/sprucemymac-helper"
readonly plist="$contents/Library/LaunchDaemons/com.van426326.sprucemymac.helper.plist"

[[ -x "$helper" && -f "$plist" && ! -L "$helper" && ! -L "$plist" ]]
[[ "$(/usr/bin/stat -f '%Lp' "$helper")" == "755" ]]
[[ "$(/usr/bin/stat -f '%Lp' "$plist")" == "644" ]]
/usr/bin/plutil -lint "$plist" > /dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")" == "com.van426326.sprucemymac.helper" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$plist")" == \
    "Contents/Library/HelperTools/sprucemymac-helper" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:com.van426326.sprucemymac.helper' "$plist")" == "true" ]]

manifest=$("$helper" --self-test)
expected_manifest='{"protocol":1,"service":"com.van426326.sprucemymac.helper","tasks":["flush-dns-cache","rebuild-spotlight-index"],"fixed_commands":true}'
[[ "$manifest" == "$expected_manifest" ]]

set +e
direct_output=$("$helper" --run-task flush-dns-cache 2>&1)
direct_status=$?
set -e
[[ "$direct_status" -eq 64 ]]
printf '%s\n' "$direct_output" | /usr/bin/grep -F 'accepts no command-line tasks' > /dev/null

if [[ -f "$contents/_CodeSignature/CodeResources" ]]; then
    /usr/bin/codesign --verify --deep --strict "$app_path"
fi

echo "privileged helper bundle verification passed"
