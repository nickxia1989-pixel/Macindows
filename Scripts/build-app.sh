#!/bin/bash
# 编译并打包成 build/Horizon.app。
# 用固定的开发者证书签名：系统按签名身份记住「辅助功能」授权，换成临时签名的话每次重编都要重新授权。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/Horizon.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Horizon"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Horizon"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
  echo "已签名: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "没找到开发者证书，使用临时签名（每次重编后需要重新授权辅助功能）"
fi
echo "$APP"
