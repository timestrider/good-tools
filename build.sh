#!/bin/bash
# build.sh —— 把 src/*.swift 编成 ~/Applications/Good-tools.app
#
#   ./build.sh              编默认位置，装完顺手拉起来
#   NO_OPEN=1 ./build.sh    只编不启动
#   APP=/path/to/X.app ./build.sh
#
# 只用系统自带的 swiftc，不装任何依赖。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${APP:-$HOME/Applications/Good-tools.app}"
BIN="$APP/Contents/MacOS/GoodTools"
BUNDLE_ID="local.vincent.goodtools"

SWIFTC="$(/usr/bin/xcrun --find swiftc 2>/dev/null || echo /usr/bin/swiftc)"
[ -x "$SWIFTC" ] || { echo "✗ 找不到 swiftc（需要命令行工具或 Xcode）" >&2; exit 1; }

# 必须显式给 -sdk：直接调用工具链里的 swiftc 时驱动推不出 SDK 路径，
# 会报一条极具误导性的 "unable to load standard library"。
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] && [ -d "$SDK" ] || { echo "✗ 找不到 macOS SDK" >&2; exit 1; }

# 老版本两个独立 app 也会抢同一批热键，编之前一并收掉
for name in GoodTools MemPressure; do
  if /usr/bin/pgrep -x "$name" >/dev/null 2>&1; then
    echo "· 先退出正在运行的 $name"
    /usr/bin/pkill -x "$name" || true
    for _ in 1 2 3 4; do
      /usr/bin/pgrep -x "$name" >/dev/null 2>&1 || break
      sleep 0.4
    done
    /usr/bin/pgrep -x "$name" >/dev/null 2>&1 && /usr/bin/pkill -9 -x "$name" || true
  fi
done

echo "· 编译 → $APP"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# -swift-version 5：避开 Swift 6 的严格并发检查（AppKit + Timer 闭包会报一堆）
# -parse-as-library：@main 入口的必需项（否则报 "module contains top-level code"）
TMP_BIN="$(/usr/bin/mktemp -t goodtools).bin"
"$SWIFTC" -O -swift-version 5 -parse-as-library \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -o "$TMP_BIN" \
  "$ROOT/src/"*.swift \
  -framework Cocoa -framework WebKit -framework ScreenCaptureKit \
  -framework Carbon -framework ServiceManagement -framework UserNotifications

/bin/mv -f "$TMP_BIN" "$BIN"
/bin/cp -f "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && \
  /bin/cp -f "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc 签名，但钉死 designated requirement（只认 bundle id，不含 cdhash）。
# 默认 ad-hoc 会把 cdhash 写进 DR，于是每改一次代码重编就换一次指纹，系统里
# 「屏幕录制」那个开关看着还开着，TCC 却认为不是同一个 app 而静默拒绝。
DESIGNATED_REQ="designated => identifier \"$BUNDLE_ID\""
/usr/bin/codesign --force --sign - --timestamp=none \
  --identifier "$BUNDLE_ID" -r="$DESIGNATED_REQ" "$APP" >/dev/null 2>&1 || \
  echo "  （ad-hoc 签名失败，一般不影响本地运行）"

echo "· 自检：$("$BIN" --dump | head -1)"
echo "✓ 完成：$APP"

if [ -z "${NO_OPEN:-}" ]; then
  /usr/bin/open "$APP"
  sleep 1
  RUNNING=$(/usr/bin/pgrep -x GoodTools | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  if [ "$RUNNING" = "1" ]; then
    echo "  已启动（运行中实例数 1 ✓）"
  else
    echo "  ⚠ 运行中实例数 = $RUNNING（应为 1）"
  fi
fi
