import AppKit

/// 原位预览：鼠标在悬停窗的某一项上停住时，在那扇窗口真实所在的位置放一张它的全尺寸画面，
/// 不用真的切过去就能看清它（和 Windows 任务栏的「速览」是一回事）。
///
/// 这是 Macindows 自己的一扇浮窗，只显示一张图：浮在普通窗口上面、在悬停窗和程序坞下面，不接鼠标。
/// 被预览的窗口本身不动。
final class PeekController {
    private let panel: NSPanel
    private let imageView = NSImageView()
    private var windowID: CGWindowID?
    private var generation = 0

    /// 正在预览的窗口；没在预览时为 nil
    var current: CGWindowID? { panel.isVisible ? windowID : nil }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // 比普通窗口高，比浮动面板、程序坞低
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // 阴影跟着画面的形状走（画面本身带着窗口的圆角）
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        panel.contentView = imageView
    }

    /// 在 frame（AppKit 坐标）处预览一扇窗口。先用手头的缩略图顶上，全尺寸的画面截到了再换。
    func show(windowID id: CGWindowID, frame: NSRect, placeholder: NSImage?) {
        generation += 1
        let token = generation
        let switching = panel.isVisible
        if windowID != id || !switching {
            imageView.image = placeholder
        }
        windowID = id
        panel.setFrame(frame, display: true)
        if placeholder != nil { present(animated: !switching) }

        Task { @MainActor [weak self] in
            let image = await Thumbnailer.capture(windowIDs: [id], fullResolution: true)[id]
            guard let self, token == self.generation, let image else { return }
            self.imageView.image = image
            self.present(animated: !self.panel.isVisible)
        }
    }

    private func present(animated: Bool) {
        panel.invalidateShadow()
        guard !panel.isVisible || panel.alphaValue < 1 else { return }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.15 : 0
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        generation += 1
        let token = generation
        windowID = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, token == self.generation else { return }
            self.panel.orderOut(nil)
            self.imageView.image = nil
        })
    }
}
