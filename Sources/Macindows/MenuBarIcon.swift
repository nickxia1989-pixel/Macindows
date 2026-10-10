import AppKit

/// 菜单栏上的图标：和应用图标同一个意思的单色版——四格窗，左上那一格带 Mac 窗口的三个圆点。
/// 是「模板图像」，颜色由系统按菜单栏的深浅自动决定。
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Macindows"
        return image
    }()

    static func draw(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(rect.width, rect.height) / 18
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)

        let pane: CGFloat = 7, gap: CGFloat = 2, radius: CGFloat = 1.9
        let total = pane * 2 + gap
        let origin = CGPoint(x: (18 - total) / 2, y: (18 - total) / 2)
        context.setFillColor(NSColor.black.cgColor)
        for row in 0..<2 {
            for column in 0..<2 {
                let frame = CGRect(x: origin.x + CGFloat(column) * (pane + gap), y: origin.y + CGFloat(1 - row) * (pane + gap), width: pane, height: pane)
                context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
        }
        context.fillPath()

        // 左上那一格挖出三个小圆点
        context.setBlendMode(.clear)
        let first = CGRect(x: origin.x, y: origin.y + pane + gap, width: pane, height: pane)
        for index in 0..<3 {
            let center = CGPoint(x: first.minX + 1.75 + CGFloat(index) * 1.75, y: first.maxY - 1.85)
            context.fillEllipse(in: CGRect(x: center.x - 0.6, y: center.y - 0.6, width: 1.2, height: 1.2))
        }
        context.restoreGState()
    }
}
