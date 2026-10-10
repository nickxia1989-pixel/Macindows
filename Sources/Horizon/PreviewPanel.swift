import AppKit

/// 悬停窗里要展示的一个窗口。不区分它是开着、隐藏还是最小化：对「我要切到哪个窗口」来说这不重要。
struct PreviewEntry {
    let title: String
    /// 是否就是用户眼下正在用的那个窗口
    let isCurrent: Bool
    /// 窗口的宽高比；缩略图还没截到时先按它占位，免得图到了以后版面跳动
    let aspect: CGFloat?
    var thumbnail: NSImage?
}

/// 应用从不处于激活状态，按钮必须肯响应「第一次点击」，否则第一下会被系统当成激活窗口用掉
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 悬停窗里的一项。列表模式下是一行，缩略图模式下是一格。
final class PreviewItemView: NSView {
    static let rowHeight: CGFloat = 28
    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let currentFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// 一格里除缩略图之外占掉的宽和高（标题行与四周留白）
    static let cellChrome = CGSize(width: 8, height: 30)

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let entry: PreviewEntry
    /// 缩略图可用的最大范围；nil 表示列表行
    private let thumbBound: CGSize?
    private let highlight = NSView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let thumbView = NSImageView()
    private let closeButton = FirstMouseButton()
    private var tracking: NSTrackingArea?

    init(entry: PreviewEntry, thumbBound: CGSize?, placeholder: NSImage?) {
        self.entry = entry
        self.thumbBound = thumbBound
        super.init(frame: .zero)
        wantsLayer = true

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = thumbBound == nil ? 7 : 10
        highlight.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(highlight)

        titleLabel.stringValue = entry.title
        titleLabel.font = entry.isCurrent ? Self.currentFont : Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = entry.title
        addSubview(titleLabel)

        if thumbBound != nil {
            thumbView.wantsLayer = true
            thumbView.layer?.cornerRadius = 6
            thumbView.layer?.masksToBounds = true
            thumbView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            thumbView.layer?.borderWidth = entry.isCurrent ? 2 : 0.5
            thumbView.layer?.borderColor = (entry.isCurrent ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            thumbView.imageAlignment = .alignCenter
            if let image = entry.thumbnail {
                thumbView.imageScaling = .scaleAxesIndependently
                thumbView.image = image
            } else if let placeholder, let bound = thumbBound {
                // 还没截到画面（或截不到）时放一个 App 图标占位
                thumbView.imageScaling = .scaleProportionallyDown
                let side = min(48, bound.height * 0.5)
                let copy = placeholder.copy() as! NSImage
                copy.size = NSSize(width: side, height: side)
                thumbView.image = copy
            }
            addSubview(thumbView)
        } else {
            icon.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 12, weight: entry.isCurrent ? .semibold : .regular)
            icon.contentTintColor = entry.isCurrent ? .controlAccentColor : .secondaryLabelColor
            addSubview(icon)
        }

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭窗口")
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "关闭窗口"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        if let bound = thumbBound {
            highlight.frame = bounds
            titleLabel.frame = NSRect(x: 6, y: 5, width: max(0, width - 30), height: 17)
            closeButton.frame = NSRect(x: width - 23, y: 4, width: 18, height: 18)
            // 每一格大小相同，缩略图按窗口自己的比例缩进这一格里并居中
            let aspect = entry.thumbnail.map { $0.size.width / max($0.size.height, 1) } ?? entry.aspect ?? (bound.width / bound.height)
            let fitted = min(bound.width / aspect, bound.height)
            let size = CGSize(width: (fitted * aspect).rounded(), height: fitted.rounded())
            thumbView.frame = NSRect(x: ((width - size.width) / 2).rounded(), y: (26 + (bound.height - size.height) / 2).rounded(),
                                     width: size.width, height: size.height)
        } else {
            highlight.frame = bounds.insetBy(dx: 0, dy: 1)
            icon.frame = NSRect(x: 9, y: (height - 16) / 2, width: 16, height: 16)
            closeButton.frame = NSRect(x: width - 25, y: (height - 18) / 2, width: 18, height: 18)
            titleLabel.frame = NSRect(x: 32, y: (height - 17) / 2, width: max(0, width - 62), height: 17)
        }
    }

    // 整个条目是一个点击目标，只有关闭按钮例外
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton ? hit : self
    }

    // 应用本身从不处于激活状态，所以追踪区域必须是「始终有效」的
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
    }

    // 中键关闭，和浏览器标签页、Windows 任务栏的习惯一致
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    @objc private func closeClicked() { onClose?() }

    private func setHovering(_ hovering: Bool) {
        highlight.layer?.backgroundColor = (hovering ? NSColor.labelColor.withAlphaComponent(0.1) : .clear).cgColor
        closeButton.isHidden = !hovering
    }
}

/// 悬停窗的内容：一组窗口。没有标题行，只列窗口。
final class PreviewContentView: NSView {
    static let padding: CGFloat = 6
    static let spacing: CGFloat = 4
    /// 缩略图再窄就看不清了，这时改成竖排的标题列表（和 Windows 任务栏的做法一致）
    static let minThumbWidth: CGFloat = 104

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    private(set) var items: [PreviewItemView] = []
    private var extras: [NSView] = []

    override var isFlipped: Bool { true }

    private func reset() {
        (items as [NSView] + extras).forEach { $0.removeFromSuperview() }
        items = []
        extras = []
    }

    /// 重建内容并返回所需尺寸。maxSize 是屏幕上能给悬停窗的最大范围。
    @discardableResult
    func configure(entries: [PreviewEntry], thumbnails: Bool, placeholder: NSImage?, maxSize: CGSize) -> NSSize {
        reset()
        var size: NSSize?
        if thumbnails { size = layoutCells(entries, placeholder: placeholder, maxWidth: maxSize.width) }
        let result = size ?? layoutRows(entries, maxSize: maxSize)
        for (index, item) in items.enumerated() {
            item.onSelect = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
        }
        setFrameSize(result)
        return result
    }

    /// 横向一排，窗口多了就整体缩小；缩到最小还放不下则返回 nil，由调用方改用列表。
    private func layoutCells(_ entries: [PreviewEntry], placeholder: NSImage?, maxWidth: CGFloat) -> NSSize? {
        let count = CGFloat(entries.count)
        let preferred = entries.count > 1 ? CGSize(width: 200, height: 128) : CGSize(width: 280, height: 180)
        let available = maxWidth - Self.padding * 2 - Self.spacing * (count - 1)
        let width = min(preferred.width, (available / count).rounded(.down) - PreviewItemView.cellChrome.width)
        guard width >= Self.minThumbWidth else { return nil }
        let bound = CGSize(width: width, height: (width * preferred.height / preferred.width).rounded())
        let cell = CGSize(width: bound.width + PreviewItemView.cellChrome.width, height: bound.height + PreviewItemView.cellChrome.height)
        var x = Self.padding
        for entry in entries {
            let item = PreviewItemView(entry: entry, thumbBound: bound, placeholder: placeholder)
            item.frame = NSRect(origin: CGPoint(x: x, y: Self.padding), size: cell)
            addSubview(item)
            items.append(item)
            x += cell.width + Self.spacing
        }
        return NSSize(width: x - Self.spacing + Self.padding, height: cell.height + Self.padding * 2)
    }

    private func layoutRows(_ entries: [PreviewEntry], maxSize: CGSize) -> NSSize {
        // 屏幕放不下全部行时，只显示放得下的，并在末尾注明还有多少个
        let capacity = max(1, Int((maxSize.height - Self.padding * 2) / PreviewItemView.rowHeight))
        let visible = entries.count > capacity ? Array(entries.prefix(capacity - 1)) : entries
        let remaining = entries.count - visible.count

        // 宽度跟着最长的标题走，但有上下限
        var widest: CGFloat = 0
        for entry in visible {
            let font = entry.isCurrent ? PreviewItemView.currentFont : PreviewItemView.titleFont
            widest = max(widest, (entry.title as NSString).size(withAttributes: [.font: font]).width + 62)
        }
        let rowWidth = min(max(widest.rounded(.up) + 4, 220), min(420, maxSize.width - Self.padding * 2))
        var y = Self.padding
        for entry in visible {
            let item = PreviewItemView(entry: entry, thumbBound: nil, placeholder: nil)
            item.frame = NSRect(x: Self.padding, y: y, width: rowWidth, height: PreviewItemView.rowHeight)
            addSubview(item)
            items.append(item)
            y += PreviewItemView.rowHeight
        }
        if remaining > 0 {
            let more = NSTextField(labelWithString: "还有 \(remaining) 个窗口")
            more.font = .systemFont(ofSize: 12)
            more.textColor = .secondaryLabelColor
            more.frame = NSRect(x: Self.padding + 32, y: y + 6, width: rowWidth - 40, height: 16)
            addSubview(more)
            extras = [more]
            y += PreviewItemView.rowHeight
        }
        return NSSize(width: rowWidth + Self.padding * 2, height: y + Self.padding)
    }
}

/// 叠在程序坞旁边的独立浮窗。不抢焦点，不出现在调度中心和窗口切换里。
final class PreviewPanel: NSPanel {
    let content = PreviewContentView()
    private let glass = NSGlassEffectView()

    init() {
        glass.cornerRadius = 14
        glass.contentView = content
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // 只有需要键盘输入的控件才会让面板成为键盘焦点；点条目和按钮不会抢走当前窗口的焦点
        becomesKeyOnlyIfNeeded = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = glass
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func render(entries: [PreviewEntry], thumbnails: Bool, placeholder: NSImage?, maxSize: CGSize) -> NSSize {
        let size = content.configure(entries: entries, thumbnails: thumbnails, placeholder: placeholder, maxSize: maxSize)
        setContentSize(size)
        glass.frame = NSRect(origin: .zero, size: size)
        content.frame = NSRect(origin: .zero, size: size)
        return size
    }
}
