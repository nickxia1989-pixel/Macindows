import ApplicationServices
import Darwin

/// 用到的少量私有接口。全部在运行时查找，缺了就退回公开接口，不会因此启动失败。
/// 这几个符号被 AltTab、yabai 等工具长期使用，已确认在 macOS 27 上存在。
enum PrivateAPI {
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let axGetWindow = symbol("_AXUIElementGetWindow", as: AXGetWindowFn.self)
    private static let getProcessForPID = symbol("GetProcessForPID", as: GetProcessForPIDFn.self)
    private static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self)
    private static let postEventRecord = symbol("SLPSPostEventRecordTo", as: PostEventRecordFn.self)

    static var availability: [(String, Bool)] {
        [("_AXUIElementGetWindow", axGetWindow != nil), ("GetProcessForPID", getProcessForPID != nil),
         ("_SLPSSetFrontProcessWithOptions", setFrontProcess != nil), ("SLPSPostEventRecordTo", postEventRecord != nil)]
    }

    /// 辅助功能里的窗口元素对应的系统窗口号。截缩略图和精确切换窗口都要用它。
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let axGetWindow else { return nil }
        var id: CGWindowID = 0
        return axGetWindow(element, &id) == .success && id != 0 ? id : nil
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
}
