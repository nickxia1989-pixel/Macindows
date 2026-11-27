import XCTest
import MacindowsCore

final class WindowCycleTests: XCTestCase {
    func testTabVisitsInterleavedApplicationsAndWindowsInTheirSharedOrder() {
        let cards = ["front app", "window", "another app", "another window"]
        var cycle = WindowCycle(backwards: false)
        var visited: [String] = []
        for _ in cards {
            visited.append(cards[cycle.index(count: cards.count, hasCurrent: true)!])
            cycle.step(backwards: false)
        }
        XCTAssertEqual(visited, ["window", "another app", "another window", "front app"])
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

    func testWhenFrontAppHasNoCardStartAtTheNearestEnd() {
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

    func testSetIndexRepositionsAndSubsequentStepsContinueFromThere() {
        var cycle = WindowCycle(backwards: false)
        cycle.setIndex(3, hasCurrent: true)
        XCTAssertEqual(cycle.index(count: 6, hasCurrent: true), 3)
        cycle.step(backwards: false)
        XCTAssertEqual(cycle.index(count: 6, hasCurrent: true), 4)
        cycle.step(backwards: true)
        XCTAssertEqual(cycle.index(count: 6, hasCurrent: true), 3)

        var noCurrent = WindowCycle(backwards: false)
        noCurrent.setIndex(2, hasCurrent: false)
        XCTAssertEqual(noCurrent.index(count: 5, hasCurrent: false), 2)
        noCurrent.step(backwards: false)
        XCTAssertEqual(noCurrent.index(count: 5, hasCurrent: false), 3)
    }
}
