import XCTest
@testable import Beadazzle

final class HoverPersistentPopoverPresentationStateTests: XCTestCase {
    func testClickPinsAlreadyHoverPresentedPreviewInsteadOfClosingIt() {
        var state = HoverPersistentPopoverPresentationState(
            isTriggerHovered: true,
            isPreviewHovered: false,
            isPresented: true,
            isPinned: false
        )

        state.togglePin()

        XCTAssertTrue(state.isPinned)
        XCTAssertTrue(state.isPresented)
    }

    func testPinnedPreviewDoesNotCloseWhenPointerLeaves() {
        var state = HoverPersistentPopoverPresentationState(
            isTriggerHovered: false,
            isPreviewHovered: false,
            isPresented: true,
            isPinned: true
        )

        XCTAssertFalse(state.shouldCloseAfterDelay)
        state.togglePin()
        XCTAssertFalse(state.isPresented)
    }

    func testDismissClearsHoverPinAndPresentationState() {
        var state = HoverPersistentPopoverPresentationState(
            isTriggerHovered: true,
            isPreviewHovered: true,
            isPresented: true,
            isPinned: true
        )

        state.dismiss()

        XCTAssertEqual(state, HoverPersistentPopoverPresentationState())
    }
}
