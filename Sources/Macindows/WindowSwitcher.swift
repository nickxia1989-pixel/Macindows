import AppKit
import MacindowsCore

/// 一个手势对应一次窗口快照。按住时列表冻结，提前松手则在枚举完成后直接切换。
final class WindowSwitcher {
    private final class Session {
        let gesture: Int
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        var cycle: WindowCycle
        var windows: [SwitcherEntry] = []
        var applications: [SwitcherEntry] = []
        var appBadges: [String: String] = [:]
        var remaining = 0
        var hasCurrent = false
        var released = false
        var selected: SwitcherChoice? {
            cycle.selection(windows: windows.count, applications: applications.count, hasCurrent: hasCurrent)
        }

        init(_ gesture: Int, backwards: Bool) {
            self.gesture = gesture
            cycle = WindowCycle(backwards: backwards)
        }
    }

    var onBegin: (() -> Void)?
    var readApplicationBadges: (() -> [String: String])?
    private let history = WindowFocusHistory()
    private var shortcut: SwitcherShortcut?
    private var panel: SwitcherPanel?
    private var session: Session?
    private let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "macindows.switcher-windows"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    var isRunning: Bool { shortcut != nil }

    func start() {
        guard shortcut == nil else { return }
        let input = SwitcherShortcut()
        input.onAction = { [weak self, weak input] gesture, action in
            guard let self, let input, self.shortcut === input else { return }
            self.handle(gesture, action)
        }
        guard input.start() else { log("window switcher: could not install keyboard shortcut"); return }
        shortcut = input
        let panel = SwitcherPanel()
        panel.onPick = { [weak self] in self?.pick($0) }
        panel.onReveal = { [weak self] in
            guard let self, let session = self.session else { return }
            self.shortcut?.panelDidShow(for: session.gesture, applicationCount: session.applications.count)
        }
        self.panel = panel
        history.onFocus = { [weak panel] key in
            if case .numbered(let pid, let id) = key { panel?.warmPreview(pid: pid, id: id) }
        }
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
        if let panel, panel.isVisible, !panel.ignoresMouseEvents, panel.frame.contains(location) { return }
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
        case .commit:
            guard let session, session.gesture == gesture else { return }
            session.released = true
            update(session)
        case .cancel:
            if session?.gesture == gesture { dismiss() }
        case .applications, .windows:
            guard let session, session.gesture == gesture, !session.windows.isEmpty, !session.applications.isEmpty else { return }
            if case .applications = action { session.cycle.enterApplications() }
            else { session.cycle.returnToWindows() }
            update(session)
        case .openApplication(let i):
            guard session?.gesture == gesture, panel?.isVisible == true else { return }
            pick(.application(i))
        }
    }

    private func load(_ session: Session) {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        session.remaining = apps.count
        guard !apps.isEmpty else { update(session); return }
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
        for app in apps {
            workers.addOperation { [weak self, weak session] in
                guard session != nil else { return }
                let snapshot = WindowIndex.snapshot(of: app)
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session, self.session === session else { return }
                    if let snapshot, !app.isTerminated {
                        if snapshot.windows.isEmpty {
                            session.applications.append(SwitcherEntry(app: app, window: nil))
                        } else {
                            session.windows += snapshot.windows.map { SwitcherEntry(app: app, window: $0) }
                        }
                    }
                    session.remaining -= 1
                    if session.remaining == 0 {
                        self.sort(session)
                        self.update(session)
                    }
                }
            }
        }
    }

    private func sort(_ session: Session) {
        // 没有焦点记录的窗口按系统窗口号从新到旧排列；最小化、隐藏和桌面归属都不参与比较。
        let ranks = history.ranks
        func byRecency(_ a: SwitcherEntry, _ b: SwitcherEntry) -> Bool {
            let left = ranks[a.key] ?? .max, right = ranks[b.key] ?? .max
            if left != right { return left < right }
            if a.window?.id != b.window?.id { return (a.window?.id ?? 0) > (b.window?.id ?? 0) }
            if a.app.processIdentifier != b.app.processIdentifier { return a.app.processIdentifier < b.app.processIdentifier }
            return a.title < b.title
        }
        session.windows.sort(by: byRecency)
        session.applications.sort(by: byRecency)
        let candidates = session.windows.indices.filter {
            let entry = session.windows[$0]
            guard entry.app.processIdentifier == session.frontPID, !entry.app.isHidden, let window = entry.window else { return false }
            return !window.isMinimized && window.isOnCurrentSpace
        }
        var current = candidates.first { session.windows[$0].window?.isMain == true }
        if current == nil, let frontPID = session.frontPID {
            // 有些应用不标记主窗口。可见层级仅用于辨认当前窗口，其他窗口保留自己的使用顺序。
            let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for info in visible where info[kCGWindowOwnerPID as String] as? pid_t == frontPID {
                if let id = info[kCGWindowNumber as String] as? CGWindowID,
                   let match = candidates.first(where: { session.windows[$0].window?.id == id }) {
                    current = match
                    break
                }
            }
        }
        if let current {
            let entry = session.windows.remove(at: current)
            history.note(entry.key)
            session.windows.insert(entry, at: 0)
            session.hasCurrent = true
        }
    }

    private func update(_ session: Session) {
        guard session.remaining == 0 else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == session.frontPID else { dismiss(); return }
        if session.released {
            if let index = session.selected { pick(index) } else { dismiss() }
        } else if let screen = session.screen {
            if let choice = session.selected {
                let windowIndex = session.cycle.index(count: session.windows.count, hasCurrent: session.hasCurrent)
                panel?.present(windows: session.windows, applications: session.applications, selected: choice,
                               windowIndex: windowIndex, on: screen, appBadges: session.appBadges)
            } else {
                panel?.showEmpty(on: screen)
            }
        }
    }

    private func pick(_ choice: SwitcherChoice) {
        guard let session, session.remaining == 0 else { return }
        let entry: SwitcherEntry
        switch choice {
        case .window(let i):
            guard session.windows.indices.contains(i) else { return }
            entry = session.windows[i]
        case .application(let i):
            guard session.applications.indices.contains(i) else { return }
            entry = session.applications[i]
        }
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
        if let session { shortcut?.end(session.gesture) }
        session = nil
        workers.cancelAllOperations()
        panel?.dismiss(animated: animated)
    }
}
