import AppKit
import HorizonCore

/// `Horizon --diagnose`：把运行环境和程序坞的读取结果写到日志目录，不常驻。
/// 要通过「open Horizon.app --args --diagnose」启动，权限才算在 Horizon 自己头上。
enum Diagnose {
    static let url = Log.directory.appendingPathComponent("diagnose.txt")

    static func run() {
        Log.prepare()
        var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
        func brief(_ rect: CGRect) -> String {
            rect.isNull ? "读不到" : "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
        }

        add("Horizon 诊断 \(Date())")
        add("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        add("辅助功能权限: \(Accessibility.isTrusted ? "已授权" : "未授权")")
        add("屏幕录制权限: \(Thumbnailer.isAuthorized ? "已授权" : "未授权")")
        add("私有接口: " + PrivateAPI.availability.map { "\($0.0)=\($0.1 ? "可用" : "缺失")" }.joined(separator: " "))
        for screen in NSScreen.screens {
            add("屏幕 \(screen.localizedName): 全部\(brief(screen.frame)) 可用\(brief(screen.visibleFrame))")
        }

        if Accessibility.isTrusted {
            let dock = DockInspector()
            dock.refresh()
            add("程序坞图标区域: \(brief(dock.frame))")
            let items = dock.allItems()
            add("程序坞图标 \(items.count) 个")
            for item in items {
                var line = "  [\(item.subrole.replacingOccurrences(of: "AX", with: ""))] \(item.title) \(brief(item.frame))"
                guard let app = item.runningApp, let snapshot = WindowIndex.snapshot(of: app) else {
                    add(line)
                    continue
                }
                line += " 运行中 最前=\(snapshot.isFrontmost) 隐藏=\(snapshot.isHidden) 窗口=\(snapshot.windows.count) 点击→\(dockClickAction(for: snapshot.state))"
                add(line)
                for window in snapshot.windows {
                    add("      · \(window.title.prefix(24)) 窗口号=\(window.id.map(String.init) ?? "无") 最小化=\(window.isMinimized) 主窗口=\(window.isMain)")
                }
            }
            if let probe = items.first(where: \.isApplication) {
                let fresh = DockInspector()
                fresh.refresh()
                let hit = fresh.item(at: CGPoint(x: probe.frame.midX, y: probe.frame.midY))
                add("按位置查图标自检（\(probe.title)）: " + (hit.map { $0.isSame(as: probe) ? "通过" : "返回了别的图标 \($0.title)" } ?? "没有返回图标"))
            }
            let interceptor = ClickInterceptor()
            add("点击拦截可创建: \(interceptor.start() ? "是" : "否")")
            interceptor.stop()
        } else {
            add("未授权辅助功能，跳过程序坞与窗口检查")
        }

        try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
