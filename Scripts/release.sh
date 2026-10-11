#!/bin/bash
# 打一个可以发给别人的版本：同时支持苹果芯片和 Intel、用 Developer ID 签名、经过苹果公证。
# 产物是 dist/Macindows.zip，对方解压后双击就能打开。
#
# 公证需要事先保存过一次凭据（存在钥匙串里，之后不用再输）：
#   xcrun notarytool store-credentials "macindows-notary" --apple-id "<苹果账号邮箱>" --team-id <团队编号>
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-macindows-notary}"
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [ -z "$IDENTITY" ]; then
  echo "没找到 Developer ID Application 证书，无法打分发版本"
  exit 1
fi

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Macindows"

APP="dist/Macindows.app"
ZIP="dist/Macindows.zip"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Macindows"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 公证的两个硬性要求：加固运行时（--options runtime）和苹果时间戳服务器签发的时间戳（--timestamp）
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "已签名: $IDENTITY"
ditto -c -k --keepParent "$APP" "$ZIP"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "还没有保存公证凭据（$PROFILE）。$ZIP 已签名但未公证，对方打开时仍会被系统拦一次。"
  exit 0
fi

# 上传给苹果的公证服务并等结果，通常几分钟
RESULT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1)"
echo "$RESULT" | tail -6
if ! echo "$RESULT" | grep -q "status: Accepted"; then
  echo "公证没有通过。用上面的 id 运行 xcrun notarytool log <id> --keychain-profile $PROFILE 可以看原因"
  exit 1
fi

# 把公证结果钉到应用上，对方离线时也能验证；钉完要重新压缩
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl -a -vv "$APP" 2>&1 | head -2
echo "已公证，可以发送: $ZIP"
