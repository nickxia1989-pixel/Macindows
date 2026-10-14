import AppKit
import MacindowsCore

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
        var name: String { app.localizedName ?? "?" }
        /// 用户点下去的那一刻，这个 App 已有的全部窗口（包括留着的、隐形的）。之后出现在屏幕上、又不在其中的，才是新开的
        let before: Set<CGWindowID>
        /// 其中留着的那些（见 isKeptWindow）
        let kept: Set<CGWindowID>
        /// 卡片上放着的那扇留着的窗口
        let shown: CGWindowID?
        let started = ProcessInfo.processInfo.systemUptime
        var timers: [Timer] = []
        /// 新开的那扇窗口（找到之后）
        var window: CGWindowID?
        var title = ""
        /// 它最近一次静止时的位置大小
        var frame: CGRect?
        /// 它已经离开屏幕，正在要它的画面
        var leaving = false
        var finished = false

        init(app: NSRunningApplication, key: String, before: Set<CGWindowID>, kept: Set<CGWindowID>, shown: CGWindowID?) {
            self.app = app
            self.key = key
            self.before = before
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
            return (PreviewEntry(title: kept.title, aspect: nil, thumbnail: Self.picture(image), isPlaceholder: true), "kept window")
        }
        shownKept[key] = nil
        if let learned = learned[key] {
            return (PreviewEntry(title: learned.title, aspect: nil, thumbnail: learned.image, isPlaceholder: true), "learned new window")
        }
        return (blank, "blank")
    }

    // MARK: 学新开的窗口
    //
    // 整个过程只看窗口服务器那边的信息、只向窗口服务器要画面，不向 App 问话：App 开窗口的那一阵子往往正忙，
    // 问它要等上好几百毫秒，甚至因此被当成卡住而暂时不再理它，以前时常学不到图就是这个原因。

    /// 用户让一个没有窗口的 App 开窗口了（点了它在程序坞里的图标，或者点了那张卡片）。看接下来出来的是哪扇窗口：
    /// 是卡片上那扇留着的窗口，说明预览没错；是一扇新开的，就截下它刚打开时的样子，下次悬停这个 App 时用。
    /// 留着的窗口点了却没回来，以后这个 App 就不再拿留着的窗口当预览。
    /// 点图标时这里在鼠标按下的那一刻就被调用，程序坞要等松开才去叫 App，所以这时记下的窗口里还没有新开的那扇。
    func noteReopen(of app: NSRunningApplication, enabled: Bool) {
        guard enabled else { return }
        end()
        let key = Self.key(of: app)
        let pid = app.processIdentifier
        let all = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let before = Set(all.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }.compactMap { ($0[kCGWindowNumber as String] as? Int).map(CGWindowID.init) })
        let current = Watch(app: app, key: key, before: before, kept: Set(WindowIndex.keptWindows(of: app).map(\.id)), shown: shownKept[key])
        watch = current
        log("watching \(current.name) for the window it opens")
        current.timers.append(repeating(0.08) { [weak self] in self?.lookForWindow() })
    }

    private func lookForWindow() {
        guard let watch, watch.window == nil else { return }
        guard !watch.app.isTerminated, ProcessInfo.processInfo.systemUptime - watch.started < 4 else {
            log("\(watch.name) did not open a window")
            return end()
        }
        guard let found = Self.onScreenWindows(of: watch.app.processIdentifier).first else { return }
        if found.id == watch.shown {
            log("kept window of \(watch.name) came back as shown")
            return end()
        }
        // 一扇原来就有的窗口回到了屏幕上（留着的，或者别的藏着的）：这个 App 不是每次新开的那种，没什么可学
        if watch.before.contains(found.id) {
            if watch.shown != nil { mislead(watch) }
            log("an existing window of \(watch.name) came back")
            return end()
        }
        // 开出来的是一扇新的：留着的那些窗口点了不会回来，拿它们当预览只会误导
        if !watch.kept.isEmpty { mislead(watch) }
        log("new window of \(watch.name) appeared")
        learn(found.id, title: found.title, frame: found.frame, in: watch)
    }

    /// 截下新窗口刚打开时的样子。这一步时机很微妙：用户可能一打开就把它最小化或者关掉。
    /// 实测这两个过程里窗口都不是「正常」的样子——最小化时窗口被扭曲着缩向程序坞，位置大小每一帧都在变，
    /// 最后几帧缩成和程序坞图标一样大；关闭时它一边变淡一边略微缩小——这时截到的就是变了形、半透明的画面。所以：
    /// 先在开窗动画结束后尽早截一张，再到 0.8 秒、网页之类的内容多半已经加载出来时截一张替换它；
    /// 每张截之前确认窗口静止、不透明，截完再确认一遍，中途变了就作废，留着上一张合格的。
    /// 窗口被收起来以后（最小化、隐藏），窗口服务器还留着它完整的画面，这时再要一张，见 left。
    private func learn(_ id: CGWindowID, title: String, frame: CGRect, in watch: Watch) {
        watch.window = id
        watch.title = title.isEmpty ? watch.name : title
        watch.frame = frame
        var seen: CGRect?
        for delay in [0.25, 0.8] {
            watch.timers.append(once(delay) { [weak self, weak watch] in
                guard let self, let watch, !watch.finished, !watch.leaving else { return }
                self.attempt(id, in: watch, last: delay == 0.8)
            })
        }
        // 盯着它：记下静止时的大小（隔 0.1 秒两次一样才算，最小化动画里每一帧都不同），看它有没有离开屏幕
        watch.timers.append(repeating(0.1) { [weak self, weak watch] in
            guard let self, let watch, !watch.finished, !watch.leaving else { return }
            if let frame = Self.steadyFrame(of: id) {
                if frame == seen, frame.width >= minimumListableWindowSize.width, frame.height >= minimumListableWindowSize.height { watch.frame = frame }
                seen = frame
            } else if Self.hasLeftScreen(id) {
                watch.leaving = true
                self.left(id, in: watch, tries: 0)
            }
        })
        // 用户什么都没做的话 3 秒后收工
        watch.timers.append(once(3) { [weak self, weak watch] in
            guard let watch, self?.watch === watch, !watch.leaving else { return }
            self?.end()
        })
    }

    /// 截一张。先隔 40 毫秒读两次窗口的位置大小，一样并且不透明才截，截完再读一次，还是一样才算数
    private func attempt(_ id: CGWindowID, in watch: Watch, last: Bool) {
        guard let first = Self.steadyFrame(of: id) else { return log("new window of \(watch.name) is moving, skipped a picture") }
        watch.timers.append(once(0.04) { [weak self, weak watch] in
            guard let self, let watch, !watch.finished, !watch.leaving else { return }
            guard Self.steadyFrame(of: id) == first else { return log("new window of \(watch.name) started to change, skipped a picture") }
            guard let image = PrivateAPI.captureWindow(id), Self.image(image, fits: first) else { return log("could not capture the new window of \(watch.name)") }
            guard Self.steadyFrame(of: id) == first else { return log("new window of \(watch.name) changed while being captured, dropped the picture") }
            watch.frame = first
            self.keep(Self.picture(image), for: watch, how: last ? "after it loaded" : "right after it opened")
            if last { self.end() }
        })
    }

    /// 新窗口离开了屏幕。被收起来的（最小化、隐藏，或者 App 关窗口时只是藏起来），窗口服务器还留着它完整的画面，要一张；
    /// 要到的要是和窗口大小对不上（还在动画的最后几帧），隔一会儿再要，最多一秒。
    /// 真关掉的不要：它淡出时画面已经清空了，截到的是一片白，留着之前截好的那张。
    private func left(_ id: CGWindowID, in watch: Watch, tries: Int) {
        guard !watch.finished else { return }
        switch Self.whereabouts(of: id) {
        case .gone:
            log("new window of \(watch.name) was closed")
            return end()
        case .tuckedAway:
            if let image = PrivateAPI.captureWindow(id), let frame = watch.frame, Self.image(image, fits: frame) {
                keep(Self.picture(image), for: watch, how: "after it was minimized or hidden")
                return end()
            }
        case .leaving:
            break
        }
        guard tries < 10 else {
            log("new window of \(watch.name) left the screen, no picture of it matched its size")
            return end()
        }
        watch.timers.append(once(0.1) { [weak self, weak watch] in
            guard let self, let watch else { return }
            self.left(id, in: watch, tries: tries + 1)
        })
    }

    private enum Whereabouts {
        /// 已经没了
        case gone
        /// 不在屏幕上、但还在：最小化了、被隐藏了，或者关窗口时 App 只是把它藏起来
        case tuckedAway
        /// 还在屏幕上淡出、缩小
        case leaving
    }

    private static func whereabouts(of id: CGWindowID) -> Whereabouts {
        // 只问这一扇窗口的那种查法对不在屏幕上的窗口什么也不给，只能在全部窗口里找
        let all = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let info = all.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(id) }) else { return .gone }
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 0
        return (info[kCGWindowIsOnscreen as String] as? Bool) != true && alpha > 0.01 ? .tuckedAway : .leaving
    }

    /// 截到的画面和窗口的大小对得上：比例一样，并且不比窗口小（视网膜屏上是窗口的两倍）
    private static func image(_ image: CGImage, fits frame: CGRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let scaleX = CGFloat(image.width) / frame.width, scaleY = CGFloat(image.height) / frame.height
        return scaleX >= 0.9 && abs(scaleX - scaleY) <= 0.08 * scaleX
    }

    /// 窗口不在屏幕上了：最小化了、被隐藏了、淡出到看不见了，或者已经没了（只问这一扇窗口的查法对不在屏幕上的窗口不给结果，也算）
    private static func hasLeftScreen(_ id: CGWindowID) -> Bool {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first else { return true }
        return (info[kCGWindowIsOnscreen as String] as? Bool) != true || (info[kCGWindowAlpha as String] as? Double ?? 0) <= 0.01
    }

    /// 这个 App 此刻在屏幕上的普通窗口，排在最前的在前面
    private static func onScreenWindows(of pid: pid_t) -> [(id: CGWindowID, title: String, frame: CGRect)] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 0) > 0.01, let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  bounds.width >= minimumListableWindowSize.width, bounds.height >= minimumListableWindowSize.height else { return nil }
            return (CGWindowID(number), info[kCGWindowName as String] as? String ?? "", bounds)
        }
    }

    /// 窗口此刻的位置大小，前提是它在屏幕上、完全不透明；否则（正在最小化、正在关闭、已经不在了）为 nil
    private static func steadyFrame(of id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true, (info[kCGWindowAlpha as String] as? Double ?? 0) >= 0.99,
              let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return nil }
        return bounds
    }

    private static func picture(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func keep(_ image: NSImage, for watch: Watch, how: String) {
        if learned.count > 40 { learned.removeAll() }
        learned[watch.key] = (image, watch.title)
        log("learned how a new window of \(watch.name) looks, \(how) (\(Int(image.size.width))x\(Int(image.size.height)))")
    }

    private func mislead(_ watch: Watch) {
        guard keptMisleads.insert(watch.key).inserted else { return }
        log("kept window of \(watch.name) did not come back, using new-window previews for it from now on")
    }

    private func end() {
        guard let watch else { return }
        watch.finished = true
        watch.timers.forEach { $0.invalidate() }
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
