import AppKit
import HorizonCore

/// 跟踪鼠标在程序坞上的位置，决定旁边的浮窗何时出现、显示什么、何时消失。
final class HoverController {
    let dock = DockInspector()
    let tracker = MouseTracker()
    /// 鼠标拖动时通知点击拦截器（用来区分「点击」和「拖图标」）
    var onDrag: ((CGPoint) -> Void)?
    var isEnabled = true { didSet { if !isEnabled { hide() }; updateSuppression(force: true) } }
    var wantsThumbnails = false
    /// 是否让程序坞自带的名称标签不出现，改由 Horizon 来显示
    var replacesDockLabels = true { didSet { updateSuppression(force: true) } }

    private enum Shown {
        case windows(DockItem, NSRunningApplication, AppSnapshot)
        case label(DockItem)

        var item: DockItem {
            switch self {
            case .windows(let item, _, _), .label(let item): return item
            }
        }
    }

    private let panel = PreviewPanel()
    private var hovered: DockItem?
    private var shown: Shown?
    private var signature = ""
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var refreshTimer: Timer?
    private var captureGeneration = 0
    /// 最近截到的画面。窗口最小化或隐藏后截不到新的，就用它
    private var thumbnailCache: [CGWindowID: NSImage] = [:]
    /// 当前是否在吞程序坞范围内的鼠标移动（即程序坞自己的标签是否被屏蔽）
    private var suppressing = false
    private var dockAllowsSuppression = true
    private var preferencesCheckedAt: TimeInterval = -100

    private let showDelay: TimeInterval = 0.25
    private let hideDelay: TimeInterval = 0.25

    @discardableResult
    func start() -> Bool {
        dock.refresh()
        updateSuppression(force: true)
        log("dock frame \(dock.frame) label suppression \(suppressing)")
        tracker.onMove = { [weak self] in self?.mouseMoved(to: $0) }
        tracker.onDrag = { [weak self] in self?.onDrag?($0) }
        panel.content.onSelect = { [weak self] in self?.select($0) }
        panel.content.onClose = { [weak self] in self?.close($0) }
        return tracker.start()
    }

    func stop() {
        tracker.stop()
        hide()
    }

    // MARK: 屏蔽程序坞自带的标签

    /// 程序坞开了放大或自动隐藏时，它需要鼠标移动事件才能正常工作，这两种情况下不屏蔽。
    private func updateSuppression(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if force || now - preferencesCheckedAt > 5 {
            preferencesCheckedAt = now
            let domain = "com.apple.dock" as CFString
            CFPreferencesAppSynchronize(domain)
            func flag(_ key: String) -> Bool { (CFPreferencesCopyAppValue(key as CFString, domain) as? Bool) ?? false }
            dockAllowsSuppression = !flag("magnification") && !flag("autohide")
        }
        let zone = dock.zone
        suppressing = isEnabled && replacesDockLabels && dockAllowsSuppression && !zone.isNull
        tracker.setSuppressedZone(suppressing ? zone : .null)
    }

    // MARK: 鼠标

    private func mouseMoved(to point: CGPoint) {
        guard isEnabled else { return }
        let location = NSPoint(x: point.x, y: primaryScreenHeight - point.y)
        // 鼠标已经移进浮窗：保持显示
        if panel.isVisible, panel.frame.insetBy(dx: -4, dy: -4).contains(location) {
            cancelHide()
            return
        }
        // 自动隐藏的程序坞滑出来时位置会变，靠近屏幕边缘时查得勤一点
        dock.refresh(maxAge: isNearScreenEdge(location) ? 0.3 : 3)
        updateSuppression()

        let item = dock.item(at: point).flatMap { $0.isSeparator ? nil : $0 }
        if let item, item.isSame(as: hovered) {
            cancelHide()
            return
        }
        guard item != nil || hovered != nil else { return }
        hovered = item
        showTimer?.invalidate()
        guard let item else {
            scheduleHide()
            return
        }
        cancelHide()
        present(item)
    }

    private func isNearScreenEdge(_ location: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return false }
        return !screen.frame.insetBy(dx: 90, dy: 90).contains(location)
    }

    /// 鼠标刚移到一个图标上：有窗口的 App 稍等一下再弹窗口列表，其余的立刻显示名称
    private func present(_ item: DockItem) {
        guard item.isApplication, let app = item.runningApp,
              let snapshot = WindowIndex.snapshot(of: app), !snapshot.windows.isEmpty else {
            showLabel(for: item)
            return
        }
        if panel.isVisible {
            showWindows(item, app: app, snapshot: snapshot)
        } else {
            showTimer = timer(showDelay) { [weak self] in
                guard let self, item.isSame(as: self.hovered) else { return }
                self.showWindows(item, app: app, snapshot: WindowIndex.snapshot(of: app) ?? snapshot)
            }
        }
    }

    // MARK: 显示与隐藏

    /// 点击多窗口 App 的图标时调用：立即显示，不等悬停延时
    func showPinned(for item: DockItem, app: NSRunningApplication) {
        showTimer?.invalidate()
        cancelHide()
        hovered = item
        if let snapshot = WindowIndex.snapshot(of: app), !snapshot.windows.isEmpty {
            showWindows(item, app: app, snapshot: snapshot)
        }
    }

    /// 一次点击被原样交给了程序坞（切换、还原之类）：收起浮窗，和 Windows 的习惯一致
    func dockClickPassedThrough() {
        showTimer?.invalidate()
        hide()
    }

    private func showWindows(_ item: DockItem, app: NSRunningApplication, snapshot: AppSnapshot) {
        guard isEnabled, !snapshot.windows.isEmpty else {
            showLabel(for: item)
            return
        }
        if case .windows(let current, _, _)? = shown, current.isSame(as: item) {} else {
            log("show windows of \(item.title): \(snapshot.windows.count) thumbnails=\(showsThumbnails)")
        }
        shown = .windows(item, app, snapshot)
        render()
        reveal()
        if refreshTimer == nil {
            let refresh = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(refresh, forMode: .common)
            refreshTimer = refresh
        }
        loadThumbnails()
    }

    /// 没有窗口可列的图标（没运行的 App、文件夹、废纸篓等）：显示名称。
    /// 只在程序坞自己的标签被屏蔽时才显示，否则会出现两个标签。
    private func showLabel(for item: DockItem) {
        guard isEnabled, suppressing, !item.title.isEmpty else {
            hide()
            return
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        captureGeneration += 1
        shown = .label(item)
        signature = ""
        position(size: panel.renderLabel(item.title), item: item, gap: 6)
        reveal()
    }

    private func reveal() {
        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        showTimer?.invalidate()
        hideTimer?.invalidate()
        refreshTimer?.invalidate()
        refreshTimer = nil
        shown = nil
        signature = ""
        captureGeneration += 1
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func scheduleHide() {
        guard panel.isVisible, hideTimer?.isValid != true else { return }
        // 名称标签不需要等鼠标移过去点，鼠标一离开就收
        let delay: TimeInterval
        if case .label? = shown { delay = 0.05 } else { delay = hideDelay }
        hideTimer = timer(delay) { [weak self] in self?.hide() }
    }

    private func cancelHide() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func timer(_ delay: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: 内容

    private var showsThumbnails: Bool { wantsThumbnails && Thumbnailer.isAuthorized }

    private func entries(for snapshot: AppSnapshot) -> [PreviewEntry] {
        snapshot.windows.map { window in
            let size = window.element.frame?.size
            return PreviewEntry(title: window.title,
                                isCurrent: snapshot.isFrontmost && !snapshot.isHidden && window.isMain && !window.isMinimized,
                                aspect: size.flatMap { $0.height > 1 ? $0.width / $0.height : nil },
                                thumbnail: window.id.flatMap { thumbnailCache[$0] })
        }
    }

    private func render() {
        guard case .windows(let item, let app, let snapshot)? = shown else { return }
        let list = entries(for: snapshot)
        signature = Self.signature(of: list)
        guard let layout = layout(for: item) else { return }
        let size = panel.render(entries: list, thumbnails: showsThumbnails, placeholder: app.icon, maxSize: layout.maxSize)
        position(size: size, item: item, gap: 8)
    }

    private static func signature(of entries: [PreviewEntry]) -> String {
        entries.map { "\($0.title)|\($0.isCurrent)" }.joined(separator: "\n")
    }

    /// 程序坞贴在哪条边、它占掉的范围，以及浮窗最大能有多大。全部是 AppKit 坐标。
    private func layout(for item: DockItem) -> (edge: DockEdge, itemFrame: CGRect, dockFrame: CGRect, visible: CGRect, maxSize: CGSize)? {
        let height = primaryScreenHeight
        let itemFrame = cocoaRect(fromTopLeft: item.frame, primaryHeight: height)
        var dockFrame = cocoaRect(fromTopLeft: dock.frame.isNull ? item.frame : dock.frame, primaryHeight: height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(itemFrame) }) ?? NSScreen.main else { return nil }
        let edge = dockEdge(dockFrame: dockFrame, screenFrame: screen.frame)
        // 程序坞的玻璃底板比图标区域略宽，以系统为它留出的那条边为准，浮窗才不会压在上面
        let visible = screen.visibleFrame
        let margin: CGFloat = 12
        var maxSize = CGSize(width: visible.width - margin * 2, height: visible.height - margin * 2)
        switch edge {
        case .left:
            dockFrame.size.width = max(dockFrame.maxX, visible.minX) - dockFrame.minX
            maxSize.width = visible.maxX - dockFrame.maxX - 8 - margin
        case .right:
            let left = min(dockFrame.minX, visible.maxX)
            dockFrame = CGRect(x: left, y: dockFrame.minY, width: dockFrame.maxX - left, height: dockFrame.height)
            maxSize.width = dockFrame.minX - 8 - visible.minX - margin
        case .bottom:
            dockFrame.size.height = max(dockFrame.maxY, visible.minY) - dockFrame.minY
            maxSize.height = visible.maxY - dockFrame.maxY - 8 - margin
        }
        return (edge, itemFrame, dockFrame, visible, maxSize)
    }

    private func position(size: NSSize, item: DockItem, gap: CGFloat) {
        guard let layout = layout(for: item) else { return }
        let origin = panelOrigin(panelSize: size, itemFrame: layout.itemFrame, dockFrame: layout.dockFrame,
                                 edge: layout.edge, visibleFrame: layout.visible, gap: gap)
        panel.setFrameOrigin(origin)
    }

    /// 窗口列表开着的时候每秒看一眼：窗口开了、关了、改了标题就跟着更新
    private func refresh() {
        guard case .windows(let item, let app, _)? = shown else { return }
        guard let snapshot = WindowIndex.snapshot(of: app), !snapshot.windows.isEmpty else {
            showLabel(for: item)
            return
        }
        shown = .windows(item, app, snapshot)
        if Self.signature(of: entries(for: snapshot)) != signature {
            render()
            loadThumbnails()
        }
    }

    private func loadThumbnails() {
        guard showsThumbnails, case .windows(_, _, let snapshot)? = shown else { return }
        let ids = snapshot.windows.compactMap(\.id)
        guard !ids.isEmpty else { return }
        captureGeneration += 1
        let generation = captureGeneration
        Task { @MainActor [weak self] in
            let images = await Thumbnailer.capture(windowIDs: ids)
            guard let self, generation == self.captureGeneration, !images.isEmpty else { return }
            if self.thumbnailCache.count > 80 { self.thumbnailCache.removeAll() }
            self.thumbnailCache.merge(images) { _, new in new }
            self.render()
        }
    }

    // MARK: 操作

    private func select(_ index: Int) {
        guard case .windows(_, let app, let snapshot)? = shown, snapshot.windows.indices.contains(index) else { return }
        let window = snapshot.windows[index]
        hide()
        WindowIndex.focus(window, of: app)
    }

    private func close(_ index: Int) {
        guard case .windows(_, let app, let snapshot)? = shown, snapshot.windows.indices.contains(index) else { return }
        let window = snapshot.windows[index]
        log("close window \(window.id.map(String.init) ?? "-") of \(app.localizedName ?? "?")")
        WindowIndex.close(window)
        _ = timer(0.3) { [weak self] in self?.refresh() }
    }
}
