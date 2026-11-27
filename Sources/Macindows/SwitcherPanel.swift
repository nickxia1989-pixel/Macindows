import AppKit
import MacindowsCore

struct SwitcherEntry {
    let app: NSRunningApplication
    /// nil 代表已确认没有可切换窗口（或枚举超时兜底）、但仍在运行的应用。
    var window: AppWindow?

    var lastPreview: NSImage?
    /// 为真表示应用在枚举时暂时未应答，仅作兜底卡片保留，不标注「没有打开的窗口」。
    var isFallback = false
    var previewSize: CGSize? { window?.frame?.size ?? lastPreview?.size }

    var title: String {
        window?.title ?? app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? L("应用")
    }

    var appName: String {
        app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? L("应用")
    }

    /// 顶部状态提示（普通在当前桌面上可见的窗口返回 nil）。
    var statusText: String? {
        if let window {
            if window.isMinimized { return L("已最小化") }
            if app.isHidden { return L("已隐藏") }
            if !window.isOnCurrentSpace { return L("其他桌面") }
            return nil
        }
        return isFallback ? nil : L("无打开窗口")
    }

    var statusSymbol: String? {
        if let window {
            if window.isMinimized { return "minus.circle.fill" }
            if app.isHidden { return "eye.slash.fill" }
            if !window.isOnCurrentSpace { return "rectangle.on.rectangle" }
        }
        return nil
    }

    var isDimmedPreview: Bool {
        if let window { return window.isMinimized || app.isHidden }
        return !isFallback
    }

    var key: SwitcherWindowKey {
        guard let window else { return .application(app.processIdentifier) }
        return SwitcherWindowKey(pid: app.processIdentifier, element: window.element, id: window.id)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class NumberBadge: NSView {
    private let height: CGFloat = 30
    private let label = NSTextField(labelWithString: "")
    private(set) var number: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        layer?.backgroundColor = NSColor(srgbRed: 0.82, green: 0.075, blue: 0.15, alpha: 1).cgColor
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.white.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 2
        layer?.shadowOffset = .zero
        label.font = .monospacedDigitSystemFont(ofSize: 17, weight: .bold)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.textColor = .white
        addSubview(label)
        setAccessibilityElement(false)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setNumber(_ value: String?, maxWidth: CGFloat) {
        number = value
        isHidden = value == nil
        guard let value else { return }
        label.stringValue = value
        let textSize = label.intrinsicContentSize
        let width = min(maxWidth, max(height, ceil(textSize.width) + 12))
        setFrameSize(NSSize(width: width, height: height))
        label.frame = NSRect(x: 4, y: round((height - textSize.height) / 2),
                             width: max(0, width - 8), height: textSize.height)
    }
}

private final class SwitcherCard: NSView {
    override var isFlipped: Bool { true }
    private static let previewRadius: CGFloat = 8
    private let entry: SwitcherEntry
    private let previewShadow = NSView()
    private let shadowMask = CAShapeLayer()
    private let preview = NSImageView()
    private let fallback = NSImageView()
    private let badge = NSImageView()
    private let statusPill = NSView()
    private let statusIcon = NSImageView()
    private let closeChip = NSView()
    private let closeButton = FirstMouseButton()
    private let title: NSTextField
    private let appCount = NumberBadge()
    private let name: String
    private let hasShortcutNumber: Bool
    private var selectedState = false
    private var hoveredState = false
    private var tracking: NSTrackingArea?
    let appPath: String?
    var onPick: (() -> Void)?
    var onClose: (() -> Void)?

    init(_ entry: SwitcherEntry, frame: NSRect, shortcutNumber: Int?) {
        self.entry = entry
        hasShortcutNumber = shortcutNumber != nil
        appPath = entry.app.bundleURL?.standardizedFileURL.path
        let detail = entry.window == nil ? (entry.isFallback ? nil : L("没有打开的窗口")) : entry.app.localizedName
        name = [entry.title, detail, entry.statusText, shortcutNumber.map { String(format: L("快捷键 %d"), $0) }]
            .compactMap { $0 }.joined(separator: " · ")
        title = NSTextField(labelWithString: entry.title)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous

        previewShadow.wantsLayer = true
        previewShadow.layer?.shadowColor = NSColor.black.cgColor
        previewShadow.layer?.shadowOpacity = 0.45
        previewShadow.layer?.shadowRadius = 7
        previewShadow.layer?.shadowOffset = CGSize(width: 0, height: 2)
        shadowMask.fillRule = .evenOdd
        previewShadow.layer?.mask = shadowMask
        addSubview(previewShadow)

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        preview.layer?.cornerRadius = Self.previewRadius
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        preview.layer?.borderWidth = 0.75
        addSubview(preview)

        fallback.image = entry.app.icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        fallback.imageScaling = .scaleProportionallyUpOrDown
        addSubview(fallback)
        badge.image = entry.app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        badge.imageScaling = .scaleProportionallyUpOrDown
        badge.wantsLayer = true
        badge.layer?.shadowColor = NSColor.black.cgColor
        badge.layer?.shadowOpacity = 0.55
        badge.layer?.shadowRadius = 2
        badge.layer?.shadowOffset = .zero
        addSubview(badge)

        if let symbol = entry.statusSymbol {
            statusPill.wantsLayer = true
            statusPill.layer?.cornerRadius = 9
            statusPill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
            statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: entry.statusText)
            statusIcon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            statusIcon.contentTintColor = .white
            statusIcon.frame = NSRect(x: 3, y: 3, width: 12, height: 12)
            statusPill.addSubview(statusIcon)
            statusPill.setAccessibilityElement(false)
            addSubview(statusPill)
        } else {
            statusPill.isHidden = true
        }

        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.frame = NSRect(x: 10, y: bounds.height - SwitcherLayout.titleSpace + 2, width: bounds.width - 20, height: 18)
        addSubview(title)
        addSubview(appCount)
        if let shortcutNumber {
            let key = NSTextField(labelWithString: String(shortcutNumber))
            key.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
            key.textColor = .white
            key.alignment = .center
            key.wantsLayer = true
            key.layer?.cornerRadius = 5
            key.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
            key.layer?.borderWidth = 0.5
            key.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
            key.frame = NSRect(x: SwitcherLayout.pictureInset + 4, y: SwitcherLayout.pictureInset + 4, width: 20, height: 17)
            key.setAccessibilityElement(false)
            addSubview(key)
        }

        closeChip.wantsLayer = true
        closeChip.layer?.cornerRadius = 10
        closeChip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        closeChip.layer?.borderWidth = 0.5
        closeChip.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        closeChip.isHidden = true
        addSubview(closeChip)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("关闭窗口"))
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        closeButton.contentTintColor = .white
        closeButton.isBordered = false
        closeButton.toolTip = L("关闭窗口")
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateDescription()
        badge.isHidden = true
        positionPicture(size: entry.previewSize)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage) {
        positionPicture(size: image.size)
        // 保留细描边与投影：浅色界面靠深色底板拉出反差，深色终端/编辑器靠细亮边分清轮廓。
        preview.layer?.borderWidth = 0.75
        preview.image = image
        preview.alphaValue = entry.isDimmedPreview ? 0.78 : 1
        fallback.isHidden = true
        badge.isHidden = false
        updateColors()
    }

    private func positionPicture(size: CGSize?) {
        let picture = SwitcherLayout.pictureFrame(for: size, in: bounds)
        preview.frame = picture
        previewShadow.frame = picture
        let shape = CGPath(roundedRect: NSRect(origin: .zero, size: picture.size),
                           cornerWidth: Self.previewRadius, cornerHeight: Self.previewRadius, transform: nil)
        previewShadow.layer?.shadowPath = shape
        let around = NSRect(origin: .zero, size: picture.size).insetBy(dx: -24, dy: -24)
        let outside = CGMutablePath()
        outside.addRect(around)
        outside.addPath(shape)
        shadowMask.frame = NSRect(origin: .zero, size: picture.size)
        shadowMask.path = outside
        let symbolSide = min(64, round(min(picture.width, picture.height) * 0.52))
        fallback.frame = NSRect(x: picture.midX - symbolSide / 2, y: picture.midY - symbolSide / 2,
                                width: symbolSide, height: symbolSide)
        let badgeSide = min(34, max(20, round(picture.height * 0.24)), bounds.width - 6)
        let badgeX = max(3, min(bounds.width - badgeSide - 3, picture.maxX - badgeSide + 2))
        badge.frame = NSRect(x: badgeX, y: max(3, picture.maxY - badgeSide + 2), width: badgeSide, height: badgeSide)
        statusPill.frame = NSRect(x: picture.minX + 4, y: max(picture.minY + 4, picture.maxY - 22), width: 18, height: 18)
        positionCloseButton()
    }

    private func positionCloseButton() {
        let inset = SwitcherLayout.pictureInset + 3
        let size: CGFloat = 20
        let x: CGFloat
        if appCount.number == nil {
            x = bounds.width - inset - size
        } else {
            // 右上角有未读角标时，关闭按钮放到角标左侧并避开左上角 1–9 编号。
            let minX = hasShortcutNumber ? (inset + 24) : inset
            x = max(minX, appCount.frame.minX - size - 4)
        }
        let frame = NSRect(x: x, y: inset, width: size, height: size)
        closeChip.frame = frame
        closeButton.frame = frame
    }

    func setAppCount(_ number: String?) {
        guard number != appCount.number else { return }
        let inset = SwitcherLayout.pictureInset
        appCount.setNumber(number, maxWidth: bounds.width - 2 * inset)
        appCount.setFrameOrigin(NSPoint(x: bounds.maxX - inset - appCount.frame.width, y: inset))
        positionCloseButton()
        updateDescription()
    }

    private func updateDescription() {
        let description = appCount.number.map { name + " · " + String(format: L("应用角标 %@"), $0) } ?? name
        toolTip = description
        setAccessibilityLabel(description)
    }

    func setSelected(_ selected: Bool) {
        selectedState = selected
        updateColors()
        setAccessibilitySelected(selected)
    }

    private func updateColors() {
        let showClose = hoveredState && entry.window != nil
        closeButton.isHidden = !showClose
        closeChip.isHidden = !showClose
        title.font = .systemFont(ofSize: 12.5, weight: selectedState ? .semibold : .medium)
        title.textColor = selectedState ? .white : (hoveredState ? NSColor.white.withAlphaComponent(0.95) : NSColor.white.withAlphaComponent(0.84))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if selectedState {
                layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
                layer?.borderColor = NSColor.controlAccentColor.cgColor
                layer?.borderWidth = 2.5
            } else if hoveredState {
                layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
                layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
                layer?.borderWidth = 1
            } else {
                layer?.backgroundColor = NSColor.white.withAlphaComponent(0.065).cgColor
                layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
                layer?.borderWidth = 0.5
            }
            preview.layer?.borderColor = NSColor.white.withAlphaComponent(preview.image == nil ? 0.16 : 0.22).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoveredState = true
        updateColors()
    }

    override func mouseExited(with event: NSEvent) {
        hoveredState = false
        updateColors()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton ? hit : self
    }
    override func mouseDown(with event: NSEvent) { onPick?() }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, entry.window != nil { onClose?() }
    }
    @objc private func closeClicked() { onClose?() }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }
}

/// 用同一页的预览一起展示卡片，后续截图更新原来的图像视图。
final class SwitcherPanel: NSPanel {
    /// 玻璃四周留出的透明边，用来画柔和圆角阴影，避免系统自带边框在深色下描出方形细线。
    static let margin: CGFloat = 28
    private static let cornerRadius: CGFloat = 22

    var onPick: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onTurnPage: ((Int) -> Void)?
    var onPageChange: ((Range<Int>) -> Void)?
    private let previews: SwitcherPreviews
    private let root = NSView()
    private let shadowLayer = CALayer()
    private let shadowMask = CAShapeLayer()
    private let glass = NSGlassEffectView()
    private let rimView = GlassRimView()
    private let canvas = FlippedView()
    private let headerDivider = NSView()
    private let headerIcon = NSImageView()
    private let heading = NSTextField(labelWithString: L("切换窗口"))
    private let statusTag = NSTextField(labelWithString: "")
    private let statusTagBackdrop = NSView()
    private let pageNumber = NSTextField(labelWithString: "")
    private var layout: SwitcherLayout?
    private var visibleFrame: NSRect = .zero
    private var cards: [SwitcherCard] = []
    private weak var highlighted: SwitcherCard?
    private var page: Range<Int> = 0..<0
    private var appBadges: [String: String] = [:]
    private var isDismissing = false
    private var transitionGeneration = 0
    private var lastPageTurn: TimeInterval = 0
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 玻璃卡片本身在屏幕上的区域（不含四周透明阴影边）。
    var cardFrame: NSRect { frame.insetBy(dx: Self.margin, dy: Self.margin) }

    /// 与悬停窗一致：让非激活面板的玻璃始终以活跃态渲染，避免发闷的磨砂质感。
    @objc(hasKeyAppearance) var alwaysLooksActive: Bool { true }

    init(previewCache: SharedPreviewCache = SharedPreviewCache()) {
        previews = SwitcherPreviews(cache: previewCache)
        glass.contentView = canvas
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        // 不用系统窗口阴影：在 macOS 26/27 无边框深色面板上会描出底角方形、顶角错位的细线。改为自绘柔和阴影。
        hasShadow = false
        animationBehavior = .none
        // 统一使用深色烟熏液态玻璃浮层，与浅色/白色应用窗口形成清晰的图底对比，避免「白底找白窗」。
        appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.38
        shadowLayer.shadowRadius = 14
        shadowLayer.shadowOffset = CGSize(width: 0, height: -4)
        shadowMask.fillRule = .evenOdd
        shadowLayer.mask = shadowMask
        root.layer?.addSublayer(shadowLayer)
        glass.style = .regular
        glass.tintColor = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 0.38)
        glass.cornerRadius = Self.cornerRadius
        rimView.cornerRadius = Self.cornerRadius
        root.addSubview(glass)
        root.addSubview(rimView)
        contentView = root
        headerDivider.wantsLayer = true
        headerDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        headerDivider.isHidden = true
        headerIcon.imageScaling = .scaleProportionallyUpOrDown
        headerIcon.isHidden = true
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.textColor = .white
        heading.lineBreakMode = .byTruncatingTail
        heading.maximumNumberOfLines = 1
        statusTagBackdrop.wantsLayer = true
        statusTagBackdrop.layer?.cornerRadius = 6
        statusTagBackdrop.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        statusTagBackdrop.isHidden = true
        statusTag.font = .systemFont(ofSize: 11, weight: .medium)
        statusTag.textColor = NSColor.white.withAlphaComponent(0.86)
        statusTag.alignment = .center
        statusTagBackdrop.addSubview(statusTag)
        pageNumber.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pageNumber.textColor = NSColor.white.withAlphaComponent(0.65)
        canvas.addSubview(headerDivider)
        canvas.addSubview(headerIcon)
        canvas.addSubview(heading)
        canvas.addSubview(statusTagBackdrop)
        canvas.addSubview(pageNumber)
        setAccessibilityTitle(L("切换窗口"))
        previews.warm()
    }

    func focusPreview(_ key: SwitcherWindowKey) {
        if case .numbered(let pid, let id) = key { previews.focus(.init(pid: pid, id: id)) }
        else { previews.focus(nil) }
    }

    func preview(for snapshot: AppSnapshot) -> NSImage? { previews.preview(for: snapshot) }
    func lastClosedPreview(for app: NSRunningApplication) -> NSImage? { previews.lastClosedPreview(for: app) }
    func stopPreviews() { previews.stop() }

    func neighbor(from index: Int, direction: SwitcherDirection) -> Int? {
        layout?.neighbor(from: index, direction: direction)
    }

    func pageFirstIndex(offsetBy delta: Int, from selected: Int) -> Int? {
        guard let layout, layout.pages.count > 1,
              let current = layout.pages.firstIndex(where: { $0.contains(selected) }) else { return nil }
        let next = (current + delta + layout.pages.count) % layout.pages.count
        return layout.pages[next].lowerBound
    }

    /// 面板打开期间删除或更新卡片后，强制按最新列表重排。
    func invalidateLayout() {
        layout = nil
        previews.endPage()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let layout, layout.pages.count > 1 else { super.scrollWheel(with: event); return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : -event.scrollingDeltaY
        guard abs(delta) > 2 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPageTurn >= 0.25 else { return }
        lastPageTurn = now
        onTurnPage?(delta > 0 ? 1 : -1)
    }

    func present(entries: [SwitcherEntry], selected: Int, on screen: NSScreen, appBadges: [String: String]) {
        let visible = screen.visibleFrame
        let geometry = (visible == visibleFrame ? layout : nil)
            ?? SwitcherLayout(windowSizes: entries.map(\.previewSize), screenSize: visible.size)
        guard let pageIndex = geometry.pages.firstIndex(where: { $0.contains(selected) }) else { return }
        let range = geometry.pages[pageIndex]
        let keys = entries[range].compactMap { entry in
            entry.window?.id.map { SwitcherPreviews.Window(pid: entry.app.processIdentifier, id: $0) }
        }
        let longestSide = geometry.frames[range].reduce(CGFloat(0)) { max($0, $1.width, $1.height) }
        self.appBadges = appBadges
        previews.present(keys, maxSize: longestSide) { [weak self] images in
            self?.drawPage(entries: entries, selected: selected, visible: visible,
                           geometry: geometry, pageIndex: pageIndex, range: range, images: images)
        } refresh: { [weak self] images in
            guard let self, self.page == range else { return }
            for (slot, i) in range.enumerated() {
                if let id = entries[i].window?.id, let image = images[id] { self.cards[slot].setImage(image) }
            }
        }
    }

    private func applyFrame(size: NSSize, centeredIn visible: CGRect) {
        let margin = Self.margin
        let radius = Self.cornerRadius
        let outer = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
        let cardOrigin = NSPoint(x: round(visible.midX - size.width / 2), y: round(visible.midY - size.height / 2))
        setFrame(NSRect(x: cardOrigin.x - margin, y: cardOrigin.y - margin, width: outer.width, height: outer.height), display: false)
        let bounds = NSRect(origin: .zero, size: outer)
        let card = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        root.frame = bounds
        glass.cornerRadius = radius
        glass.frame = card
        rimView.frame = card
        rimView.cornerRadius = radius
        canvas.frame = NSRect(origin: .zero, size: size)

        let outline = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
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
    }

    private func drawPage(entries: [SwitcherEntry], selected: Int,
                          visible: CGRect, geometry: SwitcherLayout, pageIndex: Int, range: Range<Int>, images: SwitcherPreviews.Images) {
        if layout == nil || visible != visibleFrame {
            clearPage()
            layout = geometry
            visibleFrame = visible
            applyFrame(size: geometry.size, centeredIn: visible)
            updateApplicationBadges(appBadges)
        }
        let pageChanged = range != page
        if pageChanged {
            clearPage()
            page = range
            let canShowImages = Thumbnailer.isAuthorized
            for (slot, i) in range.enumerated() {
                let entry = entries[i]
                let card = SwitcherCard(entry, frame: geometry.frames[i], shortcutNumber: slot < 9 ? slot + 1 : nil)
                if canShowImages, let image = entry.window?.id.flatMap({ images[$0] }) ?? entry.lastPreview {
                    card.setImage(image)
                }
                card.onPick = { [weak self] in self?.onPick?(i) }
                card.onClose = { [weak self] in self?.onClose?(i) }
                canvas.addSubview(card)
                cards.append(card)
            }
            updateApplicationBadges(appBadges)
        }
        let chosen = cards[selected - range.lowerBound]
        if highlighted !== chosen {
            highlighted?.setSelected(false)
            chosen.setSelected(true)
            highlighted = chosen
        }
        updateHeader(for: entries[selected], geometry: geometry, pageIndex: pageIndex)
        let revealed = reveal()
        if pageChanged || revealed {
            onPageChange?(range)
        }
    }

    /// 复用顶部标题栏，展示当前高亮窗口的完整标题与状态，避免卡片变窄时看不清窗口名。
    private func updateHeader(for entry: SwitcherEntry, geometry: SwitcherLayout, pageIndex: Int) {
        let edge = SwitcherLayout.inset + 4
        let headerHeight: CGFloat = 42
        let panelWidth = geometry.size.width
        var rightEdge = panelWidth - edge

        headerDivider.frame = NSRect(x: SwitcherLayout.inset, y: headerHeight - 4, width: max(0, panelWidth - 2 * SwitcherLayout.inset), height: 0.5)
        headerDivider.isHidden = false

        if geometry.pages.count > 1 {
            pageNumber.stringValue = String(format: L("第 %d / %d 页"), pageIndex + 1, geometry.pages.count)
            pageNumber.sizeToFit()
            let pageOriginX = rightEdge - pageNumber.frame.width
            pageNumber.setFrameOrigin(NSPoint(x: pageOriginX, y: round((headerHeight - 4 - pageNumber.frame.height) / 2)))
            pageNumber.isHidden = false
            rightEdge = pageOriginX - 10
        } else {
            pageNumber.isHidden = true
        }

        if let tag = entry.statusText {
            statusTag.stringValue = tag
            statusTag.sizeToFit()
            let pillWidth = statusTag.frame.width + 12
            let pillHeight: CGFloat = 19
            let pillX = rightEdge - pillWidth
            statusTagBackdrop.frame = NSRect(x: pillX, y: round((headerHeight - 4 - pillHeight) / 2), width: pillWidth, height: pillHeight)
            statusTag.frame = NSRect(x: 6, y: round((pillHeight - statusTag.frame.height) / 2),
                                     width: statusTag.frame.width, height: statusTag.frame.height)
            statusTagBackdrop.isHidden = false
            rightEdge = pillX - 8
        } else {
            statusTagBackdrop.isHidden = true
        }

        headerIcon.image = entry.app.icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        headerIcon.frame = NSRect(x: edge, y: round((headerHeight - 4 - 18) / 2), width: 18, height: 18)
        headerIcon.isHidden = false

        let fullTitle: String
        if entry.window != nil, entry.title != entry.appName {
            fullTitle = "\(entry.title) — \(entry.appName)"
        } else {
            fullTitle = entry.title
        }
        heading.stringValue = fullTitle
        heading.sizeToFit()
        let titleX = edge + 24
        let available = max(40, rightEdge - titleX)
        heading.frame = NSRect(x: titleX, y: round((headerHeight - 4 - heading.frame.height) / 2),
                               width: min(heading.frame.width, available), height: heading.frame.height)
    }

    func updateApplicationBadges(_ counts: [String: String]) {
        appBadges = counts
        for card in cards { card.setAppCount(card.appPath.flatMap { counts[$0] }) }
    }

    func showEmpty(on screen: NSScreen) {
        previews.endPage()
        let visible = screen.visibleFrame
        clearPage()
        headerDivider.isHidden = true
        headerIcon.isHidden = true
        statusTagBackdrop.isHidden = true
        heading.stringValue = L("没有可切换的窗口")
        heading.sizeToFit()
        let size = NSSize(width: heading.frame.width + 48, height: heading.frame.height + 32)
        applyFrame(size: size, centeredIn: visible)
        heading.setFrameOrigin(NSPoint(x: 24, y: 16))
        pageNumber.isHidden = true
        if reveal() {
            onPageChange?(0..<0)
        }
    }

    private func clearPage() {
        highlighted = nil
        for card in cards { card.removeFromSuperview() }
        cards.removeAll()
        page = 0..<0
    }

    @discardableResult
    private func reveal() -> Bool {
        let fromHidden = !isVisible
        guard fromHidden || isDismissing else { return false }
        isDismissing = false
        ignoresMouseEvents = false
        canvas.setAccessibilityHidden(false)
        if fromHidden {
            alphaValue = 0
            orderFrontRegardless()
        }
        transition(showing: true, fromHidden: fromHidden)
        return true
    }

    func dismiss(animated: Bool = true) {
        previews.endPage()
        guard animated, isVisible else { finishDismissal(); return }
        guard !isDismissing else { return }
        isDismissing = true
        ignoresMouseEvents = true
        canvas.setAccessibilityHidden(true)
        // 留住画面淡出。连按 ⌘Tab 时下一次手势可以立即用新快照重建。
        layout = nil
        transition(showing: false)
    }

    private func transition(showing: Bool, fromHidden: Bool = false) {
        transitionGeneration += 1
        let generation = transitionGeneration
        let duration = showing ? 0.13 : 0.09
        let curve = CAMediaTimingFunction(name: showing ? .easeOut : .easeIn)
        if let layer = root.layer {
            let current = layer.presentation()?.transform ?? CATransform3DIdentity
            layer.removeAnimation(forKey: "switcherScale")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                // AppKit 可以把图层的锚点设在角上；以面板中心为缩放原点。
                func scaled(_ factor: CGFloat) -> CATransform3D {
                    let dx = layer.bounds.width * (0.5 - layer.anchorPoint.x) * (1 - factor)
                    let dy = layer.bounds.height * (0.5 - layer.anchorPoint.y) * (1 - factor)
                    return CATransform3DMakeAffineTransform(CGAffineTransform(a: factor, b: 0, c: 0, d: factor, tx: dx, ty: dy))
                }
                let scale = CABasicAnimation(keyPath: "transform")
                scale.fromValue = NSValue(caTransform3D: fromHidden ? scaled(0.975) : current)
                scale.toValue = NSValue(caTransform3D: showing ? CATransform3DIdentity : scaled(0.985))
                scale.duration = duration
                scale.timingFunction = curve
                scale.fillMode = .forwards
                scale.isRemovedOnCompletion = showing
                layer.add(scale, forKey: "switcherScale")
            }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = curve
            animator().alphaValue = showing ? 1 : 0
        }, completionHandler: { [weak self] in
            guard !showing, let self, self.transitionGeneration == generation else { return }
            self.finishDismissal()
        })
    }

    private func finishDismissal() {
        transitionGeneration += 1
        if isVisible { orderOut(nil) }
        root.layer?.removeAnimation(forKey: "switcherScale")
        isDismissing = false
        layout = nil
        clearPage()
    }
}
