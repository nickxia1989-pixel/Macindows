import XCTest
@testable import MacindowsCore

final class ClickPolicyTests: XCTestCase {
    private func state(running: Bool = true, front: Bool = false, hidden: Bool = false, windows: Int, minimized: Int = 0) -> AppWindowState {
        AppWindowState(isRunning: running, isFrontmost: front, isHidden: hidden, windowCount: windows, minimizedCount: minimized)
    }

    func testNotRunningIsLeftToTheDock() {
        XCTAssertEqual(dockClickAction(for: state(running: false, windows: 0)), .passThrough)
    }

    func testNoWindowsIsLeftToTheDock() {
        XCTAssertEqual(dockClickAction(for: state(front: true, windows: 0)), .passThrough)
    }

    func testSingleWindowFrontmostGetsHidden() {
        XCTAssertEqual(dockClickAction(for: state(front: true, windows: 1)), .hideApp)
    }

    func testSingleWindowInBackgroundIsActivatedByTheDock() {
        XCTAssertEqual(dockClickAction(for: state(front: false, windows: 1)), .passThrough)
    }

    func testSingleWindowOffScreenIsRestoredByTheDock() {
        XCTAssertEqual(dockClickAction(for: state(front: true, windows: 1, minimized: 1)), .passThrough)
        XCTAssertEqual(dockClickAction(for: state(front: false, hidden: true, windows: 1)), .passThrough)
    }

    func testMultipleWindowsAlwaysShowTheList() {
        XCTAssertEqual(dockClickAction(for: state(front: true, windows: 2)), .showWindowList)
        XCTAssertEqual(dockClickAction(for: state(front: false, windows: 3, minimized: 3)), .showWindowList)
        XCTAssertEqual(dockClickAction(for: state(front: false, hidden: true, windows: 2)), .showWindowList)
    }
}

final class WindowFilterTests: XCTestCase {
    func testStandardWindowsAreListed() {
        XCTAssertTrue(isListableWindow(subrole: "AXStandardWindow", isMinimized: false))
        XCTAssertTrue(isListableWindow(subrole: "AXStandardWindow", isMinimized: true))
    }

    func testMinimizedWindowsReportedAsDialogsAreStillListed() {
        XCTAssertTrue(isListableWindow(subrole: "AXDialog", isMinimized: true))
    }

    func testPanelsAndOnScreenDialogsAreNotListed() {
        XCTAssertFalse(isListableWindow(subrole: "AXDialog", isMinimized: false))
        XCTAssertFalse(isListableWindow(subrole: "AXFloatingWindow", isMinimized: false))
        XCTAssertFalse(isListableWindow(subrole: "AXSystemDialog", isMinimized: true))
        XCTAssertFalse(isListableWindow(subrole: nil, isMinimized: true))
    }
}

final class GeometryTests: XCTestCase {
    func testCoordinateConversionRoundTrips() {
        let r = cocoaRect(fromTopLeft: CGRect(x: 10, y: 30, width: 100, height: 50), primaryHeight: 1440)
        XCTAssertEqual(r, CGRect(x: 10, y: 1360, width: 100, height: 50))
        XCTAssertEqual(topLeftPoint(fromCocoa: CGPoint(x: 5, y: 1440), primaryHeight: 1440), CGPoint(x: 5, y: 0))
    }

    func testDockEdgeDetection() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        XCTAssertEqual(dockEdge(dockFrame: CGRect(x: 0, y: 400, width: 59, height: 600), screenFrame: screen), .left)
        XCTAssertEqual(dockEdge(dockFrame: CGRect(x: 2500, y: 400, width: 59, height: 600), screenFrame: screen), .right)
        XCTAssertEqual(dockEdge(dockFrame: CGRect(x: 800, y: 0, width: 900, height: 70), screenFrame: screen), .bottom)
    }

    func testPanelSitsBesideALeftDockAndStaysOnScreen() {
        let visible = CGRect(x: 59, y: 0, width: 2501, height: 1410)
        let dock = CGRect(x: 0, y: 400, width: 59, height: 600)
        let origin = panelOrigin(panelSize: CGSize(width: 300, height: 200), itemFrame: CGRect(x: 6, y: 900, width: 46, height: 46),
                                 dockFrame: dock, edge: .left, visibleFrame: visible)
        XCTAssertEqual(origin, CGPoint(x: 67, y: 823))
        // 图标靠近屏幕顶部时，悬停窗不能伸出可见区域
        let top = panelOrigin(panelSize: CGSize(width: 300, height: 200), itemFrame: CGRect(x: 6, y: 1380, width: 46, height: 46),
                              dockFrame: dock, edge: .left, visibleFrame: visible)
        XCTAssertEqual(top.y, 1204)
    }

    func testPanelSitsAboveABottomDock() {
        let visible = CGRect(x: 0, y: 70, width: 2560, height: 1340)
        let dock = CGRect(x: 800, y: 0, width: 900, height: 66)
        let origin = panelOrigin(panelSize: CGSize(width: 400, height: 160), itemFrame: CGRect(x: 820, y: 8, width: 50, height: 50),
                                 dockFrame: dock, edge: .bottom, visibleFrame: visible)
        XCTAssertEqual(origin, CGPoint(x: 645, y: 74))
        // 最左边的图标：悬停窗不能伸出屏幕左缘
        let leftmost = panelOrigin(panelSize: CGSize(width: 400, height: 160), itemFrame: CGRect(x: 20, y: 8, width: 50, height: 50),
                                   dockFrame: dock, edge: .bottom, visibleFrame: visible)
        XCTAssertEqual(leftmost.x, 6)
    }

    func testCorridorBridgesTheGapAboveABottomDock() {
        let dock = CGRect(x: 800, y: 0, width: 900, height: 89)
        let item = CGRect(x: 820, y: 8, width: 60, height: 76)
        let panel = CGRect(x: 650, y: 125, width: 400, height: 160)
        let gap = corridor(panelFrame: panel, itemFrame: item, dockFrame: dock, edge: .bottom)
        XCTAssertEqual(gap, CGRect(x: 650, y: 89, width: 400, height: 36))
        // 从图标正上方移向悬停窗的路径都在空隙里
        XCTAssertTrue(gap.contains(CGPoint(x: item.midX, y: 100)))
        XCTAssertFalse(gap.contains(CGPoint(x: 600, y: 100)))
    }

    func testCorridorCoversTheIconWhenThePanelIsPushedAside() {
        // 最左边的图标：悬停窗被屏幕边缘挤到右边，空隙仍要盖住图标正上方
        let dock = CGRect(x: 0, y: 0, width: 900, height: 89)
        let item = CGRect(x: 2, y: 8, width: 60, height: 76)
        let panel = CGRect(x: 40, y: 125, width: 300, height: 160)
        let gap = corridor(panelFrame: panel, itemFrame: item, dockFrame: dock, edge: .bottom)
        XCTAssertEqual(gap.minX, 2)
        XCTAssertEqual(gap.maxX, 340)
    }

    func testCorridorBesideALeftDock() {
        let dock = CGRect(x: 0, y: 400, width: 59, height: 600)
        let item = CGRect(x: 6, y: 900, width: 46, height: 46)
        let panel = CGRect(x: 200, y: 823, width: 300, height: 200)
        XCTAssertEqual(corridor(panelFrame: panel, itemFrame: item, dockFrame: dock, edge: .left), CGRect(x: 59, y: 823, width: 141, height: 200))
    }

    func testAimZoneCoversTheDockUnderAWidePanel() {
        // 底部程序坞：图标在下，很宽的悬停窗在上方
        let dock = CGRect(x: 236, y: 10, width: 2088, height: 79)
        let item = CGRect(x: 1000, y: 10, width: 63, height: 79)
        let panel = CGRect(x: 300, y: 125, width: 1400, height: 160)
        let zone = aimZone(panelFrame: panel, itemFrame: item, dockFrame: dock, edge: .bottom)
        // 悬停窗正下方的图标都在这一段里，不管鼠标是斜着来还是先横着走
        XCTAssertTrue(zone.contains(CGPoint(x: 937, y: 45)))
        XCTAssertTrue(zone.contains(CGPoint(x: 400, y: 20)))
        XCTAssertTrue(zone.contains(CGPoint(x: 1650, y: 80)))
        // 贴着屏幕底边也算
        XCTAssertTrue(zone.contains(CGPoint(x: 1200, y: 0)))
        // 悬停窗范围之外的图标不在其中，移过去应该立刻切换
        XCTAssertFalse(zone.contains(CGPoint(x: 250, y: 45)))
        XCTAssertFalse(zone.contains(CGPoint(x: 1800, y: 45)))
        // 程序坞上方属于另一块（悬停窗和程序坞之间的空隙），不归这里管
        XCTAssertFalse(zone.contains(CGPoint(x: 1000, y: 100)))
    }

    func testAimZoneFollowsTheIconWhenThePanelIsPushedAside() {
        let dock = CGRect(x: 0, y: 10, width: 900, height: 79)
        let item = CGRect(x: 2, y: 10, width: 60, height: 79)
        let panel = CGRect(x: 40, y: 125, width: 300, height: 160)
        let zone = aimZone(panelFrame: panel, itemFrame: item, dockFrame: dock, edge: .bottom)
        XCTAssertTrue(zone.contains(CGPoint(x: 5, y: 45)))
    }

    func testAimZoneBesideALeftDock() {
        let dock = CGRect(x: 0, y: 400, width: 59, height: 600)
        let item = CGRect(x: 6, y: 900, width: 46, height: 46)
        let panel = CGRect(x: 200, y: 600, width: 300, height: 400)
        let zone = aimZone(panelFrame: panel, itemFrame: item, dockFrame: dock, edge: .left)
        XCTAssertTrue(zone.contains(CGPoint(x: 30, y: 700)))
        XCTAssertFalse(zone.contains(CGPoint(x: 30, y: 500)))
        XCTAssertFalse(zone.contains(CGPoint(x: 100, y: 700)))
    }

    func testPassingThroughVersusArriving() {
        // 底部程序坞，悬停窗在上方（AppKit 坐标里 y 向上）
        // 甩向远处的窗口：很快，带一点向上
        XCTAssertTrue(isPassingThrough(velocity: CGVector(dx: -1800, dy: 220), edge: .bottom))
        // 先贴着程序坞快速横扫：没有向上，但速度快
        XCTAssertTrue(isPassingThrough(velocity: CGVector(dx: 900, dy: 0), edge: .bottom))
        // 慢慢斜着往上移：不快，但确实在靠近悬停窗
        XCTAssertTrue(isPassingThrough(velocity: CGVector(dx: 150, dy: 70), edge: .bottom))
        // 移到隔壁图标上减速停下：又慢又平，是到了
        XCTAssertFalse(isPassingThrough(velocity: CGVector(dx: 180, dy: 10), edge: .bottom))
        XCTAssertFalse(isPassingThrough(velocity: CGVector(dx: 0, dy: 0), edge: .bottom))
        // 往下（远离悬停窗）不算靠近
        XCTAssertFalse(isPassingThrough(velocity: CGVector(dx: 60, dy: -200), edge: .bottom))
    }

    func testPassingThroughForSideDocks() {
        XCTAssertTrue(isPassingThrough(velocity: CGVector(dx: 80, dy: 0), edge: .left))
        XCTAssertFalse(isPassingThrough(velocity: CGVector(dx: -80, dy: 100), edge: .left))
        XCTAssertTrue(isPassingThrough(velocity: CGVector(dx: -80, dy: 0), edge: .right))
    }
}
