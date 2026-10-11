# Macindows

给 macOS 程序坞补上两件事，程序坞本身不被修改：

- **悬停**在程序坞里某个 App 的图标上，弹出它的全部窗口（开着的、隐藏的、最小化的），点哪个切到哪个。窗口按打开的先后排成一排，多了整体缩小，再多就改成标题列表。App 在运行但一个窗口都没开时，弹一个同样大小的占位卡片，点它开一个窗口。
- **点击**图标的规则与 Windows 合并任务栏一致：App 只有一个窗口时，点一下切过去，已经是当前窗口就最小化，最小化了再点就放回来；有多个窗口时只弹出窗口列表。

## 构建与安装

需要 macOS 26 或更新版本，以及 Xcode 命令行工具。

```bash
./Scripts/install.sh
```

这条命令会编译、打包、签名，把 `Macindows.app` 放进「应用程序」目录并启动它。只想打包不安装的话用 `./Scripts/build-app.sh`，产物在 `build/Macindows.app`。

首次运行要在「系统设置 → 隐私与安全性 → 辅助功能」里打开 Macindows。菜单栏会出现一个四格窗图标，可以在那里暂停、开启窗口缩略图（需要「屏幕录制」权限）、设置登录时自动启动或退出。

应用图标由 `swift Scripts/make-icon.swift Resources` 生成，菜单栏图标在代码里绘制（`Sources/Macindows/MenuBarIcon.swift`）。

## 分发给别人

```bash
./Scripts/release.sh
```

产物是 `dist/Macindows.zip`：同时支持苹果芯片和 Intel，用 Developer ID 证书签名并经过苹果公证，对方解压后双击就能打开。需要钥匙串里有 Developer ID Application 证书，并且事先保存过一次公证凭据（之后不用再输）：

```bash
xcrun notarytool store-credentials "macindows-notary" --apple-id "<苹果账号邮箱>" --team-id <团队编号>
```

没保存凭据时脚本只签名不公证。本机安装的版本仍然用 `install.sh`，两者签名不同，混用会让系统要求重新授权辅助功能。

## 排查

```bash
swift test                                         # 点击规则和坐标换算的单元测试
open -n /Applications/Macindows.app --args --diagnose        # 结果写到 ~/Library/Logs/Macindows/diagnose.txt
open -n /Applications/Macindows.app --args --selftest        # Macindows 运行时模拟一次悬停（会短暂移动鼠标），结果写到 selftest.txt
build/Macindows.app/Contents/MacOS/Macindows --render-sample /tmp/macindows-sample   # 用假数据渲染悬停窗版面
```

运行日志在 `~/Library/Logs/Macindows/macindows.log`。

## 目录

- `Sources/MacindowsCore`：点击规则、坐标换算等纯逻辑
- `Sources/Macindows`：应用本体
- `preview/`：定稿前用来比较方案的网页原型
