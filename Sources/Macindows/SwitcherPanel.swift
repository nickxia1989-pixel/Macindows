import AppKit
import MacindowsCore

struct SwitcherEntry {
    let app: NSRunningApplication
    /// nil 代表已确认没有可切换窗口、但仍在运行的应用。
    let window: AppWindow?

    var title: String {
        window?.title ?? app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? L("应用")
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
    private let height: CGFloat
    private let label = NSTextField(labelWithString: "")
    private(set) var number: String?

    init(compact: Bool) {
        height = compact ? 21 : 30
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
        label.font = .monospacedDigitSystemFont(ofSize: compact ? 12 : 17, weight: .bold)
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
    private let preview = NSImageView()
    private let fallback = NSImageView()
    private let badge = NSImageView()
    private let title: NSTextField
    private let appCount: NumberBadge
    private let isApplication: Bool
    private let name: String
    let appPath: String?
    var onPick: (() -> Void)?

    init(_ entry: SwitcherEntry, frame: NSRect, applicationIndex: Int? = nil) {
        isApplication = applicationIndex != nil
        appCount = NumberBadge(compact: isApplication)
        appPath = entry.app.bundleURL?.standardizedFileURL.path
        let detail = isApplication ? L("没有打开的窗口") : entry.app.localizedName
        let number = applicationIndex.flatMap { $0 < 9 ? $0 + 1 : nil }
        name = [entry.title, detail, number.map { String(format: L("快捷键 %d"), $0) }].compactMap { $0 }.joined(separator: " · ")
        title = NSTextField(labelWithString: entry.title)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true
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

        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.frame = NSRect(x: 10, y: bounds.height - SwitcherLayout.titleSpace, width: bounds.width - 20, height: 19)
        addSubview(title)
        addSubview(appCount)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateDescription()
        if isApplication {
            preview.isHidden = true
            fallback.isHidden = true
            badge.frame = NSRect(x: round(bounds.midX - 17), y: 6, width: 34, height: 34)
            title.font = .systemFont(ofSize: 11, weight: .medium)
            title.alignment = .center
            title.frame = NSRect(x: 4, y: 43, width: bounds.width - 8, height: 16)
            if let number {
                let key = NSTextField(labelWithString: String(number))
                key.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                key.alignment = .center
                key.wantsLayer = true
                key.layer?.cornerRadius = 4
                key.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
                key.frame = NSRect(x: 5, y: 5, width: 18, height: 17)
                key.setAccessibilityElement(false)
                addSubview(key)
            }
        } else {
            badge.isHidden = true
            positionPicture(size: entry.window?.frame?.size)
        }
        setSelected(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage) {
        positionPicture(size: image.size)
        preview.image = image
        fallback.isHidden = true
        badge.isHidden = false
    }

    private func positionPicture(size: CGSize?) {
        let picture = SwitcherLayout.pictureFrame(for: size, in: bounds)
        preview.frame = picture
        let symbolSide = min(72, round(min(picture.width, picture.height) * 0.52))
        fallback.frame = NSRect(x: picture.midX - symbolSide / 2, y: picture.midY - symbolSide / 2,
                                width: symbolSide, height: symbolSide)
        let badgeSide = min(38, max(20, round(picture.height * 0.23)), bounds.width - 6)
        let badgeX = max(3, min(bounds.width - badgeSide - 3, picture.maxX - badgeSide + 2))
        badge.frame = NSRect(x: badgeX, y: max(3, picture.maxY - badgeSide + 2), width: badgeSide, height: badgeSide)
    }

    func setAppCount(_ number: String?) {
        guard number != appCount.number else { return }
        let inset: CGFloat = isApplication ? 4 : SwitcherLayout.pictureInset
        appCount.setNumber(number, maxWidth: bounds.width - 2 * inset - (isApplication ? 22 : 0))
        appCount.setFrameOrigin(NSPoint(x: bounds.maxX - inset - appCount.frame.width, y: inset))
        updateDescription()
    }

    private func updateDescription() {
        let description = appCount.number.map { name + " · " + String(format: L("应用角标 %@"), $0) } ?? name
        toolTip = description
        setAccessibilityLabel(description)
    }

    func setSelected(_ selected: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.17)
                                               : NSColor.labelColor.withAlphaComponent(0.045)).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = selected ? 2.5 : 0
        }
        setAccessibilitySelected(selected)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { onPick?() }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }
}

/// 用同一页的预览一起展示卡片，后续截图更新原来的图像视图。
final class SwitcherPanel: NSPanel {
    var onPick: ((SwitcherChoice) -> Void)?
    var onReveal: (() -> Void)?
    private let previews = SwitcherPreviews()
    private let glass = NSGlassEffectView()
    private let canvas = FlippedView()
    private let heading = NSTextField(labelWithString: L("切换窗口"))
    private let pageNumber = NSTextField(labelWithString: "")
    private let appHeading = NSTextField(labelWithString: L("无窗口应用"))
    private let appScroll = NSScrollView()
    private let appRow = FlippedView()
    private var appCards: [SwitcherCard] = []
    private var layout: SwitcherLayout?
    private var visibleFrame: NSRect = .zero
    private var cards: [SwitcherCard] = []
    private weak var highlighted: SwitcherCard?
    private var page: Range<Int> = 0..<0
    private var appBadges: [String: String] = [:]
    private var isDismissing = false
    private var transitionGeneration = 0
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        // 让玻璃和卡片一起缩放，窗口本身始终使用最终布局和点击区域。
        let root = NSView()
        root.wantsLayer = true
        glass.wantsLayer = true
        glass.autoresizingMask = [.width, .height]
        glass.style = .regular
        glass.cornerRadius = 24
        glass.contentView = canvas
        root.addSubview(glass)
        contentView = root
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        pageNumber.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pageNumber.textColor = .secondaryLabelColor
        appHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        appScroll.drawsBackground = false
        appScroll.hasHorizontalScroller = true
        appScroll.autohidesScrollers = true
        appScroll.scrollerStyle = .overlay
        appScroll.documentView = appRow
        for view in [heading, pageNumber, appHeading, appScroll] { canvas.addSubview(view) }
        setAccessibilityTitle(L("切换窗口"))
        previews.warm()
    }

    func warmPreview(pid: pid_t, id: CGWindowID) { previews.warm(.init(pid: pid, id: id)) }
    func stopPreviews() { previews.stop() }

    func present(windows: [SwitcherEntry], applications: [SwitcherEntry], selected: SwitcherChoice,
                 windowIndex: Int?, on screen: NSScreen, appBadges: [String: String]) {
        let visible = screen.visibleFrame
        let geometry = (visible == visibleFrame ? layout : nil)
            ?? SwitcherLayout(windowSizes: windows.map { $0.window?.frame?.size }, screenSize: visible.size, applicationCount: applications.count)
        let pageIndex = windowIndex.flatMap { i in geometry.pages.firstIndex { $0.contains(i) } }
        let range = pageIndex.map { geometry.pages[$0] } ?? 0..<0
        let keys = windows[range].compactMap { entry in
            entry.window?.id.map { SwitcherPreviews.Window(pid: entry.app.processIdentifier, id: $0) }
        }
        let longestSide = geometry.frames[range].reduce(CGFloat(0)) { max($0, $1.width, $1.height) }
        self.appBadges = appBadges
        previews.present(keys, maxSize: longestSide) { [weak self] images in
            self?.drawPage(windows: windows, applications: applications, selected: selected, visible: visible,
                           geometry: geometry, pageIndex: pageIndex, range: range, images: images)
        } refresh: { [weak self] images in
            guard let self, self.page == range else { return }
            for (slot, i) in range.enumerated() {
                if let id = windows[i].window?.id, let image = images[id] { self.cards[slot].setImage(image) }
            }
        }
    }

    private func drawPage(windows: [SwitcherEntry], applications: [SwitcherEntry], selected: SwitcherChoice,
                          visible: CGRect, geometry: SwitcherLayout, pageIndex: Int?, range: Range<Int>, images: SwitcherPreviews.Images) {
        if layout == nil || visible != visibleFrame {
            clearPage()
            layout = geometry
            visibleFrame = visible
            let size = geometry.size
            let frame = NSRect(x: round(visible.midX - size.width / 2), y: round(visible.midY - size.height / 2),
                               width: size.width, height: size.height)
            setFrame(frame, display: false)
            let edge = SwitcherLayout.inset + 4
            heading.stringValue = windows.isEmpty ? L("无窗口应用") : L("切换窗口")
            heading.sizeToFit()
            heading.setFrameOrigin(NSPoint(x: edge, y: 14))
            configureApplicationStrip(applications, frame: geometry.applicationStrip, hasWindows: !windows.isEmpty)
            updateApplicationBadges(appBadges)
        }
        if let pageIndex, geometry.pages.count > 1 {
            pageNumber.stringValue = String(format: L("第 %d / %d 页"), pageIndex + 1, geometry.pages.count)
            pageNumber.sizeToFit()
            pageNumber.setFrameOrigin(NSPoint(x: heading.frame.maxX + 8, y: round(heading.frame.midY - pageNumber.frame.height / 2)))
            pageNumber.isHidden = false
        } else { pageNumber.isHidden = true }
        if range != page {
            clearPage()
            page = range
            for i in range {
                let card = SwitcherCard(windows[i], frame: geometry.frames[i])
                if let id = windows[i].window?.id, let image = images[id] { card.setImage(image) }
                card.onPick = { [weak self] in self?.onPick?(.window(i)) }
                canvas.addSubview(card)
                cards.append(card)
            }
            updateApplicationBadges(appBadges)
        }
        let chosen: SwitcherCard
        switch selected {
        case .window(let i):
            chosen = cards[i - range.lowerBound]
        case .application(let i):
            chosen = appCards[i]
            chosen.scrollToVisible(chosen.bounds)
        }
        if highlighted !== chosen {
            highlighted?.setSelected(false)
            chosen.setSelected(true)
            highlighted = chosen
        }
        reveal()
    }

    private func configureApplicationStrip(_ apps: [SwitcherEntry], frame: CGRect, hasWindows: Bool) {
        for card in appCards { card.removeFromSuperview() }
        appCards.removeAll()
        appScroll.isHidden = apps.isEmpty
        appHeading.isHidden = apps.isEmpty || !hasWindows
        guard !apps.isEmpty else { return }
        appScroll.frame = frame
        let headingWidth = ceil(appHeading.intrinsicContentSize.width)
        appHeading.frame = CGRect(x: frame.minX + 4, y: frame.minY - 24, width: headingWidth, height: 18)
        let size = SwitcherLayout.appCardSize, stride = size.width + SwitcherLayout.appGap
        appRow.frame = CGRect(x: 0, y: 0, width: max(frame.width, CGFloat(apps.count) * stride - SwitcherLayout.appGap), height: frame.height)
        for (i, app) in apps.enumerated() {
            let card = SwitcherCard(app, frame: CGRect(origin: CGPoint(x: CGFloat(i) * stride, y: 0), size: size), applicationIndex: i)
            card.onPick = { [weak self] in self?.onPick?(.application(i)) }
            appRow.addSubview(card)
            appCards.append(card)
        }
        appRow.scroll(.zero)
    }

    func updateApplicationBadges(_ counts: [String: String]) {
        appBadges = counts
        for card in cards + appCards { card.setAppCount(card.appPath.flatMap { counts[$0] }) }
    }

    func showEmpty(on screen: NSScreen) {
        previews.endPage()
        let visible = screen.visibleFrame
        clearPage()
        heading.stringValue = L("没有可切换的窗口")
        configureApplicationStrip([], frame: .zero, hasWindows: false)
        heading.sizeToFit()
        let size = NSSize(width: heading.frame.width + 48, height: heading.frame.height + 32)
        setFrame(NSRect(x: round(visible.midX - size.width / 2), y: round(visible.midY - size.height / 2),
                        width: size.width, height: size.height), display: false)
        heading.setFrameOrigin(NSPoint(x: 24, y: 16))
        pageNumber.isHidden = true
        reveal()
    }

    private func clearPage() {
        highlighted = nil
        for card in cards { card.removeFromSuperview() }
        cards.removeAll()
        page = 0..<0
    }

    private func reveal() {
        let fromHidden = !isVisible
        guard fromHidden || isDismissing else { return }
        isDismissing = false
        ignoresMouseEvents = false
        canvas.setAccessibilityHidden(false)
        if fromHidden {
            alphaValue = 0
            orderFrontRegardless()
        }
        transition(showing: true, fromHidden: fromHidden)
        onReveal?()
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
        if let layer = glass.layer {
            let current = layer.presentation()?.transform ?? CATransform3DIdentity
            layer.removeAnimation(forKey: "switcherScale")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                // AppKit 可以把图层的锚点设在角上；以玻璃中心为缩放原点。
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
        glass.layer?.removeAnimation(forKey: "switcherScale")
        isDismissing = false
        layout = nil
        clearPage()
        configureApplicationStrip([], frame: .zero, hasWindows: false)
    }
}
