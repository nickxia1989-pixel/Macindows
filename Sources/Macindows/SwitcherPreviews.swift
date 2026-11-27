import AppKit
import MacindowsCore

/// 每次手势只准备当前页。缓存随切换器开关存活，不保存到磁盘。
@MainActor
final class SwitcherPreviews {
    struct Window: Hashable {
        let pid: pid_t
        let id: CGWindowID

        var cacheKey: NSNumber {
            NSNumber(value: UInt64(UInt32(bitPattern: pid)) << 32 | UInt64(id))
        }
    }

    typealias Images = [CGWindowID: NSImage]
    private let cache: SharedPreviewCache
    private var inFlight: [Window: Task<NSImage?, Never>] = [:]
    private var observations: [pid_t: SwitcherWindowObservation] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var focused: Window?
    private var checkpoint: Task<Void, Never>?
    private var warmup: Task<Void, Never>?
    private var capture: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var page: [Window]?
    private var images: Images = [:]
    private var firstFrame: ((Images) -> Void)?
    private var stopped = false

    init(cache: SharedPreviewCache = SharedPreviewCache()) {
        self.cache = cache
    }

    /// 开启功能时预热普通应用的窗口。逐扇进行，用户正在呼出的页面可以优先取图。
    func warm() {
        let workspace = NSWorkspace.shared
        let regular = workspace.runningApplications.filter { $0.activationPolicy == .regular }
        for app in regular { observe(app, warmExisting: false) }
        let center = workspace.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.didLaunchApplicationNotification { self.observe(app) }
                    else if self.observations[app.processIdentifier]?.app == app {
                        self.observations.removeValue(forKey: app.processIdentifier)?.stop()
                    }
                }
            })
        }
        guard Thumbnailer.isAuthorized else { return }
        let apps = Set(regular.map(\.processIdentifier))
        warmup = Task { [weak self] in
            let windows = await Task.detached(priority: .utility) {
                let info = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID) as? [[String: Any]] ?? []
                return info.compactMap { entry -> Window? in
                    guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, apps.contains(pid),
                          entry[kCGWindowLayer as String] as? Int == 0,
                          let id = entry[kCGWindowNumber as String] as? CGWindowID,
                          let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                          let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                          frame.width >= minimumListableWindowSize.width, frame.height >= minimumListableWindowSize.height else { return nil }
                    return Window(pid: pid, id: id)
                }
            }.value
            for window in windows.prefix(64) {
                guard !Task.isCancelled, let self else { return }
                _ = await self.fastImage(for: window)
            }
        }
    }

    private func observe(_ app: NSRunningApplication, warmExisting: Bool = true) {
        guard !stopped, app.activationPolicy == .regular, !app.isTerminated, Thumbnailer.isAuthorized else { return }
        let pid = app.processIdentifier
        guard observations[pid]?.app != app else { return }
        observations[pid]?.stop()
        observations[pid] = SwitcherWindowObservation(app: app, warmExisting: warmExisting, cachedImage: { [weak self] id in
            self?.cache.image(for: pid, id: id)
        }) { [weak self] id in
            Task { [weak self] in _ = await self?.fastImage(for: Window(pid: pid, id: id)) }
        }
    }

    func preview(for snapshot: AppSnapshot) -> NSImage? {
        let app = snapshot.app
        guard Thumbnailer.isAuthorized else { clearImages(); return nil }
        observe(app)
        guard let watch = observations[app.processIdentifier] else { return nil }
        watch.saw(snapshot.windows)
        return snapshot.windows.isEmpty ? watch.lastPreview.image : nil
    }

    /// 供程序坞悬停窗在无窗口卡片里复用最后关闭那扇窗口的画面。
    func lastClosedPreview(for app: NSRunningApplication) -> NSImage? {
        guard Thumbnailer.isAuthorized else { return nil }
        return observations[app.processIdentifier]?.lastPreview.image
    }

    private func store(_ image: NSImage, for window: Window, cost: Int) {
        cache.set(image, for: window.pid, id: window.id, cost: cost)
        observations[window.pid]?.captured(image, for: window.id)
    }

    private func clearImages() {
        cache.removeAll()
        for observation in observations.values { observation.clearPreview() }
    }

    /// 焦点切换时更新画面。编辑期间只更新正在使用的那一扇，关闭后继续使用最后成功取得的图。
    func focus(_ window: Window?) {
        guard !stopped, focused != window else { return }
        focused = window
        checkpoint?.cancel()
        guard let window, Thumbnailer.isAuthorized else { return }
        checkpoint = Task { [weak self] in
            _ = await self?.fastImage(for: window, refresh: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, self != nil, Thumbnailer.isAuthorized,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else { return }
                // 没有键鼠操作时不反复截取同一画面。
                let recentlyUsed = [CGEventType.keyDown, .leftMouseDown, .scrollWheel].contains {
                    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < 3.5
                }
                if recentlyUsed, await self?.fastImage(for: window, refresh: true) == nil { return }
            }
        }
    }

    /// 窗口服务通常已有合成好的画面，最小化时也能读取。预热与当前页共用进行中的请求。
    /// 按屏幕原生分辨率抓取再缩到 1024px，与 capturePage 的 Retina 清晰度保持一致，避免先糊后清。
    private func fastImage(for window: Window, refresh: Bool = false) async -> NSImage? {
        guard !stopped, !Task.isCancelled else { return nil }
        if !refresh, let image = cache.image(for: window.pid, id: window.id) { return image }
        if let task = inFlight[window] { return await task.value }
        let task = Task { [weak self] () -> NSImage? in
            let raw = await Task.detached(priority: Task.currentPriority) {
                Thumbnailer.windowServerThumbnail(window.id, longestSide: 1024, highResolution: true)
            }.value
            guard let self, let raw, !Task.isCancelled, Thumbnailer.isAuthorized else { return nil }
            let image = NSImage(cgImage: raw, size: NSSize(width: raw.width, height: raw.height))
            self.store(image, for: window, cost: raw.bytesPerRow * raw.height)
            return image
        }
        inFlight[window] = task
        let result = await task.value
        inFlight[window] = nil
        return result
    }

    func present(_ windows: [Window], maxSize: CGFloat, draw: @escaping (Images) -> Void,
                 refresh: @escaping (Images) -> Void) {
        let authorized = Thumbnailer.isAuthorized
        guard authorized, !windows.isEmpty else {
            if !authorized { clearImages() }
            endPage()
            draw([:])
            return
        }
        if page == windows {
            if firstFrame == nil { draw(images) } else { firstFrame = draw }
            return
        }
        endPage()
        page = windows
        firstFrame = draw
        for window in windows { images[window.id] = cache.image(for: window.pid, id: window.id) }
        let missing = windows.filter { images[$0.id] == nil }
        if missing.isEmpty {
            showFirstFrame()
        } else {
            // 单扇窗口不应无限拖住面板。到期仍无画面时使用应用图标，快捷切换本身始终可以立即提交。
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                if !Task.isCancelled { self?.showFirstFrame() }
            }
        }
        capture = Task { [weak self] in
            guard let self else { return }
            var fresh = Set<Window>()
            for start in stride(from: 0, to: missing.count, by: 4) {
                guard !Task.isCancelled else { return }
                let batch = missing[start..<min(start + 4, missing.count)]
                await withTaskGroup(of: (Window, NSImage?).self) { group in
                    for window in batch { group.addTask { (window, await self.fastImage(for: window)) } }
                    for await (window, image) in group {
                        guard !Task.isCancelled, let image else { continue }
                        fresh.insert(window)
                        self.images[window.id] = image
                        if self.firstFrame == nil { refresh([window.id: image]) }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            if missing.allSatisfy({ fresh.contains($0) }) { self.showFirstFrame() }

            // 已有首帧的窗口更新内容；窗口服务没给画面的再用公开截屏接口补一次。
            let remaining = windows.filter { !fresh.contains($0) }
            let keys = Dictionary(remaining.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            await Thumbnailer.capturePage(windowIDs: remaining.map(\.id), maxPixelSize: min(512, maxSize)) { batch in
                guard !Task.isCancelled, Thumbnailer.isAuthorized else { return }
                for (id, image) in batch {
                    guard let window = keys[id], let rep = image.representations.first else { continue }
                    self.store(image, for: window, cost: max(1, rep.pixelsWide * rep.pixelsHigh * 4))
                    self.images[id] = image
                }
                if self.firstFrame == nil { refresh(batch) }
                else if self.images.count == windows.count { self.showFirstFrame() }
            }
            if !Task.isCancelled { self.showFirstFrame() }
        }
    }

    private func showFirstFrame() {
        guard let draw = firstFrame else { return }
        firstFrame = nil
        deadline?.cancel()
        deadline = nil
        if !Thumbnailer.isAuthorized {
            images.removeAll()
            clearImages()
        }
        draw(images)
    }

    func endPage() {
        capture?.cancel()
        deadline?.cancel()
        capture = nil
        deadline = nil
        page = nil
        firstFrame = nil
        images.removeAll()
    }

    func stop() {
        stopped = true
        checkpoint?.cancel()
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceObservers.removeAll()
        for observation in observations.values { observation.stop() }
        observations.removeAll()
        endPage()
        warmup?.cancel()
        warmup = nil
        for task in inFlight.values { task.cancel() }
    }
}
