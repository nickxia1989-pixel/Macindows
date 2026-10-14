import AppKit
import ScreenCaptureKit

/// 把程序坞的名称气泡遮掉。
///
/// 鼠标停在图标上时，程序坞会在图标上方显示它的名称气泡。悬停窗贴着程序坞摆的时候正好压在气泡上，
/// 但程序坞的那种玻璃很透，气泡会从缝里透出来，尖角还会从底下露出来。系统没有不显示气泡的办法
/// （气泡画在程序坞自己那扇窗口里，也没有对应的设置），同类工具都是任它露着。
///
/// 这里的做法是：把气泡所在的那一小块屏幕，换成它背后原本的画面。截一张「不含程序坞、不含我们自己」的那一小块屏幕，
/// 放进一扇只比程序坞高一层的小窗口里，盖在气泡上。画面和周围严丝合缝，看起来就是气泡没有出现。
/// 背后的东西在动的话（比如在放视频），每隔一会儿重截一次。
///
/// 需要「屏幕录制」权限，所以只在用户开了缩略图时才用；程序坞本身不受任何影响。
final class LabelEraser {
    private let panel: NSPanel
    private let imageView = NSImageView()
    /// 正在遮的那一块（左上角为原点的全局坐标）；没在遮时为 nil
    private var covering: CGRect?
    /// 事先截好、还没用上的画面
    private var prepared: (rect: CGRect, image: CGImage, at: TimeInterval)?
    private var generation = 0
    private var refreshTimer: Timer?
    /// 截屏时除了这块遮挡自己，还要排除哪些窗口（给的是窗口号）
    private let alsoExclude: () -> [Int]

    init(alsoExclude: @escaping () -> [Int]) {
        self.alsoExclude = alsoExclude
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // 只比程序坞高一层：盖得住气泡，又在悬停窗底下，悬停窗的玻璃透出来的就是这张画面
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        panel.contentView = imageView
    }

    /// 气泡马上要被盖住了：先把那一块的画面截好，到时候立刻能用
    func prepare(_ rect: CGRect) {
        guard covering == nil else { return }
        generation += 1
        let token = generation
        Task { @MainActor [weak self] in
            guard let image = await self?.capture(rect), let self, token == self.generation else { return }
            self.prepared = (rect, image, ProcessInfo.processInfo.systemUptime)
        }
    }

    /// 开始（或者换一个位置）遮住这一块
    func cover(_ rect: CGRect) {
        if let covering, covering == rect { return }
        covering = rect
        generation += 1
        if let prepared, prepared.rect == rect, ProcessInfo.processInfo.systemUptime - prepared.at < 1 {
            show(prepared.image, at: rect)
        } else if panel.isVisible {
            // 换了位置而新画面还没到：先撤掉，不能拿别处的画面盖过来
            panel.orderOut(nil)
        }
        prepared = nil
        refresh()
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stop() {
        guard covering != nil || prepared != nil else { return }
        covering = nil
        prepared = nil
        generation += 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        if panel.isVisible { panel.orderOut(nil) }
        imageView.image = nil
    }

    private func refresh() {
        guard let rect = covering else { return }
        let token = generation
        Task { @MainActor [weak self] in
            guard let image = await self?.capture(rect), let self, token == self.generation, self.covering == rect else { return }
            self.show(image, at: rect)
        }
    }

    private func show(_ image: CGImage, at rect: CGRect) {
        imageView.image = NSImage(cgImage: image, size: rect.size)
        panel.setFrame(NSRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// 截下这一块屏幕在「没有程序坞、没有悬停窗」时的样子。
    /// 每次都重新向系统要一遍窗口清单：要排除的是具体的几扇窗口（程序坞的、悬停窗、这块遮挡自己），而它们随时在出现和消失。
    /// 原位预览的那扇浮窗不排除——它本来就在气泡背后，该出现在画面里。
    @MainActor
    private func capture(_ rect: CGRect) async -> CGImage? {
        let own = Set(([panel.windowNumber] + alsoExclude()).filter { $0 > 0 }.map { CGWindowID($0) })
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.frame.intersects(rect) }) else { return nil }
        let excluded = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.dock" || own.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        // 截取范围用的是这块屏幕自己的坐标
        configuration.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = max(1, Int(rect.width * scale))
        configuration.height = max(1, Int(rect.height * scale))
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
