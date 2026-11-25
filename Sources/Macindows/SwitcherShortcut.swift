import AppKit
import Carbon.HIToolbox

/// 仅在开关启用期间安装。键盘回调独占一条轻量线程，窗口枚举、截图和界面都不在输入路径上。
final class SwitcherShortcut {
    enum Action {
        case step(backwards: Bool), commit, cancel
        case applications, windows, openApplication(Int)
    }

    var onAction: ((_ gesture: Int, _ action: Action) -> Void)?
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private let lock = NSLock()
    private var serial = 0
    private var tracking: Int?
    private var visibleApplicationCount: Int?
    private var swallowed = Set<Int>()

    func start() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let shortcut = Unmanaged<SwitcherShortcut>.fromOpaque(context).takeUnretainedValue()
            return shortcut.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }
        self.tap = tap
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            self.loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            ready.signal()
            CFRunLoopRun()
            withExtendedLifetime(self) {}
        }
        thread.name = "macindows.switcher-shortcut"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        if let tap { CFMachPortInvalidate(tap) }
        if let loop { CFRunLoopStop(loop) }
        tap = nil
    }

    func end(_ gesture: Int) {
        lock.withLock { if tracking == gesture { tracking = nil } }
    }

    func panelDidShow(for gesture: Int, applicationCount: Int) {
        lock.withLock { if tracking == gesture { visibleApplicationCount = applicationCount } }
    }

    private static let digits: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
        kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3, kVK_ANSI_Keypad4: 4,
        kVK_ANSI_Keypad5: 5, kVK_ANSI_Keypad6: 6, kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8, kVK_ANSI_Keypad9: 9
    ]

    func reviveIfNeeded() {
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func send(_ action: Action, for gesture: Int) {
        DispatchQueue.main.async { [weak self] in self?.onAction?(gesture, action) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tracking { send(.cancel, for: tracking) }
            tracking = nil
            swallowed.removeAll()
            DispatchQueue.main.async { [weak self] in self?.reviveIfNeeded() }
            return false
        }
        let flags = event.flags
        if type == .flagsChanged {
            if !flags.contains(.maskCommand), let tracking {
                self.tracking = nil
                send(.commit, for: tracking)
            }
            return false
        }

        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp { return swallowed.remove(key) != nil }
        guard type == .keyDown else { return false }
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let otherModifiers: CGEventFlags = [.maskAlternate, .maskControl, .maskSecondaryFn]
        if key == kVK_Tab, flags.contains(.maskCommand), flags.intersection(otherModifiers).isEmpty,
           !repeating || tracking != nil {
            if tracking == nil {
                serial += 1
                visibleApplicationCount = nil
            }
            tracking = serial
            swallowed.insert(key)
            send(.step(backwards: flags.contains(.maskShift)), for: serial)
            return true
        }
        if repeating, swallowed.contains(key) { return true }
        if let tracking, let visibleApplicationCount, flags.contains(.maskCommand),
           flags.intersection([.maskControl, .maskAlternate, .maskShift]).isEmpty {
            if let number = Self.digits[key], !flags.contains(.maskSecondaryFn) {
                swallowed.insert(key)
                if number <= visibleApplicationCount {
                    self.tracking = nil
                    send(.openApplication(number - 1), for: tracking)
                }
                return true
            }
            // 部分键盘给方向键附加 Fn 标志。
            if visibleApplicationCount > 0, key == kVK_DownArrow || key == kVK_UpArrow {
                swallowed.insert(key)
                send(key == kVK_DownArrow ? .applications : .windows, for: tracking)
                return true
            }
        }
        if let tracking {
            self.tracking = nil
            send(.cancel, for: tracking)
            if key == kVK_Escape, flags.intersection(otherModifiers).isEmpty {
                swallowed.insert(key)
                return true
            }
        }
        swallowed.remove(key)
        return false
    }
}
