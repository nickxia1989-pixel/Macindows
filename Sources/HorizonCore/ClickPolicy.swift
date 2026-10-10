/// 点击程序坞里某个 App 图标时，Horizon 该怎么处理这次点击。
public enum DockClickAction: Equatable {
    /// 不干预，交给程序坞按系统原样处理
    case passThrough
    /// 截下点击，隐藏这个 App（等同 ⌘H）
    case hideApp
    /// 截下点击，弹出这个 App 的窗口列表
    case showWindowList
}

public struct AppWindowState: Equatable {
    public var isRunning: Bool
    public var isFrontmost: Bool
    public var isHidden: Bool
    /// 标准窗口的数量，最小化的也算
    public var windowCount: Int
    public var minimizedCount: Int

    public init(isRunning: Bool, isFrontmost: Bool, isHidden: Bool, windowCount: Int, minimizedCount: Int) {
        self.isRunning = isRunning
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
        self.windowCount = windowCount
        self.minimizedCount = minimizedCount
    }
}

/// 规则与 Windows 合并任务栏一致：
/// 多个窗口只列出来让用户挑；单个窗口则「切过去 / 已是当前就收起 / 不在屏幕上就放回来」。
/// 凡是程序坞原生就能做对的情况都不截，只截系统做不到的两种。
public func dockClickAction(for s: AppWindowState) -> DockClickAction {
    guard s.isRunning else { return .passThrough }
    if s.windowCount >= 2 { return .showWindowList }
    guard s.windowCount == 1 else { return .passThrough }
    if s.isHidden || s.minimizedCount >= 1 { return .passThrough }
    return s.isFrontmost ? .hideApp : .passThrough
}
