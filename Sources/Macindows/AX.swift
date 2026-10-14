import AppKit
import ApplicationServices

// 辅助功能接口的薄封装：读属性失败一律返回 nil，调用方按「读不到」处理。
extension AXUIElement {
    func raw(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success ? value : nil
    }

    /// 同 raw，另外告诉调用方失败的原因（用来分辨「没有这个属性」和「App 没应答」）
    func copy(_ name: String) -> (error: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(self, name as CFString, &value)
        return (error, error == .success ? value : nil)
    }

    func string(_ name: String) -> String? { raw(name) as? String }
    func bool(_ name: String) -> Bool? { (raw(name) as? NSNumber)?.boolValue }
    func url(_ name: String) -> URL? { (raw(name) as? NSURL) as URL? }

    func element(_ name: String) -> AXUIElement? {
        guard let value = raw(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ name: String) -> [AXUIElement] {
        guard let array = raw(name) as? [AnyObject] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    private func axValue(_ name: String) -> AXValue? {
        guard let value = raw(name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    /// 左上角为原点的全局坐标
    var frame: CGRect? {
        guard let positionValue = axValue(kAXPositionAttribute), let sizeValue = axValue(kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(self, action as CFString) == .success
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 向别的 App 问话时最多等多久。系统默认是 6 秒；对方卡住的话，我们不能跟着卡这么久。
    /// 设在「系统级」的元素上，对本进程里所有的辅助功能调用都生效。
    static func limitWaiting(to seconds: Float = 0.3) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    /// 未授权时让系统弹出引导对话框（系统只会弹一次）
    static func promptIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 主屏幕（坐标原点所在的那块）的高度，用于两套坐标系互换
var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

/// 记住哪些 App 刚刚没应答。卡住的 App 每问一次都要等到超时，短时间内不再去问它。
enum AXHealth {
    private static let lock = NSLock()
    private static var silencedUntil: [pid_t: TimeInterval] = [:]
    /// 一次问话等了这么久还没应答，就当它卡住了
    static let slowThreshold: TimeInterval = 0.25
    private static let backoff: TimeInterval = 5

    static func isBackedOff(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = silencedUntil[pid] else { return false }
        if until > ProcessInfo.processInfo.systemUptime { return true }
        silencedUntil[pid] = nil
        return false
    }

    static func backOff(_ pid: pid_t) {
        lock.lock()
        silencedUntil[pid] = ProcessInfo.processInfo.systemUptime + backoff
        lock.unlock()
        log("app \(pid) is not answering, leaving it alone for \(Int(backoff))s")
    }
}
