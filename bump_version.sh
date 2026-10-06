#!/bin/bash
#
# bump_version.sh —— 打包前递增构建号（CURRENT_PROJECT_VERSION）
#
# 用法（Mac 终端，在 LanShare/ios 目录下）：
#   ./bump_version.sh            # 仅构建号 +1（如 1 -> 2）
#   ./bump_version.sh --marketing # 构建号 +1 且营销版本末位 +1（如 1.0.0 -> 1.0.1）
#
# 改的是 project.yml 里的版本，需在其后执行 xcodegen generate 才会生效。

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
FILE="$DIR/project.yml"
[ -f "$FILE" ] || { echo "未找到 $FILE"; exit 1; }

# 递增构建号（LanShare 与 ShareExtension 两处都会 +1，保持一致便于嵌入）
perl -i -pe 's/^((\s*)CURRENT_PROJECT_VERSION:\s*)"(\d+)"\s*$/$1 . ($3 + 1) . "\n"/e' "$FILE"

if [ "${1:-}" = "--marketing" ]; then
  # 营销版本 x.y.z -> x.y.(z+1)
  perl -i -pe 's/^((\s*)MARKETING_VERSION:\s*)"(\d+\.\d+)\.(\d+)"\s*$/$1 . $3 . "." . ($4 + 1) . "\n"/e' "$FILE"
fi

echo "版本号已更新："
grep -nE "MARKETING_VERSION|CURRENT_PROJECT_VERSION" "$FILE"
