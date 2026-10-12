import AppKit
import MacindowsCore

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
        /// App 在运行但没有窗口：一个占位项，点它开一个窗口
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
    /// App 一时没应答（正忙或刚启动）时的重试
    private var retryTimer: Timer?
    private var retryItem: DockItem?
    private var retryAttempts = 0
    /// 悬停窗开着时连续几次没读到窗口；偶尔一次读不到不该把悬停窗关掉
    private var refreshFailures = 0
    private var monitors: [Any] = []
    private var lastMove: TimeInterval = 0
    private var captureGeneration = 0
    /// 悬停窗和程序坞之间的空隙（AppKit 坐标）。鼠标从图标移向悬停窗时经过这里，不算离开
    private var bridge = CGRect.null
    /// 悬停窗贴着程序坞的哪条边
    private var shownEdge = DockEdge.bottom
    /// 悬停窗正下方的那一段程序坞（AppKit 坐标）。鼠标在这里只是路过别的图标时不切换
    private var aimArea = CGRect.null
    private var aimTimer: Timer?
    /// 最近几十毫秒的鼠标位置（AppKit 坐标），用来估算移动速度
    private var trail: [(time: TimeInterval, point: NSPoint)] = []
    /// 程序坞自己的菜单（右键、按住 Control 点、按住不放都会叫出来）是否开着。开着的时候悬停窗让位，不和它叠在一起
    private var dockMenuOpen = false
    private var menuItem: DockItem?
    private var menuTimer: Timer?
    private var menuSeen = false
    private var menuDeadline: TimeInterval = 0
    /// 最近截到的画面。窗口最小化或隐藏后截不到新的，就用它
    private var thumbnailCache: [CGWindowID: NSImage] = [:]

    private let showDelay: TimeInterval = 0.25
    private let hideDelay: TimeInterval = 0.25
    /// 鼠标被判定为「路过」之后如果就此停住，过这么久按它停住的位置重新处理
    private let aimSettle: TimeInterval = 0.15

    func start() {
        guard monitors.isEmpty else { return }
        dock.refresh()
        log("dock frame \(dock.frame)")
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        // 全局监听收不到发给自己窗口的事件，补一个本地的
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
        panel.content.onSelect = { [weak self] in self?.select($0) }
        panel.content.onClose = { [weak self] in self?.close($0) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        menuTimer?.invalidate()
        menuTimer = nil
        dockMenuOpen = false
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
        if event.type == .rightMouseDown {
            mouseDown(at: point, opensMenu: true)
            return
        }
        guard isEnabled, !dockMenuOpen else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMove >= 0.016 else { return }
        lastMove = now
        // 停顿过之后重新开始算速度；只保留最近 70 毫秒
        if let last = trail.last, event.timestamp - last.time > 0.12 { trail.removeAll() }
        trail.append((event.timestamp, location))
        trail.removeAll { event.timestamp - $0.time > 0.07 }
        evaluate(location: location, point: point)
    }

    /// 按鼠标当前位置决定悬停窗的去留。location 是 AppKit 坐标，point 是同一位置的左上角原点坐标。
    private func evaluate(location: NSPoint, point: CGPoint, honoringAim: Bool = true) {
        // 悬停窗里哪一项该亮，每次鼠标移动都按实际位置重新确定一遍（和窗口自己收到的鼠标事件互为备份）
        if panel.isVisible { panel.content.refreshHover() }
        // 鼠标已经移进悬停窗，或正在从图标移向它的空隙里：保持显示
        if panel.isVisible, panel.cardFrame.insetBy(dx: -4, dy: -4).contains(location) || bridge.contains(location) {
            cancelHide()
            endAim()
            return
        }
        // 自动隐藏的程序坞滑出来时位置会变，靠近屏幕边缘时查得勤一点
        dock.refresh(maxAge: isNearScreenEdge(location) ? 0.3 : 3)

        let item = dock.item(at: point).flatMap { $0.isApplication ? $0 : nil }
        if let item, item.isSame(as: hovered) {
            // 只有鼠标停在「悬停窗所属的那个图标」上才续命；停在别的没有内容可显示的图标上，旧的悬停窗照常关闭
            if item.isSame(as: shown?.item) {
                cancelHide()
                endAim()
            }
            return
        }
        // 悬停窗很宽时，从图标移向远处的窗口会扫过别的图标（往往先贴着程序坞横着走一阵再往上）。
        // 不靠等时间来区分，而是看鼠标怎么动：还在快速移动、或者正朝悬停窗去，就是路过，不切换也不关闭；
        // 一旦慢下来又不是朝悬停窗去的，就是到了，立刻按它所在的图标处理。
        if honoringAim, panel.isVisible, shown != nil, aimArea.contains(location),
           isPassingThrough(velocity: recentVelocity(), edge: shownEdge) {
            cancelHide()
            // 路过途中突然停住（没有后续的移动事件来触发判断）：稍等一下按停住的位置处理
            aimTimer?.invalidate()
            aimTimer = timer(aimSettle) { [weak self] in
                guard let self else { return }
                self.endAim()
                let current = NSEvent.mouseLocation
                self.evaluate(location: current, point: topLeftPoint(fromCocoa: current, primaryHeight: primaryScreenHeight), honoringAim: false)
            }
            return
        }
        endAim()
        guard item != nil || hovered != nil else { return }
        hovered = item
        showTimer?.invalidate()
        retryTimer?.invalidate()
        // 没在运行的 App 没什么可显示的，交给程序坞自己的名称气泡
        guard let item, let app = item.runningApp else {
            scheduleHide()
            return
        }
        guard let snapshot = WindowIndex.snapshot(of: app) else {
            // App 在运行，但这一次没读到它的窗口（它正忙，或者是启动后第一次问它，应答慢了）。
            // 鼠标还停在这个图标上的话过一会儿再问，最多再问两次，而不是就此什么都不显示
            scheduleHide()
            if !item.isSame(as: retryItem) {
                retryItem = item
                retryAttempts = 0
            }
            if retryAttempts < 2 {
                retryAttempts += 1
                log("no answer from \(item.title), retry \(retryAttempts)")
                retryTimer = timer(0.4) { [weak self] in
                    guard let self, item.isSame(as: self.hovered) else { return }
                    self.hovered = nil
                    let current = NSEvent.mouseLocation
                    self.evaluate(location: current, point: topLeftPoint(fromCocoa: current, primaryHeight: primaryScreenHeight))
                }
            }
            return
        }
        retryItem = nil
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

    private func endAim() {
        aimTimer?.invalidate()
        aimTimer = nil
    }

    /// 最近几十毫秒的平均速度（点/秒，AppKit 坐标）。样本不够时当作静止
    private func recentVelocity() -> CGVector {
        guard let first = trail.first, let last = trail.last, last.time - first.time >= 0.012 else { return .zero }
        let elapsed = last.time - first.time
        return CGVector(dx: (last.point.x - first.point.x) / elapsed, dy: (last.point.y - first.point.y) / elapsed)
    }

    private func isNearScreenEdge(_ location: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return false }
        return !screen.frame.insetBy(dx: 90, dy: 90).contains(location)
    }

    // MARK: 程序坞的菜单

    /// 鼠标在程序坞上按下了。右键一定会叫出程序坞的菜单，立刻让位；
    /// 左键则可能是按住不放或按住 Control 点，也会叫出菜单，所以留意一小会儿。
    func mouseDown(at point: CGPoint, opensMenu: Bool) {
        guard isEnabled, dock.contains(point) else { return }
        menuItem = dock.item(at: point)
        menuSeen = false
        menuDeadline = ProcessInfo.processInfo.systemUptime + (opensMenu ? 0.8 : 1.5)
        if opensMenu {
            dockMenuOpen = true
            hide()
        }
        menuTimer?.invalidate()
        let poll = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollDockMenu() }
        RunLoop.main.add(poll, forMode: .common)
        menuTimer = poll
    }

    private func pollDockMenu() {
        if isDockMenuShowing() {
            menuSeen = true
            if !dockMenuOpen {
                dockMenuOpen = true
                hide()
            }
        } else if menuSeen || ProcessInfo.processInfo.systemUptime > menuDeadline {
            // 菜单关了（或者根本没出现）：恢复正常。鼠标要离开这个图标再回来才会重新弹出悬停窗
            menuTimer?.invalidate()
            menuTimer = nil
            menuItem = nil
            dockMenuOpen = false
        }
    }

    /// 实测程序坞的菜单开着时有两个迹象：被点的图标在辅助功能里多出一个「已显示的菜单」，
    /// 屏幕上多出一个属于 DockHelper 进程、处在菜单层级的窗口。两个都看，任何一个成立就算开着。
    private func isDockMenuShowing() -> Bool {
        if let menuItem, menuItem.element.element("AXShownMenuUIElement") != nil { return true }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return windows.contains {
            ($0[kCGWindowOwnerName as String] as? String) == "DockHelper" && (($0[kCGWindowLayer as String] as? Int) ?? 0) >= menuLevel
        }
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
        guard isEnabled, !dockMenuOpen, !app.isTerminated else {
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
            // 和只有一个窗口时的悬停窗一样大：标题是 App 的名字，原本放画面的地方是一扇空白的窗口，正中是 App 图标
            let entry = PreviewEntry(title: app.localizedName ?? item.title, aspect: nil, thumbnail: nil, isPlaceholder: true)
            if let layout = layout(for: item) {
                place(panel.render(entries: [entry], thumbnails: showsThumbnails, placeholder: app.icon, maxSize: layout.maxSize), layout)
            }
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
        refreshFailures = 0
        shown = nil
        signature = ""
        captureGeneration += 1
        bridge = .null
        aimArea = .null
        endAim()
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
        entries.map(\.title).joined(separator: "\n")
    }

    private typealias Layout = (edge: DockEdge, itemFrame: CGRect, dockFrame: CGRect, visible: CGRect, maxSize: CGSize, gap: CGFloat)

    private func place(_ size: NSSize, _ layout: Layout) {
        let origin = panelOrigin(panelSize: size, itemFrame: layout.itemFrame, dockFrame: layout.dockFrame,
                                 edge: layout.edge, visibleFrame: layout.visible, gap: layout.gap)
        panel.setCardOrigin(origin)
        shownEdge = layout.edge
        aimArea = aimZone(panelFrame: NSRect(origin: origin, size: size), itemFrame: layout.itemFrame, dockFrame: layout.dockFrame, edge: layout.edge)
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
        guard !current.app.isTerminated else {
            hide()
            return
        }
        guard let snapshot = WindowIndex.snapshot(of: current.app) else {
            // 偶尔一次读不到就先保持原样，连续三次才认为它真的没法显示了
            refreshFailures += 1
            if refreshFailures >= 3 { hide() }
            return
        }
        refreshFailures = 0
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
        // 占位项只有一个：点它就是开窗口
        if case .empty? = shown {
            openWindow()
            return
        }
        guard case .windows(_, let app, let snapshot)? = shown, snapshot.windows.indices.contains(index) else { return }
        let window = snapshot.windows[index]
        // 先收起悬停窗，再去切窗口；切窗口放到后台线程，这样悬停窗一点就消失，不用等窗口的动画
        hide()
        DispatchQueue.global(qos: .userInteractive).async { WindowIndex.focus(window, of: app) }
    }

    private func close(_ index: Int) {
        guard case .windows(_, let app, let snapshot)? = shown, snapshot.windows.indices.contains(index) else { return }
        let window = snapshot.windows[index]
        log("close window \(window.id.map(String.init) ?? "-") of \(app.localizedName ?? "?")")
        DispatchQueue.global(qos: .userInteractive).async { WindowIndex.close(window) }
        _ = timer(0.3) { [weak self] in self?.refresh() }
    }

    /// 让一个没有窗口的 App 开一个窗口。直接请程序坞执行它自己的「点击图标」动作，效果和用户亲手点一下完全一样。
    private func openWindow() {
        guard case .empty(let item, let app)? = shown else { return }
        hide()
        DispatchQueue.global(qos: .userInteractive).async {
            let pressed = item.element.perform(kAXPressAction)
            log("open window of \(item.title) via dock press=\(pressed)")
            if !pressed, let url = app.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

}
