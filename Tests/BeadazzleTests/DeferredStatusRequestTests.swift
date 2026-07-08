import XCTest
@testable import Beadazzle

final class DeferredStatusRequestTests: XCTestCase {
    func testRequestSortsIssueIDsAndPreservesAncestorIDs() {
        let request = DeferredStatusRequest(
            issueIDs: ["bd-2", "bd-1", "bd-2"],
            title: nil,
            status: "deferred",
            reopeningAncestorIssueIDs: ["bd-parent", "bd-grandparent", "bd-parent"]
        )

        XCTAssertEqual(request.issueIDs, ["bd-1", "bd-2"])
        XCTAssertEqual(request.status, "deferred")
        XCTAssertEqual(request.reopeningAncestorIssueIDs, ["bd-grandparent", "bd-parent"])
        XCTAssertEqual(request.targetDescription, "2 selected beads")
    }

    func testSingleIssueRequestUsesIssueTitle() {
        let request = DeferredStatusRequest(
            issues: [
                BeadIssue(
                    id: "bd-1",
                    title: "Polish deferred flow",
                    description: "",
                    design: "",
                    acceptanceCriteria: "",
                    notes: "",
                    status: "open",
                    priority: 1,
                    issueType: "task",
                    assignee: nil,
                    owner: nil,
                    createdAt: nil,
                    updatedAt: nil,
                    closedAt: nil,
                    dueAt: nil,
                    deferUntil: nil,
                    externalRef: nil,
                    parentID: nil,
                    labels: [],
                    dependencyCount: 0,
                    dependentCount: 0,
                    commentCount: 0,
                    pinned: false,
                    ephemeral: false,
                    isTemplate: false
                )
            ],
            status: "deferred",
            reopeningAncestorIssueIDs: ["bd-parent"]
        )

        XCTAssertEqual(request.issueIDs, ["bd-1"])
        XCTAssertEqual(request.reopeningAncestorIssueIDs, ["bd-parent"])
        XCTAssertEqual(request.targetDescription, "bd-1: Polish deferred flow")
    }
}
