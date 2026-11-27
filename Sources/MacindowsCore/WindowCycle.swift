/// 在枚举窗口期间也能记住连续的 Tab。列表确定后再计算下标，一次手势内顺序保持不变。
public struct WindowCycle {
    private let firstStep: Int
    private var offset: Int

    public init(backwards: Bool) {
        firstStep = backwards ? -1 : 1
        offset = firstStep
    }

    public mutating func step(backwards: Bool) {
        offset += backwards ? -1 : 1
    }

    /// 直接把选中位置移到目标下标（方向键移动、关闭当前窗口后保持邻位选中等），之后的 Tab 从这里继续。
    public mutating func setIndex(_ target: Int, hasCurrent: Bool) {
        let start = !hasCurrent && firstStep > 0 ? -1 : 0
        offset = target - start
    }

    /// 当前窗口或无窗口应用（如果有）排在下标 0。前台没有对应卡片时，正向从第一张开始，反向从最后一张开始。
    public func index(count: Int, hasCurrent: Bool) -> Int? {
        guard count > 0 else { return nil }
        let start = !hasCurrent && firstStep > 0 ? -1 : 0
        return ((start + offset) % count + count) % count
    }
}
