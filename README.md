<div align="center">
  <img src="docs/images/icon.png" width="128" alt="Macindows 图标">
  <h1>Macindows</h1>
  <p><b>为程序坞添一分实用，不减一分优雅。</b><br>悬停看窗口，点击即切换。</p>
  <p>
    <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26 及以上">
    <img src="https://img.shields.io/badge/架构-Apple%20芯片%20%7C%20Intel-2b86f2" alt="Apple 芯片与 Intel">
    <img src="https://img.shields.io/badge/签名-Developer%20ID%20已公证-28c840" alt="Developer ID 签名并经过公证">
    <img src="https://img.shields.io/badge/联网-从不-555555" alt="从不联网">
    <img src="https://img.shields.io/badge/许可证-MIT-8a8a8a" alt="MIT 许可证">
  </p>
  <p><b>简体中文</b> · <a href="README.en.md">English</a></p>
  <p>
    <a href="https://github.com/nickxia1989-pixel/Macindows/releases/latest"><b>下载</b></a> ·
    <a href="#理念">理念</a> ·
    <a href="#功能">功能</a> ·
    <a href="#安装">安装</a> ·
    <a href="#权限与隐私">权限与隐私</a> ·
    <a href="#从源码构建">从源码构建</a>
  </p>
</div>

<p align="center">
  <img src="docs/images/hover.png" width="804" alt="鼠标悬停在程序坞图标上，弹出这个应用的全部窗口">
</p>

## 理念

程序坞很美，只是不够实用。Macindows 补上这一点，别的都不碰。

- **最小改动**：只加悬停预览和点击切换，不替换、不修改程序坞。
- **保持原貌**：程序坞的外观与操作一切照旧，退出即还原。
- **数据不出本机**：需要系统权限，但不联网，没有统计，没有账号。

## 功能

### 悬停：一眼看到所有窗口

把鼠标停在程序坞里任意一个应用的图标上：

- **列出这个应用的全部窗口**，包括开着的、被隐藏的、已经最小化的。点哪个，切到哪个。
- **窗口按打开的先后排成一排**，顺序不会因为切换而变化。窗口多了整体缩小，再多就改成标题列表。
- **缩略图可选**。不想授予屏幕录制权限的话，悬停窗只显示窗口标题，其他功能不受影响。
- **应用在运行但没有窗口时**，显示一张同样大小的卡片，里面是一扇带应用图标的空白窗口，点一下就打开新窗口。
- **可以直接关闭窗口**：悬停窗里每个窗口都有关闭按钮，也可以用鼠标中键点击。
- **不容易误触**：从图标移向悬停窗的途中划过别的图标，不会让悬停窗切走。

### 点击：与 Windows 合并任务栏相同的规则

| 应用的状态 | 点一下图标 |
| --- | --- |
| 只有一个窗口，不在最前 | 切到这个窗口 |
| 只有一个窗口，已经在最前 | 最小化 |
| 只有一个窗口，已经最小化 | 放回来 |
| 有多个窗口 | 弹出窗口列表，点哪个切到哪个 |
| 没有运行，或没有窗口 | 交给程序坞，与系统原有行为一致 |

右键菜单等程序坞原有的操作仍然由程序坞自己处理，菜单弹出时悬停窗会自动让开。

### 菜单栏

菜单栏上的四格窗图标里可以：暂停或启用 Macindows、开关窗口缩略图、设置登录时自动启动、查看权限状态、打开日志所在位置、退出。

## 安装

1. 在 [Releases](https://github.com/nickxia1989-pixel/Macindows/releases/latest) 下载 `Macindows.dmg`。
2. 打开它，把 Macindows 拖进「应用程序」。
3. 启动 Macindows，按提示在「系统设置 › 隐私与安全性 › 辅助功能」中允许它。
4. 想看窗口缩略图的话，在菜单栏图标里打开「显示窗口缩略图」，再到「系统设置 › 隐私与安全性 › 录屏与系统录音」里允许 Macindows，然后重新打开它。

<p align="center">
  <img src="docs/images/install.png" width="560" alt="打开安装镜像后，把 Macindows 拖进「应用程序」">
</p>

安装包使用 Developer ID 签名并经过 Apple 公证，打开时不会被系统拦截。

**系统要求**：macOS 26 或更新版本，Apple 芯片或 Intel 处理器。

**界面语言**：简体中文、English，跟随系统语言。

## 权限与隐私

| 权限 | 是否必需 | 用来做什么 |
| --- | --- | --- |
| 辅助功能 | 必需 | 判断鼠标停在程序坞的哪个图标上；列出、切换、最小化、关闭窗口；识别对程序坞图标的点击 |
| 屏幕录制（系统设置里叫「录屏与系统录音」） | 可选 | 只用于生成悬停窗里的窗口缩略图 |

这些权限的能力范围很大，所以把 Macindows 实际做了什么说清楚：

- **不联网。** 代码里没有任何网络请求：没有统计，没有崩溃上报，没有自动更新检查，没有账号。
- **缩略图只存在于内存。** 画面用来显示在悬停窗里，不写入磁盘，不离开本机。
- **只在本机保存两样东西。** 一是两项设置（是否启用、是否显示缩略图）；二是一份排查问题用的日志，位于 `~/Library/Logs/Macindows/`，只记录应用名称和窗口数量，不含窗口标题和画面，超过约 512 KB 自动清理。
- **键盘输入不在监听范围内。** 只监听鼠标的移动和点击，并且只处理落在程序坞图标上的左键点击。
- **可以自行验证。** 全部源码都在这个仓库里，可以对照上面每一条逐项检查，也可以自己编译使用。

## 工作原理

- **读取程序坞**：通过系统的辅助功能接口获取程序坞里各个图标的位置和对应的应用，程序坞进程本身不被修改或注入，也不需要关闭系统完整性保护。
- **悬停窗**：Macindows 自己的一个浮动窗口，摆在图标上方。它和程序坞是两个独立的东西。
- **点击规则**：监听对程序坞图标的点击，按上面的表格决定是自己处理，还是原样交还给程序坞。

需要说明的一点：为了精确切换到指定窗口，以及给最小化的窗口生成缩略图，Macindows 用到了少量未公开的系统接口。每一处都有回退方案，但 macOS 大版本更新后可能需要适配，这也是它无法上架 Mac App Store 的原因。

## 已知限制

- 只支持 macOS 26 及以上，因为悬停窗使用了这一代系统的液态玻璃材质。
- 目前只在 macOS 27、Apple 芯片的机器上完整测试过。Intel 版本已包含在安装包里，但尚未实测。
- 程序坞放在屏幕侧边时可以使用，但悬停窗与名称气泡之间的距离是估算的。
- 位于其他桌面空间或处于全屏状态的窗口，表现尚未充分验证。

## 从源码构建

需要 macOS 26 或更新版本，以及 Xcode 命令行工具。

```bash
./Scripts/install.sh
```

这条命令会编译、打包、签名，把 `Macindows.app` 放进「应用程序」并启动它。只想打包不安装的话用 `./Scripts/build-app.sh`，产物在 `build/Macindows.app`。本机没有开发证书时会使用临时签名，可以正常运行，只是每次重新编译后需要重新授权辅助功能。

应用图标由 `swift Scripts/make-icon.swift Resources` 生成，菜单栏图标在代码里绘制（`Sources/Macindows/MenuBarIcon.swift`）。

界面文字在代码里以简体中文书写，英文译文在 `Resources/en.lproj/Localizable.strings`，新增文字时两边要一起改。

<details>
<summary><b>打包成可以分发的安装镜像</b></summary>

<br>

```bash
./Scripts/release.sh
```

产物是 `dist/Macindows.dmg`：同时支持 Apple 芯片和 Intel，用 Developer ID 证书签名并经过 Apple 公证。需要钥匙串里有你自己的 Developer ID Application 证书，并且事先保存过一次公证凭据：

```bash
xcrun notarytool store-credentials "macindows-notary" --apple-id "<Apple 账号邮箱>" --team-id <团队编号>
```

没保存凭据时脚本只签名不公证。证书和凭据都只存在于本机钥匙串，仓库里不包含任何签名材料。

镜像打开后的版面（窗口大小、图标位置、背景图）由 `Scripts/make-dmg.sh` 让访达写进镜像，所以打包途中访达会短暂弹出一个窗口，首次运行时系统会询问是否允许控制访达。背景图由 `swift Scripts/make-dmg-background.swift Resources` 生成，改版面时两个脚本里的坐标要一起改。

</details>

## 排查问题

```bash
swift test                                              # 点击规则和坐标换算的单元测试
open -n /Applications/Macindows.app --args --diagnose   # 结果写到 ~/Library/Logs/Macindows/diagnose.txt
open -n /Applications/Macindows.app --args --selftest   # 模拟一次悬停（会短暂移动鼠标），结果写到 selftest.txt
build/Macindows.app/Contents/MacOS/Macindows --render-sample /tmp/macindows-sample   # 用假数据渲染悬停窗版面
```

**权限开关已经打开，却不起作用？** 在系统设置对应的列表里选中 Macindows，点「−」删掉，再重新添加。这种情况出现在同一台 Mac 上先后装过自己编译的版本和发布版时：两者签名不同，系统把它们当成两个应用，旧的授权对不上新的。

运行日志在 `~/Library/Logs/Macindows/macindows.log`。`--diagnose` 的输出会包含当前窗口的标题，同样只保存在本机；提交问题时请先自行检查再决定是否附上。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `Sources/MacindowsCore` | 点击规则、坐标换算等纯逻辑，带单元测试 |
| `Sources/Macindows` | 应用本体 |
| `Scripts` | 构建、安装、打包脚本，以及图标和安装镜像背景的绘制脚本 |
| `Resources` | 应用图标、`Info.plist`、界面译文、安装镜像背景 |

## 许可证

Macindows 以 [MIT 许可证](LICENSE) 发布。

---

<p align="center"><sub>Macindows 是独立开发的第三方工具，与 Apple 和 Microsoft 均无关联。macOS、Windows 分别是其各自所有者的商标。</sub></p>
