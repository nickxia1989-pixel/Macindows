import AppKit
import CoreGraphics
import os

/// 鼠标移动的唯一来源，同时负责让程序坞自带的名称标签不出现。
///
/// 做法：在系统把「鼠标移动」事件分发给各个 App 之前拦一道，凡是落在程序坞范围内的移动事件都吞掉。
/// 程序坞因此不知道鼠标停在哪个图标上，也就不会弹出它自己的名称标签；点击不受影响（实测程序坞按点击位置
/// 判断点的是哪个图标，不依赖之前的移动事件）。拖动是另一种事件，这里不吞，拖图标、往图标上拖文件都照常。
///
/// 监听跑在独立线程上，回调里只做一次矩形判断，不会因为主线程忙而拖慢整个系统的鼠标事件。
final class MouseTracker {
    /// 鼠标移动后在主线程回调，参数是左上角为原点的全局坐标。连续移动会合并，只报最新位置。
    var onMove: ((CGPoint) -> Void)?
    /// 按着左键拖动时在主线程回调
    var onDrag: ((CGPoint) -> Void)?

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    private struct State {
        var zone = CGRect.null
        var latest = CGPoint.zero
        var scheduled = false
    }

    var isRunning: Bool { tap != nil }

    /// 这个范围内的鼠标移动事件不再交给任何 App；传 .null 表示不吞
    func setSuppressedZone(_ zone: CGRect) {
        state.withLock { $0.zone = zone }
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue) | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tracker = Unmanaged<MouseTracker>.fromOpaque(refcon).takeUnretainedValue()
            return tracker.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let thread = Thread { [weak self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "horizon.mouse"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
    }

    /// 在监听线程上执行。返回 true 表示吞掉这个事件。
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let location = event.location
        if type == .leftMouseDragged {
            DispatchQueue.main.async { [weak self] in self?.onDrag?(location) }
            return false
        }
        guard type == .mouseMoved else { return false }
        let (swallow, schedule) = state.withLock { state -> (Bool, Bool) in
            state.latest = location
            let schedule = !state.scheduled
            state.scheduled = true
            return (state.zone.contains(location), schedule)
        }
        if schedule {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let point = self.state.withLock { state -> CGPoint in
                    state.scheduled = false
                    return state.latest
                }
                self.onMove?(point)
            }
        }
        return swallow
    }
}
