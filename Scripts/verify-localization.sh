#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT_DIR/App/Resources/Localizable.xcstrings"

/usr/bin/jq -e '
    .sourceLanguage == "zh-Hans" and
    .version == "1.0" and
    (.strings | length) >= 200 and
    ([.strings[] |
        .localizations.en.stringUnit.state == "translated" and
        (.localizations.en.stringUnit.value | type == "string" and length > 0)
    ] | all)
' "$CATALOG" > /dev/null

for required_key in \
    "概览" "智能清理" "应用卸载" "空间分析" "工具箱" \
    "系统维护" "移入废纸篓" "关于" "GPL-3.0 许可证"; do
    /usr/bin/jq -e --arg key "$required_key" '.strings[$key].localizations.en.stringUnit.value | length > 0' \
        "$CATALOG" > /dev/null
done

echo "localization catalog verification passed"
