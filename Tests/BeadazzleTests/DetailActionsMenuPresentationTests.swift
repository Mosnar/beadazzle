import XCTest
@testable import Beadazzle

final class DetailActionsMenuPresentationTests: XCTestCase {
    func testHoverPressAndFocusEachHighlightTheMenu() {
        XCTAssertTrue(DetailActionsMenuPresentationState(isHovered: true).isHighlighted)
        XCTAssertTrue(DetailActionsMenuPresentationState(isPressed: true).isHighlighted)
        XCTAssertTrue(DetailActionsMenuPresentationState(isFocused: true).isHighlighted)
        XCTAssertFalse(DetailActionsMenuPresentationState().isHighlighted)
    }
}
