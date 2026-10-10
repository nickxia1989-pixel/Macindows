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
}
