// 生成应用图标。用法：swift Scripts/make-icon.swift <输出目录>
// 输出 AppIcon.icns，以及一张 1024 的预览图 AppIcon-1024.png。
//
// 图标的意思：Windows 式的四格窗，但左上那一格是带红黄绿三个圆点的 Mac 窗口。
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: swift make-icon.swift <output directory>")
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

/// 在 1024x1024 的画布上画图标（y 向上）
func drawIcon(in context: CGContext) {
    // macOS 图标的标准外形：1024 画布里居中一个 824 的圆角方块，四周留给阴影
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.32).cgColor)
    context.addPath(bodyPath)
    context.setFillColor(color(0x1f6fe5).cgColor)
    context.fillPath()
    context.restoreGState()

    // 底色：从左上的天蓝到右下的深蓝
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x63cbff).cgColor, color(0x2b86f2).cgColor, color(0x1553cf).cgColor] as CFArray, locations: [0, 0.5, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: body.minX + 80, y: body.maxY), end: CGPoint(x: body.maxX - 80, y: body.minY), options: [])
    // 顶部一层柔和的高光
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xffffff, 0.22).cgColor, color(0xffffff, 0).cgColor] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.midY + 40), options: [])
    context.restoreGState()

    // 四格窗
    let pane: CGFloat = 236, gap: CGFloat = 30, radius: CGFloat = 46
    let total = pane * 2 + gap
    let origin = CGPoint(x: body.midX - total / 2, y: body.midY - total / 2)
    var panes: [CGRect] = []
    for row in 0..<2 {
        for column in 0..<2 {
            panes.append(CGRect(x: origin.x + CGFloat(column) * (pane + gap), y: origin.y + CGFloat(1 - row) * (pane + gap), width: pane, height: pane))
        }
    }
    for rect in panes {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x0a2a78, 0.38).cgColor)
        context.addPath(path)
        context.setFillColor(color(0xffffff).cgColor)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(path)
        context.clip()
        let fill = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xffffff).cgColor, color(0xe4eefc).cgColor] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(fill, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        context.restoreGState()
    }

    // 左上那一格是 Mac 的窗口：红黄绿三个圆点
    let first = panes[0]
    let dot: CGFloat = 21, spacing: CGFloat = 58
    for (index, hex) in [UInt32(0xff5f57), 0xfebc2e, 0x28c840].enumerated() {
        let center = CGPoint(x: first.minX + 50 + CGFloat(index) * spacing, y: first.maxY - 52)
        context.setFillColor(color(hex).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
    }
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let context = graphics.cgContext
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: context)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try render(size: points * scale).write(to: iconset.appendingPathComponent(name))
}
try render(size: 1024).write(to: output.appendingPathComponent("AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "AppIcon.icns written" : "iconutil failed")
