import AppKit
import ApplicationServices
import MacindowsCore

/// 某个 App 的一扇窗口
struct AppWindow {
    let element: AXUIElement
    let id: CGWindowID?
    let title: String
    let isMinimized: Bool
    let isMain: Bool
    /// 窗口的位置和大小，左上角为原点的全局坐标。最小化的窗口报的是放回来以后的位置
    let frame: CGRect?
    /// 是不是在当前桌面上。在别的桌面上（包括各自全屏的窗口）时为 false
    let isOnCurrentSpace: Bool
    /// 是否处于原生全屏状态
    let isFullScreen: Bool
    /// 是否支持最小化（全屏窗口或禁用最小化按钮的窗口为 false）
    let canMinimize: Bool

    /// 同一扇窗口，换个最小化状态
    func with(minimized: Bool) -> AppWindow {
        AppWindow(element: element, id: id, title: title, isMinimized: minimized, isMain: isMain,
                  frame: frame, isOnCurrentSpace: isOnCurrentSpace, isFullScreen: isFullScreen, canMinimize: canMinimize)
    }
}

/// 某一时刻某个 App 的窗口情况
struct AppSnapshot {
    let app: NSRunningApplication
    let windows: [AppWindow]
    let isHidden: Bool
    let isFrontmost: Bool

    var state: AppWindowState {
        AppWindowState(isRunning: !app.isTerminated, isFrontmost: isFrontmost, isHidden: isHidden,
                       windowCount: windows.count, minimizedCount: windows.filter(\.isMinimized).count,
                       elsewhereCount: windows.filter { !$0.isOnCurrentSpace && !$0.isMinimized }.count,
                       canMinimize: windows.count == 1 ? windows[0].canMinimize : true)
    }
}

enum WindowIndex {
    /// 批量枚举多个应用时共用一份桌面布局和窗口列表快照，避免每个应用重复向窗口服务器查询。
    struct SnapshotContext {
        let spaceLayout: PrivateAPI.SpaceLayout?
        let windowList: [[String: Any]]?

        static func capture() -> SnapshotContext {
            let layout = PrivateAPI.spaceLayout()
            let list = layout?.hasInactiveSpaces == true
                ? (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])
                : nil
            return SnapshotContext(spaceLayout: layout, windowList: list)
        }
    }

    /// 列出一个 App 的全部窗口：开着的、隐藏的、最小化的，以及别的桌面上的。
    /// 读不到（App 正忙、刚启动，或者卡住了）时返回 nil。可以在任何线程调用。
    static func snapshot(of app: NSRunningApplication, context: SnapshotContext? = nil) -> AppSnapshot? {
        guard !app.isTerminated else { return nil }
        let pid = app.processIdentifier
        guard !AXHealth.isBackedOff(pid) else { return nil }
        let element = AXUIElementCreateApplication(pid)
        // App 卡住时不能把我们也拖住
        AXUIElementSetMessagingTimeout(element, 0.3)
        let asked = ProcessInfo.processInfo.systemUptime
        let answer = element.copy(kAXWindowsAttribute)
        guard let raw = answer.value as? [AnyObject] else {
            if answer.error == .cannotComplete, ProcessInfo.processInfo.systemUptime - asked >= AXHealth.slowThreshold { AXHealth.noteSilence(pid) }
            return nil
        }
        AXHealth.noteAnswer(pid)

        let layout = context?.spaceLayout ?? PrivateAPI.spaceLayout()
        var windows = raw.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.compactMap { makeWindow($0 as! AXUIElement, of: app, layout: layout) }
        // 系统给的列表里只有当前桌面上的窗口和最小化的窗口。还有别的桌面时，那边的窗口要另外去找
        if let layout, layout.hasInactiveSpaces {
            windows += windowsOnOtherSpaces(of: app, known: Set(windows.compactMap(\.id)), layout: layout, windowList: context?.windowList)
        }
        // 顺序固定为窗口打开的先后（系统窗口号递增），和 Windows 任务栏一致。
        // 系统给的是前后层次的顺序，每切一次窗口就会变，不能直接用。
        windows = windows.enumerated().sorted { a, b in
            let left = a.element.id.map(Int.init) ?? Int.max, right = b.element.id.map(Int.init) ?? Int.max
            return left != right ? left < right : a.offset < b.offset
        }.map(\.element)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        return AppSnapshot(app: app, windows: windows, isHidden: app.isHidden, isFrontmost: frontmost)
    }

    /// 把辅助功能里的一个窗口元素读成 AppWindow；不该列出来的返回 nil
    static func makeWindow(_ window: AXUIElement, of app: NSRunningApplication, layout: PrivateAPI.SpaceLayout?,
                           onCurrentSpace: Bool? = nil) -> AppWindow? {
        let id = PrivateAPI.windowID(of: window)
        let frame = window.frame
        let title = window.string(kAXTitleAttribute) ?? ""
        let traits = WindowTraits(role: window.string(kAXRoleAttribute), subrole: window.string(kAXSubroleAttribute), title: title,
                                  size: frame?.size, level: id.flatMap(PrivateAPI.windowLevel),
                                  bundleID: app.bundleIdentifier, executablePath: app.executableURL?.path)
        guard isListableWindow(traits) else { return nil }
        var current = onCurrentSpace ?? true
        if onCurrentSpace == nil, let layout, layout.hasInactiveSpaces, let id {
            current = layout.isOnCurrentSpace(PrivateAPI.spaces(of: id))
        }
        let fullScreen = window.bool("AXFullScreen") ?? false
        let canMinimize = !fullScreen && window.isSettable(kAXMinimizedAttribute)
        return AppWindow(element: window, id: id,
                         title: title.isEmpty ? (app.localizedName ?? "") : title,
                         isMinimized: window.bool(kAXMinimizedAttribute) ?? false,
                         isMain: window.bool(kAXMainAttribute) ?? false,
                         frame: frame, isOnCurrentSpace: current,
                         isFullScreen: fullScreen, canMinimize: canMinimize)
    }

    /// 这个 App 在别的桌面上的窗口。先看窗口服务器那边有没有这样的窗口，有才去辅助功能里逐个编号找。
    private static func windowsOnOtherSpaces(of app: NSRunningApplication, known: Set<CGWindowID>,
                                             layout: PrivateAPI.SpaceLayout, windowList: [[String: Any]]? = nil) -> [AppWindow] {
        let pid = app.processIdentifier
        let all = windowList ?? (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        // 窗口服务器给的顺序是从前到后，记下来：一组标签页里留排在最前的那个
        var order: [CGWindowID: Int] = [:]
        for info in all where (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let number = info[kCGWindowNumber as String] as? Int else { continue }
            let id = CGWindowID(number)
            guard !known.contains(id), (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  bounds.width >= minimumListableWindowSize.width, bounds.height >= minimumListableWindowSize.height,
                  isOnAnotherSpace(windowSpaces: PrivateAPI.spaces(of: id), activeSpaces: layout.active, knownSpaces: layout.all) else { continue }
            order[id] = order.count
        }
        guard !order.isEmpty else { return [] }

        var found: [(rank: Int, window: AppWindow)] = []
        for element in PrivateAPI.windowElements(pid: pid, wantedIDs: Set(order.keys)) {
            guard let id = PrivateAPI.windowID(of: element), let rank = order[id], !found.contains(where: { $0.window.id == id }),
                  let window = makeWindow(element, of: app, layout: layout, onCurrentSpace: false) else { continue }
            found.append((rank, window))
        }
        found.sort { $0.rank < $1.rank }
        // 同一组标签页在那边是好几扇叠在一起的窗口，只留一个
        let duplicates = duplicateTabIndices(frames: found.map { $0.window.isMinimized ? nil : $0.window.frame })
        return found.enumerated().filter { !duplicates.contains($0.offset) }.map(\.element.window)
    }

    /// App 关窗口时留下的窗口（见 isKeptWindow），排在最前的在前面。要读窗口标题，所以需要「屏幕录制」权限。
    static func keptWindows(of app: NSRunningApplication) -> [(id: CGWindowID, title: String)] {
        guard let layout = PrivateAPI.spaceLayout() else { return [] }
        let pid = app.processIdentifier
        let all = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return all.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return nil }
            let id = CGWindowID(number), title = info[kCGWindowName as String] as? String ?? ""
            guard isKeptWindow(layer: info[kCGWindowLayer as String] as? Int ?? -1, isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                               alpha: info[kCGWindowAlpha as String] as? Double ?? 1, size: bounds.size, hasTitle: !title.isEmpty,
                               windowSpaces: PrivateAPI.spaces(of: id), knownSpaces: layout.all) else { return nil }
            return (id, title)
        }
    }

    /// 对窗口的操作（切过去、最小化、关掉）都放到这条队列上，一个接一个地执行，不占主线程（原因见 focus）。
    /// 必须排队：用户连着点图标时，「最小化」还卡在动画里，后面的「放回来」要是抢先执行了，窗口就会停在相反的状态
    static let actions = DispatchQueue(label: "macindows.window-actions", qos: .userInteractive)

    /// 也要放到 actions 上执行：窗口播放最小化动画期间，这一步可能迟迟不返回
    static func minimize(_ window: AppWindow) {
        window.element.set(kAXMinimizedAttribute, kCFBooleanTrue)
    }

    /// 切到指定窗口：先把它弄回屏幕上（取消隐藏、取消最小化），再提到最前。窗口在别的桌面上时，系统会跟着切过去。
    /// 要放到 actions 上执行：窗口正在播放「从程序坞放回来」的动画时，目标 App 要等动画播完才答复，
    /// 「提到最前」这一步会被卡住几百毫秒；放在主线程上的话，这期间悬停窗关不掉，鼠标也没人理。
    static func focus(_ window: AppWindow, of app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        if window.isMinimized { window.element.set(kAXMinimizedAttribute, kCFBooleanFalse) }

        var precise = false
        if let id = window.id {
            precise = PrivateAPI.bringToFront(pid: app.processIdentifier, windowID: id)
        }
        window.element.perform(kAXRaiseAction)
        window.element.set(kAXMainAttribute, kCFBooleanTrue)
        if !precise {
            // 退路：公开接口。会把这个 App 的所有窗口一起带到前面。
            activate(app)
        }
        log("focus \(app.localizedName ?? "?") window=\(window.id.map(String.init) ?? "-") precise=\(precise) currentSpace=\(window.isOnCurrentSpace)")
    }

    static func activate(_ app: NSRunningApplication) {
        DispatchQueue.main.async {
            guard !app.isTerminated else { return }
            NSApp.yieldActivation(to: app)
            app.activate(from: .current, options: [])
        }
    }

    /// 应用自己决定重新打开时要显示什么，例如文稿、新建窗口或文件选择器。
    static func reopen(_ app: NSRunningApplication, dockItem: DockItem? = nil) {
        guard !app.isTerminated else { return }
        if let dockItem {
            let pressed = dockItem.element.perform(kAXPressAction)
            log("open window of \(dockItem.title) via dock press=\(pressed)")
            if pressed { return }
        }
        guard let url = app.bundleURL else { activate(app); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.allowsRunningApplicationSubstitution = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if error != nil { activate(app) }
        }
    }

    /// 同样要放到 actions 上执行：App 弹出「是否保存」之类的对话框时，这一步也可能迟迟不返回。
    /// 若最小化窗口无法直接点关闭按钮，先还原再关；若触发了保存确认表（AXSheet），主动把窗口带到前台。
    static func close(_ window: AppWindow, of app: NSRunningApplication? = nil, onSheet: (() -> Void)? = nil) {
        var pressed = false
        if let button = window.element.element(kAXCloseButtonAttribute) {
            pressed = button.perform(kAXPressAction)
        }
        if !pressed, window.isMinimized {
            window.element.set(kAXMinimizedAttribute, kCFBooleanFalse)
            Thread.sleep(forTimeInterval: 0.15)
            if let button = window.element.element(kAXCloseButtonAttribute) {
                pressed = button.perform(kAXPressAction)
            }
        }
        guard pressed, let app, !app.isTerminated else { return }
        Thread.sleep(forTimeInterval: 0.12)
        let hasSheet = window.element.elements(kAXChildrenAttribute).contains {
            $0.string(kAXRoleAttribute) == kAXSheetRole
        }
        if hasSheet {
            focus(window.with(minimized: false), of: app)
            if let onSheet { DispatchQueue.main.async(execute: onSheet) }
        }
    }

    static func hide(_ app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        app.hide()
    }

    static func quit(_ app: NSRunningApplication) {
        guard !app.isTerminated else { return }
        app.terminate()
    }
}
