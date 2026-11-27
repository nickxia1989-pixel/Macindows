import AppKit
import MacindowsCore

/// 窗口销毁时已经无法截图或查询窗口号。趁窗口还在时关联 AX 元素和窗口号，
/// 在应用仍运行时保留最后一扇窗口的预览。
final class SwitcherWindowObservation {
    let app: NSRunningApplication
    private let queue = DispatchQueue(label: "macindows.switcher-window-lifetime", qos: .utility)
    // AX 查询、注册和事件按进程串行处理。
    private var observer: AXObserver?
    private var windows: [AXUIElement: AppWindow] = [:]
    // 下列属性由主线程读写。
    private var source: CFRunLoopSource?
    private(set) var lastPreview = LastWindowPreview<NSImage>()
    private var stopped = false
    private let cachedImage: (CGWindowID) -> NSImage?
    private let onCreated: (CGWindowID) -> Void

    init(app: NSRunningApplication, warmExisting: Bool, cachedImage: @escaping (CGWindowID) -> NSImage?,
         onCreated: @escaping (CGWindowID) -> Void) {
        self.app = app
        self.cachedImage = cachedImage
        self.onCreated = onCreated
        queue.async { self.start(warmExisting: warmExisting) }
    }

    private func start(warmExisting: Bool) {
        let callback: AXObserverCallback = { _, element, name, context in
            guard let context else { return }
            let watch = Unmanaged<SwitcherWindowObservation>.fromOpaque(context).takeUnretainedValue()
            watch.queue.async { watch.receive(name as String, element: element) }
        }
        var created: AXObserver?
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created else { return }
        observer = created
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        AXObserverAddNotification(created, application, kAXWindowCreatedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        if let snapshot = WindowIndex.snapshot(of: app) {
            synchronize(snapshot.windows)
            if warmExisting {
                let ids = snapshot.windows.compactMap(\.id)
                DispatchQueue.main.async { if !self.stopped { ids.forEach(self.onCreated) } }
            }
        }
        let source = AXObserverGetRunLoopSource(created)
        DispatchQueue.main.async {
            guard !self.stopped else { return }
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func register(_ window: AppWindow) {
        if windows[window.element] == nil, let observer {
            AXObserverAddNotification(observer, window.element, kAXUIElementDestroyedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
        windows[window.element] = window
    }

    private func receive(_ notification: String, element: AXUIElement) {
        if notification == kAXUIElementDestroyedNotification {
            guard let removed = windows.removeValue(forKey: element) else { return }
            publishCandidate(lastRemoved: removed)
        } else if notification == kAXWindowCreatedNotification,
                  let window = WindowIndex.makeWindow(element, of: app, layout: nil) {
            register(window)
            publishCandidate()
            if let id = window.id {
                DispatchQueue.main.async { if !self.stopped { self.onCreated(id) } }
            }
        }
    }

    /// 有些应用隐藏文稿时不发送销毁事件。用切换器已成功枚举的窗口校准记录。
    func saw(_ visible: [AppWindow]) {
        queue.async { self.synchronize(visible) }
    }

    private func synchronize(_ list: [AppWindow]) {
        let remaining = Set(list.map(\.element))
        let removed = windows.values.filter { !remaining.contains($0.element) }
        for window in removed { windows.removeValue(forKey: window.element) }
        for window in list { register(window) }
        if !windows.isEmpty || !removed.isEmpty {
            publishCandidate(lastRemoved: removed.count == 1 ? removed[0] : nil)
        }
    }

    private func publishCandidate(lastRemoved: AppWindow? = nil) {
        // 唯一还在的窗口就是下次无声关闭时的候选。多扇同时消失且没有顺序时保留图标。
        let id = windows.count == 1 ? windows.values.first?.id : (windows.isEmpty ? lastRemoved?.id : nil)
        let hasOpenWindows = !windows.isEmpty
        DispatchQueue.main.async {
            guard !self.stopped else { return }
            self.lastPreview.observe(candidate: id, hasOpenWindows: hasOpenWindows, cached: id.flatMap(self.cachedImage))
        }
    }

    func captured(_ image: NSImage, for id: CGWindowID) {
        lastPreview.captured(image, for: id)
    }

    func clearPreview() {
        lastPreview = LastWindowPreview()
    }

    func stop() {
        stopped = true
        clearPreview()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
    }
}
