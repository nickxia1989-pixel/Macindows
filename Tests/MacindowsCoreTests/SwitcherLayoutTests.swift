import XCTest
import MacindowsCore

final class SwitcherLayoutTests: XCTestCase {
    private let laptop = CGSize(width: 1512, height: 949)
    private let landscape = CGSize(width: 1600, height: 1000)
    private let portrait = CGSize(width: 500, height: 900)
    private let square = CGSize(width: 800, height: 800)

    func testFitsBeyondEightAndShrinksAsWindowsAccumulate() {
        func layout(_ count: Int) -> SwitcherLayout {
            SwitcherLayout(windowSizes: Array(repeating: landscape, count: count), screenSize: laptop)
        }
        let few = layout(3), medium = layout(14), many = layout(40)
        XCTAssertEqual(few.pages, [0..<3])
        XCTAssertEqual(medium.pages, [0..<14])
        XCTAssertEqual(many.pages, [0..<40])
        XCTAssertGreaterThan(few.frames[0].height, medium.frames[0].height)
        XCTAssertGreaterThan(medium.frames[0].height, many.frames[0].height)
    }

    func testScreenSpaceDecidesWhenToPaginate() {
        let sizes = Array<CGSize?>(repeating: landscape, count: 60)
        let laptopLayout = SwitcherLayout(windowSizes: sizes, screenSize: laptop)
        let desktopLayout = SwitcherLayout(windowSizes: sizes, screenSize: CGSize(width: 2560, height: 1380))
        XCTAssertGreaterThan(laptopLayout.pages.count, 1)
        XCTAssertEqual(desktopLayout.pages, [0..<60])
        XCTAssertGreaterThan(laptopLayout.pages[0].count, 8)
        XCTAssertEqual(laptopLayout.pages.flatMap { $0 }, Array(sizes.indices))
    }

    func testPortraitLandscapeAndSquareHaveDistinctFrames() {
        let sizes = [portrait, landscape, square]
        let layout = SwitcherLayout(windowSizes: sizes, screenSize: laptop)
        XCTAssertLessThan(layout.frames[0].width, layout.frames[2].width)
        XCTAssertGreaterThan(layout.frames[1].width, layout.frames[2].width)
        for (index, size) in sizes.enumerated() {
            let card = layout.frames[index]
            let picture = SwitcherLayout.pictureFrame(for: size, in: card)
            XCTAssertEqual(picture.width / picture.height, size.width / size.height, accuracy: 0.01)
            XCTAssertTrue(CGRect(origin: .zero, size: card.size).contains(picture))
        }
    }

    func testMixedShapesAcrossPagesDoNotClipOverlapOrReorder() {
        let shapes: [CGSize?] = [portrait, landscape, square, nil, CGSize(width: 4000, height: 600), CGSize(width: 200, height: 1600)]
        let sizes = (0..<183).map { shapes[$0 % shapes.count] }
        for screen in [CGSize(width: 1024, height: 640), CGSize(width: 850, height: 1450), laptop] {
            let layout = SwitcherLayout(windowSizes: sizes, screenSize: screen)
            XCTAssertLessThanOrEqual(layout.size.width, screen.width)
            XCTAssertLessThanOrEqual(layout.size.height, screen.height)
            XCTAssertEqual(layout.pages.flatMap { $0 }, Array(sizes.indices))
            for page in layout.pages {
                var previous: CGRect?
                for i in page {
                    let card = layout.frames[i]
                    XCTAssertTrue(CGRect(origin: .zero, size: layout.size).contains(card))
                    XCTAssertGreaterThanOrEqual(card.width, 120)
                    let picture = SwitcherLayout.pictureFrame(for: sizes[i], in: card)
                    XCTAssertLessThanOrEqual(picture.maxY, card.height - SwitcherLayout.titleSpace)
                    if let previous {
                        XCTAssertTrue(card.minY >= previous.maxY || (card.minY == previous.minY && card.minX >= previous.maxX))
                    }
                    previous = card
                }
            }
        }
    }

    func testMissingFrameUsesFallbackUntilImageArrives() {
        let layout = SwitcherLayout(windowSizes: [nil], screenSize: laptop)
        let card = layout.frames[0]
        for unavailable in [nil, CGSize.zero, CGSize(width: CGFloat.nan, height: 20)] {
            let picture = SwitcherLayout.pictureFrame(for: unavailable, in: card)
            XCTAssertEqual(picture.width / picture.height, SwitcherLayout.defaultAspect, accuracy: 0.01)
        }
        let actual = SwitcherLayout.pictureFrame(for: portrait, in: card)
        XCTAssertLessThan(actual.width, actual.height)
    }
}
