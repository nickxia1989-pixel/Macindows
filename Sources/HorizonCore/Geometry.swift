import CoreGraphics

public enum DockEdge: Equatable { case left, bottom, right }

// 辅助功能接口和鼠标事件用「左上角为原点、y 向下」的全局坐标，AppKit 用「左下角为原点、y 向上」。
// 两者以主屏幕（带菜单栏的那块）的高度互相换算。

public func cocoaRect(fromTopLeft r: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

public func topLeftPoint(fromCocoa p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
    CGPoint(x: p.x, y: primaryHeight - p.y)
}

/// 程序坞贴在屏幕哪条边。两个矩形须在同一坐标系。
public func dockEdge(dockFrame: CGRect, screenFrame: CGRect) -> DockEdge {
    if dockFrame.width >= dockFrame.height { return .bottom }
    return dockFrame.midX < screenFrame.midX ? .left : .right
}

/// 悬停窗的左下角位置（AppKit 坐标）：贴在程序坞外侧、对准被悬停的图标，并限制在可见区域内。
public func panelOrigin(panelSize: CGSize, itemFrame: CGRect, dockFrame: CGRect, edge: DockEdge,
                        visibleFrame: CGRect, gap: CGFloat = 8, margin: CGFloat = 6) -> CGPoint {
    var x: CGFloat, y: CGFloat
    switch edge {
    case .left:
        x = dockFrame.maxX + gap
        y = itemFrame.midY - panelSize.height / 2
    case .right:
        x = dockFrame.minX - gap - panelSize.width
        y = itemFrame.midY - panelSize.height / 2
    case .bottom:
        x = itemFrame.midX - panelSize.width / 2
        y = dockFrame.maxY + gap
    }
    let maxX = max(visibleFrame.minX + margin, visibleFrame.maxX - panelSize.width - margin)
    let maxY = max(visibleFrame.minY + margin, visibleFrame.maxY - panelSize.height - margin)
    // 贴着程序坞的那一侧不夹紧：可见区域已经扣掉了程序坞，夹了反而会把悬停窗推远
    if edge == .bottom { x = min(max(x, visibleFrame.minX + margin), maxX) } else { y = min(max(y, visibleFrame.minY + margin), maxY) }
    if edge == .left { x = min(x, maxX) }
    if edge == .right { x = max(x, visibleFrame.minX + margin) }
    if edge == .bottom { y = min(y, maxY) }
    return CGPoint(x: x.rounded(), y: y.rounded())
}

/// 悬停窗和程序坞之间的那段空隙（AppKit 坐标）。鼠标从图标移向悬停窗时要穿过这里，期间悬停窗不能关。
/// 沿程序坞方向取悬停窗和图标两者的并集，这样悬停窗被屏幕边缘挤偏时，从图标直着移过去也不会出界。
public func corridor(panelFrame: CGRect, itemFrame: CGRect, dockFrame: CGRect, edge: DockEdge) -> CGRect {
    switch edge {
    case .bottom:
        let minX = min(panelFrame.minX, itemFrame.minX), maxX = max(panelFrame.maxX, itemFrame.maxX)
        return CGRect(x: minX, y: dockFrame.maxY, width: maxX - minX, height: max(0, panelFrame.minY - dockFrame.maxY))
    case .left:
        let minY = min(panelFrame.minY, itemFrame.minY), maxY = max(panelFrame.maxY, itemFrame.maxY)
        return CGRect(x: dockFrame.maxX, y: minY, width: max(0, panelFrame.minX - dockFrame.maxX), height: maxY - minY)
    case .right:
        let minY = min(panelFrame.minY, itemFrame.minY), maxY = max(panelFrame.maxY, itemFrame.maxY)
        return CGRect(x: panelFrame.maxX, y: minY, width: max(0, dockFrame.minX - panelFrame.maxX), height: maxY - minY)
    }
}

/// 悬停窗开着时，程序坞上位于它正下方（侧边程序坞则是正旁边）的那一整段，两端再各放宽一点（AppKit 坐标）。
/// 鼠标从图标移向悬停窗、尤其是移向远处的窗口时，往往先贴着程序坞横着走一阵再往上，途中会扫过别的图标。
/// 在这一段里路过别的图标不算数，要停住一会儿才切换。
public func aimZone(panelFrame: CGRect, itemFrame: CGRect, dockFrame: CGRect, edge: DockEdge,
                    slack: CGFloat = 12, depth: CGFloat = 60) -> CGRect {
    switch edge {
    case .bottom:
        let minX = min(panelFrame.minX, itemFrame.minX) - slack, maxX = max(panelFrame.maxX, itemFrame.maxX) + slack
        return CGRect(x: minX, y: dockFrame.minY - depth, width: maxX - minX, height: dockFrame.maxY - dockFrame.minY + depth)
    case .left:
        let minY = min(panelFrame.minY, itemFrame.minY) - slack, maxY = max(panelFrame.maxY, itemFrame.maxY) + slack
        return CGRect(x: dockFrame.minX - depth, y: minY, width: dockFrame.maxX - dockFrame.minX + depth, height: maxY - minY)
    case .right:
        let minY = min(panelFrame.minY, itemFrame.minY) - slack, maxY = max(panelFrame.maxY, itemFrame.maxY) + slack
        return CGRect(x: dockFrame.minX, y: minY, width: dockFrame.maxX - dockFrame.minX + depth, height: maxY - minY)
    }
}

/// 鼠标离悬停窗朝向程序坞的那条边还有多远。数值变小说明鼠标在向悬停窗靠近。
public func distanceToPanel(from point: CGPoint, panelFrame: CGRect, edge: DockEdge) -> CGFloat {
    switch edge {
    case .bottom: return panelFrame.minY - point.y
    case .left: return panelFrame.minX - point.x
    case .right: return point.x - panelFrame.maxX
    }
}
