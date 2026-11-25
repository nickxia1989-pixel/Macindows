import AppKit
import MacindowsCore

struct SwitcherEntry {
    let app: NSRunningApplication
    let window: AppWindow

    var key: SwitcherWindowKey {
        SwitcherWindowKey(pid: app.processIdentifier, element: window.element, id: window.id)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class NumberBadge: NSView {
    private static let height: CGFloat = 30
    private let label = NSTextField(labelWithString: "")
    private(set) var number: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
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
        let width = min(maxWidth, max(Self.height, ceil(textSize.width) + 12))
        setFrameSize(NSSize(width: width, height: Self.height))
        label.frame = NSRect(x: 4, y: round((Self.height - textSize.height) / 2),
                             width: max(0, width - 8), height: textSize.height)
    }
}

private final class SwitcherCard: NSView {
    override var isFlipped: Bool { true }
    private let preview = NSImageView()
    private let fallback = NSImageView()
    private let badge = NSImageView()
    private let title: NSTextField
    private let appCount = NumberBadge()
    private let name: String
    let appPath: String?
    var onPick: (() -> Void)?

    init(_ entry: SwitcherEntry, frame: NSRect) {
        appPath = entry.app.bundleURL?.standardizedFileURL.path
        name = [entry.window.title, entry.app.localizedName].compactMap { $0 }.joined(separator: " · ")
        title = NSTextField(labelWithString: entry.window.title)
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

        fallback.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        fallback.contentTintColor = .tertiaryLabelColor
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
        positionPicture(size: entry.window.frame?.size)
        setSelected(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage) {
        positionPicture(size: image.size)
        preview.image = image
        fallback.isHidden = true
    }

    private func positionPicture(size: CGSize?) {
        let picture = SwitcherLayout.pictureFrame(for: size, in: bounds)
        preview.frame = picture
        let symbolSide = min(38, picture.width, picture.height)
        fallback.frame = NSRect(x: picture.midX - symbolSide / 2, y: picture.midY - symbolSide / 2,
                                width: symbolSide, height: symbolSide)
        let badgeSide = min(38, max(20, round(picture.height * 0.23)), bounds.width - 6)
        let badgeX = max(3, min(bounds.width - badgeSide - 3, picture.maxX - badgeSide + 2))
        badge.frame = NSRect(x: badgeX, y: max(3, picture.maxY - badgeSide + 2), width: badgeSide, height: badgeSide)
    }

    func setAppCount(_ number: String?) {
        guard number != appCount.number else { return }
        let inset = SwitcherLayout.pictureInset
        appCount.setNumber(number, maxWidth: bounds.width - 2 * inset)
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

/// 每次只摆当前一页的卡片。翻页时才取新缩略图，翻页、取消或重新呼出都不会串图。
final class SwitcherPanel: NSPanel {
    var onPick: ((Int) -> Void)?
    private let canvas = FlippedView()
    private let heading = NSTextField(labelWithString: L("切换窗口"))
    private let counter = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: L("Tab 下一个     ⇧Tab 上一个     松开 ⌘ 切换     Esc 取消"))
    private let pageNumber = NSTextField(labelWithString: "")
    private var layout: SwitcherLayout?
    private var visibleFrame: NSRect = .zero
    private var cards: [SwitcherCard] = []
    private weak var highlighted: SwitcherCard?
    private var page: Range<Int> = 0..<0
    private var capture: Task<Void, Never>?
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
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 24
        glass.contentView = canvas
        contentView = glass
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        counter.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .right
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        pageNumber.font = counter.font
        pageNumber.textColor = .secondaryLabelColor
        pageNumber.alignment = .right
        for label in [heading, counter, hint, pageNumber] { canvas.addSubview(label) }
        setAccessibilityTitle(L("切换窗口"))
    }

    func present(_ entries: [SwitcherEntry], selected: Int, on screen: NSScreen, appBadges: [String: String] = [:]) {
        let visible = screen.visibleFrame
        if layout == nil || visible != visibleFrame {
            clearPage()
            layout = SwitcherLayout(windowSizes: entries.map { $0.window.frame?.size }, screenSize: visible.size)
            visibleFrame = visible
        }
        guard let layout, let pageIndex = layout.pages.firstIndex(where: { $0.contains(selected) }) else { return }
        let range = layout.pages[pageIndex]
        if range != page {
            clearPage()
            page = range
            let size = layout.size
            let frame = NSRect(x: round(visible.midX - size.width / 2), y: round(visible.midY - size.height / 2),
                               width: size.width, height: size.height)
            setFrame(frame, display: false)
            let edge = SwitcherLayout.inset + 4
            heading.frame = NSRect(x: edge, y: 14, width: size.width - 112, height: 22)
            counter.frame = NSRect(x: size.width - 100, y: 16, width: 80, height: 18)
            pageNumber.stringValue = layout.pages.count > 1
                ? String(format: L("第 %d / %d 页"), pageIndex + 1, layout.pages.count) : ""
            pageNumber.sizeToFit()
            pageNumber.setFrameOrigin(NSPoint(x: size.width - edge - pageNumber.frame.width, y: size.height - 27))
            let hintWidth = size.width - 2 * edge - (pageNumber.stringValue.isEmpty ? 0 : pageNumber.frame.width + 12)
            hint.frame = NSRect(x: edge, y: size.height - 27, width: hintWidth, height: 17)
            hint.stringValue = L("Tab 下一个     ⇧Tab 上一个     松开 ⌘ 切换     Esc 取消")
            if hint.intrinsicContentSize.width > hintWidth { hint.stringValue = L("松开 ⌘ 切换     Esc 取消") }
            for i in range {
                let card = SwitcherCard(entries[i], frame: layout.frames[i])
                card.onPick = { [weak self] in self?.onPick?(i) }
                canvas.addSubview(card)
                cards.append(card)
            }
            updateApplicationBadges(appBadges)
            let ids = range.compactMap { entries[$0].window.id }
            let longestSide = layout.frames[range].reduce(CGFloat(0)) { max($0, $1.width, $1.height) }
            capture = Task { @MainActor [weak self] in
                await Thumbnailer.capturePage(windowIDs: ids, maxPixelSize: longestSide) { images in
                    guard !Task.isCancelled, let self else { return }
                    for (slot, i) in range.enumerated() {
                        if let id = entries[i].window.id, let image = images[id] { self.cards[slot].setImage(image) }
                    }
                }
            }
        }
        counter.stringValue = "\(selected + 1) / \(entries.count)"
        let chosen = cards[selected - range.lowerBound]
        if highlighted !== chosen {
            highlighted?.setSelected(false)
            chosen.setSelected(true)
            highlighted = chosen
        }
        if !isVisible { orderFrontRegardless() }
    }

    func updateApplicationBadges(_ counts: [String: String]) {
        for card in cards { card.setAppCount(card.appPath.flatMap { counts[$0] }) }
    }

    func showEmpty(on screen: NSScreen) {
        let visible = screen.visibleFrame
        setFrame(NSRect(x: visible.midX - 140, y: visible.midY - 39, width: 280, height: 78), display: false)
        heading.frame = NSRect(x: 20, y: 16, width: 240, height: 22)
        counter.frame = .zero
        pageNumber.stringValue = ""
        hint.frame = NSRect(x: 20, y: 45, width: 240, height: 18)
        hint.stringValue = L("没有可切换的窗口")
        if !isVisible { orderFrontRegardless() }
    }

    private func clearPage() {
        capture?.cancel()
        capture = nil
        highlighted = nil
        for card in cards { card.removeFromSuperview() }
        cards.removeAll()
        page = 0..<0
    }

    func dismiss() {
        if isVisible { orderOut(nil) }
        layout = nil
        clearPage()
    }
}
