import CoreGraphics
import Foundation

/// 辅助功能报告的一扇窗口，判断它要不要列出来时用得上的那些特征。读不到的填 nil。
public struct WindowTraits {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var size: CGSize?
    /// 窗口所在的层级：普通窗口是 0，浮在上面的面板是 3
    public var level: Int?
    public var bundleID: String?
    /// 可执行文件的完整路径。没有应用标识的进程（Wine、模拟器）靠它辨认
    public var executablePath: String?

    public init(role: String? = "AXWindow", subrole: String?, title: String? = nil, size: CGSize? = nil, level: Int? = nil,
                bundleID: String? = nil, executablePath: String? = nil) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.size = size
        self.level = level
        self.bundleID = bundleID
        self.executablePath = executablePath
    }

    var hasTitle: Bool { !(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isOnNormalLevel: Bool { level == nil || level == 0 }
    var executableName: String { (executablePath ?? "").split(separator: "/").last.map(String.init) ?? "" }

    func isFrom(_ prefixes: String...) -> Bool {
        guard let bundleID else { return false }
        return prefixes.contains { bundleID.hasPrefix($0) }
    }
}

/// 再小就不会是一扇给人用的窗口了（很多 App 留着几扇 1×1、或者和菜单栏一样扁的隐形窗口）
public let minimumListableWindowSize = CGSize(width: 100, height: 50)

/// 辅助功能报告的一扇窗口要不要列出来。
///
/// 一般规则：处在普通层级的「标准窗口」和「对话框」。对话框也要算，有两个原因——
/// 一是窗口最小化、或者整个 App 被隐藏之后，系统会把它的类型从标准窗口改报成对话框（在 macOS 27 上对
/// 活动监视器、终端、Developer 等实测如此），恢复后又变回来；二是有些 App 的主窗口本来就报成对话框。
/// 浮在上面的面板、提醒条之类虽然类型相同，但不在普通层级，靠层级排除。
///
/// 个别 App 的窗口不按常理报告类型，另有专门的规则：有的要额外放行，有的要多一道要求。
public func isListableWindow(_ w: WindowTraits) -> Bool {
    if let size = w.size, size.width < minimumListableWindowSize.width || size.height < minimumListableWindowSize.height { return false }
    for rule in appRules where rule.applies(w) {
        if let requires = rule.requires, !requires(w) { return false }
        if let accepts = rule.accepts, accepts(w) { return true }
    }
    return w.isOnNormalLevel && (w.subrole == "AXStandardWindow" || w.subrole == "AXDialog")
}

private struct AppRule {
    let applies: (WindowTraits) -> Bool
    /// 满足就列出来，不再看一般规则
    var accepts: ((WindowTraits) -> Bool)?
    /// 不满足就一定不列
    var requires: ((WindowTraits) -> Bool)?
}

/// 这些都是各个 App 自己的怪癖，来自 AltTab、DockDoor 等同类工具多年积累的反馈，没有逐个实测。
private let appRules: [AppRule] = [
    // JetBrains 系列和 Android Studio 会开一些没有标题的隐形对话框
    AppRule(applies: { $0.isFrom("com.jetbrains.", "com.google.android.studio") },
            requires: { ($0.subrole == "AXStandardWindow" || $0.hasTitle) && ($0.size.map { $0.width > 100 && $0.height > 100 } ?? true) }),
    // Steam 的窗口不报类型，只能靠有没有标题来认
    AppRule(applies: { $0.isFrom("com.valvesoftware.steam") },
            accepts: { $0.hasTitle && $0.role != nil }, requires: { $0.hasTitle && $0.role != nil }),
    // 全屏播放视频时的窗口不报类型
    AppRule(applies: { $0.isFrom("org.mozilla.firefox") }, accepts: { $0.role == "AXWindow" && ($0.size?.height ?? 0) > 400 }),
    AppRule(applies: { $0.isFrom("org.videolan.vlc") }, accepts: { $0.role == "AXWindow" }),
    // 主窗口报成浮动窗口
    AppRule(applies: { $0.isFrom("com.adobe.Audition", "com.adobe.AfterEffects") }, accepts: { $0.subrole == "AXFloatingWindow" }),
    AppRule(applies: { $0.isFrom("com.autodesk.AutoCAD") }, accepts: { $0.subrole == "AXDocumentWindow" }),
    AppRule(applies: { $0.isFrom("com.autodesk.fusion360") }, requires: { $0.hasTitle }),
    AppRule(applies: { $0.isFrom("com.apple.iBooksX", "com.apple.iWork.Keynote") }, accepts: { _ in true }),
    AppRule(applies: { $0.isFrom("com.blizzard.worldofwarcraft", "net.battle.bootstrapper") }, accepts: { $0.role == "AXWindow" }),
    // 没有应用标识的进程：CrossOver / Wine 里跑的 Windows 程序、安卓模拟器、置顶的 scrcpy
    AppRule(applies: { $0.bundleID == nil && ($0.executableName == "wine64-preloader" || ($0.executablePath ?? "").contains("/winetemp-")) },
            accepts: { $0.role == "AXWindow" && $0.subrole == "AXUnknown" && $0.level == 0 }),
    AppRule(applies: { $0.bundleID == nil && $0.executableName.hasPrefix("qemu-system") },
            accepts: { $0.role == "AXWindow" && $0.hasTitle && $0.title != "Window" && $0.isOnNormalLevel }),
    AppRule(applies: { $0.executableName == "scrcpy" }, accepts: { $0.role == "AXWindow" && $0.subrole == "AXStandardWindow" && $0.level == 3 }),
]

// MARK: 别的桌面上的窗口

/// 一扇窗口是不是确实待在别的桌面上（包括各自全屏的窗口——全屏的窗口自己占一个桌面）。
/// windowSpaces 是这扇窗口所在的桌面，activeSpaces 是各块屏幕此刻显示的桌面，knownSpaces 是现有的全部桌面。
///
/// 系统给的窗口列表里没有别的桌面上的窗口，要靠逐个编号去试；试出来的除了真正的窗口，还有 App 留着没显示的窗口。
/// 后者不在任何桌面上，或者挂在一个已经不存在的桌面上，靠这里排除。
public func isOnAnotherSpace(windowSpaces: [Int], activeSpaces: Set<Int>, knownSpaces: Set<Int>) -> Bool {
    guard !windowSpaces.isEmpty, activeSpaces.isDisjoint(with: windowSpaces) else { return false }
    return !knownSpaces.isDisjoint(with: windowSpaces)
}

/// 同一组标签页里的各个标签页，在系统里各是一扇窗口（访达、终端、Safari、Ghostty 等用的系统原生标签页都是如此），
/// 它们的位置和大小完全重合。在当前桌面上，系统的窗口列表只给选中的那一个；在别的桌面上逐个试出来的则是全部。
/// 这里把位置大小完全相同的归成一组，每组只留排在最前的一个，返回其余该丢掉的那些的下标。
public func duplicateTabIndices(frames: [CGRect?]) -> Set<Int> {
    struct Key: Hashable { let x, y, width, height: Int }
    var seen = Set<Key>()
    var duplicates = Set<Int>()
    for (index, frame) in frames.enumerated() {
        guard let frame, frame.width > 0, frame.height > 0 else { continue }
        let key = Key(x: Int(frame.minX.rounded()), y: Int(frame.minY.rounded()), width: Int(frame.width.rounded()), height: Int(frame.height.rounded()))
        if !seen.insert(key).inserted { duplicates.insert(index) }
    }
    return duplicates
}
