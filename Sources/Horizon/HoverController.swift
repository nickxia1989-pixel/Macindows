import AppKit
import HorizonCore

/// 跟踪鼠标在程序坞上的位置，决定悬停窗何时出现、显示什么、何时消失。
final class HoverController {
    let dock = DockInspector()
    /// 鼠标拖动时通知点击拦截器（用来区分「点击」和「拖图标」）
    var onDrag: ((CGPoint) -> Void)?
    var isEnabled = true { didSet { if !isEnabled { hide() } } }
    var wantsThumbnails = false

    /// 悬停窗当前显示的内容
    private enum Shown {
        /// 一个 App 的窗口列表
        case windows(DockItem, NSRunningApplication, AppSnapshot)
        /// App 在运行但没有窗口：一行提示，可以打开窗口或退出
        case empty(DockItem, NSRunningApplication)

        var item: DockItem {
            switch self {
            case .windows(let item, _, _), .empty(let item, _): return item
            }
        }

        var app: NSRunningApplication {
            switch self {
            case .windows(_, let app, _), .empty(_, let app): return app
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
    private var monitors: [Any] = []
    private var lastMove: TimeInterval = 0
    private var captureGeneration = 0
    /// 悬停窗和程序坞之间的空隙（AppKit 坐标）。鼠标从图标移向悬停窗时经过这里，不算离开
    private var bridge = CGRect.null
    /// 最近截到的画面。窗口最小化或隐藏后截不到新的，就用它
    private var thumbnailCache: [CGWindowID: NSImage] = [:]

    private let showDelay: TimeInterval = 0.25
    private let hideDelay: TimeInterval = 0.25

    func start() {
        guard monitors.isEmpty else { return }
        dock.refresh()
        log("dock frame \(dock.frame)")
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        // 全局监听收不到发给自己窗口的事件，补一个本地的
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
        panel.content.onSelect = { [weak self] in self?.select($0) }
        panel.content.onClose = { [weak self] in self?.close($0) }
        panel.content.onOpen = { [weak self] in self?.openWindow() }
        panel.content.onQuit = { [weak self] in self?.quit() }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hide()
    }

    // MARK: 鼠标

    private func handle(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        let point = topLeftPoint(fromCocoa: location, primaryHeight: primaryScreenHeight)
        if event.type == .leftMouseDragged {
            // 拖着东西经过程序坞时不弹悬停窗
            onDrag?(point)
            return
        }
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMove >= 0.016 else { return }
        lastMove = now

        // 鼠标已经移进悬停窗，或正在从图标移向它的路上：保持显示
        if panel.isVisible, panel.cardFrame.insetBy(dx: -4, dy: -4).contains(location) || bridge.contains(location) {
            cancelHide()
            return
        }
        // 自动隐藏的程序坞滑出来时位置会变，靠近屏幕边缘时查得勤一点
        dock.refresh(maxAge: isNearScreenEdge(location) ? 0.3 : 3)

        let item = dock.item(at: point).flatMap { $0.isApplication ? $0 : nil }
        if let item, item.isSame(as: hovered) {
            // 只有鼠标停在「悬停窗所属的那个图标」上才续命；停在别的没有内容可显示的图标上，旧的悬停窗照常关闭
            if item.isSame(as: shown?.item) { cancelHide() }
            return
        }
        guard item != nil || hovered != nil else { return }
        hovered = item
        showTimer?.invalidate()
        // 没在运行的 App 没什么可显示的，交给程序坞自己的名称气泡
        guard let item, let app = item.runningApp, let snapshot = WindowIndex.snapshot(of: app) else {
            scheduleHide()
            return
        }
        cancelHide()
        if panel.isVisible {
            present(item, app: app, snapshot: snapshot)
        } else {
            showTimer = timer(showDelay) { [weak self] in
                guard let self, item.isSame(as: self.hovered) else { return }
                self.present(item, app: app, snapshot: WindowIndex.snapshot(of: app) ?? snapshot)
            }
        }
    }

    private func isNearScreenEdge(_ location: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return false }
        return !screen.frame.insetBy(dx: 90, dy: 90).contains(location)
    }

    // MARK: 显示与隐藏

    /// 点击多窗口 App 的图标时调用：立即显示，不等悬停延时
    func showPinned(for item: DockItem, app: NSRunningApplication) {
        showTimer?.invalidate()
        cancelHide()
        hovered = item
        if let snapshot = WindowIndex.snapshot(of: app) { present(item, app: app, snapshot: snapshot) }
    }

    /// 一次点击被原样交给了程序坞（切换、还原之类）：收起悬停窗，和 Windows 的习惯一致
    func dockClickPassedThrough() {
        showTimer?.invalidate()
        hide()
    }

    private func present(_ item: DockItem, app: NSRunningApplication, snapshot: AppSnapshot) {
        guard isEnabled, !app.isTerminated else {
            hide()
            return
        }
        if snapshot.windows.isEmpty {
            if case .empty(let current, _)? = shown, current.isSame(as: item) {} else {
                log("show empty card of \(item.title)")
            }
            shown = .empty(item, app)
            signature = ""
            captureGeneration += 1
            if let layout = layout(for: item) { place(panel.renderEmpty(), layout) }
        } else {
            if case .windows(let current, _, _)? = shown, current.isSame(as: item) {} else {
                log("show windows of \(item.title): \(snapshot.windows.count) thumbnails=\(showsThumbnails)")
            }
            shown = .windows(item, app, snapshot)
            render()
            loadThumbnails()
        }
        reveal()
        if refreshTimer == nil {
            let refresh = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(refresh, forMode: .common)
            refreshTimer = refresh
        }
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
        bridge = .null
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func scheduleHide() {
        guard panel.isVisible, hideTimer?.isValid != true else { return }
        hideTimer = timer(hideDelay) { [weak self] in self?.hide() }
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
        place(panel.render(entries: list, thumbnails: showsThumbnails, placeholder: app.icon, maxSize: layout.maxSize), layout)
    }

    private static func signature(of entries: [PreviewEntry]) -> String {
        entries.map { "\($0.title)|\($0.isCurrent)" }.joined(separator: "\n")
    }

    private typealias Layout = (edge: DockEdge, itemFrame: CGRect, dockFrame: CGRect, visible: CGRect, maxSize: CGSize, gap: CGFloat)

    private func place(_ size: NSSize, _ layout: Layout) {
        let origin = panelOrigin(panelSize: size, itemFrame: layout.itemFrame, dockFrame: layout.dockFrame,
                                 edge: layout.edge, visibleFrame: layout.visible, gap: layout.gap)
        panel.setCardOrigin(origin)
        bridge = corridor(panelFrame: NSRect(origin: origin, size: size), itemFrame: layout.itemFrame, dockFrame: layout.dockFrame, edge: layout.edge)
    }

    /// 程序坞自带的名称气泡紧贴在图标外侧，悬停窗要让到它外面，两者才不会叠在一起。
    /// 气泡的尺寸是实测的：高约 30 点；宽度是名称的文字宽度加两侧各约 15 点。
    private func labelClearance(for item: DockItem, edge: DockEdge) -> CGFloat {
        let spacing: CGFloat = 6
        switch edge {
        case .bottom:
            return 30 + spacing
        case .left, .right:
            let text = (item.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
            return text.rounded(.up) + 32 + spacing
        }
    }

    /// 程序坞贴在哪条边、它占掉的范围，以及悬停窗最大能有多大。全部是 AppKit 坐标。
    private func layout(for item: DockItem) -> Layout? {
        let height = primaryScreenHeight
        let itemFrame = cocoaRect(fromTopLeft: item.frame, primaryHeight: height)
        var dockFrame = cocoaRect(fromTopLeft: dock.frame.isNull ? item.frame : dock.frame, primaryHeight: height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(itemFrame) }) ?? NSScreen.main else { return nil }
        let edge = dockEdge(dockFrame: dockFrame, screenFrame: screen.frame)
        // 程序坞的玻璃底板比图标区域略宽，以系统为它留出的那条边为准，悬停窗才不会压在上面
        let visible = screen.visibleFrame
        let margin: CGFloat = 12
        let gap = labelClearance(for: item, edge: edge)
        var maxSize = CGSize(width: visible.width - margin * 2, height: visible.height - margin * 2)
        switch edge {
        case .left:
            dockFrame.size.width = max(dockFrame.maxX, visible.minX) - dockFrame.minX
            maxSize.width = visible.maxX - dockFrame.maxX - gap - margin
        case .right:
            let left = min(dockFrame.minX, visible.maxX)
            dockFrame = CGRect(x: left, y: dockFrame.minY, width: dockFrame.maxX - left, height: dockFrame.height)
            maxSize.width = dockFrame.minX - gap - visible.minX - margin
        case .bottom:
            dockFrame.size.height = max(dockFrame.maxY, visible.minY) - dockFrame.minY
            maxSize.height = visible.maxY - dockFrame.maxY - gap - margin
        }
        return (edge, itemFrame, dockFrame, visible, maxSize, gap)
    }

    /// 悬停窗开着的时候每秒看一眼：窗口开了、关了、改了标题，或者 App 退出了，就跟着更新
    private func refresh() {
        guard let current = shown else { return }
        guard !current.app.isTerminated, let snapshot = WindowIndex.snapshot(of: current.app) else {
            hide()
            return
        }
        switch current {
        case .empty(let item, let app):
            if !snapshot.windows.isEmpty { present(item, app: app, snapshot: snapshot) }
        case .windows(let item, let app, _):
            if snapshot.windows.isEmpty {
                // 最后一个窗口刚被关掉：换成「没有打开的窗口」那一行
                present(item, app: app, snapshot: snapshot)
            } else {
                shown = .windows(item, app, snapshot)
                if Self.signature(of: entries(for: snapshot)) != signature {
                    render()
                    loadThumbnails()
                }
            }
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

    /// 让一个没有窗口的 App 开一个窗口。直接请程序坞执行它自己的「点击图标」动作，效果和用户亲手点一下完全一样。
    private func openWindow() {
        guard case .empty(let item, let app)? = shown else { return }
        hide()
        let pressed = item.element.perform(kAXPressAction)
        log("open window of \(item.title) via dock press=\(pressed)")
        if !pressed, let url = app.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func quit() {
        guard case .empty(let item, let app)? = shown else { return }
        hide()
        log("quit \(item.title)")
        app.terminate()
    }
}
