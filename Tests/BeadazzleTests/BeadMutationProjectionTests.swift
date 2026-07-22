import XCTest
@testable import Beadazzle

final class BeadMutationProjectionTests: XCTestCase {
    func testSparseEntriesLayerOverAuthoritativeIssuesAndDependencies() throws {
        let child = issue("bd-child", parentID: "bd-parent")
        let parent = issue("bd-parent")
        let dependency = BeadDependency(
            issueID: child.id,
            dependsOnID: parent.id,
            type: "parent-child"
        )
        let base = BeadProjectIndex(
            issues: [child, parent],
            dependencies: [dependency],
            semantics: .empty
        )
        var projection = BeadMutationProjection()
        let entry = BeadMutationProjectionEntry(
            issueChanges: [
                child.id: .update(
                    BeadIssueMutationPatch(
                        status: .set("closed"),
                        parentID: .set(nil)
                    )
                )
            ],
            removedDependencies: [dependency]
        )

        projection.append(entry)

        XCTAssertEqual(projection.issue(with: child.id, in: base)?.status, "closed")
        XCTAssertNil(projection.issue(with: child.id, in: base)?.parentID)
        XCTAssertTrue(projection.dependencies(for: child.id, in: base).isEmpty)
        let materialized = projection.materialized(over: base)
        XCTAssertEqual(materialized.issues.first { $0.id == child.id }?.status, "closed")
        XCTAssertTrue(materialized.dependencies.isEmpty)
    }

    func testOnlySucceededEntriesRetireOnAuthoritativeReconcile() {
        let base = BeadProjectIndex(
            issues: [issue("bd-1")],
            dependencies: [],
            semantics: .empty
        )
        var projection = BeadMutationProjection()
        let succeeded = BeadMutationProjectionEntry(
            issueChanges: ["bd-1": .update(BeadIssueMutationPatch(title: .set("Saved")))]
        )
        let pending = BeadMutationProjectionEntry(
            issueChanges: ["bd-1": .update(BeadIssueMutationPatch(status: .set("closed")))]
        )
        projection.append(succeeded)
        projection.append(pending)
        XCTAssertTrue(projection.markSucceeded(succeeded.id))

        projection.reconcile(authoritative: true)

        XCTAssertEqual(projection.issue(with: "bd-1", in: base)?.title, "Example")
        XCTAssertEqual(projection.issue(with: "bd-1", in: base)?.status, "closed")
    }

    func testSettledMutationHistoryCompactsWithoutChangingLayeredResult() {
        let base = BeadProjectIndex(
            issues: [issue("bd-1")],
            dependencies: [],
            semantics: .empty
        )
        var projection = BeadMutationProjection()

        for offset in 0..<1_000 {
            let entry = BeadMutationProjectionEntry(
                issueChanges: [
                    "bd-1": .update(BeadIssueMutationPatch(title: .set("Title \(offset)")))
                ]
            )
            projection.append(entry)
            XCTAssertTrue(projection.markSucceeded(entry.id))
        }

        XCTAssertEqual(projection.entries.count, 1)
        XCTAssertEqual(projection.issue(with: "bd-1", in: base)?.title, "Title 999")
    }

    func testLargeMaterializationStopsWhenCancelled() {
        let issues = (0..<10_000).map { issue("bd-\($0)") }
        let base = BeadProjectIndex(issues: issues, dependencies: [], semantics: .empty)
        var projection = BeadMutationProjection()
        projection.append(
            BeadMutationProjectionEntry(
                issueChanges: ["bd-9999": .update(BeadIssueMutationPatch(status: .set("closed"))) ]
            )
        )

        let materialized = projection.materialized(over: base, shouldCancel: { true })

        XCTAssertNil(materialized)
        XCTAssertEqual(projection.issue(with: "bd-9999", in: base)?.status, "closed")
    }

    private func issue(_ id: String, parentID: String? = nil) -> BeadIssue {
        BeadIssue(
            id: id,
            title: "Example",
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
            parentID: parentID,
            labels: [],
            dependencyCount: 0,
            dependentCount: 0,
            commentCount: 0,
            pinned: false,
            ephemeral: false,
            isTemplate: false
        )
    }
}
