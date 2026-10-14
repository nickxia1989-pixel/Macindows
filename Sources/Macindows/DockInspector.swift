import AppKit
import ApplicationServices
import MacindowsCore
import os

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

/// 只读地观察程序坞：它在哪、鼠标停在哪个图标上。不修改程序坞的任何东西。
///
/// 鼠标停在哪个图标上不靠自己算，而是直接听程序坞说：鼠标移到一个图标上时，程序坞会在辅助功能里把它标成
/// 「选中」并发出通知。这样图标放大、程序坞自动隐藏再滑出来这些情况都不用另外处理，鼠标不在程序坞上时也没有任何开销。
final class DockInspector {
    /// 程序坞说鼠标停着的图标变了（也可能变成哪个都不是）。在主线程调用
    var onHoverChanged: ((DockItem?) -> Void)?

    /// 程序坞图标区域，左上角为原点的全局坐标；读不到时为 .null。只在主线程读写
    private(set) var frame: CGRect = .null

    private struct Shared {
        var list: AXUIElement?
        var zone = CGRect.null
        var isHorizontal = true
    }

    /// 点击监听在它自己的线程上，也要问「鼠标停在哪个图标上」「这次点击在不在程序坞范围里」，所以这两样加锁
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private var pid: pid_t = 0
    private var observer: AXObserver?
    private var healthTimer: Timer?
    private var followUps: [Timer] = []

    // MARK: 找到程序坞

    /// 找到程序坞进程和它的图标列表，读出图标区域。不订阅通知。返回是否找到
    @discardableResult
    func locate() -> Bool {
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        pid = dock?.processIdentifier ?? 0
        var list: AXUIElement?
        if pid != 0 {
            let application = AXUIElementCreateApplication(pid)
            list = application.elements(kAXChildrenAttribute).first { $0.string(kAXRoleAttribute) == kAXListRole }
        }
        shared.withLockUnchecked { $0.list = list }
        refreshFrame()
        return list != nil
    }

    private var list: AXUIElement? { shared.withLockUnchecked { $0.list } }

    private func refreshFrame() {
        // 偶尔一次读不到就沿用上次的，不因此当作程序坞不见了
        if let list {
            frame = list.frame ?? frame
        } else {
            frame = .null
        }
        let zone = computeZone(), horizontal = frame.isNull || frame.width >= frame.height
        shared.withLockUnchecked {
            $0.zone = zone
            $0.isHorizontal = horizontal
        }
    }

    /// 程序坞认鼠标的范围：图标区域略放宽，并在贴边的那一侧一直延伸到屏幕边缘。
    /// 实测程序坞正好从图标区域的边界开始认为鼠标「在图标上」，放宽几个点是为了留出余量。
    private func computeZone() -> CGRect {
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

    /// 这个位置（左上角为原点的全局坐标）在不在程序坞认鼠标的范围里。任何线程都可以调用
    func contains(_ point: CGPoint) -> Bool { shared.withLockUnchecked { $0.zone }.contains(point) }

    /// 这个位置是不是落在这个图标所占的那一段程序坞上（只看沿程序坞的方向：程序坞从图标一直到屏幕边缘都认）。
    /// 任何线程都可以调用
    func isPoint(_ point: CGPoint, over item: DockItem) -> Bool { isPoint(point, overSpan: item.frame) }

    private func isPoint(_ point: CGPoint, overSpan frame: CGRect) -> Bool {
        let (zone, horizontal) = shared.withLockUnchecked { ($0.zone, $0.isHorizontal) }
        guard zone.contains(point) else { return false }
        return horizontal ? (frame.minX - 2...frame.maxX + 2).contains(point.x)
                          : (frame.minY - 2...frame.maxY + 2).contains(point.y)
    }

    /// 鼠标（在 point 处）此刻是不是确实停在这个图标上。
    ///
    /// 「鼠标到了哪个图标上」程序坞说得又快又准，但「鼠标已经走了」它要慢半拍：实测鼠标离开图标、去了程序坞以外的地方之后，
    /// 它还要再过 0.3 秒左右（305～320 毫秒，和名称气泡消失的时间一致）才改口，其间不会再发通知。
    /// 所以在哪个图标上听程序坞的，还在不在那儿看鼠标的位置。
    func isMouse(at point: CGPoint, over item: DockItem) -> Bool {
        if isPoint(point, over: item) { return true }
        // 图标放大时它的位置会跟着鼠标变，和当初记下的对不上就再问一次它现在在哪
        guard contains(point), let fresh = item.element.frame, fresh != item.frame else { return false }
        return isPoint(point, overSpan: fresh)
    }

    // MARK: 听程序坞说鼠标停在哪

    func start() {
        subscribe()
        guard healthTimer == nil else { return }
        // 程序坞进程会被系统重启（例如改了它的设置），图标列表也可能整个重建，这时通知就断了；隔一会儿看一眼
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.checkHealth() }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        unsubscribe()
    }

    private func subscribe() {
        unsubscribe()
        guard locate(), let list else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            Unmanaged<DockInspector>.fromOpaque(context).takeUnretainedValue().selectionChanged()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let added = AXObserverAddNotification(created, list, kAXSelectedChildrenChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        guard added == .success || added == .notificationAlreadyRegistered else {
            log("dock hover notification refused: \(added.rawValue)")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        log("listening to dock \(pid), icons at \(frame)")
    }

    private func unsubscribe() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        followUps.forEach { $0.invalidate() }
        followUps = []
    }

    var isListening: Bool { observer != nil }

    private func checkHealth() {
        let current = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
        guard current == pid, observer != nil, let list, list.string(kAXRoleAttribute) != nil else {
            subscribe()
            return
        }
        // 列表还答话，但已经不是程序坞现在用的那个了
        let live = AXUIElementCreateApplication(pid).elements(kAXChildrenAttribute).first { $0.string(kAXRoleAttribute) == kAXListRole }
        if let live, !CFEqual(live, list) {
            subscribe()
        } else {
            // 屏幕布局、程序坞大小可能变了
            refreshFrame()
        }
    }

    private func selectionChanged() {
        report()
        // 鼠标离开图标时通知马上就到，但程序坞要再过 0.3 秒左右才改口（见 isMouse），而且改口时不再发通知。
        // 所以过了这段时间再读两次，把它后来的说法补上
        followUps.forEach { $0.invalidate() }
        followUps = [0.36, 0.7].map { delay in
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.report() }
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
    }

    /// 读一次程序坞说的「鼠标停着的图标」并通知出去（和上次一样也通知：通知本身就说明鼠标动过了）。
    /// 悬停窗开着的时候调用方也会定时调它，作为通知之外的兜底
    func report() {
        // 图标放大、程序坞滑出来时图标区域会变，跟着更新
        refreshFrame()
        onHoverChanged?(hoveredItem())
    }

    /// 程序坞此刻说鼠标停着的图标。直接去问程序坞，任何线程都可以调用
    func hoveredItem() -> DockItem? {
        guard let list else { return nil }
        return list.elements(kAXSelectedChildrenAttribute).first.flatMap(makeItem)
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
