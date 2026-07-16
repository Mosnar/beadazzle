import XCTest
@testable import Beadazzle

@MainActor
final class BeadMutationFailureTests: XCTestCase {
    func testDialogMessageIncludesCommandAndOutputSections() {
        let failure = BeadMutationFailure(
            title: "Couldn't update bd-1",
            message: "The Beads command failed.",
            command: "bd update bd-1 --assignee alice",
            output: "error: not found"
        )
        let body = failure.dialogMessage
        XCTAssertTrue(body.contains("The Beads command failed."))
        XCTAssertTrue(body.contains("Command:\nbd update bd-1 --assignee alice"))
        XCTAssertTrue(body.contains("Output:\nerror: not found"))
    }

    func testDialogMessageOmitsEmptySections() {
        let failure = BeadMutationFailure(title: "Title", message: "Just a message.")
        XCTAssertEqual(failure.dialogMessage, "Just a message.")
    }

    func testIsRetryableReflectsRetryClosure() {
        XCTAssertFalse(BeadMutationFailure(title: "T", message: "m").isRetryable)
        XCTAssertTrue(BeadMutationFailure(title: "T", message: "m", retry: {}).isRetryable)
    }

    func testHasSameContentIgnoresIDAndRetry() {
        let a = BeadMutationFailure(title: "T", message: "m", command: "c", output: "o", retry: {})
        let b = BeadMutationFailure(title: "T", message: "m", command: "c", output: "o")
        XCTAssertTrue(a.hasSameContent(as: b))
        XCTAssertFalse(a.hasSameContent(as: BeadMutationFailure(title: "T2", message: "m")))
    }

    func testLongOutputIsTruncatedInDialogMessage() {
        let longOutput = String(repeating: "x", count: 5000)
        let failure = BeadMutationFailure(title: "T", message: "m", command: "c", output: longOutput)
        XCTAssertTrue(failure.dialogMessage.contains("output truncated"))
        XCTAssertLessThan(failure.dialogMessage.count, 5000)
    }

    func testAccessibilityAnnouncementCombinesTitleAndMessage() {
        let failure = BeadMutationFailure(title: "Couldn't update bd-1", message: "The Beads command failed.")
        XCTAssertEqual(failure.accessibilityAnnouncement, "Couldn't update bd-1. The Beads command failed.")
    }
}
