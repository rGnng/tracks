import XCTest
@testable import Audia

final class AlbumGridLayoutTests: XCTestCase {
    private let layout = AlbumGridLayout(
        count: 10,
        columns: 4,
        cardWidth: 100,
        cardHeight: 120,
        columnSpacing: 22,
        rowSpacing: 26,
        padding: 22
    )

    func testFrameAtFirstIndex() {
        XCTAssertEqual(layout.frame(at: 0),
                       CGRect(x: 22, y: 22, width: 100, height: 120))
    }

    func testFrameAtColumnBoundary() {
        XCTAssertEqual(layout.frame(at: 4),
                       CGRect(x: 22, y: 168, width: 100, height: 120))
    }

    func testFrameAtLastIndex() {
        XCTAssertEqual(layout.frame(at: 9),
                       CGRect(x: 144, y: 314, width: 100, height: 120))
    }

    func testInvalidIndexHasNoFrame() {
        XCTAssertNil(layout.frame(at: -1))
        XCTAssertNil(layout.frame(at: 10))
    }

    func testIndexAtPoint() {
        XCTAssertEqual(layout.index(at: CGPoint(x: 30, y: 30)), 0)
        XCTAssertEqual(layout.index(at: CGPoint(x: 150, y: 30)), 1)
        XCTAssertEqual(layout.index(at: CGPoint(x: 30, y: 180)), 4)
        XCTAssertNil(layout.index(at: CGPoint(x: 10, y: 30)))
        XCTAssertNil(layout.index(at: CGPoint(x: 30, y: 600)))
    }
}
