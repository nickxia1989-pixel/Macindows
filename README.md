# Horizon

给 macOS 程序坞补上两件事，程序坞本身不被修改：

- **悬停**在程序坞里某个 App 的图标上，弹出它的全部窗口（开着的、隐藏的、最小化的），点哪个切到哪个。窗口按打开的先后排成一排，多了整体缩小，再多就改成标题列表。
- **点击**图标的规则与 Windows 合并任务栏一致：App 只有一个窗口时，点一下切过去，已经是当前窗口就收起；有多个窗口时只弹出窗口列表。

## 构建与运行

需要 macOS 26 或更新版本，以及 Xcode 命令行工具。

```bash
./Scripts/build-app.sh
open build/Horizon.app
```

首次运行要在「系统设置 → 隐私与安全性 → 辅助功能」里打开 Horizon。菜单栏会出现一个地平线图标，可以在那里暂停、开启窗口缩略图（需要「屏幕录制」权限）或退出。

## 排查

```bash
swift test                                         # 点击规则和坐标换算的单元测试
open -n build/Horizon.app --args --diagnose        # 结果写到 ~/Library/Logs/Horizon/diagnose.txt
open -n build/Horizon.app --args --selftest        # Horizon 运行时模拟一次悬停（会短暂移动鼠标），结果写到 selftest.txt
build/Horizon.app/Contents/MacOS/Horizon --render-sample /tmp/horizon-sample   # 用假数据渲染悬停窗版面
```

运行日志在 `~/Library/Logs/Horizon/horizon.log`。

## 目录

- `Sources/HorizonCore`：点击规则、坐标换算等纯逻辑
- `Sources/Horizon`：应用本体
- `preview/`：定稿前用来比较方案的网页原型
