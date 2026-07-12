import XCTest
@testable import Beadazzle

final class BeadSavedViewQueryEvaluatorTests: XCTestCase {
    func testNestedGroupsCombinePeopleLabelsDatesAndActivity() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let issues = [
            issue("a", title: "Crash fix", owner: "Alice", labels: ["urgent", "ios"], updatedAt: now.addingTimeInterval(-86_400), comments: 3),
            issue("b", title: "Docs", owner: "Alice", labels: ["docs"], updatedAt: now.addingTimeInterval(-20 * 86_400), comments: 0),
            issue("c", title: "Crash report", owner: "Bob", labels: ["urgent", "ios"], updatedAt: now, comments: 5)
        ]
        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: .fallback(issues: issues))
        let owner = condition(.owner, .isAnyOf, strings: ["Alice"])
        let labels = condition(.labels, .containsAll, strings: ["urgent", "ios"])
        var recent = condition(.updated, .inTheLast)
        recent.value.relativeAmount = 7
        recent.value.relativeUnit = .days
        let title = condition(.title, .contains, text: "crash")
        let comments = condition(.comments, .greaterThan, number: 2)
        let nested = BeadFilterGroup(match: .any, children: [.condition(title), .condition(comments)])
        let group = BeadFilterGroup(match: .all, children: [
            .condition(owner), .condition(labels), .condition(recent), .group(nested)
        ])

        let result = BeadSavedViewQueryEvaluator.filteredIssueIDs(
            index: index,
            filter: filter(group),
            now: now
        )

        XCTAssertEqual(result, ["a"])
    }

    func testMissingValuesFlagsHierarchyAndRelationships() {
        let parent = issue("parent", title: "Parent", pinned: true)
        var child = issue("child", title: "Child")
        child.parentID = "parent"
        let dependency = BeadDependency(issueID: "child", dependsOnID: "parent", type: "blocks", createdAt: nil)
        let issues = [parent, child]
        let index = BeadProjectIndex(issues: issues, dependencies: [dependency], semantics: .fallback(issues: issues))
        let group = BeadFilterGroup(match: .all, children: [
            .condition(condition(.owner, .isEmpty)),
            .condition(condition(.parent, .hasNone)),
            .condition(condition(.children, .hasAny)),
            .condition(condition(.pinned, .isTrue)),
            .condition(condition(.dependents, .hasAny))
        ])

        XCTAssertEqual(BeadSavedViewQueryEvaluator.filteredIssueIDs(index: index, filter: filter(group)), ["parent"])
    }

    func testAdvancedPredicateRoundTripsInFinalVersionOnePayload() throws {
        let group = BeadFilterGroup(match: .any, children: [
            .condition(condition(.assignee, .contains, text: "sam")),
            .condition(condition(.due, .isEmpty))
        ])
        let view = BeadSavedView(
            id: UUID(), name: "Advanced", symbolName: "star", query: filter(group),
            ordering: .sorted(BeadSavedViewSort(field: .priority, direction: .ascending))
        )
        let payload = BeadSavedViewsPayload(rootNodes: [.view(view)])

        let decoded = try JSONDecoder().decode(BeadSavedViewsPayload.self, from: JSONEncoder().encode(payload))

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.rootNodes, [.view(view)])
    }

    func testInvalidPredicateFailsClosedInsteadOfBroadeningBaseView() {
        let issues = [issue("a", title: "One"), issue("b", title: "Two")]
        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: .fallback(issues: issues))
        let invalid = BeadFilterCondition(field: .status, operation: .before)
        let invalidGroup = BeadFilterGroup(children: [.condition(invalid)])

        XCTAssertFalse(invalidGroup.isValid)
        XCTAssertEqual(BeadSavedViewQueryEvaluator.filteredIssueIDs(index: index, filter: filter(invalidGroup)), [])
        XCTAssertEqual(BeadSavedViewQueryEvaluator.matchingIssueCount(index: index, filter: filter(invalidGroup)), 0)
    }

    func testRelativeDaysUseCalendarBoundariesConsistently() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 15))!
        let nextDay = calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 0, minute: 1))!
        let updated = calendar.date(from: DateComponents(year: 2026, month: 7, day: 5, hour: 8))!
        let issues = [issue("a", title: "Boundary", updatedAt: updated)]
        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: .fallback(issues: issues))
        var recent = condition(.updated, .inTheLast)
        recent.value.relativeAmount = 7
        recent.value.relativeUnit = .days
        let query = filter(BeadFilterGroup(children: [.condition(recent)]))

        XCTAssertEqual(BeadSavedViewQueryEvaluator.filteredIssueIDs(index: index, filter: query, now: now), ["a"])
        XCTAssertEqual(BeadSavedViewQueryEvaluator.matchingIssueCount(index: index, filter: query, now: now), 1)
        XCTAssertEqual(BeadSavedViewQueryEvaluator.filteredIssueIDs(index: index, filter: query, now: nextDay), [])
        XCTAssertEqual(BeadSavedViewQueryEvaluator.matchingIssueCount(index: index, filter: query, now: nextDay), 0)
    }

    func testCountEvaluationReportsCancellationDuringBaseFiltering() {
        let issues = (0..<100).map { issue("bd-\($0)", title: "Issue \($0)") }
        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: .fallback(issues: issues))
        let query = BeadSavedViewQuery(
            basePreset: .all,
            statusFilters: [], typeFilters: [], priorityFilters: [], labelFilters: [], searchText: "Issue"
        )

        XCTAssertNil(BeadSavedViewQueryEvaluator.matchingIssueCount(
            index: index,
            filter: query,
            shouldCancel: { true }
        ))
    }

    func testCombinedListQueryHonorsCancellationDuringBaseFiltering() {
        let issues = (0..<100).map { issue("bd-\($0)", title: "Issue \($0)") }
        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: .fallback(issues: issues))

        let result = BeadIssueListQuery.filteredIssueIDsAndCounts(
            index: index,
            bookmark: .all,
            statusFilters: [],
            typeFilters: [],
            priorityFilters: [],
            labelFilters: [],
            searchText: "Issue",
            shouldCancel: { true }
        )

        XCTAssertTrue(result.matchingIDs.isEmpty)
        XCTAssertEqual(result.counts, .empty)
    }

    private func filter(_ group: BeadFilterGroup) -> BeadSavedViewQuery {
        BeadSavedViewQuery(
            basePreset: .all,
            statusFilters: [],
            typeFilters: [],
            priorityFilters: [],
            labelFilters: [],
            searchText: "",
            advancedPredicate: group
        )
    }

    private func condition(
        _ field: BeadFilterField,
        _ operation: BeadFilterOperation,
        text: String = "",
        strings: Set<String> = [],
        number: Int = 0
    ) -> BeadFilterCondition {
        BeadFilterCondition(
            field: field,
            operation: operation,
            value: BeadFilterValue(text: text, strings: strings, number: number)
        )
    }

    private func issue(
        _ id: String,
        title: String,
        owner: String? = nil,
        labels: [String] = [],
        updatedAt: Date? = nil,
        comments: Int = 0,
        pinned: Bool = false
    ) -> BeadIssue {
        BeadIssue(
            id: id, title: title, description: "", design: "", acceptanceCriteria: "", notes: "",
            status: "open", priority: 2, issueType: "task", assignee: nil, owner: owner,
            createdAt: nil, updatedAt: updatedAt, closedAt: nil, dueAt: nil, deferUntil: nil,
            externalRef: nil, parentID: nil, labels: labels, dependencyCount: 0, dependentCount: 0,
            commentCount: comments, pinned: pinned, ephemeral: false, isTemplate: false
        )
    }
}
