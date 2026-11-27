import XCTest
import MacindowsCore

final class LastWindowPreviewTests: XCTestCase {
    func testRepeatedOpensKeepTheClosedWindowAfterTheLiveCacheEvictsIt() {
        var preview = LastWindowPreview<String>()
        var cached: String? = "portrait"
        preview.observe(candidate: 8, hasOpenWindows: true, cached: cached)
        preview.observe(candidate: 8, hasOpenWindows: false, cached: cached)
        XCTAssertEqual(preview.image, "portrait")

        cached = nil
        for _ in 0..<3 {
            preview.observe(candidate: 8, hasOpenWindows: false, cached: cached)
            preview.observe(candidate: nil, hasOpenWindows: false, cached: cached)
            XCTAssertEqual(preview.image, "portrait")
        }
    }

    func testAReopenedAppUsesOnlyItsNewFinalWindow() {
        var preview = LastWindowPreview<String>()
        preview.observe(candidate: 3, hasOpenWindows: false, cached: "old document")
        preview.observe(candidate: 7, hasOpenWindows: true, cached: nil)
        preview.captured("late old capture", for: 3)
        XCTAssertNil(preview.image)

        preview.observe(candidate: 7, hasOpenWindows: false, cached: nil)
        preview.captured("new document", for: 7)
        preview.observe(candidate: nil, hasOpenWindows: false, cached: nil)
        XCTAssertEqual(preview.image, "new document")
    }

    func testAmbiguousCloseShowsNoPictureAfterMultipleWindowsOpened() {
        var preview = LastWindowPreview<String>()
        preview.observe(candidate: 3, hasOpenWindows: false, cached: "old document")
        preview.observe(candidate: nil, hasOpenWindows: true, cached: nil)
        preview.observe(candidate: nil, hasOpenWindows: false, cached: nil)
        preview.captured("late old capture", for: 3)
        XCTAssertNil(preview.image)
    }
}
