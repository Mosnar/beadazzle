import XCTest
@testable import Beadazzle

final class BeadIssueSortOrderTests: XCTestCase {
    func testEverySortDirectionIsStrictForIdenticalIssues() {
        let issue = issue("bd-1", title: "Example", status: "open", type: "task")

        for sort in IssueSort.allCases {
            for direction in SortDirection.allCases {
                let order = BeadIssueSortOrder(sort: sort, direction: direction)
                XCTAssertFalse(
                    order.areInIncreasingOrder(issue, issue),
                    "\(sort.rawValue) \(direction.rawValue) must not order an issue before itself"
                )
            }
        }
    }

    func testDescendingSortWithDuplicatePrimaryKeysIsDeterministic() {
        let issues = (0..<1_000).map { offset in
            issue(String(format: "bd-%04d", offset), title: "Shared", status: "open", type: "task")
        }
        let order = BeadIssueSortOrder(sort: .status, direction: .descending)
        let sorted = issues.sorted(by: order.areInIncreasingOrder)

        XCTAssertEqual(sorted.first?.id, "bd-0999")
        XCTAssertEqual(sorted.last?.id, "bd-0000")
    }

    func testDuplicatePrimaryKeysAreNotMutuallyOrdered() {
        let lhs = issue("bd-1", title: "Shared", status: "open", type: "task")
        let rhs = issue("bd-2", title: "Shared", status: "open", type: "task")
        let order = BeadIssueSortOrder(sort: .status, direction: .descending)

        XCTAssertNotEqual(
            order.areInIncreasingOrder(lhs, rhs),
            order.areInIncreasingOrder(rhs, lhs)
        )
    }

    func testPrioritySortUsesUpdatedDateTieBreaker() {
        let older = issue(
            "bd-1",
            title: "Older",
            status: "open",
            type: "task",
            priority: 1,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = issue(
            "bd-2",
            title: "Newer",
            status: "open",
            type: "task",
            priority: 1,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let lowerPriority = issue(
            "bd-3",
            title: "Lower Priority",
            status: "open",
            type: "task",
            priority: 2,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let order = BeadIssueSortOrder(sort: .priority, direction: .ascending)

        XCTAssertEqual([older, lowerPriority, newer].sorted(by: order.areInIncreasingOrder).map(\.id), ["bd-2", "bd-1", "bd-3"])
    }

    func testCompactIndexSortMatchesFullIssueComparatorForEveryFieldAndDirection() {
        let issues = [
            issue(
                "bd-10", title: "Issue 10", status: "open", type: "task", priority: 2,
                createdAt: Date(timeIntervalSince1970: 30), updatedAt: Date(timeIntervalSince1970: 40)
            ),
            issue(
                "bd-2", title: "Issue 2", status: "closed", type: "bug", priority: 0,
                createdAt: nil, updatedAt: Date(timeIntervalSince1970: 20)
            ),
            issue(
                "bd-1", title: "Álpha", status: "open", type: "epic", priority: 2,
                createdAt: Date(timeIntervalSince1970: 10), updatedAt: nil
            ),
            issue(
                "bd-20", title: "beta", status: "review", type: "task", priority: 3,
                createdAt: Date(timeIntervalSince1970: 20), updatedAt: Date(timeIntervalSince1970: 30)
            )
        ]
        let index = BeadProjectIndex(
            issues: issues,
            dependencies: [],
            semantics: .fallback(issues: issues)
        )

        for sort in IssueSort.allCases {
            for direction in SortDirection.allCases {
                let order = BeadIssueSortOrder(sort: sort, direction: direction)
                let expected = issues.sorted(by: order.areInIncreasingOrder).map(\.id)
                XCTAssertEqual(
                    index.sortedIssueIDs(Array(issues.map(\.id).reversed()), sortOrder: order),
                    expected,
                    "\(sort.rawValue) \(direction.rawValue)"
                )
            }
        }
    }

    private func issue(
        _ id: String,
        title: String,
        status: String,
        type: String,
        priority: Int = 2,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> BeadIssue {
        BeadIssue(
            id: id,
            title: title,
            description: "",
            design: "",
            acceptanceCriteria: "",
            notes: "",
            status: status,
            priority: priority,
            issueType: type,
            assignee: nil,
            owner: nil,
            createdAt: createdAt,
            updatedAt: updatedAt,
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
    }
}
