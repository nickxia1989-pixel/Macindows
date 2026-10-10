import AppKit
import ApplicationServices
import HorizonCore

/// 程序坞里的一个图标。frame 是左上角为原点的全局坐标。
struct DockItem {
    let element: AXUIElement
    let frame: CGRect
    let title: String
    let subrole: String
    let url: URL?

    var isApplication: Bool { subrole == "AXApplicationDockItem" }
    var isSeparator: Bool { subrole == "AXSeparatorDockItem" }

    func isSame(as other: DockItem?) -> Bool {
        guard let other else { return false }
        return CFEqual(element, other.element)
    }

    /// 这个图标对应的、正在运行的 App；没在运行则为 nil
    var runningApp: NSRunningApplication? {
        guard isApplication, let url else { return nil }
        let target = url.standardizedFileURL.path
        let apps = NSWorkspace.shared.runningApplications
        if let exact = apps.first(where: { $0.bundleURL?.standardizedFileURL.path == target }) { return exact }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        return apps.first { $0.bundleIdentifier == bundleID }
    }
}

/// 只读地观察程序坞：它在哪、鼠标底下是哪个图标。不修改程序坞的任何东西。
final class DockInspector {
    private var application: AXUIElement?
    private var list: AXUIElement?
    private var pid: pid_t = 0
    private var refreshedAt: TimeInterval = 0
    private var cachedItem: DockItem?

    /// 程序坞图标区域，左上角为原点的全局坐标；读不到时为 .null
    private(set) var frame: CGRect = .null

    func refresh(maxAge: TimeInterval = 0) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - refreshedAt >= maxAge else { return }
        refreshedAt = now

        // 程序坞进程会被系统重启（例如改了它的设置），进程号变了就重新找一遍
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        if dock?.processIdentifier != pid || application == nil {
            pid = dock?.processIdentifier ?? 0
            application = pid != 0 ? AXUIElementCreateApplication(pid) : nil
            list = nil
            cachedItem = nil
            if let application { AXUIElementSetMessagingTimeout(application, 0.25) }
        }
        guard let application else { frame = .null; return }
        if list == nil {
            list = application.elements(kAXChildrenAttribute).first { $0.string(kAXRoleAttribute) == kAXListRole }
        }
        if let newFrame = list?.frame {
            if newFrame != frame { cachedItem = nil }
            frame = newFrame
        } else {
            list = nil
            frame = .null
        }
    }

    /// 程序坞认鼠标的范围：图标区域略放宽，并在贴边的那一侧一直延伸到屏幕边缘。
    /// 实测程序坞正好从图标区域的边界开始认为鼠标「在图标上」，放宽几个点是为了留出余量。
    var zone: CGRect {
        guard !frame.isNull else { return .null }
        var zone = frame.insetBy(dx: -4, dy: -4)
        let height = primaryScreenHeight
        let screens = NSScreen.screens.map { CGRect(x: $0.frame.minX, y: height - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
        guard let screen = screens.first(where: { $0.intersects(frame) }) else { return zone }
        switch dockEdge(dockFrame: frame, screenFrame: screen) {
        case .bottom: zone.size.height = screen.maxY - zone.minY
        case .left: zone = CGRect(x: screen.minX, y: zone.minY, width: zone.maxX - screen.minX, height: zone.height)
        case .right: zone.size.width = screen.maxX - zone.minX
        }
        return zone
    }

    func contains(_ point: CGPoint) -> Bool { zone.contains(point) }

    /// 指定位置上的程序坞图标。鼠标停在同一个图标上时不会重复查询。
    func item(at point: CGPoint) -> DockItem? {
        guard contains(point), let application else { cachedItem = nil; return nil }
        // 放宽出来的那一圈和贴屏幕边的那一条不在任何图标的范围里，先把点收回图标区域再查
        let point = CGPoint(x: min(max(point.x, frame.minX + 1), frame.maxX - 1), y: min(max(point.y, frame.minY + 1), frame.maxY - 1))
        if let cachedItem, cachedItem.frame.insetBy(dx: 0, dy: -6).contains(point) { return cachedItem }

        var hit: AXUIElement?
        var item: DockItem?
        if AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success, let hit {
            item = makeItem(hit)
        }
        // 个别情况下按位置查询只返回整个列表，这时退回逐个比对图标的位置
        if item == nil {
            item = allItems().first { $0.frame.contains(point) }
        }
        // 图标的纵向范围和图标区域不完全重合，这里再用横向（或纵向）位置兜底一次
        if item == nil {
            let horizontal = frame.width >= frame.height
            item = allItems().first { horizontal ? ($0.frame.minX...$0.frame.maxX).contains(point.x) : ($0.frame.minY...$0.frame.maxY).contains(point.y) }
        }
        cachedItem = item
        return item
    }

    func allItems() -> [DockItem] {
        (list?.elements(kAXChildrenAttribute) ?? []).compactMap(makeItem)
    }

    private func makeItem(_ element: AXUIElement) -> DockItem? {
        guard element.string(kAXRoleAttribute) == "AXDockItem", let frame = element.frame else { return nil }
        return DockItem(element: element, frame: frame,
                        title: element.string(kAXTitleAttribute) ?? "",
                        subrole: element.string(kAXSubroleAttribute) ?? "",
                        url: element.url(kAXURLAttribute))
    }
}
