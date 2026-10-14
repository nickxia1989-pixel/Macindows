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
                       elsewhereCount: windows.filter { !$0.isOnCurrentSpace && !$0.isMinimized }.count)
    }
}

enum WindowIndex {
    /// 列出一个 App 的全部窗口：开着的、隐藏的、最小化的，以及别的桌面上的。
    /// 读不到（App 正忙、刚启动，或者卡住了）时返回 nil。可以在任何线程调用。
    static func snapshot(of app: NSRunningApplication) -> AppSnapshot? {
        guard !app.isTerminated else { return nil }
        let pid = app.processIdentifier
        guard !AXHealth.isBackedOff(pid) else { return nil }
        let element = AXUIElementCreateApplication(pid)
        // App 卡住时不能把我们也拖住
        AXUIElementSetMessagingTimeout(element, 0.3)
        let asked = ProcessInfo.processInfo.systemUptime
        let answer = element.copy(kAXWindowsAttribute)
        guard let raw = answer.value as? [AnyObject] else {
            if answer.error == .cannotComplete, ProcessInfo.processInfo.systemUptime - asked >= AXHealth.slowThreshold { AXHealth.backOff(pid) }
            return nil
        }

        let layout = PrivateAPI.spaceLayout()
        var windows = raw.filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.compactMap { makeWindow($0 as! AXUIElement, of: app, layout: layout) }
        // 系统给的列表里只有当前桌面上的窗口和最小化的窗口。还有别的桌面时，那边的窗口要另外去找
        if let layout, layout.hasInactiveSpaces {
            windows += windowsOnOtherSpaces(of: app, known: Set(windows.compactMap(\.id)), layout: layout)
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
    private static func makeWindow(_ window: AXUIElement, of app: NSRunningApplication, layout: PrivateAPI.SpaceLayout?,
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
        return AppWindow(element: window, id: id,
                         title: title.isEmpty ? (app.localizedName ?? "") : title,
                         isMinimized: window.bool(kAXMinimizedAttribute) ?? false,
                         isMain: window.bool(kAXMainAttribute) ?? false,
                         frame: frame, isOnCurrentSpace: current)
    }

    /// 这个 App 在别的桌面上的窗口。先看窗口服务器那边有没有这样的窗口，有才去辅助功能里逐个编号找。
    private static func windowsOnOtherSpaces(of app: NSRunningApplication, known: Set<CGWindowID>, layout: PrivateAPI.SpaceLayout) -> [AppWindow] {
        let pid = app.processIdentifier
        let all = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
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
        for element in PrivateAPI.windowElements(pid: pid) {
            guard let id = PrivateAPI.windowID(of: element), let rank = order[id], !found.contains(where: { $0.window.id == id }),
                  let window = makeWindow(element, of: app, layout: layout, onCurrentSpace: false) else { continue }
            found.append((rank, window))
        }
        found.sort { $0.rank < $1.rank }
        // 同一组标签页在那边是好几扇叠在一起的窗口，只留一个
        let duplicates = duplicateTabIndices(frames: found.map { $0.window.isMinimized ? nil : $0.window.frame })
        return found.enumerated().filter { !duplicates.contains($0.offset) }.map(\.element.window)
    }

    /// 切到指定窗口：先把它弄回屏幕上（取消隐藏、取消最小化），再提到最前。窗口在别的桌面上时，系统会跟着切过去。
    /// 要在后台线程调用：窗口正在播放「从程序坞放回来」的动画时，目标 App 要等动画播完才答复，
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
            DispatchQueue.main.async {
                NSApp.yieldActivation(to: app)
                app.activate(from: .current, options: [])
            }
        }
        log("focus \(app.localizedName ?? "?") window=\(window.id.map(String.init) ?? "-") precise=\(precise) currentSpace=\(window.isOnCurrentSpace)")
    }

    /// 同样要在后台线程调用：App 弹出「是否保存」之类的对话框时，这一步也可能迟迟不返回
    static func close(_ window: AppWindow) {
        if let button = window.element.element(kAXCloseButtonAttribute) {
            button.perform(kAXPressAction)
        }
    }
}
