import AppKit
import MacindowsCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hover = HoverController()
    private let interceptor = ClickInterceptor()
    private var onboarding: OnboardingWindowController?
    private var trustTimer: Timer?
    private var running = false
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.prepare()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        log("launch Macindows \(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        defaults.register(defaults: ["enabled": true, "thumbnails": false])
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
        interceptor.stop()
        hover.stop()
        Log.flush()
    }

    private func startServices() {
        guard !running else { return }
        running = true
        hover.isEnabled = defaults.bool(forKey: "enabled")
        hover.wantsThumbnails = defaults.bool(forKey: "thumbnails")
        hover.onDrag = { [weak self] in self?.interceptor.mouseDragged(to: $0) }
        hover.start()

        interceptor.decide = { [weak self] point in self?.decide(clickAt: point) ?? .passThrough }
        interceptor.onMouseDown = { [weak self] point in self?.hover.mouseDown(at: point, opensMenu: false) }
        // 开了缩略图却还没有屏幕录制权限（例如刚换了新的应用标识）：让系统弹出授权请求
        if hover.wantsThumbnails, !Thumbnailer.isAuthorized { Thumbnailer.requestAccess() }
        let tapped = interceptor.start()
        log("services started, click interception \(tapped ? "on" : "FAILED")")
    }

    /// 鼠标在程序坞上按下时：按规则决定截不截这次点击
    private func decide(clickAt point: CGPoint) -> ClickInterceptor.Decision {
        guard hover.isEnabled else { return .passThrough }
        hover.dock.refresh(maxAge: 1)
        guard hover.dock.contains(point), let item = hover.dock.item(at: point), item.isApplication else { return .passThrough }
        guard let app = item.runningApp, let snapshot = WindowIndex.snapshot(of: app) else {
            hover.dockClickPassedThrough()
            return .passThrough
        }
        let action = dockClickAction(for: snapshot.state)
        log("dock click \(item.title): windows=\(snapshot.windows.count) front=\(snapshot.isFrontmost) hidden=\(snapshot.isHidden) -> \(action)")
        switch action {
        case .passThrough:
            hover.dockClickPassedThrough()
            return .passThrough
        case .minimizeWindow:
            guard let window = snapshot.windows.first else { return .passThrough }
            return .intercept { [weak self] in
                self?.hover.hide()
                // 放到后台线程：窗口播放最小化动画期间，这一步可能迟迟不返回
                DispatchQueue.global(qos: .userInteractive).async { window.element.set(kAXMinimizedAttribute, kCFBooleanTrue) }
            }
        case .restoreWindow:
            guard let window = snapshot.windows.first else { return .passThrough }
            return .intercept { [weak self] in
                self?.hover.hide()
                DispatchQueue.global(qos: .userInteractive).async { WindowIndex.focus(window, of: app) }
            }
        case .showWindowList:
            return .intercept { [weak self] in self?.hover.showPinned(for: item, app: app) }
        }
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
        if defaults.bool(forKey: "thumbnails"), !Thumbnailer.isAuthorized {
            let hint = NSMenuItem(title: L("需要“屏幕录制”权限，授权后请重新打开 Macindows"), action: nil, keyEquivalent: "")
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
        hover.isEnabled = value
        log("enabled=\(value)")
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

    @objc private func revealLog() {
        Log.flush()
        NSWorkspace.shared.activateFileViewerSelecting([Log.url])
    }
}
