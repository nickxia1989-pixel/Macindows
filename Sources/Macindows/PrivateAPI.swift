import ApplicationServices
import Darwin
import Foundation
import MacindowsCore

/// 用到的少量私有接口。全部在运行时查找，缺了就退回公开接口，不会因此启动失败。
/// 这几个符号被 AltTab、yabai 等工具长期使用，已确认在 macOS 27 上存在。
enum PrivateAPI {
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CaptureWindowListFn = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32) -> Unmanaged<CFArray>?
    private typealias CreateWithTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias GetWindowLevelFn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Int32>) -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let axGetWindow = symbol("_AXUIElementGetWindow", as: AXGetWindowFn.self)
    private static let getProcessForPID = symbol("GetProcessForPID", as: GetProcessForPIDFn.self)
    private static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self)
    private static let postEventRecord = symbol("SLPSPostEventRecordTo", as: PostEventRecordFn.self)
    private static let mainConnection = symbol("CGSMainConnectionID", as: MainConnectionFn.self)
    private static let captureWindowList = symbol("CGSHWCaptureWindowList", as: CaptureWindowListFn.self)
    private static let createWithToken = symbol("_AXUIElementCreateWithRemoteToken", as: CreateWithTokenFn.self)
    private static let getWindowLevel = symbol("CGSGetWindowLevel", as: GetWindowLevelFn.self)
    private static let copySpacesForWindows = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
    private static let copyManagedDisplaySpaces = symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)

    static var availability: [(String, Bool)] {
        [("_AXUIElementGetWindow", axGetWindow != nil), ("GetProcessForPID", getProcessForPID != nil),
         ("_SLPSSetFrontProcessWithOptions", setFrontProcess != nil), ("SLPSPostEventRecordTo", postEventRecord != nil),
         ("CGSHWCaptureWindowList", mainConnection != nil && captureWindowList != nil),
         ("_AXUIElementCreateWithRemoteToken", createWithToken != nil), ("CGSGetWindowLevel", getWindowLevel != nil),
         ("CGSCopySpacesForWindows", copySpacesForWindows != nil), ("CGSCopyManagedDisplaySpaces", copyManagedDisplaySpaces != nil)]
    }

    /// 辅助功能里的窗口元素对应的系统窗口号。截缩略图和精确切换窗口都要用它。
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let axGetWindow else { return nil }
        var id: CGWindowID = 0
        return axGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// 直接向窗口服务器要一个窗口当前的画面。和公开的截屏接口不同，它对已经最小化或被隐藏的窗口也有效
    /// （窗口服务器一直留着它们的画面）。同样需要「屏幕录制」权限。
    static func captureWindow(_ id: CGWindowID, fullResolution: Bool = false) -> CGImage? {
        guard let mainConnection, let captureWindowList else { return nil }
        var id = id
        // 忽略屏幕形状的裁剪（1 << 11）；按 1 倍分辨率（1 << 9）还是屏幕本身的分辨率（1 << 8）；
        // 总是给完整大小的画面（1 << 19）——开着台前调度时，不加这一项拿到的画面会被压扁
        let options: UInt32 = (1 << 11) | (fullResolution ? 1 << 8 : 1 << 9) | (1 << 19)
        guard let images = captureWindowList(mainConnection(), &id, 1, options)?.takeRetainedValue() as? [AnyObject],
              let first = images.first, CFGetTypeID(first) == CGImage.typeID else { return nil }
        return (first as! CGImage)
    }

    /// 把指定 App 的指定窗口切到最前，并且只带这一个窗口上来（公开接口会把该 App 的所有窗口都带上来）。
    static func bringToFront(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getProcessForPID, let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        let userGenerated: UInt32 = 0x200
        guard setFrontProcess(&psn, windowID, userGenerated) == .success else { return false }
        // 让这个窗口成为键盘焦点所在的窗口：向目标进程投递一对合成的事件记录
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { raw in
            for (offset, byte) in raw.enumerated() { bytes[0x3c + offset] = byte }
        }
        for index in 0x20..<0x30 { bytes[index] = 0xff }
        bytes[0x08] = 0x01
        _ = postEventRecord(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEventRecord(&psn, &bytes)
        return true
    }

    // MARK: 窗口的层级与所在的桌面

    /// 窗口所在的层级：普通窗口是 0，浮在上面的面板是 3。读不到时为 nil
    static func windowLevel(of id: CGWindowID) -> Int? {
        guard let mainConnection, let getWindowLevel else { return nil }
        var level: Int32 = 0
        return getWindowLevel(mainConnection(), id, &level) == 0 ? Int(level) : nil
    }

    /// 窗口所在的桌面（调度中心里的一个个「桌面」，全屏的窗口各占一个）。读不到、或者窗口不在任何桌面上时为空
    static func spaces(of id: CGWindowID) -> [Int] {
        guard let mainConnection, let copySpacesForWindows else { return [] }
        // 7 = 当前的、其他的、用户的桌面都算
        let result = copySpacesForWindows(mainConnection(), 7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue()
        return (result as? [NSNumber])?.map(\.intValue) ?? []
    }

    /// 各块屏幕此刻显示的桌面，以及现有的全部桌面
    struct SpaceLayout {
        let active: Set<Int>
        let all: Set<Int>
        /// 有没有哪个桌面此刻没在显示。没有的话，就不可能有窗口待在「别的桌面」上
        var hasInactiveSpaces: Bool { all.count > active.count }

        func isOnCurrentSpace(_ windowSpaces: [Int]) -> Bool {
            !isOnAnotherSpace(windowSpaces: windowSpaces, activeSpaces: active, knownSpaces: all)
        }
    }

    static func spaceLayout() -> SpaceLayout? {
        guard let mainConnection, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        var active = Set<Int>(), all = Set<Int>()
        for display in displays {
            if let current = (display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int {
                active.insert(current)
                all.insert(current)
            }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if let id = space["ManagedSpaceID"] as? Int { all.insert(id) }
            }
        }
        return active.isEmpty ? nil : SpaceLayout(active: active, all: all)
    }

    // MARK: 逐个编号找窗口

    /// 一个 App 在辅助功能里的全部窗口元素，包括系统的窗口列表不给的那些（主要是别的桌面上的窗口）。
    ///
    /// 做法是 AltTab、yabai 等工具用了多年的：辅助功能的元素可以凭「进程号 + 编号」直接造出来，
    /// 把编号从 0 试到 999，是窗口的留下。实测一个 App 试一遍要 15 到 40 毫秒。
    /// 试出来的不全是真正的窗口（还有 App 留着没显示的），调用方要自己再筛。要在后台线程或可以等的地方调用。
    static func windowElements(pid: pid_t) -> [AXUIElement] {
        guard let createWithToken else { return [] }
        // 20 个字节：进程号、0、一个固定的标记（'coco'）、8 字节的编号
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
        var elements: [AXUIElement] = []
        var failures = 0
        for id in UInt64(0)..<1000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            guard let element = createWithToken(token as CFData)?.takeRetainedValue() else { continue }
            var role: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            // App 没应答：它卡住了，再试下去每个编号都要等到超时
            if error == .cannotComplete {
                failures += 1
                if failures >= 2 { break }
                continue
            }
            failures = 0
            if error == .success, (role as? String) == kAXWindowRole { elements.append(element) }
        }
        return elements
    }
}
