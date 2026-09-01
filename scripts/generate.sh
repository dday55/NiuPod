#!/bin/zsh
# 生成 Xcode 工程（xcodegen + 必要修补）
#
# 用法：./scripts/generate.sh
#
# 为什么要补一刀：
#   1. 本机 xcodegen 2.45.4 会忽略 target 的 `resources` 键，asset catalog 只能
#      以 `type: folder` 从 sources 引入。
#   2. 但 `type: folder` 生成的是 `lastKnownFileType = folder`，Xcode 会把它当
#      普通文件夹原样拷进 bundle，不会跑 actool，产物里就没有 Assets.car，
#      AppIcon 也就不会生效。
#   3. 正确类型是 `folder.assetcatalog`。xcodegen 没有暴露这个选项，
#      所以在生成后改这一处。
set -euo pipefail

cd "$(dirname "$0")/.."

# 非交互 shell 不加载 .zshrc，Homebrew 的 bin 可能不在 PATH 里，补一下
[[ -d /opt/homebrew/bin && ":$PATH:" != *":/opt/homebrew/bin:"* ]] && export PATH="/opt/homebrew/bin:$PATH"
[[ -d /usr/local/bin && ":$PATH:" != *":/usr/local/bin:"* ]] && export PATH="/usr/local/bin:$PATH"
command -v xcodegen >/dev/null 2>&1 || { echo "!! 找不到 xcodegen，先执行 brew install xcodegen"; exit 1; }

# 团队 ID 不入库：从本地 .niupod-team 读出后注入环境变量，由 project.yml 的
# ${NIUPOD_TEAM_ID} 展开。没跑过 set-team.sh 时显式置空——否则占位符字面量
# 会原样进 pbxproj，Xcode 的签名报错让人摸不着头脑；置空后是标准提示。
if [[ -f .niupod-team ]]; then
  export NIUPOD_TEAM_ID="$(tr -d '[:space:]' < .niupod-team)"
elif [[ -z "${NIUPOD_TEAM_ID:-}" ]]; then
  export NIUPOD_TEAM_ID=""
  echo "!! 未设置团队 ID：先运行 ./scripts/set-team.sh <你的TeamID>"
  echo "   （模拟器构建不受影响；真机构建需在 Xcode Signing 面板选团队）"
fi

echo "==> xcodegen generate"
xcodegen generate

PBX=NiuPod.xcodeproj/project.pbxproj
BEFORE="lastKnownFileType = folder; path = Assets.xcassets"
AFTER="lastKnownFileType = folder.assetcatalog; path = Assets.xcassets"

if grep -q "$BEFORE" "$PBX"; then
  /usr/bin/sed -i '' "s|$BEFORE|$AFTER|" "$PBX"
  echo "==> 已修正 Assets.xcassets 类型为 folder.assetcatalog"
elif grep -q "folder.assetcatalog; path = Assets.xcassets" "$PBX"; then
  echo "==> Assets.xcassets 类型已是 folder.assetcatalog，跳过"
else
  echo "!! 没找到 Assets.xcassets 的引用，检查 project.yml 的 sources 配置"
  exit 1
fi
