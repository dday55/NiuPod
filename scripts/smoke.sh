#!/bin/zsh
# 模拟器冒烟：构建 → 安装 → 启动 → 抓日志 → 退出
#
# 用法：./scripts/smoke.sh [模拟器UDID]（默认用已启动的设备）
set -uo pipefail

cd "$(dirname "$0")/.."

UDID="${1:-booted}"
BUNDLE_ID="com.niupod"

# xcodebuild 的 destination 不认 "booted"，先解析成真实 UDID；
# 否则构建必失败，脚本却拿旧产物继续冒烟，报假绿灯。
if [[ "$UDID" == "booted" ]]; then
  UDID=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
  [[ -z "$UDID" ]] && { echo "!! 没有已启动的模拟器，先启动一个或显式传入 UDID"; exit 1; }
fi

echo "==> 构建（目标模拟器）"
BUILD_OUTPUT=$(xcodebuild \
  -project NiuPod.xcodeproj \
  -scheme NiuPod \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build/DerivedData \
  OTHER_SWIFT_FLAGS="-disable-sandbox" \
  build 2>&1)
echo "$BUILD_OUTPUT" | grep -E "error:|BUILD" | sort -u
echo "$BUILD_OUTPUT" | grep -q "BUILD SUCCEEDED" || { echo "!! 构建失败，中止冒烟"; exit 1; }

APP=$(find build/DerivedData/Build/Products -maxdepth 2 -name "NiuPod.app" -type d | head -1)
if [[ -z "$APP" ]]; then
  echo "!! 找不到构建产物"; exit 1
fi
echo "==> 产物：$APP"

echo "==> 安装"
xcrun simctl install "$UDID" "$APP" || { echo "!! 安装失败"; exit 1; }

echo "==> 启动"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" > /tmp/niupod-smoke.log 2>&1 &
LAUNCH_PID=$!
sleep 6
kill $LAUNCH_PID 2>/dev/null
wait $LAUNCH_PID 2>/dev/null

echo "==> 日志（最后 40 行）"
tail -n 40 /tmp/niupod-smoke.log

if grep -qiE "crash|fatal error|Fatal Exception|SIGABRT|EXC_BAD" /tmp/niupod-smoke.log; then
  echo "!! 检测到崩溃迹象"
  exit 1
fi
echo "==> 冒烟完成，未发现崩溃"
