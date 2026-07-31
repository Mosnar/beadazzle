import XCTest
@testable import Beadazzle

final class IssueDraftRebaseTests: XCTestCase {
    func testRebasePreservesLocalFieldsAndAdoptsUnrelatedPulledFields() {
        let baselineIssue = issue(title: "Original", description: "Original description")
        let baseline = IssueDraft(issue: baselineIssue)
        var local = baseline
        local.description = "Local description"
        var pulled = baselineIssue
        pulled.title = "Pulled title"

        let result = local.rebased(from: baseline, onto: pulled)

        XCTAssertEqual(result.draft.title, "Pulled title")
        XCTAssertEqual(result.draft.description, "Local description")
        XCTAssertTrue(result.conflictingFields.isEmpty)
    }

    func testRebaseReportsOnlyFieldsChangedDifferentlyOnBothSides() {
        let baselineIssue = issue(title: "Original", description: "Original description")
        let baseline = IssueDraft(issue: baselineIssue)
        var local = baseline
        local.title = "Local title"
        local.description = "Shared description"
        var pulled = baselineIssue
        pulled.title = "Pulled title"
        pulled.description = "Shared description"
        pulled.priority = 0

        let result = local.rebased(from: baseline, onto: pulled)

        XCTAssertEqual(result.draft.title, "Local title")
        XCTAssertEqual(result.draft.description, "Shared description")
        XCTAssertEqual(result.draft.priority, 0)
        XCTAssertEqual(result.conflictingFields, [.title])
    }

    func testNormalizedLabelsDoNotCreateFormattingOnlyConflict() {
        let baselineIssue = issue(labels: ["area:ui", "phase:ready"])
        let baseline = IssueDraft(issue: baselineIssue)
        var local = baseline
        local.labels = ["phase:ready", "area:ui"]
        var pulled = baselineIssue
        pulled.title = "Pulled title"

        let result = local.rebased(from: baseline, onto: pulled)

        XCTAssertFalse(result.conflictingFields.contains(.labels))
        XCTAssertEqual(result.draft.labels, ["area:ui", "phase:ready"])
    }

    private func issue(
        title: String = "Original",
        description: String = "",
        labels: [String] = []
    ) -> BeadIssue {
        BeadIssue(
            id: "bd-1",
            title: title,
            description: description,
            design: "",
            acceptanceCriteria: "",
            notes: "",
            status: "open",
            priority: 2,
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
            labels: labels,
            dependencyCount: 0,
            dependentCount: 0,
            commentCount: 0,
            pinned: false,
            ephemeral: false,
            isTemplate: false
        )
    }
}
