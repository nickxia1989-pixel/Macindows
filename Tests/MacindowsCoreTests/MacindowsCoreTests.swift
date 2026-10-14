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

    func testSingleWindowFrontmostGetsMinimized() {
        XCTAssertEqual(dockClickAction(for: state(front: true, windows: 1)), .minimizeWindow)
    }

    func testSingleWindowInBackgroundIsActivatedByTheDock() {
        XCTAssertEqual(dockClickAction(for: state(front: false, windows: 1)), .passThrough)
    }

    func testSingleMinimizedWindowIsRestored() {
        // 最小化之后这个 App 往往仍是「最前」的那个，再点一下要能放回来；它不在最前时也一样
        XCTAssertEqual(dockClickAction(for: state(front: true, windows: 1, minimized: 1)), .restoreWindow)
        XCTAssertEqual(dockClickAction(for: state(front: false, windows: 1, minimized: 1)), .restoreWindow)
    }

    func testHiddenAppIsShownByTheDock() {
        XCTAssertEqual(dockClickAction(for: state(front: false, hidden: true, windows: 1)), .passThrough)
        XCTAssertEqual(dockClickAction(for: state(front: false, hidden: true, windows: 1, minimized: 1)), .passThrough)
    }

    func testSingleWindowOnAnotherSpaceIsLeftToTheDock() {
        // 窗口在别的桌面上：程序坞会切过去。哪怕 App 算「最前」，也不能把看不见的窗口最小化掉
        let elsewhere = AppWindowState(isRunning: true, isFrontmost: true, isHidden: false, windowCount: 1, minimizedCount: 0, elsewhereCount: 1)
        XCTAssertEqual(dockClickAction(for: elsewhere), .passThrough)
        // 别的桌面上有窗口、这里也有：照样列出来挑
        let both = AppWindowState(isRunning: true, isFrontmost: true, isHidden: false, windowCount: 2, minimizedCount: 0, elsewhereCount: 1)
        XCTAssertEqual(dockClickAction(for: both), .showWindowList)
    }

    func testMultipleWindowsAlwaysShowTheList() {
        XCTAssertEqual(dockClickAction(for: state(front: true, windows: 2)), .showWindowList)
        XCTAssertEqual(dockClickAction(for: state(front: false, windows: 3, minimized: 3)), .showWindowList)
        XCTAssertEqual(dockClickAction(for: state(front: false, hidden: true, windows: 2)), .showWindowList)
    }
}

final class WindowFilterTests: XCTestCase {
    private func window(_ subrole: String?, level: Int? = 0, size: CGSize? = CGSize(width: 900, height: 600), title: String? = "文稿",
                        role: String? = "AXWindow", bundle: String? = "com.example.app", path: String? = nil) -> WindowTraits {
        WindowTraits(role: role, subrole: subrole, title: title, size: size, level: level, bundleID: bundle, executablePath: path)
    }

    func testStandardWindowsAreListed() {
        XCTAssertTrue(isListableWindow(window("AXStandardWindow")))
        // 层级读不到时不因此丢掉窗口
        XCTAssertTrue(isListableWindow(window("AXStandardWindow", level: nil, size: nil)))
    }

    func testDialogsOnTheNormalLevelAreListed() {
        // 最小化或被隐藏的窗口会被系统改报成对话框；有些 App 的主窗口本来就是对话框
        XCTAssertTrue(isListableWindow(window("AXDialog")))
    }

    func testFloatingPanelsAreNotListed() {
        // 提醒条之类：类型是对话框，但浮在普通窗口上面
        XCTAssertFalse(isListableWindow(window("AXDialog", level: 3)))
        XCTAssertFalse(isListableWindow(window("AXStandardWindow", level: 8)))
        XCTAssertFalse(isListableWindow(window("AXFloatingWindow")))
        XCTAssertFalse(isListableWindow(window("AXSystemDialog")))
        XCTAssertFalse(isListableWindow(window("AXUnknown")))
        XCTAssertFalse(isListableWindow(window(nil)))
    }

    func testTinyWindowsAreNotListed() {
        XCTAssertFalse(isListableWindow(window("AXStandardWindow", size: CGSize(width: 1, height: 1))))
        // 和菜单栏一样扁的隐形窗口
        XCTAssertFalse(isListableWindow(window("AXStandardWindow", size: CGSize(width: 2560, height: 30))))
        XCTAssertTrue(isListableWindow(window("AXStandardWindow", size: CGSize(width: 100, height: 50))))
    }

    func testAppSpecificRules() {
        // JetBrains：没有标题的对话框是隐形窗口，有标题的才算
        XCTAssertFalse(isListableWindow(window("AXDialog", title: "", bundle: "com.jetbrains.intellij")))
        XCTAssertTrue(isListableWindow(window("AXDialog", title: "设置", bundle: "com.jetbrains.intellij")))
        XCTAssertTrue(isListableWindow(window("AXStandardWindow", title: "", bundle: "com.google.android.studio")))
        // Steam：窗口不报类型，靠标题认
        XCTAssertTrue(isListableWindow(window(nil, title: "Steam", bundle: "com.valvesoftware.steam")))
        XCTAssertFalse(isListableWindow(window("AXStandardWindow", title: "", bundle: "com.valvesoftware.steam")))
        // Firefox 全屏视频
        XCTAssertTrue(isListableWindow(window("AXUnknown", bundle: "org.mozilla.firefox")))
        XCTAssertFalse(isListableWindow(window("AXUnknown", size: CGSize(width: 400, height: 300), bundle: "org.mozilla.firefox")))
        // Adobe 的主窗口报成浮动窗口；别的 App 的浮动窗口不受影响
        XCTAssertTrue(isListableWindow(window("AXFloatingWindow", bundle: "com.adobe.AfterEffects")))
        // CrossOver 里的 Windows 程序
        XCTAssertTrue(isListableWindow(window("AXUnknown", bundle: nil, path: "/Users/me/Library/wine/bin/wine64-preloader")))
        XCTAssertFalse(isListableWindow(window("AXUnknown", level: 3, bundle: nil, path: "/Users/me/Library/wine/bin/wine64-preloader")))
        // 安卓模拟器
        XCTAssertTrue(isListableWindow(window("AXUnknown", title: "Pixel 9", bundle: nil, path: "/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64")))
        XCTAssertFalse(isListableWindow(window("AXUnknown", title: "Window", bundle: nil, path: "/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64")))
        // 置顶的 scrcpy
        XCTAssertTrue(isListableWindow(window("AXStandardWindow", level: 3, bundle: nil, path: "/opt/homebrew/bin/scrcpy")))
    }
}

final class SpaceTests: XCTestCase {
    func testOnlyWindowsOnAnotherExistingSpaceCount() {
        let active: Set<Int> = [1, 852], known: Set<Int> = [1, 7, 852]
        XCTAssertTrue(isOnAnotherSpace(windowSpaces: [7], activeSpaces: active, knownSpaces: known))
        // 在当前桌面上的不算「别的桌面」
        XCTAssertFalse(isOnAnotherSpace(windowSpaces: [1], activeSpaces: active, knownSpaces: known))
        XCTAssertFalse(isOnAnotherSpace(windowSpaces: [7, 852], activeSpaces: active, knownSpaces: known))
        // App 留着没显示的窗口：不在任何桌面上
        XCTAssertFalse(isOnAnotherSpace(windowSpaces: [], activeSpaces: active, knownSpaces: known))
        // 挂在一个已经不存在的桌面上
        XCTAssertFalse(isOnAnotherSpace(windowSpaces: [99], activeSpaces: active, knownSpaces: known))
    }

    func testTabsOfOneWindowCollapse() {
        let tab = CGRect(x: 100, y: 80, width: 1200, height: 800)
        let frames: [CGRect?] = [tab, CGRect(x: 300, y: 200, width: 900, height: 600), tab.offsetBy(dx: 0.2, dy: -0.3), nil, tab, nil]
        // 位置大小相同的只留最前面的一个；读不到位置的不参与合并
        XCTAssertEqual(duplicateTabIndices(frames: frames), [2, 4])
        XCTAssertEqual(duplicateTabIndices(frames: []), [])
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
