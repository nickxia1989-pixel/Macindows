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

/// `Horizon --selftest`：在 Horizon 正常运行时模拟几次鼠标移动，检查悬停相关的行为。
/// 会把鼠标在程序坞附近移动约 7 秒再移回原处，不点击任何东西。结果写到日志目录的 selftest.txt。
enum SelfTest {
    static let url = Log.directory.appendingPathComponent("selftest.txt")

    static func run() {
        var lines: [String] = ["Horizon 自检 \(Date())"]
        defer { try? lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8) }
        guard Accessibility.isTrusted else { lines.append("未授权辅助功能"); return }

        let dock = DockInspector()
        dock.refresh()
        let items = dock.allItems().filter(\.isApplication)
        func windowCount(_ item: DockItem) -> Int { item.runningApp.flatMap { WindowIndex.snapshot(of: $0) }?.windows.count ?? 0 }
        guard let target = items.first(where: { windowCount($0) > 0 }) else {
            lines.append("程序坞里没有带窗口的 App，无法自检")
            return
        }
        func far(_ item: DockItem) -> Bool { abs(item.frame.midX - target.frame.midX) + abs(item.frame.midY - target.frame.midY) > 100 }
        // 在运行但没有窗口的 App，以及根本没在运行的 App
        let idle = items.first { $0.runningApp != nil && windowCount($0) == 0 && far($0) }
        let stopped = items.first { $0.runningApp == nil && far($0) }

        func move(_ point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func hover(_ item: DockItem) {
            move(CGPoint(x: item.frame.midX, y: item.frame.midY)); spin(0.08)
            move(CGPoint(x: item.frame.midX + 2, y: item.frame.midY + 1))
        }
        /// 正在运行的那个 Horizon 的悬停窗在屏幕上的位置（左上角为原点）；没显示则为 nil
        func panelFrame() -> CGRect? {
            let me = ProcessInfo.processInfo.processIdentifier
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            for window in info where (window[kCGWindowOwnerName as String] as? String) == "Horizon" {
                guard (window[kCGWindowOwnerPID as String] as? Int32) != me, (window[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow)),
                      let bounds = window[kCGWindowBounds as String] as? [String: Any], let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
                return rect.insetBy(dx: PreviewPanel.margin, dy: PreviewPanel.margin)
            }
            return nil
        }

        let origin = CGEvent(source: nil)?.location ?? .zero
        let horizontal = dock.frame.width >= dock.frame.height
        let onLeft = dock.frame.midX < 400
        let outside = horizontal ? CGPoint(x: target.frame.midX, y: dock.frame.minY - 400)
                                 : CGPoint(x: onLeft ? dock.frame.maxX + 500 : dock.frame.minX - 500, y: target.frame.midY)

        move(outside); spin(0.3)
        hover(target); spin(0.9)
        guard let panel = panelFrame() else {
            lines.append("窗口列表: 没有弹出")
            move(origin); return
        }
        let gap = horizontal ? dock.frame.minY - panel.maxY : (onLeft ? panel.minX - dock.frame.maxX : dock.frame.minX - panel.maxX)
        lines.append("窗口列表: 已弹出，离程序坞 \(Int(gap.rounded())) 点（系统的名称气泡占其中约 30 点）")

        // 停在列表和程序坞之间的空隙里，超过关闭延时也不应该关
        let inGap = horizontal ? CGPoint(x: target.frame.midX, y: dock.frame.minY - gap / 2)
                               : CGPoint(x: onLeft ? dock.frame.maxX + gap / 2 : dock.frame.minX - gap / 2, y: target.frame.midY)
        move(inGap); spin(0.05); move(CGPoint(x: inGap.x + 1, y: inGap.y)); spin(0.8)
        lines.append("鼠标停在空隙里 0.8 秒: " + (panelFrame() != nil ? "列表保持显示" : "列表被关掉了"))
        move(CGPoint(x: panel.midX, y: panel.midY)); spin(0.05); move(CGPoint(x: panel.midX + 1, y: panel.midY)); spin(0.6)
        lines.append("鼠标移进列表: " + (panelFrame() != nil ? "列表保持显示" : "列表被关掉了"))

        // 列表开着时移到「在运行但没有窗口」的 App 上：换成一行的小卡片
        if let idle {
            hover(target); spin(0.4)
            let list = panelFrame()
            hover(idle); spin(0.2)
            move(CGPoint(x: idle.frame.midX - 2, y: idle.frame.midY)); spin(0.7)
            if let card = panelFrame() {
                let moved = abs(card.midX - (list?.midX ?? card.midX)) > 20 || card.height < (list?.height ?? 0)
                lines.append("移到在运行但没有窗口的 App 上: " + (card.height <= 44 && moved ? "换成了小卡片（\(Int(card.width))x\(Int(card.height))）" : "显示的不是小卡片（\(Int(card.width))x\(Int(card.height))）"))
            } else {
                lines.append("移到在运行但没有窗口的 App 上: 什么都没显示")
            }
        } else {
            lines.append("程序坞里没有「在运行但没有窗口」的 App，跳过这一项")
        }

        // 列表开着时移到没在运行的 App 上：旧列表应该自己关掉
        if let stopped {
            hover(target); spin(0.4)
            hover(stopped); spin(0.2)
            move(CGPoint(x: stopped.frame.midX - 2, y: stopped.frame.midY)); spin(0.7)
            lines.append("移到没在运行的 App 上: " + (panelFrame() == nil ? "旧列表已关闭" : "旧列表还开着"))
        } else {
            lines.append("程序坞里没有未运行的 App，跳过这一项")
        }

        move(outside); spin(0.4)
        lines.append("鼠标移开后: " + (panelFrame() == nil ? "列表已关闭" : "列表还开着"))
        move(origin); spin(0.1)
    }
}
