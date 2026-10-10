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

/// `Horizon --selftest`：在 Horizon 正常运行时，模拟一次「鼠标停到程序坞图标上」，检查整条链路。
/// 会把鼠标移到程序坞上约 1 秒再移回原处，不点击任何东西。结果写到日志目录的 selftest.txt。
enum SelfTest {
    static let url = Log.directory.appendingPathComponent("selftest.txt")

    static func run() {
        var lines: [String] = ["Horizon 自检 \(Date())"]
        defer { try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8) }
        guard Accessibility.isTrusted else { lines.append("未授权辅助功能"); return }

        let dock = DockInspector()
        dock.refresh()
        let items = dock.allItems().filter(\.isApplication)
        guard let target = items.first(where: { item in
            guard let app = item.runningApp, let snapshot = WindowIndex.snapshot(of: app) else { return false }
            return !snapshot.windows.isEmpty
        }), let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            lines.append("程序坞里没有带窗口的 App，无法自检")
            return
        }
        let list = AXUIElementCreateApplication(dockApp.processIdentifier).elements(kAXChildrenAttribute).first { $0.string(kAXRoleAttribute) == kAXListRole }
        func dockSelection() -> [String] { (list?.elements(kAXSelectedChildrenAttribute) ?? []).map { $0.string(kAXTitleAttribute) ?? "?" } }
        func move(_ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func logSize() -> UInt64 { ((try? FileManager.default.attributesOfItem(atPath: Log.url.path))?[.size] as? UInt64) ?? 0 }

        let origin = CGEvent(source: nil)?.location ?? .zero
        let horizontal = dock.frame.width >= dock.frame.height
        let outside = horizontal ? CGPoint(x: target.frame.midX, y: dock.frame.minY - 240)
                                 : CGPoint(x: dock.frame.midX < 400 ? dock.frame.maxX + 240 : dock.frame.minX - 240, y: target.frame.midY)
        let before = logSize()
        move(outside); spin(0.3)
        move(CGPoint(x: target.frame.midX, y: target.frame.midY)); spin(0.1)
        move(CGPoint(x: target.frame.midX + 2, y: target.frame.midY + 1)); spin(1.0)

        let selection = dockSelection()
        var appended = ""
        if let handle = try? FileHandle(forReadingFrom: Log.url) {
            try? handle.seek(toOffset: before)
            appended = String(data: handle.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? handle.close()
        }
        lines.append("程序坞自带的名称标签: " + (selection.isEmpty ? "没有出现（已屏蔽）" : "出现了（\(selection.joined(separator: ","))）"))
        lines.append("Horizon 的窗口列表: " + (appended.contains("show windows of \(target.title)") ? "已弹出" : "没有弹出"))

        move(outside); spin(0.4)
        move(origin); spin(0.1)
        lines.append("鼠标已移回原处")
    }
}
