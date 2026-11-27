import AppKit
import MacindowsCore

/// 一个手势对应一次窗口快照。按住时列表冻结，提前松手则在枚举完成后直接切换。
final class WindowSwitcher {
    private final class Session {
        let gesture: Int
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        var cycle: WindowCycle
        var entries: [SwitcherEntry] = []
        var visiblePage: Range<Int> = 0..<0
        var appBadges: [String: String] = [:]
        var pendingApps: [pid_t: NSRunningApplication] = [:]
        var deadlineTimer: Timer?
        var ready = false
        var hasCurrent = false
        var released = false
        var selected: Int? {
            cycle.index(count: entries.count, hasCurrent: hasCurrent)
        }

        init(_ gesture: Int, backwards: Bool) {
            self.gesture = gesture
            cycle = WindowCycle(backwards: backwards)
        }
    }

    var onBegin: (() -> Void)?
    var readApplicationBadges: (() -> [String: String])?
    /// 切换器尚未记录最后关闭画面时，向程序坞无窗口预览模块借图（例如飞书、备忘录等保留窗口）。
    var fallbackWindowlessPreview: ((NSRunningApplication) -> NSImage?)?
    private let previewCache: SharedPreviewCache
    private let history = WindowFocusHistory()
    private var shortcut: SwitcherShortcut?
    private var panel: SwitcherPanel?
    private var session: Session?
    /// 刚刚由本切换器触发的目标进程，短时间内允许前台进程从旧值过渡到它而不误取消下一次连按。
    private var lastPickedPID: pid_t?
    private var lastPickedUntil: TimeInterval = 0
    private let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "macindows.switcher-windows"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    init(previewCache: SharedPreviewCache = SharedPreviewCache()) {
        self.previewCache = previewCache
    }

    var isRunning: Bool { shortcut != nil }

    func lastClosedPreview(for app: NSRunningApplication) -> NSImage? {
        panel?.lastClosedPreview(for: app)
    }

    /// 程序坞悬停点击切换窗口时也记入最近使用顺序，保持两边排序一致。
    func noteFocused(app: NSRunningApplication, window: AppWindow) {
        guard shortcut != nil else { return }
        history.note(SwitcherWindowKey(pid: app.processIdentifier, element: window.element, id: window.id))
    }

    func start() {
        guard shortcut == nil else { return }
        let input = SwitcherShortcut()
        input.onAction = { [weak self, weak input] gesture, action in
            guard let self, let input, self.shortcut === input else { return }
            self.handle(gesture, action)
        }
        guard input.start() else { log("window switcher: could not install keyboard shortcut"); return }
        shortcut = input
        let panel = SwitcherPanel(previewCache: previewCache)
        panel.onPick = { [weak self] in self?.pick($0) }
        panel.onClose = { [weak self] in self?.closeEntry(at: $0) }
        panel.onTurnPage = { [weak self] delta in self?.turnPage(by: delta) }
        panel.onPageChange = { [weak self] range in
            guard let self, let session = self.session else { return }
            session.visiblePage = range
            self.shortcut?.panelDidShow(for: session.gesture, shortcutCount: min(9, range.count))
        }
        self.panel = panel
        history.onFocus = { [weak panel] key in panel?.focusPreview(key) }
        history.start()
    }

    func stop() {
        dismiss(animated: false)
        panel?.stopPreviews()
        history.onFocus = nil
        history.stop()
        shortcut?.stop()
        shortcut = nil
        panel = nil
    }

    func checkShortcut() { shortcut?.reviveIfNeeded() }

    func mouseDown(at point: CGPoint) {
        guard session != nil else { return }
        let location = CGPoint(x: point.x, y: primaryScreenHeight - point.y)
        if let panel, panel.isVisible, !panel.ignoresMouseEvents, panel.cardFrame.contains(location) { return }
        dismiss()
    }

    private func handle(_ gesture: Int, _ action: SwitcherShortcut.Action) {
        switch action {
        case .step(let backwards):
            if let session, session.gesture == gesture {
                session.cycle.step(backwards: backwards)
                update(session)
            } else {
                dismiss()
                let session = Session(gesture, backwards: backwards)
                self.session = session
                onBegin?()
                load(session)
            }
        case .move(let direction):
            guard let session, session.gesture == gesture, session.ready,
                  let current = session.selected,
                  let next = panel?.neighbor(from: current, direction: direction) else { return }
            session.cycle.setIndex(next, hasCurrent: session.hasCurrent)
            update(session)
        case .closeSelected:
            guard let session, session.gesture == gesture, session.ready,
                  let index = session.selected else { return }
            closeEntry(at: index)
        case .minimizeSelected:
            guard let session, session.gesture == gesture, session.ready,
                  let index = session.selected else { return }
            minimizeEntry(at: index)
        case .hideSelected:
            guard let session, session.gesture == gesture, session.ready,
                  let index = session.selected else { return }
            hideEntry(at: index)
        case .quitSelected:
            guard let session, session.gesture == gesture, session.ready,
                  let index = session.selected else { return }
            quitEntry(at: index)
        case .commit:
            guard let session, session.gesture == gesture else { return }
            session.released = true
            update(session)
        case .cancel:
            if session?.gesture == gesture { dismiss() }
        case .selectShortcut(let offset):
            guard let session, session.gesture == gesture, panel?.isVisible == true else { return }
            let target = session.visiblePage.lowerBound + offset
            guard session.visiblePage.contains(target), session.entries.indices.contains(target) else { return }
            pick(target)
        }
    }

    private func load(_ session: Session) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        guard !apps.isEmpty else {
            session.ready = true
            update(session)
            return
        }
        for app in apps { session.pendingApps[app.processIdentifier] = app }

        // 个别应用卡顿时不让整个切换器无限干等：140ms 后先用已就绪的窗口弹出，未应答的作为应用兜底卡保留。
        let deadline = Timer(timeInterval: 0.14, repeats: false) { [weak self, weak session] _ in
            guard let self, let session, self.session === session, !session.ready else { return }
            self.finalize(session)
        }
        RunLoop.main.add(deadline, forMode: .common)
        session.deadlineTimer = deadline

        // 程序坞应答较晚时也能先显示窗口、松键切换。
        if let readApplicationBadges {
            workers.addOperation { [weak self, weak session] in
                let badges = readApplicationBadges()
                DispatchQueue.main.async {
                    guard let self, let session, self.session === session else { return }
                    session.appBadges = badges
                    self.panel?.updateApplicationBadges(badges)
                }
            }
        }
        // 整批枚举共用一份桌面布局与窗口列表快照，避免每个应用重复向窗口服务器查询。
        workers.addOperation { [weak self, weak session] in
            guard let self, session != nil else { return }
            let context = WindowIndex.SnapshotContext.capture()
            for app in apps {
                self.workers.addOperation { [weak self, weak session] in
                    guard session != nil else { return }
                    let snapshot = WindowIndex.snapshot(of: app, context: context)
                    DispatchQueue.main.async { [weak self, weak session] in
                        guard let self, let session, self.session === session, !session.ready else { return }
                        session.pendingApps.removeValue(forKey: app.processIdentifier)
                        if !app.isTerminated {
                            if let snapshot {
                                let lastPreview = self.panel?.preview(for: snapshot)
                                    ?? (snapshot.windows.isEmpty ? self.fallbackWindowlessPreview?(app) : nil)
                                if snapshot.windows.isEmpty {
                                    session.entries.append(SwitcherEntry(app: app, window: nil, lastPreview: lastPreview))
                                } else {
                                    session.entries += snapshot.windows.map { SwitcherEntry(app: app, window: $0) }
                                }
                            } else {
                                // 应用一时未应答时仍保留为兜底卡片，避免从 ⌘Tab 里消失。
                                let preview = self.panel?.lastClosedPreview(for: app) ?? self.fallbackWindowlessPreview?(app)
                                session.entries.append(SwitcherEntry(app: app, window: nil, lastPreview: preview, isFallback: true))
                            }
                        }
                        if session.pendingApps.isEmpty {
                            self.finalize(session)
                        }
                    }
                }
            }
        }
    }

    private func finalize(_ session: Session) {
        guard !session.ready else { return }
        session.deadlineTimer?.invalidate()
        session.deadlineTimer = nil
        for app in session.pendingApps.values where !app.isTerminated {
            let preview = panel?.lastClosedPreview(for: app) ?? fallbackWindowlessPreview?(app)
            session.entries.append(SwitcherEntry(app: app, window: nil, lastPreview: preview, isFallback: true))
        }
        session.pendingApps.removeAll()
        session.ready = true
        sort(session)
        update(session)
    }

    private func sort(_ session: Session) {
        let ranks = history.ranks
        session.entries.sort { a, b in
            let left = ranks[a.key] ?? .max, right = ranks[b.key] ?? .max
            if left != right { return left < right }
            // 未观察到焦点时，按应用启动时间、进程和窗口号给两种卡片一致且稳定的次序。
            let aLaunch = a.app.launchDate ?? .distantPast, bLaunch = b.app.launchDate ?? .distantPast
            if aLaunch != bLaunch { return aLaunch > bLaunch }
            if a.app.processIdentifier != b.app.processIdentifier { return a.app.processIdentifier > b.app.processIdentifier }
            if a.window?.id != b.window?.id { return (a.window?.id ?? 0) > (b.window?.id ?? 0) }
            return a.title < b.title
        }
        let candidates = session.entries.indices.filter {
            let entry = session.entries[$0]
            guard entry.app.processIdentifier == session.frontPID, !entry.app.isHidden, let window = entry.window else { return false }
            return !window.isMinimized && window.isOnCurrentSpace
        }
        var current = candidates.first { session.entries[$0].window?.isMain == true }
        if current == nil, let frontPID = session.frontPID {
            // 有些应用不标记主窗口。可见层级仅用于辨认当前窗口，其他窗口保留自己的使用顺序。
            let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for info in visible where info[kCGWindowOwnerPID as String] as? pid_t == frontPID {
                if let id = info[kCGWindowNumber as String] as? CGWindowID,
                   let match = candidates.first(where: { session.entries[$0].window?.id == id }) {
                    current = match
                    break
                }
            }
        }
        if current == nil {
            current = session.entries.firstIndex { $0.app.processIdentifier == session.frontPID && $0.window == nil && !$0.app.isHidden }
        }
        if let current {
            let entry = session.entries.remove(at: current)
            history.note(entry.key)
            session.entries.insert(entry, at: 0)
            session.hasCurrent = true
        }
    }

    private func update(_ session: Session) {
        guard session.ready else { return }
        let currentFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if currentFront != session.frontPID {
            let recentlyPicked = ProcessInfo.processInfo.systemUptime < lastPickedUntil
                && (currentFront == lastPickedPID || session.frontPID == lastPickedPID)
            if !recentlyPicked && !session.released {
                dismiss()
                return
            }
        }
        if session.released {
            if let index = session.selected { pick(index) } else { dismiss() }
        } else if let screen = session.screen {
            if let choice = session.selected {
                panel?.present(entries: session.entries, selected: choice, on: screen, appBadges: session.appBadges)
            } else {
                panel?.showEmpty(on: screen)
            }
        }
    }

    private func turnPage(by delta: Int) {
        guard let session, session.ready, let selected = session.selected,
              let target = panel?.pageFirstIndex(offsetBy: delta, from: selected) else { return }
        session.cycle.setIndex(target, hasCurrent: session.hasCurrent)
        update(session)
    }

    private func closeEntry(at index: Int) {
        guard let session, session.ready, session.entries.indices.contains(index) else { return }
        let entry = session.entries[index]
        guard let window = entry.window else { return }
        log("switcher close window \(window.id.map(String.init) ?? "-") of \(entry.appName)")
        WindowIndex.actions.async { [weak self] in
            WindowIndex.close(window, of: entry.app) {
                self?.dismiss()
            }
        }
        removeEntries(in: session, matching: { $0 == index }, anchor: index)
    }

    private func minimizeEntry(at index: Int) {
        guard let session, session.ready, session.entries.indices.contains(index) else { return }
        let entry = session.entries[index]
        guard let window = entry.window, !window.isMinimized, window.canMinimize else { return }
        log("switcher minimize window \(window.id.map(String.init) ?? "-") of \(entry.appName)")
        session.entries[index].window = window.with(minimized: true)
        WindowIndex.actions.async { WindowIndex.minimize(window) }
        panel?.invalidateLayout()
        update(session)
    }

    private func hideEntry(at index: Int) {
        guard let session, session.ready, session.entries.indices.contains(index) else { return }
        let entry = session.entries[index]
        guard !entry.app.isHidden else { return }
        log("switcher hide \(entry.appName)")
        WindowIndex.hide(entry.app)
        panel?.invalidateLayout()
        update(session)
    }

    private func quitEntry(at index: Int) {
        guard let session, session.ready, session.entries.indices.contains(index) else { return }
        let app = session.entries[index].app
        let pid = app.processIdentifier
        log("switcher quit \(session.entries[index].appName)")
        WindowIndex.quit(app)
        removeEntries(in: session, matching: { session.entries[$0].app.processIdentifier == pid }, anchor: index)
    }

    private func removeEntries(in session: Session, matching shouldRemove: (Int) -> Bool, anchor: Int) {
        let kept = session.entries.enumerated().filter { !shouldRemove($0.offset) }.map(\.element)
        session.entries = kept
        if kept.isEmpty {
            dismiss()
            return
        }
        let clamped = min(anchor, kept.count - 1)
        session.cycle.setIndex(clamped, hasCurrent: session.hasCurrent)
        panel?.invalidateLayout()
        update(session)
    }

    private func pick(_ index: Int) {
        guard let session, session.ready, session.entries.indices.contains(index) else { return }
        let entry = session.entries[index]
        history.note(entry.key)
        lastPickedPID = entry.app.processIdentifier
        lastPickedUntil = ProcessInfo.processInfo.systemUptime + 0.45
        dismiss()
        WindowIndex.actions.async {
            guard !entry.app.isTerminated else { return }
            if let window = entry.window {
                // 提交前复核窗口是否已经关闭或改变了最小化状态。
                guard window.element.string(kAXRoleAttribute) == kAXWindowRole else { return }
                let minimized = window.element.bool(kAXMinimizedAttribute) ?? window.isMinimized
                WindowIndex.focus(window.with(minimized: minimized), of: entry.app)
            } else if let snapshot = WindowIndex.snapshot(of: entry.app) {
                // 按住 ⌘ 期间应用可能已经有了窗口，这时直接切过去。
                if let window = snapshot.windows.first(where: \.isMain) ?? snapshot.windows.first {
                    WindowIndex.focus(window, of: entry.app)
                } else {
                    WindowIndex.reopen(entry.app)
                }
            } else {
                WindowIndex.activate(entry.app)
            }
        }
    }

    private func dismiss(animated: Bool = true) {
        if let session {
            session.deadlineTimer?.invalidate()
            session.deadlineTimer = nil
            shortcut?.end(session.gesture)
        }
        session = nil
        workers.cancelAllOperations()
        panel?.dismiss(animated: animated)
    }
}
