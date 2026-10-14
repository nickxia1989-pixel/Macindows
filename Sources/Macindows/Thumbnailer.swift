import AppKit
import ScreenCaptureKit

/// 窗口缩略图。需要「屏幕录制」权限；没有权限时悬停窗只显示标题列表。
enum Thumbnailer {
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// 让系统弹出授权请求。授权后通常要重新打开应用才生效。
    /// 实测只调 CGRequestScreenCaptureAccess 时，系统有时既不弹窗、也不把应用登记进系统设置的列表，
    /// 所以再实际向截屏接口要一次内容：没有权限时这次调用会失败，但这是系统登记并询问用户的另一条路。
    static func requestAccess() {
        let granted = CGRequestScreenCaptureAccess()
        log("screen recording request: granted=\(granted)")
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            log("screen recording probe: " + (error.map { "failed \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "ok, \(content?.windows.count ?? 0) windows"))
        }
    }

    /// 系统的授权提示只在第一次请求时弹，之后（或者它根本没弹出来时）只能让用户自己去系统设置里打开
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 截取一批窗口。先用公开的截屏接口；它对已最小化的窗口会失败（实测报「无法开始流播放」），
    /// 这些再直接向窗口服务器要画面——窗口服务器一直留着最小化窗口的画面。两种办法都拿不到的不会出现在结果里。
    /// fullResolution 为真时按窗口原本的大小截（给「原位预览」用），否则缩到 maxPixelSize 以内。
    static func capture(windowIDs: [CGWindowID], maxPixelSize: CGFloat = 560, fullResolution: Bool = false) async -> [CGWindowID: NSImage] {
        guard isAuthorized, !windowIDs.isEmpty else { return [:] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return [:] }
        let wanted = Set(windowIDs)
        var result: [CGWindowID: NSImage] = [:]
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for window in content.windows where wanted.contains(window.windowID) {
                group.addTask {
                    let size = window.frame.size
                    guard size.width > 1, size.height > 1 else { return (window.windowID, nil) }
                    let scale = (fullResolution ? 1 : min(1, maxPixelSize / max(size.width, size.height))) * 2
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
        let missing = windowIDs.filter { result[$0] == nil }
        if !missing.isEmpty {
            let recovered = await Task.detached(priority: .userInitiated) { () -> [CGWindowID: CGImage] in
                var images: [CGWindowID: CGImage] = [:]
                for id in missing {
                    if let image = PrivateAPI.captureWindow(id, fullResolution: fullResolution) { images[id] = image }
                }
                return images
            }.value
            for (id, image) in recovered {
                result[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
            log("thumbnails: \(result.count)/\(windowIDs.count) captured, \(recovered.count) of them from the window server")
        }
        return result
    }
}
