import AppKit
import CoreGraphics

/// 在系统把鼠标点击交给程序坞之前先看一眼，必要时把这次点击截下来自己处理。
/// 程序坞本身不被修改；不截的点击原样放行。
final class ClickInterceptor {
    enum Decision {
        case passThrough
        /// 截下这次点击，鼠标松开时执行给定动作
        case intercept(() -> Void)
    }

    /// 鼠标左键按下时调用，参数是左上角为原点的全局坐标
    var decide: ((CGPoint) -> Decision)?
    /// 每次左键按下都会调用（包括带修饰键、不会被截的那些），只是知会，不影响这次点击
    var onMouseDown: ((CGPoint) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pending: (down: CGEvent, location: CGPoint, action: () -> Void)?
    private var holdTimer: Timer?
    /// 给我们自己补发的事件打的记号，避免再被自己截住
    private static let marker: Int64 = 0x484F_525A

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
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
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        release(repost: false)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// 返回 true 表示吞掉这个事件
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        // 我们处理得太慢或用户按了安全键时，系统会停用监听，这里重新打开
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("event tap disabled (\(type.rawValue)), re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return false }

        switch type {
        case .leftMouseDown:
            release(repost: false)
            onMouseDown?(event.location)
            // 带修饰键的点击是系统功能（在访达中显示、隐藏其他 App 等），一律不碰
            let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            guard event.flags.intersection(modifiers).isEmpty,
                  let decide, case .intercept(let action) = decide(event.location),
                  let copy = event.copy() else { return false }
            pending = (copy, event.location, action)
            // 按住不放是在叫出程序坞自己的菜单：把按下事件还给程序坞
            let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in self?.release(repost: true) }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
            return true
        case .leftMouseUp:
            guard let current = pending else { return false }
            pending = nil
            holdTimer?.invalidate()
            current.action()
            return true
        default:
            return false
        }
    }

    /// 按下之后鼠标被拖动了：用户是在拖图标（调整顺序、拖出程序坞），把按下事件还给程序坞
    func mouseDragged(to point: CGPoint) {
        guard let current = pending else { return }
        if hypot(point.x - current.location.x, point.y - current.location.y) > 5 { release(repost: true) }
    }

    private func release(repost: Bool) {
        guard let current = pending else { return }
        pending = nil
        holdTimer?.invalidate()
        guard repost else { return }
        // 如果按键其实已经松开（漏掉了松开事件），就不能再补发按下，否则程序坞会以为一直按着
        guard CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
        current.down.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        current.down.post(tap: .cgSessionEventTap)
    }
}
