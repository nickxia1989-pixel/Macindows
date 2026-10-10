import AppKit

/// 悬停窗里要展示的一个窗口
struct PreviewEntry {
    enum State {
        case visible, hidden, minimized

        var label: String? {
            switch self {
            case .visible: return nil
            case .hidden: return "已隐藏"
            case .minimized: return "已最小化"
            }
        }
    }

    let title: String
    let state: State
    /// 是否就是用户眼下正在用的那个窗口
    let isCurrent: Bool
    /// 窗口的宽高比；缩略图还没截到时先按它占位，免得图到了以后版面跳动
    let aspect: CGFloat?
    var thumbnail: NSImage?
}

/// 悬停窗里的一项。列表模式下是一行，缩略图模式下是一格。
final class PreviewItemView: NSView {
    static let rowHeight: CGFloat = 28
    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let currentFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let tagFont = NSFont.systemFont(ofSize: 11)
    static let cellChrome = CGSize(width: 8, height: 30)

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let entry: PreviewEntry
    private let thumbSize: CGSize?
    private let highlight = NSView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let tagLabel = NSTextField(labelWithString: "")
    private let thumbView = NSImageView()
    private let scrim = NSView()
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?

    /// thumbSize 为 nil 表示列表行
    init(entry: PreviewEntry, thumbSize: CGSize?, placeholder: NSImage?) {
        self.entry = entry
        self.thumbSize = thumbSize
        super.init(frame: .zero)
        wantsLayer = true

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = thumbSize == nil ? 7 : 10
        highlight.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(highlight)

        let offScreen = entry.state != .visible
        titleLabel.stringValue = entry.title
        titleLabel.font = entry.isCurrent ? Self.currentFont : Self.titleFont
        titleLabel.textColor = offScreen ? .secondaryLabelColor : .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = entry.title
        addSubview(titleLabel)

        if thumbSize != nil {
            thumbView.wantsLayer = true
            thumbView.layer?.cornerRadius = 6
            thumbView.layer?.masksToBounds = true
            thumbView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            thumbView.layer?.borderWidth = entry.isCurrent ? 2 : 0.5
            thumbView.layer?.borderColor = (entry.isCurrent ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            thumbView.imageAlignment = .alignCenter
            // 有「已隐藏 / 已最小化」字样盖在上面时不再放占位图标，免得两者叠在一起
            setThumbnail(entry.thumbnail, placeholder: entry.state.label == nil ? placeholder : nil)
            addSubview(thumbView)

            if let label = entry.state.label {
                scrim.wantsLayer = true
                scrim.layer?.cornerRadius = 6
                scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
                addSubview(scrim)
                tagLabel.stringValue = label
                tagLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
                tagLabel.textColor = .white
                tagLabel.alignment = .center
                addSubview(tagLabel)
            }
        } else {
            let symbol: String
            switch entry.state {
            case .visible: symbol = "macwindow"
            case .hidden: symbol = "eye.slash"
            case .minimized: symbol = "arrow.down.right.and.arrow.up.left"
            }
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 12, weight: entry.isCurrent ? .semibold : .regular)
            icon.contentTintColor = entry.isCurrent ? .controlAccentColor : (offScreen ? .tertiaryLabelColor : .secondaryLabelColor)
            addSubview(icon)

            if let label = entry.state.label {
                tagLabel.stringValue = label
                tagLabel.font = Self.tagFont
                tagLabel.textColor = .secondaryLabelColor
                addSubview(tagLabel)
            }
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

    func setThumbnail(_ image: NSImage?, placeholder: NSImage? = nil) {
        if let image {
            thumbView.imageScaling = .scaleAxesIndependently
            thumbView.image = image
        } else if let placeholder {
            // 截不到画面时放一个 App 图标占位
            thumbView.imageScaling = .scaleProportionallyDown
            let size = min(48, (thumbSize?.height ?? 48) * 0.5)
            let copy = placeholder.copy() as! NSImage
            copy.size = NSSize(width: size, height: size)
            thumbView.image = copy
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        if let thumbSize {
            highlight.frame = bounds
            titleLabel.frame = NSRect(x: 6, y: 5, width: width - 30, height: 17)
            closeButton.frame = NSRect(x: width - 23, y: 4, width: 18, height: 18)
            let thumbFrame = NSRect(x: ((width - thumbSize.width) / 2).rounded(), y: 26, width: thumbSize.width, height: thumbSize.height)
            thumbView.frame = thumbFrame
            scrim.frame = thumbFrame
            tagLabel.frame = NSRect(x: thumbFrame.minX, y: thumbFrame.midY - 8, width: thumbFrame.width, height: 16)
        } else {
            highlight.frame = bounds.insetBy(dx: 0, dy: 1)
            icon.frame = NSRect(x: 9, y: (height - 16) / 2, width: 16, height: 16)
            closeButton.frame = NSRect(x: width - 25, y: (height - 18) / 2, width: 18, height: 18)
            var titleRight = width - 30
            if entry.state.label != nil {
                tagLabel.sizeToFit()
                let tagWidth = tagLabel.frame.width
                tagLabel.frame = NSRect(x: width - 30 - tagWidth, y: (height - 14) / 2, width: tagWidth, height: 14)
                titleRight = tagLabel.frame.minX - 8
            }
            titleLabel.frame = NSRect(x: 32, y: (height - 17) / 2, width: max(0, titleRight - 32), height: 17)
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

/// 悬停窗的内容：一组条目。没有标题行，只列窗口。
final class PreviewContentView: NSView {
    static let padding: CGFloat = 6
    static let spacing: CGFloat = 4
    static let maxColumns = 3

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    private(set) var items: [PreviewItemView] = []

    override var isFlipped: Bool { true }

    /// 重建内容并返回所需尺寸
    @discardableResult
    func configure(entries: [PreviewEntry], thumbnails: Bool, placeholder: NSImage?) -> NSSize {
        items.forEach { $0.removeFromSuperview() }
        items = []
        let size = thumbnails ? layoutCells(entries, placeholder: placeholder) : layoutRows(entries)
        for (index, item) in items.enumerated() {
            item.onSelect = { [weak self] in self?.onSelect?(index) }
            item.onClose = { [weak self] in self?.onClose?(index) }
        }
        setFrameSize(size)
        return size
    }

    private func layoutRows(_ entries: [PreviewEntry]) -> NSSize {
        // 宽度跟着最长的标题走，但有上下限
        var widest: CGFloat = 0
        for entry in entries {
            let font = entry.isCurrent ? PreviewItemView.currentFont : PreviewItemView.titleFont
            var width = (entry.title as NSString).size(withAttributes: [.font: font]).width + 32 + 30
            if let label = entry.state.label {
                width += (label as NSString).size(withAttributes: [.font: PreviewItemView.tagFont]).width + 12
            }
            widest = max(widest, width)
        }
        let rowWidth = min(max(widest.rounded(.up) + 4, 220), 400)
        var y = Self.padding
        for entry in entries {
            let item = PreviewItemView(entry: entry, thumbSize: nil, placeholder: nil)
            item.frame = NSRect(x: Self.padding, y: y, width: rowWidth, height: PreviewItemView.rowHeight)
            addSubview(item)
            items.append(item)
            y += PreviewItemView.rowHeight
        }
        return NSSize(width: rowWidth + Self.padding * 2, height: y + Self.padding)
    }

    private func layoutCells(_ entries: [PreviewEntry], placeholder: NSImage?) -> NSSize {
        let bound = entries.count > 1 ? CGSize(width: 190, height: 122) : CGSize(width: 280, height: 180)
        var x = Self.padding, y = Self.padding, lineHeight: CGFloat = 0, maxRight: CGFloat = 0
        for (index, entry) in entries.enumerated() {
            if index > 0, index % Self.maxColumns == 0 {
                x = Self.padding
                y += lineHeight + Self.spacing
                lineHeight = 0
            }
            let aspect = entry.thumbnail.map { $0.size.width / max($0.size.height, 1) } ?? entry.aspect ?? 1.6
            let scale = min(bound.width / aspect, bound.height)
            let thumbSize = CGSize(width: (scale * aspect).rounded(), height: scale.rounded())
            let cellSize = CGSize(width: max(thumbSize.width, 132) + PreviewItemView.cellChrome.width,
                                  height: thumbSize.height + PreviewItemView.cellChrome.height)
            let item = PreviewItemView(entry: entry, thumbSize: thumbSize, placeholder: placeholder)
            item.frame = NSRect(origin: CGPoint(x: x, y: y), size: cellSize)
            addSubview(item)
            items.append(item)
            x += cellSize.width + Self.spacing
            maxRight = max(maxRight, x - Self.spacing)
            lineHeight = max(lineHeight, cellSize.height)
        }
        return NSSize(width: maxRight + Self.padding, height: y + lineHeight + Self.padding)
    }
}

/// 叠在程序坞旁边的独立浮窗。不抢焦点，不出现在调度中心和窗口切换里。
final class PreviewPanel: NSPanel {
    let content = PreviewContentView()
    private let container: NSView

    init() {
        let glass = NSGlassEffectView()
        glass.cornerRadius = 14
        glass.contentView = content
        container = glass
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func render(entries: [PreviewEntry], thumbnails: Bool, placeholder: NSImage?) -> NSSize {
        let size = content.configure(entries: entries, thumbnails: thumbnails, placeholder: placeholder)
        setContentSize(size)
        container.frame = NSRect(origin: .zero, size: size)
        content.frame = NSRect(origin: .zero, size: size)
        return size
    }
}
