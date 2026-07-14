import XCTest
@testable import Beadazzle

final class IssueCreationToolbarPresentationTests: XCTestCase {
    func testBreadcrumbContainsOnlyProjectAndDraft() {
        let presentation = IssueCreationToolbarPresentation(
            projectName: "Beadazzle",
            draftTitle: "New issue"
        )

        XCTAssertEqual(presentation.breadcrumbTitles, ["Beadazzle", "New issue"])
    }

    func testBlankDraftUsesUntitledFallback() {
        let presentation = IssueCreationToolbarPresentation(
            projectName: "Beadazzle",
            draftTitle: "  "
        )

        XCTAssertEqual(presentation.draftTitle, "Untitled bead")
    }

    func testPrimaryActionIsCreate() {
        XCTAssertEqual(IssueCreationToolbarPresentation.createButtonTitle, "Create")
    }
}
