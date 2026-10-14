import AppKit
import CoreGraphics

/// 在系统把鼠标点击交给程序坞之前先看一眼，必要时把这次点击截下来自己处理。
/// 程序坞本身不被修改；不截的点击原样放行。
///
/// 监听跑在它自己的线程上。全系统的鼠标点击都要先从这里过一遍，放在主线程的话，主线程一忙（比如正在等某个
/// App 答话），所有 App 里的点击都会跟着顿一下。
final class ClickInterceptor {
    enum Decision {
        case passThrough
        /// 截下这次点击，鼠标松开时在主线程执行给定动作
        case intercept(() -> Void)
    }

    /// 鼠标左键按下时调用，参数是左上角为原点的全局坐标。在监听线程上调用，不能碰只属于主线程的东西
    var decide: ((CGPoint) -> Decision)?
    /// 鼠标按下时调用（左键包括带修饰键、不会被截的那些；右键一律不截），只是知会，不影响这次点击。在主线程调用
    var onMouseDown: ((CGPoint, _ isRightButton: Bool) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    /// 被截下、还没决定怎么办的那次按下。监听线程和「按住不放」的计时都会碰它，所以加锁
    private let lock = NSLock()
    private var pending: (down: CGEvent, location: CGPoint, action: () -> Void, serial: Int)?
    private var serial = 0
    /// 给我们自己补发的事件打的记号，避免再被自己截住
    private static let marker: Int64 = 0x484F_525A

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let interceptor = Unmanaged<ClickInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            return interceptor.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "macindows.clicks"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        release(repost: false)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)
        }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        runLoop = nil
    }

    /// 系统嫌我们处理得慢、或者用户按了安全键时会停用监听。回调里会重新打开；这里给外面一个定时检查的入口，以防万一
    func reviveIfNeeded() {
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        log("event tap found disabled, re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// 返回 true 表示吞掉这个事件
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("event tap disabled (\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return false }
        let location = event.location

        switch type {
        case .rightMouseDown:
            notifyMouseDown(location, right: true)
            return false
        case .leftMouseDown:
            release(repost: false)
            notifyMouseDown(location, right: false)
            // 带修饰键的点击是系统功能（在访达中显示、隐藏其他 App 等），一律不碰
            let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            guard event.flags.intersection(modifiers).isEmpty,
                  let decide, case .intercept(let action) = decide(location),
                  let copy = event.copy() else { return false }
            lock.lock()
            serial += 1
            let current = serial
            pending = (copy, location, action, current)
            lock.unlock()
            // 按住不放是在叫出程序坞自己的菜单：把按下事件还给程序坞
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.release(repost: true, onlyIf: current)
            }
            return true
        case .leftMouseUp:
            guard let current = takePending() else { return false }
            DispatchQueue.main.async(execute: current.action)
            return true
        case .leftMouseDragged:
            // 按下之后鼠标被拖动了：用户是在拖图标（调整顺序、拖出程序坞），把按下事件还给程序坞。
            // 触发这一步的这个拖动事件本身吞掉，免得它比补发的按下先到
            lock.lock()
            let moved = pending.map { hypot(location.x - $0.location.x, location.y - $0.location.y) > 5 } ?? false
            lock.unlock()
            guard moved else { return false }
            release(repost: true)
            return true
        default:
            return false
        }
    }

    private func notifyMouseDown(_ location: CGPoint, right: Bool) {
        guard let onMouseDown else { return }
        DispatchQueue.main.async { onMouseDown(location, right) }
    }

    private func takePending(onlyIf wanted: Int? = nil) -> (down: CGEvent, location: CGPoint, action: () -> Void, serial: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = pending, wanted == nil || wanted == current.serial else { return nil }
        pending = nil
        return current
    }

    private func release(repost: Bool, onlyIf wanted: Int? = nil) {
        guard let current = takePending(onlyIf: wanted), repost else { return }
        // 如果按键其实已经松开（漏掉了松开事件），就不能再补发按下，否则程序坞会以为一直按着
        guard CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
        current.down.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        current.down.post(tap: .cgSessionEventTap)
    }
}
