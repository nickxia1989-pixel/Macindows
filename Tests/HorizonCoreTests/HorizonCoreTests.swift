import XCTest
@testable import HorizonCore

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

    func testAimTriangleKeepsADiagonalPathButNotASidewaysOne() {
        // 底部程序坞：图标在下，很宽的悬停窗在上方
        let origin = CGPoint(x: 1000, y: 45)
        let panel = CGRect(x: 300, y: 125, width: 1400, height: 160)
        let (a, b, c) = aimTriangle(from: origin, panelFrame: panel, edge: .bottom)
        // 朝悬停窗最左边那一格斜着移过去，途中每一点都在三角里
        let target = CGPoint(x: 320, y: 125)
        for step in 1...9 {
            let t = CGFloat(step) / 10
            XCTAssertTrue(triangleContains(CGPoint(x: origin.x + (target.x - origin.x) * t, y: origin.y + (target.y - origin.y) * t), a, b, c))
        }
        // 沿着程序坞水平移到隔壁图标：不在三角里，应该立刻切换
        XCTAssertFalse(triangleContains(CGPoint(x: 937, y: 45), a, b, c))
        XCTAssertFalse(triangleContains(CGPoint(x: 1063, y: 44), a, b, c))
        // 往下移（离开程序坞方向相反）也不算
        XCTAssertFalse(triangleContains(CGPoint(x: 1000, y: 20), a, b, c))
    }

    func testAimTriangleForASideDock() {
        let origin = CGPoint(x: 30, y: 600)
        let panel = CGRect(x: 200, y: 300, width: 300, height: 600)
        let (a, b, c) = aimTriangle(from: origin, panelFrame: panel, edge: .left)
        XCTAssertTrue(triangleContains(CGPoint(x: 120, y: 480), a, b, c))
        XCTAssertFalse(triangleContains(CGPoint(x: 30, y: 540), a, b, c))
    }
}
