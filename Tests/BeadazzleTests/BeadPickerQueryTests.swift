import XCTest
@testable import Beadazzle

final class BeadPickerQueryTests: XCTestCase {
    func testParentPickerExcludesCurrentDescendantsDoneAndGates() {
        let target = issue("bd-target", title: "Target")
        let index = BeadProjectIndex(
            issues: [
                target,
                issue("bd-child", title: "Child", parentID: "bd-target"),
                issue("bd-grandchild", title: "Grandchild", parentID: "bd-child"),
                issue("bd-parent", title: "Parent"),
                issue("bd-done", title: "Done", status: "closed", closedAt: Date()),
                issue("bd-gate", title: "Gate", type: "gate")
            ],
            dependencies: [],
            semantics: semantics()
        )

        let ids = Set(BeadPickerQuery.candidateIssueIDs(
            index: index,
            configuration: .parent(issue: target),
            filters: BeadPickerFilters(),
            searchText: ""
        ))

        XCTAssertTrue(ids.contains("bd-parent"))
        XCTAssertFalse(ids.contains("bd-target"))
        XCTAssertFalse(ids.contains("bd-child"))
        XCTAssertFalse(ids.contains("bd-grandchild"))
        XCTAssertFalse(ids.contains("bd-done"))
        XCTAssertFalse(ids.contains("bd-gate"))
    }

    func testBlockedByPickerExcludesExistingBlockers() {
        let target = issue("bd-target", title: "Target")
        let index = BeadProjectIndex(
            issues: [
                target,
                issue("bd-blocker", title: "Blocker"),
                issue("bd-fresh", title: "Fresh")
            ],
            dependencies: [
                BeadDependency(issueID: "bd-target", dependsOnID: "bd-blocker", type: "blocks", createdAt: nil)
            ],
            semantics: semantics()
        )

        let ids = Set(BeadPickerQuery.candidateIssueIDs(
            index: index,
            configuration: .blockedBy(issue: target),
            filters: BeadPickerFilters(),
            searchText: ""
        ))

        XCTAssertTrue(ids.contains("bd-fresh"))
        XCTAssertFalse(ids.contains("bd-target"))
        XCTAssertFalse(ids.contains("bd-blocker"))
    }

    func testOutlinePickerIncludesAncestorContextForSearchMatch() {
        let parent = issue("bd-parent", title: "Parent")
        let index = BeadProjectIndex(
            issues: [
                parent,
                issue("bd-child", title: "Needle child", parentID: "bd-parent")
            ],
            dependencies: [],
            semantics: semantics()
        )
        let configuration = BeadPickerConfiguration.blockedBy(issue: parent)
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let outline = BeadPickerQuery.rows(
            index: index,
            configuration: configuration,
            filters: BeadPickerFilters(),
            searchText: "Needle",
            mode: .outline,
            outlineState: BeadOutlineSelectionState(),
            sortOrder: sortOrder
        )
        let flat = BeadPickerQuery.rows(
            index: index,
            configuration: configuration,
            filters: BeadPickerFilters(),
            searchText: "Needle",
            mode: .flat,
            outlineState: BeadOutlineSelectionState(),
            sortOrder: sortOrder
        )

        XCTAssertEqual(outline.rows.map(\.issue.id), ["bd-parent", "bd-child"])
        XCTAssertEqual(outline.rows.map(\.isSelectable), [false, true])
        XCTAssertEqual(flat.rows.map(\.issue.id), ["bd-child"])
        XCTAssertEqual(flat.rows.map(\.isSelectable), [true])
    }

    func testPickerFiltersApplyBeforeRowsAreBuilt() {
        let target = issue("bd-target", title: "Target")
        let index = BeadProjectIndex(
            issues: [
                target,
                issue("bd-match", title: "Portal fix", status: "blocked", priority: 1, type: "bug", labels: ["ui"]),
                issue("bd-wrong-label", title: "Portal fix", status: "blocked", priority: 1, type: "bug", labels: ["api"]),
                issue("bd-wrong-type", title: "Portal fix", status: "blocked", priority: 1, type: "task", labels: ["ui"]),
                issue("bd-wrong-search", title: "Crawler fix", status: "blocked", priority: 1, type: "bug", labels: ["ui"])
            ],
            dependencies: [],
            semantics: semantics()
        )
        var filters = BeadPickerFilters()
        filters.statusFilters = ["blocked"]
        filters.typeFilters = ["bug"]
        filters.priorityFilters = [1]
        filters.labelFilters = ["ui"]

        let result = BeadPickerQuery.rows(
            index: index,
            configuration: .blockedBy(issue: target),
            filters: filters,
            searchText: "portal",
            mode: .flat,
            outlineState: BeadOutlineSelectionState(),
            sortOrder: BeadIssueSortOrder(sort: .title, direction: .ascending)
        )

        XCTAssertEqual(result.rows.map(\.issue.id), ["bd-match"])
    }

    func testPickerQueryStopsWhenCancelled() {
        let target = issue("bd-target", title: "Target")
        let index = BeadProjectIndex(
            issues: [
                target,
                issue("bd-one", title: "One"),
                issue("bd-two", title: "Two")
            ],
            dependencies: [],
            semantics: semantics()
        )

        let result = BeadPickerQuery.rows(
            index: index,
            configuration: .blockedBy(issue: target),
            filters: BeadPickerFilters(),
            searchText: "o",
            mode: .flat,
            outlineState: BeadOutlineSelectionState(),
            sortOrder: BeadIssueSortOrder(sort: .title, direction: .ascending),
            shouldCancel: { true }
        )

        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertTrue(result.matchingIssueIDs.isEmpty)
    }

    private func semantics() -> BeadProjectSemantics {
        BeadProjectSemantics(
            statuses: [
                BeadStatusDefinition(name: "open", category: .active, icon: nil, description: nil),
                BeadStatusDefinition(name: "blocked", category: .wip, icon: nil, description: nil),
                BeadStatusDefinition(name: "closed", category: .done, icon: nil, description: nil)
            ],
            types: [
                BeadTypeDefinition(name: "task", description: nil),
                BeadTypeDefinition(name: "bug", description: nil),
                BeadTypeDefinition(name: "epic", description: nil),
                BeadTypeDefinition(name: "gate", description: nil)
            ]
        )
    }

    private func issue(
        _ id: String,
        title: String,
        status: String = "open",
        priority: Int = 2,
        type: String = "task",
        closedAt: Date? = nil,
        parentID: String? = nil,
        labels: [String] = []
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
            createdAt: nil,
            updatedAt: nil,
            closedAt: closedAt,
            dueAt: nil,
            deferUntil: nil,
            externalRef: nil,
            parentID: parentID,
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
