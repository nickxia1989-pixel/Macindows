import AppKit
import Carbon.HIToolbox
import MacindowsCore

/// 仅在开关启用期间安装。键盘回调独占一条轻量线程，窗口枚举、截图和界面都不在输入路径上。
final class SwitcherShortcut {
    enum Action {
        case step(backwards: Bool)
        case move(SwitcherDirection)
        case closeSelected
        case minimizeSelected
        case hideSelected
        case quitSelected
        case commit
        case cancel
        case selectShortcut(Int)
    }

    var onAction: ((_ gesture: Int, _ action: Action) -> Void)?
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private let lock = NSLock()
    private var serial = 0
    private var tracking: Int?
    private var visibleShortcutCount: Int?
    private var swallowed = Set<Int>()
    private var stopping = false

    func start() -> Bool {
        lock.withLock { stopping = false }
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
        lock.withLock { stopping = true }
        if let tap { CFMachPortInvalidate(tap) }
        if let loop { CFRunLoopStop(loop) }
        tap = nil
    }

    func end(_ gesture: Int) {
        lock.withLock { if tracking == gesture { tracking = nil } }
    }

    func panelDidShow(for gesture: Int, shortcutCount: Int) {
        lock.withLock { if tracking == gesture { visibleShortcutCount = shortcutCount } }
    }

    private static let digits: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
        kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3, kVK_ANSI_Keypad4: 4,
        kVK_ANSI_Keypad5: 5, kVK_ANSI_Keypad6: 6, kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8, kVK_ANSI_Keypad9: 9
    ]

    private static let arrows: [Int: SwitcherDirection] = [
        kVK_LeftArrow: .left, kVK_RightArrow: .right,
        kVK_UpArrow: .up, kVK_DownArrow: .down,
    ]

    func reviveIfNeeded() {
        guard !lock.withLock({ stopping }) else { return }
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
            if !stopping {
                DispatchQueue.main.async { [weak self] in self?.reviveIfNeeded() }
            }
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
                visibleShortcutCount = nil
            }
            tracking = serial
            swallowed.insert(key)
            send(.step(backwards: flags.contains(.maskShift)), for: serial)
            return true
        }
        if repeating, swallowed.contains(key) {
            // 方向键和反引号允许按住连发，其余被吞掉的按键忽略连发。
            if let tracking, flags.contains(.maskCommand) {
                if let direction = Self.arrows[key], flags.intersection([.maskAlternate, .maskControl, .maskShift]).isEmpty {
                    send(.move(direction), for: tracking)
                } else if key == kVK_ANSI_Grave, flags.intersection(otherModifiers).isEmpty {
                    send(.step(backwards: !flags.contains(.maskShift)), for: tracking)
                }
            }
            return true
        }
        if let tracking, flags.contains(.maskCommand) {
            // 反引号：与原生 ⌘Tab 一致，按住 ⌘ 时单手反向选择。
            if key == kVK_ANSI_Grave, flags.intersection(otherModifiers).isEmpty {
                swallowed.insert(key)
                send(.step(backwards: !flags.contains(.maskShift)), for: tracking)
                return true
            }
            // 方向键在网格中按行列移动（Mac 键盘的方向键会自带 maskSecondaryFn，不能排除它）。
            if let direction = Self.arrows[key], flags.intersection([.maskAlternate, .maskControl, .maskShift]).isEmpty {
                swallowed.insert(key)
                send(.move(direction), for: tracking)
                return true
            }
            // 面板已显示时的快捷操作：数字键直达当前页前 9 张卡片；W 关闭窗口、Q 退出应用、H 隐藏、M 最小化。
            if visibleShortcutCount != nil,
               flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty {
                if let number = Self.digits[key], let count = visibleShortcutCount {
                    swallowed.insert(key)
                    if number <= count {
                        self.tracking = nil
                        send(.selectShortcut(number - 1), for: tracking)
                    }
                    return true
                }
                if !repeating {
                    switch key {
                    case kVK_ANSI_W:
                        swallowed.insert(key)
                        send(.closeSelected, for: tracking)
                        return true
                    case kVK_ANSI_Q:
                        swallowed.insert(key)
                        send(.quitSelected, for: tracking)
                        return true
                    case kVK_ANSI_H:
                        swallowed.insert(key)
                        send(.hideSelected, for: tracking)
                        return true
                    case kVK_ANSI_M:
                        swallowed.insert(key)
                        send(.minimizeSelected, for: tracking)
                        return true
                    default:
                        break
                    }
                }
            }
        }
        if let tracking {
            self.tracking = nil
            send(.cancel, for: tracking)
            // ⌘Space 仍放行给聚焦搜索；其余按键在切换器打开时吞掉，避免把 ⌘+键 误传给前台应用。
            if key == kVK_Space, flags.contains(.maskCommand), flags.intersection(otherModifiers).isEmpty {
                swallowed.remove(key)
                return false
            }
            swallowed.insert(key)
            return true
        }
        swallowed.remove(key)
        return false
    }
}
