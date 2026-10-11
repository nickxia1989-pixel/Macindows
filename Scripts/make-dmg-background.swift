// 生成安装镜像（DMG）打开后的背景图。用法：swift Scripts/make-dmg-background.swift <输出目录>
// 输出 dmg-background.tiff（内含 1 倍和 2 倍两张，访达会按屏幕自动选用），以及一张预览图 dmg-background-preview.png。
//
// 版面与 Scripts/make-dmg.sh 里摆放图标的位置是配套的：窗口内容区 660x400，
// 左边放 Macindows（中心 170,190），右边放「应用程序」（中心 490,190），坐标从左上角算起。
// 图比内容区多画 20 的高度，窗口在别的系统上略高一点时不至于露出白边；
// 底部说明文字也留足了余量，因为有人在访达里开着路径栏，窗口最下面会被它占掉一条。
//
// 底色特意选了中等明度：图标名字用黑字还是白字由访达决定（实测同一张图两种都出现过），
// 背景太亮或太暗都会让其中一种看不清。
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: swift make-dmg-background.swift <output directory>")
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let canvas = CGSize(width: 660, height: 420)
let appCenter = CGPoint(x: 170, y: 190)
let folderCenter = CGPoint(x: 490, y: 190)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// 把「从左上角算起」的坐标换成画布坐标（y 向上）
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: canvas.height - y) }

func drawText(_ string: String, centerX: CGFloat, baselineFromTop: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
    let shadow = NSShadow()
    shadow.shadowColor = color(0x1c2540, 0.45)
    shadow.shadowBlurRadius = 3
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    let text = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color(0xffffff, alpha),
        .shadow: shadow,
        .kern: size >= 18 ? 0.4 : 0.2,
    ])
    let width = text.size().width
    text.draw(at: CGPoint(x: centerX - width / 2, y: canvas.height - baselineFromTop))
}

func drawBackground(in context: CGContext) {
    // 底色：上浅下深的灰蓝
    let base = CGGradient(colorsSpace: sRGB, colors: [color(0x7089b8).cgColor, color(0x5f76a4).cgColor, color(0x51628a).cgColor] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(base, start: point(0, 0), end: point(0, canvas.height), options: [])

    // 左上一片柔光、右下略压暗，让底色不那么平
    let light = CGGradient(colorsSpace: sRGB, colors: [color(0xbfe0ff, 0.26).cgColor, color(0xbfe0ff, 0).cgColor] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(light, startCenter: point(90, -40), startRadius: 0, endCenter: point(90, -40), endRadius: 420, options: [])
    let shade = CGGradient(colorsSpace: sRGB, colors: [color(0x1f2a4d, 0.30).cgColor, color(0x1f2a4d, 0).cgColor] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(shade, startCenter: point(640, 460), startRadius: 0, endCenter: point(640, 460), endRadius: 380, options: [])

    // 两个图标身后各一团柔光，把图标从底色里托出来
    for center in [appCenter, folderCenter] {
        let glow = CGGradient(colorsSpace: sRGB, colors: [color(0xffffff, 0.20).cgColor, color(0xffffff, 0.07).cgColor, color(0xffffff, 0).cgColor] as CFArray, locations: [0, 0.55, 1])!
        let c = point(center.x, center.y)
        context.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 118, options: [])
    }

    // 中间的箭头：杆身从左到右由淡变实
    let y = appCenter.y
    let from: CGFloat = 274, to: CGFloat = 386
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: color(0x1c2540, 0.35).cgColor)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(5)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.saveGState()
    context.move(to: point(from, y))
    context.addLine(to: point(to, y))
    context.replacePathWithStrokedPath()
    context.clip()
    let fade = CGGradient(colorsSpace: sRGB, colors: [color(0xffffff, 0.10).cgColor, color(0xffffff, 0.92).cgColor] as CFArray, locations: [0, 0.85])!
    context.drawLinearGradient(fade, start: point(from - 3, y), end: point(to + 3, y), options: [.drawsAfterEndLocation])
    context.restoreGState()
    context.setStrokeColor(color(0xffffff, 0.92).cgColor)
    context.move(to: point(to - 17, y - 17))
    context.addLine(to: point(to, y))
    context.addLine(to: point(to - 17, y + 17))
    context.strokePath()
    context.endTransparencyLayer()
    context.restoreGState()

    // 背景图没法跟着系统语言切换，所以中英文都写上
    drawText("把 Macindows 拖进「应用程序」", centerX: canvas.width / 2, baselineFromTop: 58, size: 21, weight: .semibold, alpha: 0.97)
    drawText("Drag Macindows into Applications", centerX: canvas.width / 2, baselineFromTop: 82, size: 13, weight: .regular, alpha: 0.85)
    drawText("首次打开后，请在「系统设置 › 隐私与安全性 › 辅助功能」中允许 Macindows", centerX: canvas.width / 2, baselineFromTop: 330, size: 12, weight: .regular, alpha: 0.85)
    drawText("On first launch, allow Macindows in System Settings › Privacy & Security › Accessibility", centerX: canvas.width / 2, baselineFromTop: 349, size: 11.5, weight: .regular, alpha: 0.78)
}

func render(scale: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width) * scale, pixelsHigh: Int(canvas.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas  // 以点为单位的大小，2 倍图据此被识别为高分屏版本
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawBackground(in: NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let small = output.appendingPathComponent("dmg-background-1x.png")
let large = output.appendingPathComponent("dmg-background-2x.png")
try render(scale: 1).write(to: small)
try render(scale: 2).write(to: large)
try render(scale: 2).write(to: output.appendingPathComponent("dmg-background-preview.png"))

let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", small.path, large.path, "-out", output.appendingPathComponent("dmg-background.tiff").path]
try tiffutil.run()
tiffutil.waitUntilExit()
try? FileManager.default.removeItem(at: small)
try? FileManager.default.removeItem(at: large)
print(tiffutil.terminationStatus == 0 ? "dmg-background.tiff written" : "tiffutil failed")
