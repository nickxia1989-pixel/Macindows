/// 点击程序坞里某个 App 图标时，Macindows 该怎么处理这次点击。
public enum DockClickAction: Equatable {
    /// 不干预，交给程序坞按系统原样处理
    case passThrough
    /// 截下点击，把这个 App 唯一的窗口最小化
    case minimizeWindow
    /// 截下点击，把这个 App 唯一的、已经最小化的窗口放回来
    case restoreWindow
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
/// 多个窗口只列出来让用户挑；单个窗口则「切过去 / 已是当前就最小化 / 最小化了就放回来」。
/// 程序坞原生就能做对的情况（启动、切到后台的 App、取消隐藏）不截。
public func dockClickAction(for s: AppWindowState) -> DockClickAction {
    guard s.isRunning else { return .passThrough }
    if s.windowCount >= 2 { return .showWindowList }
    guard s.windowCount == 1 else { return .passThrough }
    // 整个 App 被隐藏（⌘H）时点图标，程序坞自己会把它显示出来
    if s.isHidden { return .passThrough }
    // 唯一的窗口最小化了：自己放回来。程序坞对有些 App 也会这么做，但不是每个 App 都如此，自己做才能保证来回一致
    if s.minimizedCount >= 1 { return .restoreWindow }
    return s.isFrontmost ? .minimizeWindow : .passThrough
}

/// 辅助功能报告的一个窗口要不要列出来。
/// 只列「标准窗口」，面板、对话框、浮层之类不算。但有一个坑：窗口最小化之后，系统会把它的类型从标准窗口
/// 改报成对话框（在 macOS 27 上对活动监视器、微信等实测如此），恢复后又变回来。所以最小化的对话框也要算，
/// 否则窗口一最小化就从列表里消失了。
public func isListableWindow(subrole: String?, isMinimized: Bool) -> Bool {
    if subrole == "AXStandardWindow" { return true }
    return isMinimized && subrole == "AXDialog"
}
