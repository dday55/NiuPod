#!/bin/zsh
# 生成本地工程并编译 / 测试
#
# 用法：
#   ./scripts/build.sh          # 编译
#   ./scripts/build.sh test     # 编译 + 单测
#   ./scripts/build.sh ui       # 编译 + UI 布局测试（需 UDID_SIM 指定已启动的模拟器）
#
# 说明：-disable-sandbox 只用于本机的命令行构建。本机 swift-plugin-server
# 无法创建沙箱（sandbox_apply: Operation not permitted），不加这个开关所有
# Swift 宏（@Observable 等）都会报 "produced malformed response"。
# Xcode 图形界面里正常构建不需要它。
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-build}"
UDID_SIM="${UDID_SIM:-}"

if [[ "$MODE" == "ui" ]]; then
  ACTION="test"
  DESTINATION="platform=iOS Simulator,id=$UDID_SIM"
  EXTRA=(-only-testing NiuPodUITests/FullScreenUITests)
else
  ACTION="$MODE"
  # 自动挑一台可用的 iPhone 模拟器：硬编码机型（如 iPhone 17）在新机器上
  # 未必存在，clone 后第一次跑就报 "Unable to find a device" 很劝退。
  if [[ -z "$UDID_SIM" ]]; then
    UDID_SIM=$(xcrun simctl list devices available | grep 'iPhone' | grep -oE '[0-9A-F-]{36}' | head -1)
    [[ -z "$UDID_SIM" ]] && { echo "!! 找不到可用的 iPhone 模拟器，先在 Xcode 里下载一个"; exit 1; }
  fi
  DESTINATION="platform=iOS Simulator,id=$UDID_SIM"
  EXTRA=(-only-testing NiuPodTests)
fi

echo "==> 生成 Xcode 工程"
./scripts/generate.sh

echo "==> $MODE"
xcodebuild \
  -project NiuPod.xcodeproj \
  -scheme NiuPod \
  -destination "$DESTINATION" \
  -derivedDataPath build/DerivedData \
  OTHER_SWIFT_FLAGS="-disable-sandbox" \
  "$ACTION" "${EXTRA[@]}" 2>&1 | tail -n 40
