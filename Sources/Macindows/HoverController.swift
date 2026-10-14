import AppKit
import MacindowsCore

/// 跟着鼠标停在程序坞的哪个图标上，决定悬停窗何时出现、显示什么、何时消失。
final class HoverController {
    let dock = DockInspector()
    var isEnabled = true {
        didSet {
            // 停用期间不再跟进鼠标停在哪，之前记下的已经不作数了
            hovered = nil
            muted = nil
            if !isEnabled { hide() }
        }
    }
    var wantsThumbnails = false
    /// 鼠标在悬停窗的某一项上停住时，要不要在那扇窗口原本的位置上预览它
    var wantsPeek = true { didSet { if !wantsPeek { endPeek() } } }

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
    private let peek = PeekController()
    private lazy var eraser = LabelEraser { [weak self] in self.map { [$0.panel.windowNumber] } ?? [] }
    /// 这一次悬停窗是不是贴着程序坞摆的（见 place）
    private var isSnug = false
    /// 程序坞说鼠标此刻停着的 App 图标（文件夹、废纸篓之类不管）
    private var dockItem: DockItem?
    /// 已经按它处理过的那个图标
    private var hovered: DockItem?
    /// 刚点过、或者刚关掉菜单的那个图标：鼠标要先离开它，才会再为它弹出悬停窗。
    /// 离没离开看鼠标的位置，不看程序坞的说法——菜单开着的时候程序坞会说鼠标不在任何图标上，其实鼠标没动过
    private var muted: DockItem?
    private var shown: Shown?
    private var signature = ""
    private var showTimer: Timer?
    private var refreshTimer: Timer?
    /// App 一时没应答（正忙或刚启动）时的重试
    private var retryTimer: Timer?
    private var retryItem: DockItem?
    private var retryAttempts = 0
    /// 悬停窗开着时连续几次没读到窗口；偶尔一次读不到不该把悬停窗关掉
    private var refreshFailures = 0
    private var started = false
    private var monitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?
    private var lastMove: TimeInterval = 0
    private var captureGeneration = 0
    /// 正在淡出；淡完才真正收起，这期间鼠标回来就恢复
    private var isFading = false
    private var fadeGeneration = 0
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
    private var peekTimer: Timer?
    private var peekEndTimer: Timer?
    private var settleTimer: Timer?

    private let showDelay: TimeInterval = 0.25
    private let fadeInDuration: TimeInterval = 0.175
    private let fadeOutDuration: TimeInterval = 0.4
    /// 鼠标被判定为「路过」之后如果就此停住，过这么久按它停住的位置重新处理
    private let aimSettle: TimeInterval = 0.15
    /// 鼠标在一项上停多久才开始原位预览；已经在预览时换一项不用再等
    private let peekDelay: TimeInterval = 0.5
    /// 悬停窗贴着程序坞摆时，和程序坞图标区域之间留的空隙。图标区域比程序坞的玻璃底板高出 5 点，
    /// 所以看上去悬停窗离程序坞约 6 点
    private let snugGap: CGFloat = 1

    func start() {
        guard !started else { return }
        started = true
        dock.onHoverChanged = { [weak self] in self?.dockHoverChanged($0) }
        dock.start()
        log("dock frame \(dock.frame)")
        panel.content.onSelect = { [weak self] in self?.select($0) }
        panel.content.onClose = { [weak self] in self?.close($0) }
        panel.content.onHighlight = { [weak self] in self?.highlightChanged($0) }
        // 换了桌面：悬停窗里的内容和位置都可能不对了，收起来
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hide()
        }
    }

    func stop() {
        started = false
        dock.stop()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        menuTimer?.invalidate()
        menuTimer = nil
        dockMenuOpen = false
        hide()
    }

    // MARK: 鼠标

    /// 程序坞说鼠标停着的图标变了
    private func dockHoverChanged(_ item: DockItem?) {
        dockItem = item.flatMap { $0.isApplication ? $0 : nil }
        // 鼠标已经到了别的图标上，那就肯定离开过了
        if let item, !item.isSame(as: muted) { unmute() }
        updateEraser()
        // 悬停窗开着时要看鼠标的速度来分辨「路过」和「到了」。程序坞的通知往往比我们收到的鼠标事件还快，
        // 这一刻手头的轨迹可能还没跟上；先把鼠标现在的位置记进去，还不够算速度就稍等一下再判断
        settleTimer?.invalidate()
        sampleMouse()
        if panel.isVisible, trailSpan < 0.012 {
            settleTimer = timer(0.03) { [weak self] in
                self?.sampleMouse()
                self?.evaluate(fromDock: true)
            }
        } else {
            evaluate(fromDock: true)
        }
    }

    private var trailSpan: TimeInterval {
        guard let first = trail.first, let last = trail.last else { return 0 }
        return last.time - first.time
    }

    /// 把鼠标此刻的位置记进轨迹（只保留最近 70 毫秒；停顿过之后重新开始）
    private func sampleMouse() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = trail.last, now - last.time > 0.12 { trail.removeAll() }
        trail.append((now, NSEvent.mouseLocation))
        trail.removeAll { now - $0.time > 0.07 }
    }

    private func mute(_ item: DockItem?) {
        guard let item, item.isApplication else { return }
        muted = item
        trackMouse()
    }

    private func unmute() {
        guard muted != nil else { return }
        muted = nil
        trackMouse()
    }

    /// 只在需要的时候才跟着鼠标走：悬停窗开着（要判断鼠标是不是移进了悬停窗、是不是只是路过别的图标），
    /// 或者在等鼠标离开某个图标。其余时间不监听鼠标，什么时候该弹出来由程序坞的通知决定。
    private func trackMouse() {
        let wanted = panel.isVisible || muted != nil
        guard wanted == monitors.isEmpty else { return }
        if wanted {
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] in self?.mouseMoved($0) }) {
                monitors.append(global)
            }
            // 全局监听收不到发给自己窗口的事件，补一个本地的
            if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] in self?.mouseMoved($0); return $0 }) {
                monitors.append(local)
            }
        } else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            trail.removeAll()
        }
    }

    private func mouseMoved(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMove >= 0.016 else { return }
        lastMove = now
        sampleMouse()
        evaluate()
    }

    /// 按鼠标当前的位置和程序坞说的图标，决定悬停窗的去留。
    /// fromDock 表示这一次是程序坞刚发来通知触发的（否则是鼠标移动或者定时器触发的）。
    private func evaluate(fromDock: Bool = false, honoringAim: Bool = true) {
        guard isEnabled, !dockMenuOpen else { return }
        let location = NSEvent.mouseLocation
        let point = topLeftPoint(fromCocoa: location, primaryHeight: primaryScreenHeight)
        if let muted, !dock.isMouse(at: point, over: muted) { unmute() }
        // 悬停窗里哪一项该亮，每次都按鼠标的实际位置重新确定一遍（和窗口自己收到的鼠标事件互为备份）
        if panel.isVisible { panel.content.refreshHover() }
        // 鼠标已经移进悬停窗，或正在从图标移向它的空隙里：保持显示
        if panel.isVisible, panel.cardFrame.insetBy(dx: -4, dy: -4).contains(location) || bridge.contains(location) {
            cancelHide()
            endAim()
            return
        }
        // 鼠标停在哪个图标上听程序坞的，还在不在那儿看鼠标的位置（见 DockInspector.isMouse）
        let item: DockItem?
        if !dock.contains(point) {
            // 已经出了程序坞的范围：不管程序坞怎么说，都不算停在图标上了
            item = nil
        } else if fromDock || dockItem == nil {
            item = dockItem
        } else if let dockItem, dock.isMouse(at: point, over: dockItem) {
            item = dockItem
        } else {
            // 鼠标在程序坞上，但已经不在程序坞上次说的那个图标上：它马上会来通知现在是哪个，等它
            return
        }
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
                self.evaluate(honoringAim: false)
            }
            return
        }
        endAim()
        guard item != nil || hovered != nil else { return }
        hovered = item
        showTimer?.invalidate()
        retryTimer?.invalidate()
        // 刚点过这个图标、或者它的菜单刚关：鼠标还没离开过，不再为它弹
        if let item, item.isSame(as: muted) {
            scheduleHide()
            return
        }
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
                    self.evaluate()
                }
            }
            return
        }
        retryItem = nil
        cancelHide()
        if panel.isVisible {
            present(item, app: app, snapshot: snapshot)
        } else {
            // 悬停窗会贴着程序坞弹出来的话，先把名称气泡那一块的画面截好，弹出时立刻就能遮上
            if let layout = layout(for: item), layout.canBeSnug { eraser.prepare(labelRect(for: item)) }
            showTimer = timer(showDelay) { [weak self] in
                guard let self, item.isSame(as: self.hovered) else { return }
                // 弹出来之前按鼠标的位置再确认一次它还在这个图标上
                let point = topLeftPoint(fromCocoa: NSEvent.mouseLocation, primaryHeight: primaryScreenHeight)
                guard self.dock.isMouse(at: point, over: item) else {
                    self.hovered = nil
                    return
                }
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

    // MARK: 程序坞的菜单

    /// 鼠标在程序坞上按下了。右键一定会叫出程序坞的菜单，立刻让位；
    /// 左键则可能是按住不放或按住 Control 点，也会叫出菜单，所以留意一小会儿。
    func mouseDown(at point: CGPoint, opensMenu: Bool) {
        guard isEnabled, dock.contains(point) else { return }
        menuItem = dockItem ?? dock.hoveredItem()
        menuSeen = false
        menuDeadline = ProcessInfo.processInfo.systemUptime + (opensMenu ? 0.8 : 1.5)
        if opensMenu {
            dockMenuOpen = true
            mute(menuItem)
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
                mute(menuItem)
                hide()
            }
        } else if menuSeen || ProcessInfo.processInfo.systemUptime > menuDeadline {
            // 菜单关了（或者根本没出现）：恢复正常。鼠标要离开这个图标再回来才会重新弹出悬停窗
            menuTimer?.invalidate()
            menuTimer = nil
            menuItem = nil
            dockMenuOpen = false
            // 菜单开着的这段时间没有跟进鼠标，补上：鼠标已经不在那个图标上的话，把它忘掉
            evaluate()
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

    /// 在图标上点了一下（交给了程序坞去切换、还原，或者我们自己把窗口最小化、放回来了）：
    /// 收起悬停窗，和 Windows 的习惯一致；鼠标离开这个图标之前不再弹
    func dismissAfterClick() {
        showTimer?.invalidate()
        mute(dockItem ?? hovered)
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
            endPeek()
            // 和只有一个窗口时的悬停窗一样大：标题是 App 的名字，原本放画面的地方是一扇空白的窗口，正中是 App 图标
            let entry = PreviewEntry(title: app.localizedName ?? item.title, aspect: nil, thumbnail: nil, isPlaceholder: true)
            if let layout = layout(for: item) {
                place(panel.render(entries: [entry], thumbnails: showsThumbnails, placeholder: app.icon, maxSize: layout.maxSize), layout)
            }
        } else {
            if case .windows(let current, _, _)? = shown, current.isSame(as: item) {} else {
                let elsewhere = snapshot.windows.filter { !$0.isOnCurrentSpace }.count
                log("show windows of \(item.title): \(snapshot.windows.count) (\(elsewhere) on other spaces) thumbnails=\(showsThumbnails)")
                endPeek()
            }
            shown = .windows(item, app, snapshot)
            render()
            loadThumbnails()
        }
        reveal()
        updateEraser()
        if refreshTimer == nil {
            let refresh = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(refresh, forMode: .common)
            refreshTimer = refresh
        }
    }

    private func reveal() {
        cancelHide()
        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.playEntrance(from: shownEdge, duration: fadeInDuration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeInDuration
            panel.animator().alphaValue = 1
        }
        trackMouse()
    }

    /// 立刻收起，不淡出。用在点了某个窗口、程序坞的菜单要出来这类「马上让开」的场合
    func hide() {
        showTimer?.invalidate()
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshFailures = 0
        isFading = false
        fadeGeneration += 1
        shown = nil
        // 收起之后不再跟着鼠标走，「处理过哪个图标」也就不作数了；下次程序坞说鼠标到了哪个图标，都当作新来的。
        // （点过图标之后不想马上再弹的情况另有 muted 管着）
        hovered = nil
        signature = ""
        captureGeneration += 1
        bridge = .null
        aimArea = .null
        endAim()
        endPeek()
        eraser.stop()
        if panel.isVisible { panel.orderOut(nil) }
        trackMouse()
    }

    /// 鼠标离开了：淡出，淡完再收起。淡出本身就是缓冲——开头那一百多毫秒几乎看不出变化，
    /// 鼠标只是一时滑出去又回来的话，悬停窗会恢复原样
    private func scheduleHide() {
        guard panel.isVisible, !isFading else { return }
        isFading = true
        fadeGeneration += 1
        let generation = fadeGeneration
        endPeek()
        eraser.stop()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.isFading, self.fadeGeneration == generation else { return }
            self.hide()
        })
    }

    private func cancelHide() {
        guard isFading else { return }
        isFading = false
        fadeGeneration += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
        updateEraser()
    }

    // MARK: 程序坞的名称气泡

    /// 悬停窗贴着程序坞、鼠标又停在某个图标上时，把程序坞给那个图标显示的名称气泡遮掉；其余时候撤掉遮挡
    private func updateEraser() {
        guard panel.isVisible, !isFading, isSnug, let item = dockItem else {
            eraser.stop()
            return
        }
        eraser.cover(labelRect(for: item))
    }

    /// 名称气泡占的那一块屏幕（左上角为原点的全局坐标），四周略放宽。尺寸是在底部的程序坞上实测的：
    /// 气泡的上沿在图标上沿之上 35 点，底下的尖角一直伸到图标上沿之上 3 点；宽度是名称的文字宽度加两侧各约 14 点。
    private func labelRect(for item: DockItem) -> CGRect {
        let text = (item.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        let width = (text + 28 + 12).rounded(.up)
        return CGRect(x: (item.frame.midX - width / 2).rounded(.down), y: item.frame.minY - 38, width: width, height: 37)
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
            let size = window.frame?.size
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

    private typealias Layout = (edge: DockEdge, itemFrame: CGRect, dockFrame: CGRect, visible: CGRect, maxSize: CGSize, labelGap: CGFloat, canBeSnug: Bool)

    private func place(_ size: NSSize, _ layout: Layout) {
        // 遮得掉名称气泡就贴着程序坞摆；遮不掉（没开缩略图，也就没有屏幕录制权限；或者程序坞在侧边）就让到气泡外面
        isSnug = layout.canBeSnug
        let gap = isSnug ? snugGap : layout.labelGap
        let origin = panelOrigin(panelSize: size, itemFrame: layout.itemFrame, dockFrame: layout.dockFrame,
                                 edge: layout.edge, visibleFrame: layout.visible, gap: gap)
        panel.setCardOrigin(origin)
        shownEdge = layout.edge
        aimArea = aimZone(panelFrame: NSRect(origin: origin, size: size), itemFrame: layout.itemFrame, dockFrame: layout.dockFrame, edge: layout.edge)
        bridge = corridor(panelFrame: NSRect(origin: origin, size: size), itemFrame: layout.itemFrame, dockFrame: layout.dockFrame, edge: layout.edge)
    }

    /// 程序坞自带的名称气泡紧贴在图标外侧，让到它外面需要留多大的空隙。
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
        // 程序坞的玻璃底板和图标区域不完全重合，以系统为它留出的那条边为准，悬停窗才不会压在上面
        let visible = screen.visibleFrame
        let margin: CGFloat = 12
        // 能有多大按留空隙较多的那种摆法算，两种摆法都放得下
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
        // 名称气泡的位置只在底部的程序坞上量过，侧边的程序坞不遮
        return (edge, itemFrame, dockFrame, visible, maxSize, gap, showsThumbnails && edge == .bottom)
    }

    /// 悬停窗开着的时候每秒看一眼：窗口开了、关了、改了标题，或者 App 退出了，就跟着更新
    private func refresh() {
        // 顺带再问一次程序坞鼠标停在哪：万一漏了通知，悬停窗不至于一直挂着
        dock.report()
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
                    // 窗口有增减：各项的位置变了，正在预览的那一项可能已经不是原来那扇窗口
                    endPeek()
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

    // MARK: 原位预览

    /// 鼠标停着的那一项换了
    private func highlightChanged(_ index: Int?) {
        peekTimer?.invalidate()
        peekTimer = nil
        guard wantsPeek, showsThumbnails, !isFading, let index,
              case .windows(_, let app, let snapshot)? = shown, snapshot.windows.indices.contains(index) else {
            // 鼠标从一项移到另一项时会经过中间的缝，那一瞬间哪一项都不亮；稍等一下再收，免得预览一闪一闪
            guard peekEndTimer == nil, peek.current != nil else { return }
            peekEndTimer = timer(0.15) { [weak self] in self?.endPeek() }
            return
        }
        peekEndTimer?.invalidate()
        peekEndTimer = nil
        let window = snapshot.windows[index]
        if peek.current != nil {
            // 已经在预览了：换一项不用再等
            showPeek(of: window, app: app)
        } else {
            peekTimer = timer(peekDelay) { [weak self] in self?.showPeek(of: window, app: app) }
        }
    }

    private func showPeek(of window: AppWindow, app: NSRunningApplication) {
        guard panel.isVisible, !isFading, let id = window.id, let frame = window.frame, frame.width > 1, frame.height > 1 else { return }
        if peek.current != id { log("peek at window \(id) of \(app.localizedName ?? "?")") }
        peek.show(windowID: id, frame: cocoaRect(fromTopLeft: frame, primaryHeight: primaryScreenHeight), placeholder: thumbnailCache[id])
    }

    private func endPeek() {
        peekTimer?.invalidate()
        peekTimer = nil
        peekEndTimer?.invalidate()
        peekEndTimer = nil
        peek.dismiss()
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
        endPeek()
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
