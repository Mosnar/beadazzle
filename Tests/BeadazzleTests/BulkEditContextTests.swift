import XCTest
@testable import Beadazzle

final class BulkEditContextTests: XCTestCase {
    func testBulkMutationProgressTracksSettledOutcomesWithoutExceedingTotal() {
        var progress = BulkMutationProgress(totalCount: 3)

        progress.recordCompletion(succeeded: true)
        progress.recordCompletion(succeeded: false)

        XCTAssertEqual(progress.completedCount, 2)
        XCTAssertEqual(progress.succeededCount, 1)
        XCTAssertEqual(progress.failedCount, 1)
        XCTAssertEqual(progress.remainingCount, 1)

        progress.recordCompletion(succeeded: true)
        progress.recordCompletion(succeeded: false)

        XCTAssertEqual(progress.completedCount, 3)
        XCTAssertEqual(progress.succeededCount, 2)
        XCTAssertEqual(progress.failedCount, 1)
        XCTAssertEqual(progress.remainingCount, 0)
    }

    func testBulkMutationFailuresKeepExactCountsWithBoundedDiagnostics() {
        var failures = BulkMutationFailureCollection()

        for index in 0..<100 {
            failures.record(
                issueIDs: ["bd-\(index)"],
                error: BeadError.commandFailed(
                    command: "bd set-state bd-\(index) phase=ready",
                    output: "failure \(index)"
                )
            )
        }

        XCTAssertEqual(failures.commandCount, 100)
        XCTAssertEqual(failures.issueIDs.count, 100)
        XCTAssertEqual(failures.details.count, BulkMutationFailureCollection.maximumDetailedFailures)
        XCTAssertEqual(failures.omittedDetailCount, 50)

        let result = BulkMutationResult(
            progress: BulkMutationProgress(totalCount: 100),
            outcome: .completed,
            failures: failures.details,
            failedIssueIDs: failures.failedIssueIDs,
            failureCount: failures.commandCount
        )
        XCTAssertFalse(result.isSuccessful)
        XCTAssertEqual(result.failureCount, 100)
        XCTAssertEqual(result.failedIssueIDs.count, 100)
    }

    func testLabelContextSummarizesLargeSelectionOnceAndKeepsQueriesCatalogSized() {
        let issues = (0..<10_000).map { index in
            issue(
                id: "bd-\(index)",
                labels: index.isMultiple(of: 2)
                    ? ["alpha", "beta", "phase:design"]
                    : ["alpha", "phase:implementation"]
            )
        }
        let context = BulkAddLabelsContext(
            issues: issues,
            availableLabels: ["alpha", "beta", "phase:design", "phase:implementation"],
            managedDimensions: ["phase"]
        )

        XCTAssertEqual(context.issueCount, 10_000)
        XCTAssertEqual(context.availableLabels, ["alpha", "beta"])
        XCTAssertEqual(context.coverageCount(for: "alpha"), 10_000)
        XCTAssertEqual(context.coverageCount(for: "beta"), 5_000)
        XCTAssertEqual(context.coverageCount(for: "new"), 0)
        XCTAssertEqual(context.queryState(for: "ALPHA").resolvedLabels, ["alpha"])
        XCTAssertFalse(context.queryState(for: "ALPHA").canCreate)
        XCTAssertTrue(context.queryState(for: "phase:ready").usesManagedProperty)
        XCTAssertEqual(
            context.visibleLabels(query: "", including: ["new"]),
            ["alpha", "beta", "new"]
        )
    }

    func testPropertyContextComputesChangedCountWithoutRetainingPerIssueValues() {
        let catalog = BeadStateValueCatalog(
            active: [BeadStateValuePresentation(value: "ready", displayName: "Ready", isArchived: false)],
            archived: []
        )
        let context = BulkSetPropertyContext(
            issueCount: 12_000,
            displayName: "Phase",
            currentSummary: "Mixed",
            catalog: catalog,
            candidateValues: catalog.active,
            currentValueCounts: ["ready": 4_000, "design": 6_000]
        )

        XCTAssertEqual(context.changedIssueCount(for: "ready"), 8_000)
        XCTAssertEqual(context.changedIssueCount(for: "new"), 12_000)
        XCTAssertEqual(context.displayName(for: "ready"), "Ready")
        XCTAssertEqual(context.displayName(for: "new"), "new")
    }

    private func issue(id: String, labels: [String]) -> BeadIssue {
        BeadIssue(
            id: id,
            title: id,
            description: "",
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
