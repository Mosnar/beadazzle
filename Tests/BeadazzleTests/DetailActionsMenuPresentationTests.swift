import XCTest
@testable import Beadazzle

final class DetailToolbarActionPresentationTests: XCTestCase {
    func testRestHoverPressAndFocusHaveDistinctPresentation() {
        let rest = DetailToolbarActionPresentationState()
        XCTAssertFalse(rest.isHighlighted)
        XCTAssertEqual(rest.backgroundOpacity, 0)

        let hover = DetailToolbarActionPresentationState(isHovered: true)
        XCTAssertTrue(hover.isHighlighted)
        XCTAssertEqual(hover.backgroundOpacity, 0.12)

        let press = DetailToolbarActionPresentationState(isPressed: true)
        XCTAssertTrue(press.isHighlighted)
        XCTAssertEqual(press.backgroundOpacity, 0.20)

        let focus = DetailToolbarActionPresentationState(isFocused: true)
        XCTAssertTrue(focus.isHighlighted)
        XCTAssertEqual(focus.backgroundOpacity, 0.12)
    }
}
