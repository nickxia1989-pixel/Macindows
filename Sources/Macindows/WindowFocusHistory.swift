import AppKit

/// 窗口号不可用时，仍可用辅助功能元素识别同一扇窗口。
enum SwitcherWindowKey: Hashable {
    case application(pid_t)
    case numbered(pid_t, CGWindowID)
    case element(AXUIElement)

    init(pid: pid_t, element: AXUIElement, id: CGWindowID?) {
        self = id.map { .numbered(pid, $0) } ?? .element(element)
    }
}

/// 只订阅前台应用的焦点变化。向应用读取焦点和安装 AX 通知都在后台，使用记录仅存在内存里。
final class WindowFocusHistory {
    var onFocus: ((SwitcherWindowKey) -> Void)?
    private let queue = DispatchQueue(label: "macindows.switcher-focus", qos: .userInitiated)
    private var activation: NSObjectProtocol?
    private var observer: AXObserver?
    private var generation = 0
    private var pid: pid_t?
    private var recent: [SwitcherWindowKey] = []

    func start() {
        guard activation == nil else { return }
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { [weak self] note in
            self?.follow(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        follow(NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        follow(nil)
        recent.removeAll()
    }

    private func follow(_ app: NSRunningApplication?) {
        generation += 1
        let current = generation
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        pid = nil
        guard let app, app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        self.pid = pid
        // 关掉最后一扇窗口后，应用卡片沿用这次激活的顺序。
        note(.application(pid))
        queue.async { [weak self] in
            guard let self else { return }
            let application = AXUIElementCreateApplication(pid)
            let callback: AXObserverCallback = { _, element, _, context in
                guard let context else { return }
                Unmanaged<WindowFocusHistory>.fromOpaque(context).takeUnretainedValue().focusChanged(element)
            }
            var created: AXObserver?
            var subscribed: AXObserver?
            if AXObserverCreate(pid, callback, &created) == .success, let created,
               AXObserverAddNotification(created, application, kAXFocusedWindowChangedNotification as CFString,
                                         Unmanaged.passUnretained(self).toOpaque()) == .success {
                subscribed = created
            }
            let subscription = subscribed
            let key = self.focusedKey(in: application, pid: pid)
            DispatchQueue.main.async {
                guard self.generation == current else { return }
                if let key { self.note(key) }
                self.observer = subscription
                if let subscription { CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(subscription), .commonModes) }
            }
        }
    }

    private func focusChanged(_ element: AXUIElement) {
        guard let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        let current = generation
        queue.async { [weak self] in
            guard let self else { return }
            let key: SwitcherWindowKey?
            if element.string(kAXRoleAttribute) == kAXWindowRole {
                guard element.bool(kAXMinimizedAttribute) != true else { return }
                key = SwitcherWindowKey(pid: pid, element: element, id: PrivateAPI.windowID(of: element))
            } else {
                key = self.focusedKey(in: AXUIElementCreateApplication(pid), pid: pid)
            }
            guard let key else { return }
            DispatchQueue.main.async {
                if self.generation == current { self.note(key) }
            }
        }
    }

    private func focusedKey(in application: AXUIElement, pid: pid_t) -> SwitcherWindowKey? {
        guard let window = application.element(kAXFocusedWindowAttribute), window.bool(kAXMinimizedAttribute) != true else { return nil }
        return SwitcherWindowKey(pid: pid, element: window, id: PrivateAPI.windowID(of: window))
    }

    func note(_ key: SwitcherWindowKey) {
        guard recent.first != key else { return }
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        onFocus?(key)
        // 长时间开着切换器却没有再次呼出时，也不会一直保留已关闭窗口的引用。
        if recent.count > 4096 { recent.removeLast() }
    }

    var ranks: [SwitcherWindowKey: Int] {
        var ranks: [SwitcherWindowKey: Int] = [:]
        for (rank, key) in recent.enumerated() {
            if ranks[key] == nil { ranks[key] = rank }
            if case .numbered(let pid, _) = key, ranks[.application(pid)] == nil {
                ranks[.application(pid)] = rank
            }
        }
        return ranks
    }
}
