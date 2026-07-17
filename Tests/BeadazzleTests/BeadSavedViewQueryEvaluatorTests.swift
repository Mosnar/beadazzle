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

    func testBatchedCountsMatchStandaloneEvaluationForEverySupportedFieldAndOperation() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let issues = comprehensiveIssues(now: now)
        let dependencies = [
            BeadDependency(issueID: "target", dependsOnID: "parent", type: "blocks", createdAt: now)
        ]
        let index = BeadProjectIndex(
            issues: issues,
            dependencies: dependencies,
            semantics: .fallback(issues: issues)
        )
        var entries: [(id: UUID, filter: BeadSavedViewQuery)] = []
        var expectedCounts: [UUID: Int] = [:]
        var coveredFields: Set<BeadFilterField> = []
        var coveredOperations: Set<BeadFilterOperation> = []

        for field in BeadFilterField.allCases {
            for operation in field.operations {
                let condition = BeadFilterCondition(
                    field: field,
                    operation: operation,
                    value: comprehensiveValue(for: field, operation: operation, now: now)
                )
                XCTAssertTrue(condition.isValid, "\(field.rawValue).\(operation.rawValue)")
                let query = filter(BeadFilterGroup(children: [.condition(condition)]))
                let id = UUID()
                entries.append((id: id, filter: query))
                expectedCounts[id] = try XCTUnwrap(
                    BeadSavedViewQueryEvaluator.matchingIssueCount(index: index, filter: query, now: now),
                    "\(field.rawValue).\(operation.rawValue)"
                )
                coveredFields.insert(field)
                coveredOperations.insert(operation)
            }
        }

        let counts = try XCTUnwrap(
            BeadSavedViewQueryEvaluator.matchingIssueCounts(index: index, filters: entries, now: now)
        )

        XCTAssertEqual(coveredFields, Set(BeadFilterField.allCases))
        XCTAssertEqual(coveredOperations, Set(BeadFilterOperation.allCases))
        XCTAssertEqual(counts, expectedCounts)
    }

    func testCompiledOperationsMatchIndependentExpectedIssueIDs() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let issues = comprehensiveIssues(now: now)
        let index = BeadProjectIndex(
            issues: issues,
            dependencies: [
                BeadDependency(issueID: "target", dependsOnID: "parent", type: "blocks", createdAt: now)
            ],
            semantics: .fallback(issues: issues)
        )

        var before = condition(.created, .before)
        before.value.date = now.addingTimeInterval(-10 * 86_400)
        var after = condition(.created, .after)
        after.value.date = now.addingTimeInterval(-7 * 86_400)
        var on = condition(.updated, .on)
        on.value.date = now.addingTimeInterval(-86_400)
        var recent = condition(.updated, .inTheLast)
        recent.value.relativeAmount = 7
        recent.value.relativeUnit = .days
        var notRecent = condition(.updated, .notInTheLast)
        notRecent.value.relativeAmount = 7
        notRecent.value.relativeUnit = .days

        let cases: [(name: String, condition: BeadFilterCondition, expectedIDs: Set<String>)] = [
            ("is", condition(.title, .isEqual, text: "resume crash"), ["target"]),
            ("is not", condition(.title, .isNot, text: "resume crash"), ["parent", "empty", "gate"]),
            ("contains", condition(.title, .contains, text: "resume"), ["target"]),
            ("does not contain", condition(.title, .doesNotContain, text: "resume"), ["parent", "empty", "gate"]),
            ("starts with", condition(.title, .startsWith, text: "resume"), ["target"]),
            ("is empty", condition(.externalReference, .isEmpty), ["parent", "empty", "gate"]),
            ("is not empty", condition(.externalReference, .isNotEmpty), ["target"]),
            ("is any of", condition(.owner, .isAnyOf, strings: ["alice"]), ["target"]),
            ("is none of", condition(.owner, .isNoneOf, strings: ["alice"]), ["parent", "empty", "gate"]),
            ("contains any", condition(.labels, .containsAny, strings: ["urgent"]), ["target"]),
            ("contains all", condition(.labels, .containsAll, strings: ["urgent", "ios"]), ["target"]),
            ("contains none", condition(.labels, .containsNone, strings: ["urgent"]), ["parent", "empty", "gate"]),
            ("before", before, ["parent"]),
            ("after", after, ["target", "gate"]),
            ("on", on, ["target"]),
            ("in the last", recent, ["target", "gate"]),
            ("not in the last", notRecent, ["parent"]),
            ("is true", condition(.pinned, .isTrue), ["target"]),
            ("is false", condition(.pinned, .isFalse), ["parent", "empty", "gate"]),
            ("has any", condition(.comments, .hasAny), ["target"]),
            ("has none", condition(.comments, .hasNone), ["parent", "empty", "gate"]),
            ("equals", condition(.priority, .equals, number: 2), ["target"]),
            ("greater than", condition(.priority, .greaterThan, number: 2), ["empty"]),
            ("less than", condition(.priority, .lessThan, number: 2), ["parent", "gate"])
        ]

        XCTAssertEqual(
            Set(cases.map { $0.condition.operation.rawValue }),
            Set(BeadFilterOperation.allCases.map(\.rawValue))
        )
        for testCase in cases {
            let matchingIDs = Set(BeadSavedViewQueryEvaluator.filteredIssueIDs(
                index: index,
                filter: filter(BeadFilterGroup(children: [.condition(testCase.condition)])),
                now: now
            ))
            XCTAssertEqual(matchingIDs, testCase.expectedIDs, testCase.name)
        }
    }

    func testBatchedCountsReuseAnIdenticalCompleteQueryForEveryOutputID() throws {
        let issues = [
            issue("a", title: "One", owner: "Alice"),
            issue("b", title: "Two", owner: "Alice"),
            issue("c", title: "Three", owner: "Bob")
        ]
        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: .fallback(issues: issues))
        let query = filter(BeadFilterGroup(children: [
            .condition(condition(.owner, .isAnyOf, strings: ["alice"]))
        ]))
        let firstID = UUID()
        let secondID = UUID()

        let counts = try XCTUnwrap(BeadSavedViewQueryEvaluator.matchingIssueCounts(
            index: index,
            filters: [(firstID, query), (secondID, query)]
        ))

        XCTAssertEqual(counts, [firstID: 2, secondID: 2])
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

    private func comprehensiveIssues(now: Date) -> [BeadIssue] {
        [
            BeadIssue(
                id: "parent", title: "Parent", description: "", design: "", acceptanceCriteria: "", notes: "",
                status: "open", priority: 1, issueType: "epic", assignee: nil, owner: "Pat",
                createdAt: now.addingTimeInterval(-20 * 86_400), updatedAt: now.addingTimeInterval(-10 * 86_400),
                closedAt: nil, dueAt: nil, deferUntil: nil, externalRef: nil, parentID: nil,
                labels: ["planning"], dependencyCount: 0, dependentCount: 1, commentCount: 0,
                pinned: false, ephemeral: false, isTemplate: false
            ),
            BeadIssue(
                id: "target", title: "Résumé Crash", description: "Needle description", design: "Native",
                acceptanceCriteria: "Instant results", notes: "Profiled", status: "open", priority: 2,
                issueType: "task", assignee: "Sam", owner: "Álice",
                createdAt: now.addingTimeInterval(-6 * 86_400), updatedAt: now.addingTimeInterval(-86_400),
                closedAt: now.addingTimeInterval(-86_400), dueAt: now.addingTimeInterval(86_400),
                deferUntil: now.addingTimeInterval(-30 * 86_400), externalRef: "EXT-42", parentID: "parent",
                labels: ["Urgent", "iOS"], dependencyCount: 1, dependentCount: 0, commentCount: 3,
                pinned: true, ephemeral: false, isTemplate: false
            ),
            BeadIssue(
                id: "empty", title: "", description: "", design: "", acceptanceCriteria: "", notes: "",
                status: "", priority: 4, issueType: "", assignee: nil, owner: nil,
                createdAt: nil, updatedAt: nil, closedAt: nil, dueAt: nil, deferUntil: nil,
                externalRef: nil, parentID: nil, labels: [], dependencyCount: 0, dependentCount: 0,
                commentCount: 0, pinned: false, ephemeral: true, isTemplate: true
            ),
            BeadIssue(
                id: "gate", title: "Decision", description: "", design: "", acceptanceCriteria: "", notes: "",
                status: "open", priority: 0, issueType: "gate", assignee: nil, owner: nil,
                createdAt: now, updatedAt: now, closedAt: nil, dueAt: nil, deferUntil: nil,
                externalRef: nil, parentID: nil, labels: [], dependencyCount: 0, dependentCount: 0,
                commentCount: 0, pinned: false, ephemeral: false, isTemplate: false
            )
        ]
    }

    private func comprehensiveValue(
        for field: BeadFilterField,
        operation: BeadFilterOperation,
        now: Date
    ) -> BeadFilterValue {
        var value = BeadFilterValue()
        switch operation {
        case .isAnyOf, .isNoneOf, .containsAny, .containsAll, .containsNone:
            value.strings = switch field {
            case .status: ["open"]
            case .type: ["task"]
            case .priority: ["2"]
            case .labels: ["urgent", "ios"]
            case .owner: ["alice"]
            case .assignee: ["sam"]
            default: ["value"]
            }
        case .inTheLast, .notInTheLast:
            value.relativeAmount = 7
            value.relativeUnit = .days
        case .before, .after, .on:
            value.date = now.addingTimeInterval(-86_400)
        case .equals, .greaterThan, .lessThan:
            value.number = 1
        default:
            value.text = switch field {
            case .id: "target"
            case .title, .text: "resume"
            case .externalReference: "ext-42"
            case .status: "pen"
            case .type: "ask"
            case .owner: "alice"
            case .assignee: "sam"
            case .parent: "parent"
            default: "value"
            }
        }
        return value
    }
}
