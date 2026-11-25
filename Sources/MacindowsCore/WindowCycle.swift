public enum SwitcherChoice: Equatable {
    case window(Int), application(Int)
}

/// 在枚举窗口期间也能记住连续的 Tab。列表确定后再计算下标，一次手势内顺序保持不变。
public struct WindowCycle {
    private let firstStep: Int
    private var offset: Int
    private var applicationOffset: Int?

    public init(backwards: Bool) {
        firstStep = backwards ? -1 : 1
        offset = firstStep
    }

    public mutating func step(backwards: Bool) {
        let delta = backwards ? -1 : 1
        if let applicationOffset { self.applicationOffset = applicationOffset + delta }
        else { offset += delta }
    }

    public mutating func enterApplications() {
        if applicationOffset == nil { applicationOffset = 0 }
    }

    public mutating func returnToWindows() { applicationOffset = nil }

    public func selection(windows: Int, applications: Int, hasCurrent: Bool) -> SwitcherChoice? {
        if let applicationOffset, applications > 0 {
            return .application((applicationOffset % applications + applications) % applications)
        }
        if let i = index(count: windows, hasCurrent: hasCurrent) { return .window(i) }
        return index(count: applications, hasCurrent: false).map(SwitcherChoice.application)
    }

    /// 当前窗口（如果有）排在下标 0。前台没有窗口时，正向从第一张开始，反向从最后一张开始。
    public func index(count: Int, hasCurrent: Bool) -> Int? {
        guard count > 0 else { return nil }
        let start = !hasCurrent && firstStep > 0 ? -1 : 0
        return ((start + offset) % count + count) % count
    }
}
