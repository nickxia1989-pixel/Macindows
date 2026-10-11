#!/bin/bash
# 把一个已经签好名的 Macindows.app 装进安装镜像：打开后左边是应用，右边是「应用程序」文件夹的快捷方式，拖过去就装好了。
# 用法：Scripts/make-dmg.sh <Macindows.app> <输出.dmg>
#
# 窗口大小、图标位置和背景图是访达记在镜像里的显示设置，只能让访达自己来写，
# 所以打包途中访达会短暂弹出一个窗口；首次运行时系统会询问是否允许控制访达。
# 这里的窗口尺寸和图标位置与 Scripts/make-dmg-background.swift 画的背景图是配套的。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$1"
OUT="$2"
VOLUME="Macindows"

if [ -d "/Volumes/$VOLUME" ]; then
  echo "已经挂载了一个叫 $VOLUME 的磁盘，先推出它再打包"
  exit 1
fi

WORK="$(mktemp -d)"
MOUNT="/Volumes/$VOLUME"
trap '[ -d "$MOUNT" ] && hdiutil detach -quiet "$MOUNT"; rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Macindows.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"

# 先做一个可写的镜像，挂载后让访达摆好版面，再压成只读的成品
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$WORK/rw.dmg"

# 窗口内容区 660x400，上面再加 32 的标题栏
osascript <<EOF
tell application "Finder"
  tell disk "$VOLUME"
    open
    tell container window
      set current view to icon view
      set toolbar visible to false
      set statusbar visible to false
      set the bounds to {200, 120, 860, 552}
    end tell
    set options to the icon view options of container window
    tell options
      set arrangement to not arranged
      set icon size to 128
      set text size to 13
    end tell
    set background picture of options to file ".background:background.tiff"
    set position of item "Macindows.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    update without registering applications
    -- 关掉再开一次并动一下窗口大小，访达才会把这些设置写进镜像
    close
    open
    delay 1
    tell container window
      set the bounds to {200, 120, 850, 542}
      set the bounds to {200, 120, 860, 552}
    end tell
    delay 2
    close
  end tell
end tell
EOF

# 让挂载出来的磁盘也用应用的图标。必须放在访达摆完版面之后：上面那句 update 会把自定义的磁盘图标清掉
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -c icnC "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"

sync
rm -rf "$MOUNT/.fseventsd"
hdiutil detach -quiet "$MOUNT"
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
echo "已生成: $OUT"
