import AppKit

/// 首次启动时的权限引导。授权完成后自动关闭。
final class OnboardingWindowController: NSWindowController {
    private let status = NSTextField(labelWithString: L("正在等待授权…"))

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Macindows"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let title = NSTextField(labelWithString: L("Macindows 需要“辅助功能”权限"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: [
            L("它用这项权限做四件事：知道鼠标停在程序坞的哪个图标上、列出各个 App 的窗口、切换到你选的窗口、在你点击程序坞图标时先看一眼。"),
            L("Macindows 不联网，不读取窗口里的内容。"),
        ].joined(separator: "\n\n"))
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor

        let steps = NSTextField(wrappingLabelWithString: L("打开系统设置 → 隐私与安全性 → 辅助功能，把 Macindows 的开关打开。"))
        steps.font = .systemFont(ofSize: 13)

        let button = NSButton(title: L("打开系统设置"), target: self, action: #selector(openSettings))
        button.bezelStyle = .push
        button.keyEquivalent = "\\r"

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor

        let footer = NSStackView(views: [button, status])
        footer.orientation = .horizontal
        footer.spacing = 12

        let stack = NSStackView(views: [icon, title, body, steps, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: icon)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 22, right: 26)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 480),
        ])
        window.contentView = content
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func markGranted() {
        status.stringValue = L("已授权，Macindows 开始工作。")
        status.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.close() }
    }

    @objc private func openSettings() { Accessibility.openSettings() }
}
