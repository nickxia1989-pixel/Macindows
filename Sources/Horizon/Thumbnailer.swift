import AppKit
import ScreenCaptureKit

/// 窗口缩略图。需要「屏幕录制」权限；没有权限时悬停窗只显示标题列表。
enum Thumbnailer {
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// 让系统弹出授权请求。授权后通常要重新打开应用才生效。
    static func requestAccess() { _ = CGRequestScreenCaptureAccess() }

    /// 截取一批窗口。截不到的（例如部分已最小化的窗口）不会出现在结果里。
    static func capture(windowIDs: [CGWindowID], maxPixelSize: CGFloat = 560) async -> [CGWindowID: NSImage] {
        guard isAuthorized, !windowIDs.isEmpty else { return [:] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return [:] }
        let wanted = Set(windowIDs)
        var result: [CGWindowID: NSImage] = [:]
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for window in content.windows where wanted.contains(window.windowID) {
                group.addTask {
                    let size = window.frame.size
                    guard size.width > 1, size.height > 1 else { return (window.windowID, nil) }
                    let scale = min(1, maxPixelSize / max(size.width, size.height)) * 2
                    let configuration = SCStreamConfiguration()
                    configuration.width = max(1, Int(size.width * scale))
                    configuration.height = max(1, Int(size.height * scale))
                    configuration.showsCursor = false
                    configuration.ignoreShadowsSingleWindow = true
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
                        return (window.windowID, nil)
                    }
                    return (window.windowID, NSImage(cgImage: image, size: size))
                }
            }
            for await (id, image) in group {
                if let image { result[id] = image }
            }
        }
        return result
    }
}
