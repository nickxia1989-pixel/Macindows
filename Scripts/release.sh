#!/bin/bash
# 打一个可以发给别人的版本：同时支持苹果芯片和 Intel、用 Developer ID 签名、经过苹果公证。
# 产物是 dist/Macindows.dmg，对方打开后把应用拖进「应用程序」就装好了。
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
DMG="dist/Macindows.dmg"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Macindows"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 各语言的界面文字
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# 公证的两个硬性要求：加固运行时（--options runtime）和苹果时间戳服务器签发的时间戳（--timestamp）
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "已签名: $IDENTITY"

# 把应用装进安装镜像，镜像本身也要签名
make_dmg() {
  ./Scripts/make-dmg.sh "$APP" "$DMG"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
}

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  make_dmg
  echo "还没有保存公证凭据（$PROFILE）。$DMG 已签名但未公证，对方打开时仍会被系统拦一次。"
  exit 0
fi

# 上传给苹果的公证服务并等结果，通常几分钟
notarize() {
  local result
  result="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1)"
  echo "$result" | tail -3
  if ! echo "$result" | grep -q "status: Accepted"; then
    echo "公证没有通过。用上面的 id 运行 xcrun notarytool log <id> --keychain-profile $PROFILE 可以看原因"
    exit 1
  fi
}

# 公证要做两轮。第一轮是应用本身：把公证结果钉到应用上，对方拖进「应用程序」的那一份离线时也能验证
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"
rm "$ZIP"

# 第二轮是镜像：镜像里装的是已经钉好的应用，镜像自己也钉上
make_dmg
notarize "$DMG"
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | head -2
echo "已公证，可以发送: $DMG"
