#!/bin/zsh
# 配置本地签名团队 ID（写入 .niupod-team，该文件不入库）
#
# 用法：
#   ./scripts/set-team.sh ABC123DEFG          # 写入并立即重新生成工程
#   ./scripts/set-team.sh --print             # 只看当前配置
#
# 团队 ID 在 Apple Developer 网站的 Membership 页面查看，
# 也可以在 Xcode 的 Signing & Capabilities 面板里直接复制。
#
# 为什么不放进 project.yml：团队 ID 绑个人 Apple 账号，属于身份信息，
# 提交到公开仓库等于泄露。改成由本地文件注入后，仓库里只有 ${NIUPOD_TEAM_ID}。
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--print" ]]; then
  if [[ -f .niupod-team ]]; then
    echo "当前团队 ID: $(cat .niupod-team)"
  else
    echo "未配置（无 .niupod-team）"
  fi
  exit 0
fi

TEAM_ID="${1:-}"

if [[ -z "$TEAM_ID" ]]; then
  echo "用法: ./scripts/set-team.sh <TeamID>"
  echo "      ./scripts/set-team.sh --print"
  exit 1
fi

# 团队 ID 是 10 位大写字母数字
if ! [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "!! '$TEAM_ID' 看起来不是团队 ID（应为 10 位大写字母或数字）"
  exit 1
fi

printf '%s\n' "$TEAM_ID" > .niupod-team
echo "==> 已写入 .niupod-team（该文件已被 .gitignore 忽略）"

./scripts/generate.sh
