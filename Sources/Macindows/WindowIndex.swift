import AppKit
import ApplicationServices
import MacindowsCore

/// 某个 App 的一个标准窗口
struct AppWindow {
    let element: AXUIElement
    let id: CGWindowID?
    let title: String
    let isMinimized: Bool
    let isMain: Bool
}

/// 某一时刻某个 App 的窗口情况
struct AppSnapshot {
    let app: NSRunningApplication
    let windows: [AppWindow]
    let isHidden: Bool
    let isFrontmost: Bool

    var state: AppWindowState {
        AppWindowState(isRunning: !app.isTerminated, isFrontmost: isFrontmost, isHidden: isHidden,
                       windowCount: windows.count, minimizedCount: windows.filter(\.isMinimized).count)
    }
}

enum WindowIndex {
    /// 列出一个 App 的全部标准窗口，包括隐藏和最小化的。
    /// 只能看到当前桌面上的窗口和最小化的窗口，其他桌面（Space）上的窗口系统不会给。
    static func snapshot(of app: NSRunningApplication) -> AppSnapshot? {
        guard !app.isTerminated else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // App 卡住时不能把我们也拖住
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let raw = element.raw(kAXWindowsAttribute) as? [AnyObject] else { return nil }

        let fallbackTitle = app.localizedName ?? ""
        var windows: [AppWindow] = []
        for object in raw where CFGetTypeID(object) == AXUIElementGetTypeID() {
            let window = object as! AXUIElement
            let isMinimized = window.bool(kAXMinimizedAttribute) ?? false
            guard isListableWindow(subrole: window.string(kAXSubroleAttribute), isMinimized: isMinimized) else { continue }
            let title = window.string(kAXTitleAttribute) ?? ""
            windows.append(AppWindow(element: window,
                                     id: PrivateAPI.windowID(of: window),
                                     title: title.isEmpty ? fallbackTitle : title,
                                     isMinimized: isMinimized,
                                     isMain: window.bool(kAXMainAttribute) ?? false))
        }
        // 顺序固定为窗口打开的先后（系统窗口号递增），和 Windows 任务栏一致。
        // 系统给的是前后层次的顺序，每切一次窗口就会变，不能直接用。
        windows = windows.enumerated().sorted { a, b in
            let left = a.element.id.map(Int.init) ?? Int.max, right = b.element.id.map(Int.init) ?? Int.max
            return left != right ? left < right : a.offset < b.offset
        }.map(\.element)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        return AppSnapshot(app: app, windows: windows, isHidden: app.isHidden, isFrontmost: frontmost)
    }

    /// 切到指定窗口：先把它弄回屏幕上（取消隐藏、取消最小化），再提到最前。
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
        log("focus \(app.localizedName ?? "?") window=\(window.id.map(String.init) ?? "-") precise=\(precise)")
    }

    /// 同样要在后台线程调用：App 弹出「是否保存」之类的对话框时，这一步也可能迟迟不返回
    static func close(_ window: AppWindow) {
        if let button = window.element.element(kAXCloseButtonAttribute) {
            button.perform(kAXPressAction)
        }
    }
}
