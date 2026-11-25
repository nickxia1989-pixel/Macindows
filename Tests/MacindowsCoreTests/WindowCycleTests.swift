import XCTest
import MacindowsCore

final class WindowCycleTests: XCTestCase {
    func testWindowAndAppRowsCycleIndependently() {
        var cycle = WindowCycle(backwards: false)
        func selected() -> SwitcherChoice? { cycle.selection(windows: 2, applications: 11, hasCurrent: true) }
        XCTAssertEqual(selected(), .window(1))
        cycle.step(backwards: false)
        XCTAssertEqual(selected(), .window(0))
        cycle.enterApplications()
        XCTAssertEqual(selected(), .application(0))
        cycle.step(backwards: true)
        XCTAssertEqual(selected(), .application(10))
        cycle.enterApplications()
        XCTAssertEqual(selected(), .application(10))
        cycle.returnToWindows()
        XCTAssertEqual(selected(), .window(0))
    }

    func testOnlyAppsUsePendingTabStepsAndWrap() {
        var cycle = WindowCycle(backwards: true)
        XCTAssertEqual(cycle.selection(windows: 0, applications: 4, hasCurrent: false), .application(3))
        cycle.step(backwards: false)
        XCTAssertEqual(cycle.selection(windows: 0, applications: 4, hasCurrent: false), .application(0))
        XCTAssertNil(cycle.selection(windows: 0, applications: 0, hasCurrent: false))
    }
    func testFirstStepSkipsTheCurrentWindowAndWrapsInBothDirections() {
        var cycle = WindowCycle(backwards: false)
        XCTAssertEqual(cycle.index(count: 3, hasCurrent: true), 1)
        cycle.step(backwards: true)
        XCTAssertEqual(cycle.index(count: 3, hasCurrent: true), 0)
        cycle.step(backwards: true)
        XCTAssertEqual(cycle.index(count: 3, hasCurrent: true), 2)
        XCTAssertEqual(WindowCycle(backwards: true).index(count: 3, hasCurrent: true), 2)
    }

    func testWhenFrontAppHasNoWindowStartAtTheNearestEnd() {
        var cycle = WindowCycle(backwards: false)
        XCTAssertEqual(cycle.index(count: 4, hasCurrent: false), 0)
        cycle.step(backwards: true)
        XCTAssertEqual(cycle.index(count: 4, hasCurrent: false), 3)
        XCTAssertEqual(WindowCycle(backwards: true).index(count: 4, hasCurrent: false), 3)
    }

    func testTabsReceivedBeforeEnumerationFinishes() {
        var cycle = WindowCycle(backwards: true)
        cycle.step(backwards: true)
        cycle.step(backwards: true)
        cycle.step(backwards: false)
        XCTAssertEqual(cycle.index(count: 0, hasCurrent: true), nil)
        XCTAssertEqual(cycle.index(count: 1, hasCurrent: true), 0)
        XCTAssertEqual(cycle.index(count: 12, hasCurrent: true), 10)
    }
}
