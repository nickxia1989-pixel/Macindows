import CoreGraphics

/// 一次应用运行期间只保留一张图。窗口销毁后，即使普通窗口缓存被回收，也能再次显示。
public struct LastWindowPreview<Image> {
    private var windowID: CGWindowID?
    public private(set) var image: Image?

    public init() {}

    public mutating func observe(candidate: CGWindowID?, hasOpenWindows: Bool, cached: Image?) {
        // 再次确认应用没有窗口，并没有提供新的关闭顺序。
        guard hasOpenWindows || candidate != nil else { return }
        if windowID != candidate {
            windowID = candidate
            image = cached
        } else if let cached {
            image = cached
        }
    }

    public mutating func captured(_ image: Image, for id: CGWindowID) {
        if windowID == id { self.image = image }
    }
}
