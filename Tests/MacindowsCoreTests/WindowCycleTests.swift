import XCTest
import MacindowsCore

final class WindowCycleTests: XCTestCase {
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
