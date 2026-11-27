import AppKit

/// 悬停预览和 ⌘Tab 窗口切换器共用的内存缩略图缓存。仅保存在内存里，不落盘。
/// 底层 NSCache 线程安全，可跨主线程与切换器预览模块共享。
final class SharedPreviewCache: @unchecked Sendable {
    private let cache = NSCache<NSNumber, NSImage>()

    init() {
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 128
    }

    private static func key(pid: pid_t, id: CGWindowID) -> NSNumber {
        NSNumber(value: UInt64(UInt32(bitPattern: pid)) << 32 | UInt64(id))
    }

    func image(for pid: pid_t, id: CGWindowID) -> NSImage? {
        cache.object(forKey: Self.key(pid: pid, id: id))
    }

    func set(_ image: NSImage, for pid: pid_t, id: CGWindowID, cost: Int? = nil) {
        let bytes = cost ?? estimatedCost(of: image)
        cache.setObject(image, forKey: Self.key(pid: pid, id: id), cost: max(1, bytes))
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    private func estimatedCost(of image: NSImage) -> Int {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return Int(max(1, image.size.width * image.size.height * 4))
    }
}
