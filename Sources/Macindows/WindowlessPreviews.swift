import AppKit
import ApplicationServices

/// 在运行但没有窗口的 App：悬停时那张卡片里放什么画面，以及怎么学到 App 新开的窗口长什么样。
///
/// 卡片里放的是点了以后会出来的那扇窗口，看上去就像它还开着：
/// App 关窗口时只是把它藏起来的，用那扇窗口最后的样子（窗口服务器一直留着）；
/// App 每次都开一扇新的，用它上一次新开的那扇（见 noteReopen）；都不知道时是一扇空白的窗口。
/// 学到的画面只存在内存里。
final class WindowlessPreviews {
    /// 各个 App 上一次「重新打开」时新开出来的那扇窗口的画面和标题，键是 App 的标识
    private var learned: [String: (image: NSImage, title: String)] = [:]
    /// 留着的窗口点了之后并没有回来的 App：以后不再拿留着的窗口当预览
    private var keptMisleads: Set<String> = []
    /// 卡片上此刻放着的那扇留着的窗口，键是 App 的标识
    private var shownKept: [String: CGWindowID] = [:]
    private var watch: Watch?

    private final class Watch {
        let app: NSRunningApplication
        let key: String
        /// 用户点下去的那一刻，这个 App 留着的窗口
        let kept: Set<CGWindowID>
        /// 卡片上放着的那扇留着的窗口
        let shown: CGWindowID?
        let started = ProcessInfo.processInfo.systemUptime
        var observer: AXObserver?
        var poll: Timer?
        var timers: [Timer] = []
        /// 新开的那扇窗口（找到之后）
        var window: AppWindow?
        var finished = false

        init(app: NSRunningApplication, key: String, kept: Set<CGWindowID>, shown: CGWindowID?) {
            self.app = app
            self.key = key
            self.kept = kept
            self.shown = shown
        }
    }

    private static func key(of app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? app.bundleURL?.path ?? "pid \(app.processIdentifier)"
    }

    /// 卡片的内容。enabled 为假（没开缩略图，也就没有屏幕录制权限）时总是空白的窗口。第二个返回值只用于日志
    func entry(for item: DockItem, app: NSRunningApplication, enabled: Bool) -> (PreviewEntry, String) {
        let name = app.localizedName ?? item.title
        let blank = PreviewEntry(title: name, aspect: nil, thumbnail: nil, isPlaceholder: true)
        guard enabled else { return (blank, "blank") }
        let key = Self.key(of: app)
        if !keptMisleads.contains(key), let kept = WindowIndex.keptWindows(of: app).first, let image = PrivateAPI.captureWindow(kept.id) {
            shownKept[key] = kept.id
            let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            return (PreviewEntry(title: kept.title, aspect: nil, thumbnail: picture, isPlaceholder: true), "kept window")
        }
        shownKept[key] = nil
        if let learned = learned[key] {
            return (PreviewEntry(title: learned.title, aspect: nil, thumbnail: learned.image, isPlaceholder: true), "learned new window")
        }
        return (blank, "blank")
    }

    // MARK: 学新开的窗口

    /// 用户让一个没有窗口的 App 开窗口了（点了它在程序坞里的图标，或者点了那张卡片）。看接下来出来的是哪扇窗口：
    /// 是卡片上那扇留着的窗口，说明预览没错；是一扇新开的，就截下它刚打开时的样子，下次悬停这个 App 时用。
    /// 留着的窗口点了却没回来，以后这个 App 就不再拿留着的窗口当预览。
    /// 点图标时这里在鼠标按下的那一刻就被调用，程序坞要等松开才去叫 App，所以记下的「留着的窗口」还没被拿出来。
    func noteReopen(of app: NSRunningApplication, enabled: Bool) {
        guard enabled else { return }
        end()
        let key = Self.key(of: app)
        let current = Watch(app: app, key: key, kept: Set(WindowIndex.keptWindows(of: app).map(\.id)), shown: shownKept[key])
        watch = current
        // 窗口开出来时 App 会发通知，收到就马上看；有的 App 不发，再每 0.1 秒问一次兜底
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, name, context in
            guard let context else { return }
            Unmanaged<WindowlessPreviews>.fromOpaque(context).takeUnretainedValue().handleEvent(name as String)
        }
        if AXObserverCreate(app.processIdentifier, callback, &observer) == .success, let observer {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            for name in [kAXWindowCreatedNotification, kAXMainWindowChangedNotification, kAXFocusedWindowChangedNotification] {
                AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            current.observer = observer
        }
        current.poll = repeating(0.1) { [weak self] in self?.lookForWindow() }
    }

    private func handleEvent(_ name: String) {
        guard let watch else { return }
        if watch.window == nil {
            lookForWindow()
        } else if name == kAXWindowMiniaturizedNotification || name == kAXUIElementDestroyedNotification {
            windowEvent()
        }
    }

    private func lookForWindow() {
        guard let watch, watch.window == nil else { return }
        guard !watch.app.isTerminated, ProcessInfo.processInfo.systemUptime - watch.started < 3 else {
            end()
            return
        }
        guard let window = WindowIndex.snapshot(of: watch.app)?.windows.first(where: { $0.isOnCurrentSpace && !$0.isMinimized }),
              let id = window.id else { return }
        watch.poll?.invalidate()
        let name = watch.app.localizedName ?? "?"
        if id == watch.shown {
            end()
            return
        }
        // 留着的窗口里有一扇回来了（卡片上放的不是它，或者用户没等卡片出来就点了）：这个 App 不是每次新开的那种，没什么可学
        if watch.kept.contains(id) {
            if watch.shown != nil { mislead(watch.key, name) }
            end()
            return
        }
        // 开出来的是一扇新的：留着的那些窗口点了不会回来，拿它们当预览只会误导
        if !watch.kept.isEmpty { mislead(watch.key, name) }
        learn(window, id: id, in: watch)
    }

    /// 截下新窗口刚打开时的样子。这一步时机很微妙：用户可能一打开就把它最小化或者关掉。
    /// 实测这两个过程里窗口都不是「正常」的样子——最小化时窗口被扭曲着缩向程序坞，位置大小每一帧都在变；
    /// 关闭时它一边变淡一边略微缩小——这时截到的就是变了形、半透明的画面。所以：
    /// 先在开窗动画结束后尽早截一张，再到 0.8 秒、网页之类的内容多半已经加载出来时截一张替换它；
    /// 每张截之前确认窗口静止、不透明，截完再确认一遍，中途变了就作废，留着上一张合格的。
    /// 窗口被最小化之后，窗口服务器还留着它最小化之前的完整画面，这时直接要那一张。
    private func learn(_ window: AppWindow, id: CGWindowID, in watch: Watch) {
        watch.window = window
        if let observer = watch.observer {
            for name in [kAXWindowMiniaturizedNotification, kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(observer, window.element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        for delay in [0.25, 0.8] {
            watch.timers.append(once(delay) { [weak self, weak watch] in
                guard let self, let watch, !watch.finished else { return }
                Task { @MainActor in await self.capture(id, in: watch, last: delay == 0.8) }
            })
        }
        // 用户什么都没做的话 3 秒后收工；最小化、关掉的话由事件提前收工
        watch.timers.append(once(3) { [weak self, weak watch] in
            guard let watch, self?.watch === watch else { return }
            self?.end()
        })
    }

    @MainActor
    private func capture(_ id: CGWindowID, in watch: Watch, last: Bool) async {
        let name = watch.app.localizedName ?? "?"
        // 静止：隔 40 毫秒读两次，位置大小一样，并且不透明
        guard let first = Self.steadyFrame(of: id) else { return log("new window of \(name) is not steady yet, no picture this time") }
        try? await Task.sleep(nanoseconds: 40_000_000)
        guard Self.steadyFrame(of: id) == first, !watch.finished else { return log("new window of \(name) started to change, no picture this time") }
        guard let image = await Thumbnailer.capture(windowIDs: [id])[id] else { return }
        guard Self.steadyFrame(of: id) == first, !watch.finished else { return log("new window of \(name) changed while being captured, picture dropped") }
        keep(image, for: watch, how: last ? "after it loaded" : "right after it opened")
        if last, self.watch === watch { end() }
    }

    /// 窗口此刻的位置大小，前提是它在屏幕上、完全不透明；否则（正在最小化、正在关闭、已经不在了）为 nil
    private static func steadyFrame(of id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true, (info[kCGWindowAlpha as String] as? Double ?? 0) >= 0.99,
              let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return nil }
        return bounds
    }

    /// 新窗口那边有事：被最小化了，或者被关掉了
    private func windowEvent() {
        guard let watch, let window = watch.window, let id = window.id else { return }
        let name = watch.app.localizedName ?? "?"
        if window.element.bool(kAXMinimizedAttribute) == true {
            // 最小化动画已经结束：窗口服务器留着它最小化之前的完整画面
            if let image = PrivateAPI.captureWindow(id) {
                keep(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), for: watch, how: "from before it was minimized")
            }
        } else {
            log("new window of \(name) was closed")
        }
        end()
    }

    private func keep(_ image: NSImage, for watch: Watch, how: String) {
        if learned.count > 40 { learned.removeAll() }
        learned[watch.key] = (image, watch.window?.title ?? (watch.app.localizedName ?? ""))
        log("learned how a new window of \(watch.app.localizedName ?? "?") looks, \(how) (\(Int(image.size.width))x\(Int(image.size.height)))")
    }

    private func mislead(_ key: String, _ name: String) {
        guard keptMisleads.insert(key).inserted else { return }
        log("kept window of \(name) did not come back, using new-window previews for it from now on")
    }

    private func end() {
        guard let watch else { return }
        watch.finished = true
        watch.poll?.invalidate()
        watch.timers.forEach { $0.invalidate() }
        if let observer = watch.observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        self.watch = nil
    }

    private func once(_ delay: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func repeating(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
