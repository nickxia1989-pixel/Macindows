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
        var appBadges: [String: String] = [:]
        var remaining = 0
        var hasCurrent = false
        var released = false
        var selected: Int? { cycle.index(count: entries.count, hasCurrent: hasCurrent) }

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
        history.start()
    }

    func stop() {
        dismiss()
        history.stop()
        shortcut?.stop()
        shortcut = nil
        panel = nil
    }

    func checkShortcut() { shortcut?.reviveIfNeeded() }

    func mouseDown(at point: CGPoint) {
        guard session != nil else { return }
        let location = CGPoint(x: point.x, y: primaryScreenHeight - point.y)
        if let panel, panel.isVisible, panel.frame.contains(location) { return }
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
                let windows = WindowIndex.snapshot(of: app)?.windows ?? []
                DispatchQueue.main.async { [weak self, weak session] in
                    guard let self, let session, self.session === session else { return }
                    session.entries += windows.map { SwitcherEntry(app: app, window: $0) }
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
        session.entries.sort { a, b in
            let left = ranks[a.key] ?? .max, right = ranks[b.key] ?? .max
            if left != right { return left < right }
            if a.window.id != b.window.id { return (a.window.id ?? 0) > (b.window.id ?? 0) }
            if a.app.processIdentifier != b.app.processIdentifier { return a.app.processIdentifier < b.app.processIdentifier }
            return a.window.title < b.window.title
        }
        func isFrontAppWindow(_ entry: SwitcherEntry) -> Bool {
            entry.app.processIdentifier == session.frontPID && !entry.app.isHidden &&
                !entry.window.isMinimized && entry.window.isOnCurrentSpace
        }
        var current = session.entries.firstIndex { isFrontAppWindow($0) && $0.window.isMain }
        if current == nil, let frontPID = session.frontPID {
            // 有些应用不标记主窗口。可见层级仅用于辨认当前窗口，其他窗口保留自己的使用顺序。
            let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let candidates = session.entries.indices.filter { isFrontAppWindow(session.entries[$0]) }
            for info in visible where info[kCGWindowOwnerPID as String] as? pid_t == frontPID {
                if let id = info[kCGWindowNumber as String] as? CGWindowID,
                   let match = candidates.first(where: { session.entries[$0].window.id == id }) {
                    current = match
                    break
                }
            }
        }
        if let current {
            let entry = session.entries.remove(at: current)
            history.note(entry.key)
            session.entries.insert(entry, at: 0)
            session.hasCurrent = true
        }
    }

    private func update(_ session: Session) {
        guard session.remaining == 0 else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == session.frontPID else { dismiss(); return }
        if session.released {
            if let index = session.selected { pick(index) } else { dismiss() }
        } else if let screen = session.screen {
            if panel == nil {
                panel = SwitcherPanel()
                panel?.onPick = { [weak self] index in self?.pick(index) }
            }
            if let index = session.selected {
                panel?.present(session.entries, selected: index, on: screen, appBadges: session.appBadges)
            } else {
                panel?.showEmpty(on: screen)
            }
        }
    }

    private func pick(_ index: Int) {
        guard let session, session.entries.indices.contains(index) else { return }
        let entry = session.entries[index]
        dismiss()
        WindowIndex.actions.async {
            // 卡片展示期间窗口可能已经关闭或改变了最小化状态。提交前只复核选中的这扇。
            guard !entry.app.isTerminated, entry.window.element.string(kAXRoleAttribute) == kAXWindowRole else { return }
            let minimized = entry.window.element.bool(kAXMinimizedAttribute) ?? entry.window.isMinimized
            WindowIndex.focus(entry.window.with(minimized: minimized), of: entry.app)
        }
    }

    private func dismiss() {
        if let session { shortcut?.end(session.gesture) }
        session = nil
        workers.cancelAllOperations()
        panel?.dismiss()
    }
}
