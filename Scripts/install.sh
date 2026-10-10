#!/bin/bash
# 编译、打包，安装到「应用程序」目录并重新启动。
# 应用标识和签名证书不变，所以更新后不需要重新授权辅助功能和屏幕录制。
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build-app.sh
DEST="/Applications/Macindows.app"

pkill -x Macindows 2>/dev/null || true
sleep 0.6
rm -rf "$DEST"
ditto build/Macindows.app "$DEST"
open "$DEST"
echo "已安装并启动: $DEST"
