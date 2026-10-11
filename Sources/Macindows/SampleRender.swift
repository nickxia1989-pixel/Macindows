import AppKit

/// `Macindows --render-sample <目录>`：用假数据把悬停窗的版面画成图片，不需要任何权限。
/// 只用于检查排版；玻璃材质是合成器效果，离屏渲染里看不到，这里用纯色底代替。
enum SampleRender {
    static func run(outputDirectory: String) {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let titles = ["traveler/horizon", "AXUIElement | Apple Developer Documentation", "Swift.org", "维基百科", "Hacker News", "设计笔记"]
        let aspects: [CGFloat] = [1.5, 0.95, 1.7, 1.3, 1.6, 0.8]
        func entries(_ count: Int, images: Bool) -> [PreviewEntry] {
            (0..<count).map { index in
                let aspect = aspects[index % aspects.count]
                // 每三个里留一个没有画面的，检查占位图标
                let image = images && index % 3 != 2 ? sampleImage(aspect: aspect, hue: CGFloat(index % 6) * 0.07 + 0.5) : nil
                return PreviewEntry(title: titles[index % titles.count], isCurrent: index == 0, aspect: aspect, thumbnail: image)
            }
        }
        let icon = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        // 以一块 2560 宽的屏幕为例：3 个窗口正常大小，12 个整体缩小，30 个改成列表
        let room = CGSize(width: 2536, height: 1300)
        write({ $0.configure(entries: entries(3, images: false), thumbnails: false, placeholder: nil, maxSize: room) }, appearance: .darkAqua, to: directory.appendingPathComponent("list-dark.png"))
        write({ $0.configure(entries: entries(3, images: false), thumbnails: false, placeholder: nil, maxSize: room) }, appearance: .aqua, to: directory.appendingPathComponent("list-light.png"))
        write({ $0.configure(entries: entries(1, images: true), thumbnails: true, placeholder: icon, maxSize: room) }, appearance: .darkAqua, to: directory.appendingPathComponent("thumbnails-1.png"))
        write({ $0.configure(entries: entries(3, images: true), thumbnails: true, placeholder: icon, maxSize: room) }, appearance: .darkAqua, to: directory.appendingPathComponent("thumbnails-3.png"))
        write({ $0.configure(entries: entries(6, images: true), thumbnails: true, placeholder: icon, maxSize: room) }, appearance: .aqua, to: directory.appendingPathComponent("thumbnails-6-light.png"))
        write({ $0.configure(entries: entries(18, images: true), thumbnails: true, placeholder: icon, maxSize: room) }, appearance: .darkAqua, to: directory.appendingPathComponent("thumbnails-18-compressed.png"))
        writeMenuBarIcon(to: directory)
        let empty = [PreviewEntry(title: "备忘录", isCurrent: false, aspect: nil, thumbnail: nil, isPlaceholder: true)]
        write({ $0.configure(entries: empty, thumbnails: true, placeholder: icon, maxSize: room) }, appearance: .darkAqua, to: directory.appendingPathComponent("empty-thumbnail.png"))
        write({ $0.configure(entries: empty, thumbnails: false, placeholder: nil, maxSize: room) }, appearance: .aqua, to: directory.appendingPathComponent("empty-list-light.png"))
        write({ $0.configure(entries: entries(30, images: true), thumbnails: true, placeholder: icon, maxSize: room) }, appearance: .darkAqua, to: directory.appendingPathComponent("thumbnails-30-falls-back-to-list.png"))
    }

    /// 菜单栏图标：实际大小（2 倍屏）和放大 12 倍各一张，深浅两种底色
    private static func writeMenuBarIcon(to directory: URL) {
        for (name, pixels) in [("menubar-actual@2x.png", 36), ("menubar-zoom.png", 216)] {
            let size = NSSize(width: CGFloat(pixels) * 2 + 3 * CGFloat(pixels) / 3, height: CGFloat(pixels) * 5 / 3)
            let image = NSImage(size: size, flipped: false) { _ in
                let pad = CGFloat(pixels) / 3
                for (index, dark) in [true, false].enumerated() {
                    let cell = NSRect(x: CGFloat(index) * (CGFloat(pixels) + pad * 1.5), y: 0, width: CGFloat(pixels) + pad * 1.5, height: size.height)
                    (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    cell.fill()
                    let glyph = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { rect in
                        MenuBarIcon.draw(in: rect)
                        (dark ? NSColor.white : NSColor.black).setFill()
                        rect.fill(using: .sourceIn)
                        return true
                    }
                    glyph.draw(in: NSRect(x: cell.minX + pad * 0.75, y: pad, width: CGFloat(pixels), height: CGFloat(pixels)))
                }
                return true
            }
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }
    }

    /// `--check-hover`：检查高亮是否跟着鼠标位置走、内容重建后是否还在。返回逐项结果
    static func checkHover() -> [String] {
        let entries = (0..<4).map { PreviewEntry(title: "窗口 \($0)", isCurrent: $0 == 0, aspect: 1.5, thumbnail: nil) }
        let content = PreviewContentView()
        let size = content.configure(entries: entries, thumbnails: true, placeholder: nil, maxSize: CGSize(width: 2000, height: 1000))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        func highlighted() -> [Int] { content.items.enumerated().filter { $0.element.isHighlighted }.map(\.offset) }
        func center(of index: Int) -> NSPoint { let f = content.items[index].frame; return content.convert(NSPoint(x: f.midX, y: f.midY), to: nil) }
        var results: [String] = []
        func expect(_ label: String, _ actual: [Int], _ wanted: [Int]) { results.append("\(actual == wanted ? "通过" : "失败")  \(label)：亮着的是 \(actual)，应为 \(wanted)") }

        content.updateHover(windowPoint: center(of: 1)); expect("移到第 2 项", highlighted(), [1])
        content.updateHover(windowPoint: center(of: 3)); expect("移到第 4 项", highlighted(), [3])
        content.updateHover(windowPoint: center(of: 0)); expect("来回：移回第 1 项", highlighted(), [0])
        content.updateHover(windowPoint: center(of: 2)); expect("来回：移到第 3 项", highlighted(), [2])
        // 内容重建（比如缩略图到了）：重建后按同一位置补上高亮
        let point = center(of: 2)
        content.configure(entries: entries, thumbnails: true, placeholder: nil, maxSize: CGSize(width: 2000, height: 1000))
        content.updateHover(windowPoint: point); expect("内容重建后仍停在第 3 项", highlighted(), [2])
        content.updateHover(windowPoint: nil); expect("鼠标离开", highlighted(), [])
        return results
    }

    private static func sampleImage(aspect: CGFloat, hue: CGFloat) -> NSImage {
        let size = NSSize(width: 400 * aspect, height: 400)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: NSColor(hue: hue, saturation: 0.5, brightness: 0.75, alpha: 1),
                       ending: NSColor(hue: hue + 0.08, saturation: 0.6, brightness: 0.35, alpha: 1))?.draw(in: rect, angle: -60)
            return true
        }
    }

    private static func write(_ build: (PreviewContentView) -> NSSize, appearance: NSAppearance.Name, to url: URL) {
        let content = PreviewContentView()
        let size = build(content)
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
        card.layer?.cornerRadius = min(14, size.height / 2)
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
