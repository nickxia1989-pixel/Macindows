import AppKit
import HorizonCore
import ServiceManagement

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
        add("登录时自动启动: \(SMAppService.mainApp.status == .enabled ? "已开启" : "未开启")")
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
/// 会把鼠标在程序坞附近移动约 17 秒再移回原处。期间会在一个图标上点一次右键并用 Esc 关掉菜单，不做其他点击。结果写到日志目录的 selftest.txt。
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

        // 先确认模拟的鼠标移动真的生效了。重新编译后第一次运行时，系统可能要过几秒才放行本程序发出的输入事件，
        // 这期间发出去的移动会被悄悄丢掉；不先确认的话，后面每一项都会被误判成功能失效
        var canMove = false
        for _ in 0..<12 {
            move(outside); spin(0.25)
            if let now = CGEvent(source: nil)?.location, hypot(now.x - outside.x, now.y - outside.y) < 3 { canMove = true; break }
            spin(0.5)
        }
        guard canMove else {
            lines.append("模拟的鼠标移动没有生效（系统没有放行本程序发出的输入事件），这次无法自检")
            return
        }

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

        // 从图标斜着移向悬停窗的远端一角，途中会扫过相邻的图标：列表应该一直是原来那个
        if horizontal, let neighbor = items.first(where: { abs($0.frame.midX - target.frame.midX) > 40 && abs($0.frame.midX - target.frame.midX) < 140 }) {
            hover(target); spin(0.5)
            if let before = panelFrame() {
                let start = CGPoint(x: target.frame.midX, y: target.frame.midY)
                // 终点：悬停窗在邻居那一侧、靠近程序坞的那个角的外侧，这条路线会从邻居图标上方掠过
                let direction: CGFloat = neighbor.frame.midX > target.frame.midX ? 1 : -1
                let end = CGPoint(x: neighbor.frame.midX + direction * 30, y: dock.frame.minY - gap * 0.4)
                var crossed = false
                for step in 1...14 {
                    let t = CGFloat(step) / 14
                    let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    if neighbor.frame.contains(p) { crossed = true }
                    move(p); spin(0.012)
                }
                spin(0.15)
                let after = panelFrame()
                lines.append("斜着移向悬停窗、途中扫过相邻图标（\(crossed ? "确实扫到了" : "这次路线没扫到")）: " + (after.map { abs($0.midX - before.midX) < 2 ? "列表没有被换掉" : "列表被换成了别的" } ?? "列表被关掉了"))
                // 更难的走法：先贴着程序坞快速横扫过两三个图标，再往上进悬停窗
                hover(target); spin(0.5)
                if let wide = panelFrame() {
                    let reach = min(200, max(70, (direction > 0 ? wide.maxX - start.x : start.x - wide.minX) - 20))
                    let corner = CGPoint(x: start.x + direction * reach, y: target.frame.midY - 4)
                    for step in 1...12 {
                        let t = CGFloat(step) / 12
                        move(CGPoint(x: start.x + (corner.x - start.x) * t, y: start.y + (corner.y - start.y) * t)); spin(0.016)
                    }
                    let top = CGPoint(x: corner.x, y: wide.maxY - 12)
                    for step in 1...10 {
                        let t = CGFloat(step) / 10
                        move(CGPoint(x: corner.x, y: corner.y + (top.y - corner.y) * t)); spin(0.016)
                    }
                    spin(0.25)
                    let kept = panelFrame()
                    lines.append("先横着快扫 \(Int(reach)) 点再往上进悬停窗: " + (kept.map { abs($0.midX - wide.midX) < 2 ? "列表没有被换掉" : "列表被换成了别的" } ?? "列表被关掉了"))
                }
                // 想看隔壁的 App：像真人那样先快后慢地移到相邻图标上停住，量一下从停稳到换好用了多久
                hover(target); spin(0.5)
                let destination = CGPoint(x: neighbor.frame.midX, y: neighbor.frame.midY)
                for step in 1...10 {
                    let t = CGFloat(step) / 10, eased = 1 - (1 - t) * (1 - t)
                    move(CGPoint(x: start.x + (destination.x - start.x) * eased, y: start.y + (destination.y - start.y) * eased)); spin(0.016)
                }
                let arrived = Date()
                var latency: TimeInterval?
                while Date().timeIntervalSince(arrived) < 1.2 {
                    if let now = panelFrame(), abs(now.midX - before.midX) > 2 { latency = Date().timeIntervalSince(arrived); break }
                    if panelFrame() == nil { latency = Date().timeIntervalSince(arrived); break }
                    spin(0.01)
                }
                lines.append("移到相邻图标上停住: " + (latency.map { "停稳后 \(Int(($0 * 1000).rounded())) 毫秒换好" } ?? "1.2 秒内没有换过去"))
            }
        }

        // 列表开着时移到「在运行但没有窗口」的 App 上：换成一个占位卡片
        if let idle {
            hover(target); spin(0.4)
            let list = panelFrame()
            hover(idle); spin(0.2)
            move(CGPoint(x: idle.frame.midX - 2, y: idle.frame.midY)); spin(0.7)
            if let card = panelFrame() {
                let anchored = abs(card.midX - idle.frame.midX) < 80 || abs(card.midY - idle.frame.midY) < 80
                lines.append("移到在运行但没有窗口的 App 上: " + (anchored && card.midX != list?.midX ? "换成了占位卡片（\(Int(card.width))x\(Int(card.height))，单窗口列表的大小）" : "卡片没有跟到这个图标上"))
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

        // 悬停窗开着时在图标上点右键：悬停窗要让位给程序坞自己的菜单；菜单关掉后鼠标还在图标上，也不该马上再弹
        hover(target); spin(0.6)
        if panelFrame() != nil {
            let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
            CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: center, mouseButton: .right)?.post(tap: .cghidEventTap); spin(0.05)
            CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: center, mouseButton: .right)?.post(tap: .cghidEventTap); spin(0.5)
            let duringMenu = panelFrame() == nil
            move(CGPoint(x: center.x + 3, y: center.y)); spin(0.5)
            let stillHidden = panelFrame() == nil
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
            spin(0.5)
            move(CGPoint(x: center.x - 3, y: center.y)); spin(0.6)
            let afterMenu = panelFrame() == nil
            lines.append("在图标上点右键: " + (duringMenu && stillHidden ? "悬停窗已让位" : "悬停窗还在") + "；菜单关掉后鼠标仍在图标上: " + (afterMenu ? "没有再弹" : "又弹出来了"))
            move(outside); spin(0.5)
            hover(target); spin(0.8)
            lines.append("移开再回来: " + (panelFrame() != nil ? "悬停窗正常弹出" : "悬停窗没有弹出"))
        }

        move(outside); spin(0.4)
        lines.append("鼠标移开后: " + (panelFrame() == nil ? "列表已关闭" : "列表还开着"))
        move(origin); spin(0.1)
    }
}
