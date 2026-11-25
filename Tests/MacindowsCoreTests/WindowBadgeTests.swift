import XCTest
import MacindowsCore

final class WindowBadgeTests: XCTestCase {
    func testNumericDockBadgesPreserveDisplayedNumber() {
        XCTAssertEqual(WindowBadges.dockNumber(" 7 "), "7")
        XCTAssertEqual(WindowBadges.dockNumber("９９＋"), "99+")
        XCTAssertEqual(WindowBadges.dockNumber("1,234"), "1,234")
        XCTAssertEqual(WindowBadges.dockNumber("1,234,567"), "1,234,567")
        for value in [nil, "", "0", "00", "•", "!", "3 of 5", "3,4", "12%", "3 unread", "收件箱（3 条未读消息）"] {
            XCTAssertNil(WindowBadges.dockNumber(value))
        }
    }
}
