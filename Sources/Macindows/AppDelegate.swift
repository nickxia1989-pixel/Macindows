import AppKit
import MacindowsCore
import ServiceManagement
import os

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hover = HoverController()
    private let interceptor = ClickInterceptor()
    private var onboarding: OnboardingWindowController?
    private var trustTimer: Timer?
    private var healthTimer: Timer?
    private var running = false
    private let defaults = UserDefaults.standard
    /// 「启用」开关的一份副本，给点击监听的线程读
    private let enabled = OSAllocatedUnfairLock(initialState: true)
    /// 上一次点图标时替用户做的最小化或放回来（见 decide）。点击监听的线程和执行操作的队列都会碰它，所以加锁
    private let toggleLock = NSLock()
    private var lastToggle: Toggle?

    private struct Toggle {
        let pid: pid_t
        let window: AppWindow
        let minimized: Bool
        /// 到这个时刻之前，再点这个 App 就直接反过来做
        var until: TimeInterval
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.prepare()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        log("launch Macindows \(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        defaults.register(defaults: ["enabled": true, "thumbnails": false, "peek": true])
        buildStatusItem()

        if Accessibility.promptIfNeeded() {
            startServices()
        } else {
            log("accessibility not granted yet, showing onboarding")
            let controller = OnboardingWindowController()
            onboarding = controller
            controller.present()
            // 用户在系统设置里打开开关后无需重启，这里轮询到就开工
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, Accessibility.isTrusted else { return }
                self.trustTimer?.invalidate()
                self.trustTimer = nil
                self.onboarding?.markGranted()
                self.startServices()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("terminate")
        healthTimer?.invalidate()
        interceptor.stop()
        hover.stop()
        Log.flush()
    }

    private func startServices() {
        guard !running else { return }
        running = true
        Accessibility.limitWaiting()
        setEnabled(defaults.bool(forKey: "enabled"))
        hover.wantsThumbnails = defaults.bool(forKey: "thumbnails")
        hover.wantsPeek = defaults.bool(forKey: "peek")
        hover.start()

        interceptor.decide = { [weak self] point in self?.decide(clickAt: point) ?? .passThrough }
        interceptor.onMouseDown = { [weak self] point, isRightButton in self?.hover.mouseDown(at: point, opensMenu: isRightButton) }
        // 开了缩略图却还没有屏幕录制权限（例如刚换了新的应用标识）：让系统弹出授权请求
        if hover.wantsThumbnails, !Thumbnailer.isAuthorized { Thumbnailer.requestAccess() }
        let tapped = interceptor.start()
        let health = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.interceptor.reviveIfNeeded() }
        RunLoop.main.add(health, forMode: .common)
        healthTimer = health
        log("services started, click interception \(tapped ? "on" : "FAILED"), hover notifications \(hover.dock.isListening ? "on" : "FAILED"), glass: \(DockGlass.diagnosis)")
    }

    private func setEnabled(_ value: Bool) {
        hover.isEnabled = value
        enabled.withLock { $0 = value }
    }

    /// 鼠标左键在程序坞上按下时：按规则决定截不截这次点击。
    ///
    /// 这里跑在点击监听的线程上（见 ClickInterceptor），只碰可以跨线程的东西：开关的副本、程序坞的范围、
    /// 直接向程序坞和目标 App 问话。要动悬停窗的都丢回主线程。
    private func decide(clickAt point: CGPoint) -> ClickInterceptor.Decision {
        // 不在程序坞范围里的点击到此为止，不向任何进程问话
        guard enabled.withLock({ $0 }), hover.dock.contains(point) else {
            forgetToggle()
            return .passThrough
        }
        // 点的是哪个图标以程序坞自己说的为准；它的说法偶尔慢半拍，所以再核对一下位置
        guard let item = hover.dock.hoveredItem(), item.isApplication, hover.dock.isPoint(point, over: item), let app = item.runningApp else {
            forgetToggle()
            return .passThrough
        }
        // 刚替这个 App 最小化或者放回过它的窗口，用户又点了：是想反过来。窗口这时多半还在播放动画，
        // App 要么顾不上答话，要么报的还是动画开始前的样子，问它只会做错，所以直接照着上一次反过来做
        if let toggle = recentToggle(of: app.processIdentifier) {
            log("dock click \(item.title): right after \(toggle.minimized ? "minimizing" : "restoring") it -> \(toggle.minimized ? "restoreWindow" : "minimizeWindow")")
            return toggle.minimized ? restore(toggle.window, of: app) : minimize(toggle.window, of: app)
        }
        forgetToggle()
        guard let snapshot = WindowIndex.snapshot(of: app) else {
            log("dock click \(item.title): no answer -> passThrough")
            DispatchQueue.main.async { [weak self] in self?.hover.dismissAfterClick() }
            return .passThrough
        }
        let action = dockClickAction(for: snapshot.state)
        log("dock click \(item.title): windows=\(snapshot.windows.count) front=\(snapshot.isFrontmost) hidden=\(snapshot.isHidden) -> \(action)")
        switch action {
        case .passThrough:
            let reopening = snapshot.windows.isEmpty
            DispatchQueue.main.async { [weak self] in
                // 没有窗口的 App 被点了：程序坞会请它开一扇窗口，看看开出来的是什么样
                if reopening { self?.hover.noteReopen(of: app) }
                self?.hover.dismissAfterClick()
            }
            return .passThrough
        case .minimizeWindow:
            guard let window = snapshot.windows.first else { return .passThrough }
            return minimize(window, of: app)
        case .restoreWindow:
            guard let window = snapshot.windows.first else { return .passThrough }
            return restore(window, of: app)
        case .showWindowList:
            return .intercept { [weak self] in self?.hover.showPinned(for: item, app: app) }
        }
    }

    private func minimize(_ window: AppWindow, of app: NSRunningApplication) -> ClickInterceptor.Decision {
        .intercept { [weak self] in
            // 鼠标松开、真的要做了才记下（按住不放时这次点击会还给程序坞，什么也不做）
            self?.remember(window, of: app, minimized: true)
            self?.hover.dismissAfterClick()
            WindowIndex.actions.async {
                WindowIndex.minimize(window)
                self?.toggleDone(of: app.processIdentifier)
            }
        }
    }

    private func restore(_ window: AppWindow, of app: NSRunningApplication) -> ClickInterceptor.Decision {
        .intercept { [weak self] in
            // 鼠标松开、真的要做了才记下（按住不放时这次点击会还给程序坞，什么也不做）
            self?.remember(window, of: app, minimized: false)
            self?.hover.dismissAfterClick()
            WindowIndex.actions.async {
                WindowIndex.focus(window.with(minimized: true), of: app)
                self?.toggleDone(of: app.processIdentifier)
            }
        }
    }

    /// 最小化和放回来的动画都在半秒上下。从这次点击起 1.2 秒内、或者操作做完后 0.8 秒内再点，都算紧接着点的
    private func remember(_ window: AppWindow, of app: NSRunningApplication, minimized: Bool) {
        let toggle = Toggle(pid: app.processIdentifier, window: window, minimized: minimized, until: ProcessInfo.processInfo.systemUptime + 1.2)
        toggleLock.withLock { lastToggle = toggle }
    }

    private func toggleDone(of pid: pid_t) {
        let until = ProcessInfo.processInfo.systemUptime + 0.8
        toggleLock.withLock {
            guard var toggle = lastToggle, toggle.pid == pid else { return }
            toggle.until = max(toggle.until, until)
            lastToggle = toggle
        }
    }

    private func recentToggle(of pid: pid_t) -> Toggle? {
        toggleLock.withLock {
            guard let toggle = lastToggle, toggle.pid == pid, toggle.until > ProcessInfo.processInfo.systemUptime else { return nil }
            return toggle
        }
    }

    /// 点了别处，上一次的就不再算数
    private func forgetToggle() {
        toggleLock.withLock { lastToggle = nil }
    }

    // MARK: 菜单栏

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let trusted = Accessibility.isTrusted

        let enabled = NSMenuItem(title: L("启用 Macindows"), action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = defaults.bool(forKey: "enabled") ? .on : .off
        menu.addItem(enabled)

        let thumbnails = NSMenuItem(title: L("显示窗口缩略图"), action: #selector(toggleThumbnails), keyEquivalent: "")
        thumbnails.target = self
        thumbnails.state = defaults.bool(forKey: "thumbnails") ? .on : .off
        menu.addItem(thumbnails)
        if defaults.bool(forKey: "thumbnails"), Thumbnailer.isAuthorized {
            let peek = NSMenuItem(title: L("停在缩略图上时预览整个窗口"), action: #selector(togglePeek), keyEquivalent: "")
            peek.target = self
            peek.state = defaults.bool(forKey: "peek") ? .on : .off
            peek.indentationLevel = 1
            menu.addItem(peek)
        }
        if defaults.bool(forKey: "thumbnails"), !Thumbnailer.isAuthorized {
            let grant = NSMenuItem(title: L("需要“录屏与系统录音”权限，点此打开系统设置"), action: #selector(openScreenRecordingSettings), keyEquivalent: "")
            grant.target = self
            grant.indentationLevel = 1
            menu.addItem(grant)
            let hint = NSMenuItem(title: L("授权后请重新打开 Macindows"), action: nil, keyEquivalent: "")
            hint.indentationLevel = 1
            hint.isEnabled = false
            menu.addItem(hint)
        }

        let login = NSMenuItem(title: L("登录时自动启动"), action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let access = NSMenuItem(title: trusted ? L("辅助功能权限：已授权") : L("辅助功能权限：未授权，点此打开系统设置"),
                                action: trusted ? nil : #selector(openAccessibilitySettings), keyEquivalent: "")
        access.target = self
        access.isEnabled = !trusted
        menu.addItem(access)
        if trusted, running, !interceptor.isRunning {
            let hint = NSMenuItem(title: L("点击拦截未能启动，请重新打开 Macindows"), action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }

        let logItem = NSMenuItem(title: L("在访达中显示日志"), action: #selector(revealLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("退出 Macindows"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleEnabled() {
        let value = !defaults.bool(forKey: "enabled")
        defaults.set(value, forKey: "enabled")
        setEnabled(value)
        log("enabled=\(value)")
    }

    @objc private func togglePeek() {
        let value = !defaults.bool(forKey: "peek")
        defaults.set(value, forKey: "peek")
        hover.wantsPeek = value
        log("peek=\(value)")
    }

    @objc private func toggleThumbnails() {
        let value = !defaults.bool(forKey: "thumbnails")
        defaults.set(value, forKey: "thumbnails")
        hover.wantsThumbnails = value
        log("thumbnails=\(value) authorized=\(Thumbnailer.isAuthorized)")
        if value, !Thumbnailer.isAuthorized { Thumbnailer.requestAccess() }
    }

    /// 把 Macindows 自己登记为（或撤销）登录项。登记的是当前这个 App 所在的位置，挪动 App 后需要重新勾选。
    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
            log("login item status=\(service.status.rawValue)")
        } catch {
            log("login item change failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = L("无法更改登录时自动启动")
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openAccessibilitySettings() { Accessibility.openSettings() }

    @objc private func openScreenRecordingSettings() { Thumbnailer.openSettings() }

    @objc private func revealLog() {
        Log.flush()
        NSWorkspace.shared.activateFileViewerSelecting([Log.url])
    }
}
