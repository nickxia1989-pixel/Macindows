#!/bin/bash
# 编译并打包成 build/Macindows.app。
# 用固定的开发者证书签名：系统按签名身份记住「辅助功能」授权，换成临时签名的话每次重编都要重新授权。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/Macindows.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Macindows"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Macindows"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 本机自用一律用开发证书（Apple Development）。发给别人的版本由 Scripts/release.sh 另外用 Developer ID 签名。
# 两种签名在系统看来是两个不同的应用，混着装会让辅助功能等授权反复失效，所以这里不自动挑 Developer ID。
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
  # --options runtime：开启「加固运行时」。公证要求它，本机版本也一并开启，这样自用和分发的行为一致
  codesign --force --options runtime --sign "$IDENTITY" --timestamp=none "$APP"
  echo "已签名: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "没找到开发证书，使用临时签名（每次重编后需要重新授权辅助功能）"
fi
echo "$APP"
