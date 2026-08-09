#!/bin/zsh
# ============================================================
#  run_designed_for_ipad.sh
#  纯命令行构建并运行 Velum（Designed for iPad on macOS）
#
#  原理：macOS 不能直接 open 裸的 iOS app（报 incorrect
#  executable format），但识别 "iOS App on Mac" 的 wrapper
#  结构。本脚本复刻该结构并用 lsregister 注册后启动：
#
#    ~/Applications/Velum.app/
#    ├── WrappedBundle -> Wrapper/Velum.app   (符号链接)
#    └── Wrapper/
#        └── Velum.app                        (真正的 iOS app)
#
#  用法:
#    ./tools/run_designed_for_ipad.sh          # 增量构建 + 运行
#    ./tools/run_designed_for_ipad.sh --fast   # 跳过构建，直接装最新产物运行
# ============================================================

set -e

APP_NAME="Velum"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$PROJECT_DIR/build"
PRODUCT_DIR="$DERIVED/Build/Products/Debug-ApplePleaseFixFB19282108-iphoneos"
DEST="$HOME/Applications/$APP_NAME.app"
DEST_ID="00006050-001219DA26EB401C"  # 本机 Mac (Apple Silicon)

cd "$PROJECT_DIR"

# 1. 构建（可跳过）
if [[ "$1" != "--fast" ]]; then
    echo "🔨 构建 Designed for iPad..."
    xcodebuild -project Velum.xcodeproj -scheme Velum \
        -destination "id=$DEST_ID" \
        -derivedDataPath "$DERIVED" \
        build 2>&1 | grep -E "(BUILD|error:)" | tail -3
fi

SOURCE_APP="$PRODUCT_DIR/$APP_NAME.app"
if [[ ! -d "$SOURCE_APP" ]]; then
    echo "❌ 找不到构建产物: $SOURCE_APP"
    exit 1
fi

# 2. 关闭旧实例
pkill -x "$APP_NAME" 2>/dev/null || true

# 3. 组装 wrapper 结构（iOS App on Mac 格式）
echo "📦 组装 wrapper -> $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/Wrapper"
cp -R "$SOURCE_APP" "$DEST/Wrapper/$APP_NAME.app"
ln -s "Wrapper/$APP_NAME.app" "$DEST/WrappedBundle"

# 4. 注册到 Launch Services
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null || true

# 5. 启动
echo "🚀 启动 $APP_NAME (Designed for iPad)..."
open "$DEST"
sleep 3

if pgrep -x "$APP_NAME" > /dev/null; then
    echo "✅ $APP_NAME 已成功运行！"
else
    echo "⚠️ 进程未检测到，最近日志："
    log show --last 1m --predicate "eventMessage CONTAINS '$APP_NAME'" 2>/dev/null | tail -5
    exit 1
fi
