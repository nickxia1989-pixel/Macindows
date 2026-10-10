import AppKit

/// `Horizon --render-sample <目录>`：用假数据把悬停窗的版面画成图片，不需要任何权限。
/// 只用于检查排版；玻璃材质是合成器效果，离屏渲染里看不到，这里用纯色底代替。
enum SampleRender {
    static func run(outputDirectory: String) {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let titles = ["traveler/horizon", "AXUIElement | Apple Developer Documentation", "Swift.org"]
        let states: [PreviewEntry.State] = [.visible, .visible, .minimized]
        func entries(withImages: Bool) -> [PreviewEntry] {
            titles.enumerated().map { index, title in
                PreviewEntry(title: title, state: states[index], isCurrent: index == 0, aspect: [1.5, 0.95, 1.7][index],
                             thumbnail: withImages && index < 2 ? sampleImage(aspect: [1.5, 0.95, 1.7][index], hue: CGFloat(index) * 0.3 + 0.55) : nil)
            }
        }
        let icon = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            write(entries(withImages: false), thumbnails: false, placeholder: nil, appearance: appearance, to: directory.appendingPathComponent("list-\(name).png"))
            write(entries(withImages: true), thumbnails: true, placeholder: icon, appearance: appearance, to: directory.appendingPathComponent("thumbnails-\(name).png"))
        }
        write([PreviewEntry(title: "Horizon — BarController.swift", state: .hidden, isCurrent: false, aspect: 1.4, thumbnail: nil)],
              thumbnails: false, placeholder: nil, appearance: .darkAqua, to: directory.appendingPathComponent("single-hidden.png"))
    }

    private static func sampleImage(aspect: CGFloat, hue: CGFloat) -> NSImage {
        let size = NSSize(width: 400 * aspect, height: 400)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: NSColor(hue: hue, saturation: 0.5, brightness: 0.75, alpha: 1),
                       ending: NSColor(hue: hue + 0.08, saturation: 0.6, brightness: 0.35, alpha: 1))?.draw(in: rect, angle: -60)
            return true
        }
    }

    private static func write(_ entries: [PreviewEntry], thumbnails: Bool, placeholder: NSImage?, appearance: NSAppearance.Name, to url: URL) {
        let content = PreviewContentView()
        let size = content.configure(entries: entries, thumbnails: thumbnails, placeholder: placeholder)
        let margin: CGFloat = 16
        let frame = NSRect(x: 0, y: 0, width: size.width + margin * 2, height: size.height + margin * 2)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let dark = appearance == .darkAqua

        let root = NSView(frame: frame)
        root.wantsLayer = true
        root.layer?.backgroundColor = (dark ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.72, alpha: 1)).cgColor
        let card = NSView(frame: NSRect(x: margin, y: margin, width: size.width, height: size.height))
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.backgroundColor = (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
        content.frame = card.bounds
        card.addSubview(content)
        root.addSubview(card)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()

        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
