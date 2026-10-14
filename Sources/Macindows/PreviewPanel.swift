import AppKit
import MacindowsCore

/// 悬停窗里要展示的一个窗口。不区分它是开着、隐藏还是最小化：对「我要切到哪个窗口」来说这不重要。
struct PreviewEntry {
    let title: String
    /// 窗口的宽高比；缩略图还没截到时先按它占位，免得图到了以后版面跳动
    let aspect: CGFloat?
    var thumbnail: NSImage?
    /// 不是真正的窗口，而是「这个 App 还没开窗口，点这里开一个」的入口。它和一张预览一样大。
    /// 知道点了以后会出来的那扇窗口长什么样时，thumbnail 就是它的画面，看上去和一扇开着的窗口一样；
    /// 不知道时是一扇空白的窗口，正中是 App 的图标，标题是 App 的名字
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
    /// 缩略图上方那一行（标题和关闭按钮）的高度
    private static let headerHeight: CGFloat = 30
    /// 标题底牌、关闭按钮的高度
    private static let chipHeight: CGFloat = 22
    /// 一格里除缩略图之外占掉的宽和高（标题行与四周留白）
    static let cellChrome = CGSize(width: 8, height: headerHeight + 4)
    /// 鼠标停上来时描在缩略图外面的那一圈的粗细
    private static let ringWidth: CGFloat = 3
    private static let thumbRadius: CGFloat = 6

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let entry: PreviewEntry
    /// 缩略图可用的最大范围；nil 表示列表行
    private let thumbBound: CGSize?
    private let highlight = NSView()
    private let icon = NSImageView()
    /// 垫在标题底下的底牌，只在缩略图那种版面里用。
    /// 程序坞的玻璃非常透，字直接写在上面，背后一白或者一花就看不清；程序坞自己给图标名称配的也是一个带底色的气泡，这里照做
    private let titleChip = NSView()
    private let closeChip = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let thumbView = NSImageView()
    /// 垫在缩略图底下的投影。缩略图自己要裁圆角，裁了就画不出投影，所以单独一层
    private let thumbShadow = NSView()
    /// 只让投影露出缩略图以外的那一圈：有的缩略图是半透明的，投影垫在底下会把它弄脏
    private let shadowMask = CAShapeLayer()
    /// 鼠标停上来时描在缩略图外面的一圈强调色
    private let ring = NSView()
    private let closeButton = FirstMouseButton()

    init(entry: PreviewEntry, thumbBound: CGSize?, placeholder: NSImage?) {
        self.entry = entry
        self.thumbBound = thumbBound
        super.init(frame: .zero)
        wantsLayer = true

        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 7
        highlight.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(highlight)

        if thumbBound != nil {
            for chip in [titleChip, closeChip] {
                chip.wantsLayer = true
                chip.layer?.cornerRadius = Self.chipHeight / 2
                addSubview(chip)
            }
            closeChip.isHidden = true
        }
        titleLabel.stringValue = entry.title
        titleLabel.font = Self.titleFont
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.toolTip = entry.title
        addSubview(titleLabel)

        if let bound = thumbBound {
            thumbView.wantsLayer = true
            thumbView.layer?.cornerRadius = Self.thumbRadius
            thumbView.layer?.masksToBounds = true
            thumbView.layer?.borderWidth = 0.5
            thumbView.imageAlignment = .alignCenter
            thumbShadow.wantsLayer = true
            thumbShadow.layer?.shadowColor = NSColor.black.cgColor
            thumbShadow.layer?.shadowRadius = 5
            thumbShadow.layer?.shadowOffset = CGSize(width: 0, height: 2)
            shadowMask.fillRule = .evenOdd
            thumbShadow.layer?.mask = shadowMask
            ring.wantsLayer = true
            ring.layer?.cornerRadius = Self.thumbRadius + Self.ringWidth
            ring.layer?.borderWidth = Self.ringWidth
            ring.isHidden = true
            if let image = entry.thumbnail {
                thumbView.imageScaling = .scaleAxesIndependently
                thumbView.image = image
            } else if let placeholder {
                // 没有画面可放时放一个 App 图标：窗口的画面还没截到（或截不到），或者这个 App 根本没开窗口。
                // 后一种是一扇空白的窗口，图标大一些；描边和投影都和真正的窗口画面一样
                thumbView.imageScaling = .scaleProportionallyDown
                let side = min(entry.isPlaceholder ? 64 : 48, bound.height * 0.5)
                let copy = placeholder.copy() as! NSImage
                copy.size = NSSize(width: side, height: side)
                thumbView.image = copy
            }
            addSubview(thumbShadow)
            addSubview(thumbView)
            addSubview(ring)
        } else {
            icon.image = NSImage(systemSymbolName: entry.isPlaceholder ? "macwindow.badge.plus" : "macwindow", accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
            addSubview(icon)
        }

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("关闭窗口"))
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        closeButton.isBordered = false
        closeButton.toolTip = L("关闭窗口")
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        if let bound = thumbBound {
            // 标题底牌贴着字的宽度走，放不下时截断；右边给关闭按钮留出位置
            let chip = Self.chipHeight, top = ((Self.headerHeight - chip) / 2).rounded(), inset: CGFloat = 9
            // 文字控件自己两侧各有 2 点留白，算宽度时要算上，不然刚好放得下的标题也会被截断
            let text = (entry.title as NSString).size(withAttributes: [.font: Self.titleFont]).width.rounded(.up) + 4
            let chipWidth = max(chip, min(text + (inset - 2) * 2, width - 8 - chip - 4))
            titleChip.frame = NSRect(x: 4, y: top, width: chipWidth, height: chip)
            titleLabel.frame = NSRect(x: 4 + inset - 2, y: top + (chip - 17) / 2, width: chipWidth - (inset - 2) * 2, height: 17)
            closeChip.frame = NSRect(x: width - 4 - chip, y: top, width: chip, height: chip)
            closeButton.frame = closeChip.frame
            // 每一格大小相同，缩略图按窗口自己的比例缩进这一格里并居中
            let aspect = entry.thumbnail.map { $0.size.width / max($0.size.height, 1) } ?? entry.aspect ?? (bound.width / bound.height)
            let fitted = min(bound.width / aspect, bound.height)
            let size = CGSize(width: (fitted * aspect).rounded(), height: fitted.rounded())
            let frame = NSRect(x: ((width - size.width) / 2).rounded(), y: (Self.headerHeight + (bound.height - size.height) / 2).rounded(),
                               width: size.width, height: size.height)
            thumbView.frame = frame
            ring.frame = frame.insetBy(dx: -Self.ringWidth, dy: -Self.ringWidth)
            thumbShadow.frame = frame
            let shape = CGPath(roundedRect: NSRect(origin: .zero, size: size), cornerWidth: Self.thumbRadius, cornerHeight: Self.thumbRadius, transform: nil)
            thumbShadow.layer?.shadowPath = shape
            // 遮罩比缩略图大出一圈，中间挖掉缩略图本身
            let around = NSRect(origin: .zero, size: size).insetBy(dx: -30, dy: -30)
            let outside = CGMutablePath()
            outside.addRect(around)
            outside.addPath(shape)
            shadowMask.frame = NSRect(origin: .zero, size: size)
            shadowMask.path = outside
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
            closeButton.isHidden = !isHighlighted || entry.isPlaceholder
            closeChip.isHidden = closeButton.isHidden
            updateColors()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// 各处的颜色，包括鼠标停在这一项上时的样子。颜色按这块视图自己的深浅外观来取，不依赖调用时的全局状态。
    ///
    /// 鼠标停上来时——
    /// 列表行：和系统菜单一样，整行铺上强调色、字变白。
    /// 缩略图：在窗口画面外面描一圈强调色，和调度中心里指着一个窗口时一样。画面本身不动、不放大：
    /// 试过让它略微抬起，鼠标一扫过去一排窗口挨个跳一下，看着难受。也试过在整格底下垫一块底色，像网页上的卡片。
    private func updateColors() {
        let dark = effectiveAppearance.isDark
        guard thumbBound != nil else {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                highlight.layer?.backgroundColor = isHighlighted ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            }
            titleLabel.textColor = isHighlighted ? .white : .labelColor
            icon.contentTintColor = isHighlighted ? .white : .secondaryLabelColor
            closeButton.contentTintColor = isHighlighted ? NSColor.white.withAlphaComponent(0.9) : .secondaryLabelColor
            return
        }
        // 底牌的深浅跟系统外观走，和程序坞的名称气泡一样：深色外观下是深色底白字，浅色外观下是浅色底黑字。
        // 底色够实，字的对比度就由它保证，不再取决于玻璃背后是什么
        let chipFill = dark ? NSColor.black.withAlphaComponent(0.5) : NSColor.white.withAlphaComponent(0.78)
        titleChip.layer?.backgroundColor = chipFill.cgColor
        closeChip.layer?.backgroundColor = chipFill.cgColor
        titleLabel.textColor = dark ? .white : NSColor.black.withAlphaComponent(0.85)
        closeButton.contentTintColor = dark ? NSColor.white.withAlphaComponent(0.85) : NSColor.black.withAlphaComponent(0.6)
        ring.isHidden = !isHighlighted
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.layer?.borderColor = NSColor.controlAccentColor.cgColor
            // 窗口画面常常是一片白，板子在浅色外观下也偏白，只靠一条淡淡的细线分不开，所以描边要实一些，再配上投影
            thumbView.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.26)).cgColor
            if entry.isPlaceholder, entry.thumbnail == nil {
                thumbView.layer?.backgroundColor = Self.emptyFill(dark: dark).cgColor
            } else {
                // 画面还没截到的窗口：一扇不透明的空窗口。不能透——悬停窗贴着程序坞时，底下压着程序坞的名称气泡
                thumbView.layer?.backgroundColor = NSColor(white: dark ? 0.2 : 0.95, alpha: 1).cgColor
            }
        }
        thumbShadow.layer?.shadowOpacity = dark ? 0.35 : 0.22
    }

    /// 空白窗口的底色：在玻璃上压一层很淡的暗色，像一块嵌在板子里的空玻璃片。
    /// 试过用窗口本来的白底，一大块白很刺眼；也试过半透明的白和灰，都不如这样安静（在真实玻璃上并排比过）
    private static func emptyFill(dark: Bool) -> NSColor {
        NSColor.black.withAlphaComponent(dark ? 0.22 : 0.06)
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
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

    var darkLook = Look(sheenTop: 0.05, sheenBottom: 0.04, rim: [0.46, 0.16, 0.06, 0.18]) { didSet { needsLayout = true } }
    // 浅色下面上的提亮必须很淡：稍重一点就像蒙了一层白雾，玻璃后面的颜色透不出来（实测对比过）
    var lightLook = Look(sheenTop: 0.03, sheenBottom: 0.02, rim: [0.85, 0.4, 0.18, 0.35]) { didSet { needsLayout = true } }

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
    static let padding: CGFloat = 8
    static let spacing: CGFloat = 4
    /// 缩略图再窄就看不清了，这时改成竖排的标题列表（和 Windows 任务栏的做法一致）
    static let minThumbWidth: CGFloat = 104

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    /// 鼠标停着的那一项换了（nil 表示哪一项都不在）。内容整批重建不算换：只要还停在同一个位置上就不会再报
    var onHighlight: ((Int?) -> Void)?
    private(set) var highlightedIndex: Int?
    /// 这一次排成了竖排的标题列表，而不是一排缩略图
    private(set) var isList = false
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
        isList = size == nil
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
        var index: Int?
        for (offset, item) in items.enumerated() {
            item.isHighlighted = point.map { item.frame.contains($0) } ?? false
            if item.isHighlighted { index = offset }
        }
        if index != highlightedIndex {
            highlightedIndex = index
            onHighlight?(index)
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
            widest = max(widest, (entry.title as NSString).size(withAttributes: [.font: PreviewItemView.titleFont]).width + 62)
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
    private var appearanceObservation: NSKeyValueObservation?
    /// 玻璃此刻用的是不是程序坞那种；还没定过时为 nil
    private var glassIsDock: Bool?

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
        // 玻璃的深浅可能被单独定死（见 useGlass），里面的内容始终跟着系统的深浅外观走
        appearanceObservation = observe(\.effectiveAppearance, options: [.initial]) { panel, _ in
            panel.content.appearance = panel.effectiveAppearance
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 悬停窗从不成为当前窗口，而系统会把非当前窗口里的玻璃画成发闷的磨砂（实测对比过：同一块玻璃，
    /// 只差这一项，一个通透、边缘有折射，一个像蒙了层雾）。程序坞的玻璃一直是通透的那种，
    /// 所以让悬停窗也始终按「当前窗口」的样子来画。这是 NSWindow 一个未公开的方法，Chrome、WebKit 也这样改写它。
    @objc(hasKeyAppearance) var alwaysLooksActive: Bool { true }

    /// 出现时从程序坞那一侧滑出来一小段。只挪画面，窗口本身已经在最终的位置上，鼠标该点哪还是点哪
    func playEntrance(from edge: DockEdge, duration: TimeInterval) {
        guard let layer = root.layer else { return }
        let distance: CGFloat = 7
        let offset: CGSize
        switch edge {
        case .bottom: offset = CGSize(width: 0, height: -distance)
        case .left: offset = CGSize(width: -distance, height: 0)
        case .right: offset = CGSize(width: distance, height: 0)
        }
        let slide = CABasicAnimation(keyPath: "transform.translation")
        slide.fromValue = NSValue(size: offset)
        slide.toValue = NSValue(size: .zero)
        slide.duration = duration
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(slide, forKey: "entrance")
    }

    /// 两种版面用两种玻璃。
    ///
    /// 一排缩略图：程序坞的那种玻璃。它非常透，和程序坞摆在一起是同一种质感；这种版面里的东西都有自己的底
    /// （窗口画面不透明，标题有底牌），不怕背后花。
    /// 标题列表：字直接写在玻璃上，所以用系统给菜单这类界面准备的磨砂玻璃，背后是什么都看得清字。
    /// 拿不到程序坞那种玻璃的系统上（见 DockGlass），两种版面都用磨砂的。
    private func useGlass(dock: Bool) {
        let wantsDock = dock && DockGlass.variant != nil
        guard wantsDock != glassIsDock else { return }
        glassIsDock = wantsDock
        if wantsDock, DockGlass.apply(to: glass) {
            // 实测程序坞的玻璃不随深浅外观变：深色外观下它也是浅色外观里那种通透的样子
            // （并排取色：垫黑底时两者都是 53，垫白底时都是 234；按深色外观画的话是 21 和 191，明显更暗）
            glass.appearance = NSAppearance(named: .aqua)
        } else {
            glass.style = .regular
            glass.appearance = nil
        }
        // 程序坞那种玻璃自带边缘的折射和高光，不用再补；磨砂的那种边缘很平，补一圈
        rimView.isHidden = wantsDock
    }

    func render(entries: [PreviewEntry], thumbnails: Bool, placeholder: NSImage?, maxSize: CGSize) -> NSSize {
        let size = content.configure(entries: entries, thumbnails: thumbnails, placeholder: placeholder, maxSize: maxSize)
        useGlass(dock: !content.isList)
        return apply(size, cornerRadius: 20)
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
