import AppKit

/// 悬停窗里要展示的一个窗口。不区分它是开着、隐藏还是最小化：对「我要切到哪个窗口」来说这不重要。
struct PreviewEntry {
    let title: String
    /// 是否就是用户眼下正在用的那个窗口
    let isCurrent: Bool
    /// 窗口的宽高比；缩略图还没截到时先按它占位，免得图到了以后版面跳动
    let aspect: CGFloat?
    var thumbnail: NSImage?
    /// 不是真正的窗口，而是「这个 App 还没开窗口，点这里开一个」的占位项（标题是 App 的名字）
    var isPlaceholder = false
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
            icon.image = NSImage(systemSymbolName: entry.isPlaceholder ? "macwindow.badge.plus" : "macwindow", accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 12, weight: entry.isCurrent ? .semibold : .regular)
            icon.contentTintColor = entry.isCurrent ? .controlAccentColor : .secondaryLabelColor
            addSubview(icon)
        }

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("关闭窗口"))
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = L("关闭窗口")
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

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
    }

    // 中键关闭，和浏览器标签页、Windows 任务栏的习惯一致
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, !entry.isPlaceholder { onClose?() }
    }

    @objc private func closeClicked() { onClose?() }

    /// 鼠标是否正停在这一项上。由容器按鼠标位置统一设置
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            highlight.layer?.backgroundColor = (isHighlighted ? NSColor.labelColor.withAlphaComponent(0.1) : .clear).cgColor
            closeButton.isHidden = !isHighlighted || entry.isPlaceholder
        }
    }
}

/// 玻璃边缘的反光。系统的玻璃控件边缘有一圈「上亮下暗」的高光，面上也是上浅下深，看起来有厚度；
/// NSGlassEffectView 画出来的这层很淡，单独看就像一块平的磨砂板，这里把它补足。
final class GlassRimView: NSView {
    var cornerRadius: CGFloat = 16 { didSet { needsLayout = true } }

    /// 一套高光的强度。sheen 是面上的「顶部提亮、底部压暗」，rim 是边缘那圈亮线从上到下四个位置的亮度
    struct Look {
        var sheenTop: CGFloat
        var sheenBottom: CGFloat
        var rim: [CGFloat]
    }

    var darkLook = Look(sheenTop: 0.10, sheenBottom: 0.08, rim: [0.46, 0.16, 0.06, 0.18]) { didSet { needsLayout = true } }
    // 浅色下面上的提亮必须很淡：稍重一点就像蒙了一层白雾，玻璃后面的颜色透不出来（实测对比过）
    var lightLook = Look(sheenTop: 0.06, sheenBottom: 0.03, rim: [0.85, 0.4, 0.18, 0.35]) { didSet { needsLayout = true } }

    private let sheen = CAGradientLayer()
    private let sheenMask = CAShapeLayer()
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        sheen.mask = sheenMask
        rim.mask = rimMask
        rimMask.fillColor = nil
        rimMask.strokeColor = NSColor.black.cgColor
        rimMask.lineWidth = 1
        // 图层的单位坐标 y 向上：1 是顶，0 是底
        for gradient in [sheen, rim] {
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(gradient)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 纯装饰，不接鼠标
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { needsLayout = true }

    override func layout() {
        super.layout()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        func white(_ alpha: CGFloat) -> CGColor { NSColor.white.withAlphaComponent(alpha).cgColor }
        func black(_ alpha: CGFloat) -> CGColor { NSColor.black.withAlphaComponent(alpha).cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for gradient in [sheen, rim] { gradient.frame = bounds }
        sheenMask.path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = max(0, cornerRadius - 0.5)
        rimMask.path = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
        // 面：上沿略亮，下沿略暗
        let look = dark ? darkLook : lightLook
        sheen.colors = [white(look.sheenTop), white(0), black(look.sheenBottom)]
        sheen.locations = [0, 0.55, 1]
        // 边：顶上一道亮线，两侧淡下去，底边留一点反光
        rim.colors = look.rim.map(white)
        rim.locations = [0, 0.3, 0.72, 1]
        CATransaction.commit()
    }
}

/// 悬停窗的内容：一组窗口，没有标题行。
final class PreviewContentView: NSView {
    static let padding: CGFloat = 6
    static let spacing: CGFloat = 4
    /// 缩略图再窄就看不清了，这时改成竖排的标题列表（和 Windows 任务栏的做法一致）
    static let minThumbWidth: CGFloat = 104

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    private(set) var items: [PreviewItemView] = []
    private var extras: [NSView] = []
    private var tracking: NSTrackingArea?

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
        // 内容是整批重建的（缩略图到了、标题变了都会重建），新建出来的条目不会收到「鼠标进入」，
        // 所以重建之后要按鼠标当前的位置把高亮补上，否则鼠标明明停在上面却不亮
        refreshHover()
        return result
    }

    // MARK: 鼠标悬停的高亮
    //
    // 不依赖每个条目各自的「进入 / 离开」事件：那种事件只在越过边界的一刻触发，条目一重建或鼠标移动得快就会漏。
    // 改为只看鼠标此刻在哪——在哪一项的范围里就亮哪一项。

    /// point 是窗口坐标；传 nil 表示鼠标不在这里
    func updateHover(windowPoint: NSPoint?) {
        let point = windowPoint.map { convert($0, from: nil) }
        for item in items {
            item.isHighlighted = point.map { item.frame.contains($0) } ?? false
        }
    }

    /// 按鼠标当前的实际位置重新确定高亮
    func refreshHover() {
        guard let window else {
            updateHover(windowPoint: nil)
            return
        }
        let point = window.mouseLocationOutsideOfEventStream
        updateHover(windowPoint: bounds.contains(convert(point, from: nil)) ? point : nil)
    }

    // 应用本身从不处于激活状态，所以追踪区域必须是「始终有效」的
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(windowPoint: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { updateHover(windowPoint: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { updateHover(windowPoint: nil) }

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
            let more = NSTextField(labelWithString: remaining == 1 ? L("还有 1 个窗口") : String(format: L("还有 %d 个窗口"), remaining))
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
    /// 玻璃四周留出的透明边，用来画阴影
    static let margin: CGFloat = 28

    let content = PreviewContentView()
    private let glass = NSGlassEffectView()
    private let root = NSView()
    private let rimView = GlassRimView()
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()

    init() {
        glass.contentView = content
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // 只有需要键盘输入的控件才会让面板成为键盘焦点；点条目和按钮不会抢走当前窗口的焦点
        becomesKeyOnlyIfNeeded = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        // 不用窗口自带的阴影：它会沿着形状描一圈生硬的深色细线。改为自己画一层柔和的
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        root.wantsLayer = true
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.3
        shadowLayer.shadowRadius = 9
        shadowLayer.shadowOffset = CGSize(width: 0, height: -3)
        // 只留玻璃外面的那一圈：玻璃是半透明的，阴影垫在它底下会把它整体压暗
        shadowMask.fillRule = .evenOdd
        shadowLayer.mask = shadowMask
        root.layer?.addSublayer(shadowLayer)
        root.addSubview(glass)
        root.addSubview(rimView)
        contentView = root
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func render(entries: [PreviewEntry], thumbnails: Bool, placeholder: NSImage?, maxSize: CGSize) -> NSSize {
        apply(content.configure(entries: entries, thumbnails: thumbnails, placeholder: placeholder, maxSize: maxSize), cornerRadius: 16)
    }

    private func apply(_ size: NSSize, cornerRadius: CGFloat) -> NSSize {
        let margin = Self.margin
        let bounds = NSRect(x: 0, y: 0, width: size.width + margin * 2, height: size.height + margin * 2)
        let card = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        setContentSize(bounds.size)
        root.frame = bounds
        glass.cornerRadius = cornerRadius
        glass.frame = card
        rimView.frame = card
        rimView.cornerRadius = cornerRadius
        content.frame = NSRect(origin: .zero, size: size)

        let outline = CGPath(roundedRect: card, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(outline)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = outline
        shadowMask.frame = bounds
        shadowMask.path = outside
        CATransaction.commit()
        return size
    }

    /// 玻璃卡片本身在屏幕上的位置（不含四周的透明边）
    var cardFrame: NSRect { frame.insetBy(dx: Self.margin, dy: Self.margin) }

    func setCardOrigin(_ origin: NSPoint) {
        setFrameOrigin(NSPoint(x: origin.x - Self.margin, y: origin.y - Self.margin))
    }
}
