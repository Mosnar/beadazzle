import XCTest
@testable import Beadazzle

final class BeadProjectIndexTests: XCTestCase {
    func testBookmarkOrderPrioritizesReadyAndMovesAllBeadsLast() {
        XCTAssertEqual(BeadBookmark.allCases.first, .ready)
        XCTAssertEqual(BeadBookmark.allCases.last, .all)
        XCTAssertEqual(BeadBookmark.allCases.map(\.title), [
            "Ready",
            "Stale",
            "Open",
            "In Progress",
            "Blocked",
            "Closed",
            "All Beads"
        ])
    }

    func testPresetBookmarksUseProjectStatusCategories() {
        let semantics = BeadProjectSemantics(
            statuses: [
                BeadStatusDefinition(name: "todo", category: .active, icon: nil, description: nil),
                BeadStatusDefinition(name: "review", category: .wip, icon: nil, description: nil),
                BeadStatusDefinition(name: "blocked", category: .wip, icon: nil, description: nil, isBuiltIn: true),
                BeadStatusDefinition(name: "shipped", category: .done, icon: nil, description: nil),
                BeadStatusDefinition(name: "later", category: .frozen, icon: nil, description: nil)
            ],
            types: [
                BeadTypeDefinition(name: "story", description: nil),
                BeadTypeDefinition(name: "bug", description: nil)
            ]
        )
        let issues = [
            issue("bd-1", status: "todo", type: "story"),
            issue("bd-2", status: "review", type: "story"),
            issue("bd-3", status: "blocked", type: "bug"),
            issue("bd-4", status: "shipped", type: "bug", closedAt: Date()),
            issue("bd-5", status: "later", type: "bug")
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics)

        XCTAssertEqual(index.count(for: .all), 5)
        XCTAssertEqual(index.count(for: .ready), 1)
        XCTAssertEqual(index.count(for: .open), 1)
        XCTAssertEqual(index.count(for: .inProgress), 1)
        XCTAssertEqual(index.count(for: .closed), 1)
        XCTAssertEqual(index.count(for: .blocked), 1)
        XCTAssertEqual(index.semantics.category(forStatus: "todo"), .active)
        XCTAssertEqual(index.semantics.category(forStatus: "review"), .wip)
        XCTAssertEqual(index.semantics.category(forStatus: "shipped"), .done)
        XCTAssertEqual(index.semantics.category(forStatus: "later"), .frozen)
    }

    func testBlockedBookmarkDoesNotIncludeEveryFrozenStatus() {
        let semantics = BeadProjectSemantics(
            statuses: [
                BeadStatusDefinition(name: "blocked", category: .wip, icon: nil, description: nil, isBuiltIn: true),
                BeadStatusDefinition(name: "deferred", category: .frozen, icon: nil, description: nil, isBuiltIn: true),
                BeadStatusDefinition(name: "parked", category: .frozen, icon: nil, description: nil)
            ],
            types: [BeadTypeDefinition(name: "task", description: nil)]
        )
        let issues = [
            issue("bd-1", status: "blocked", type: "task"),
            issue("bd-2", status: "deferred", type: "task"),
            issue("bd-3", status: "parked", type: "task")
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics)

        XCTAssertEqual(index.issueIDs(for: .blocked), ["bd-1"])
    }

    func testProjectWideLabelNamesAreSortedIndependentOfFilters() {
        let issues = [
            issue("bd-1", status: "open", type: "task", labels: ["source:user-report", "area:ui"]),
            issue("bd-2", status: "closed", type: "task", labels: ["area:api"]),
            issue("bd-3", status: "open", type: "task", labels: ["area:ui"])
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics())

        XCTAssertEqual(index.labelNames, ["area:api", "area:ui", "source:user-report"])
    }

    func testStaleBookmarkIncludesCliDefaultAndCustomNonDoneIssuesOlderThanTwoWeeks() {
        let old = Date().addingTimeInterval(-15 * 24 * 60 * 60)
        let recent = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let issues = [
            issue("bd-open-stale", status: "open", type: "task", updatedAt: old),
            issue("bd-review-stale", status: "review", type: "task", updatedAt: old),
            issue("bd-blocked-stale", status: "blocked", type: "task", updatedAt: old),
            issue("bd-deferred-stale", status: "deferred", type: "task", updatedAt: old),
            issue("bd-pinned-stale", status: "pinned", type: "task", updatedAt: old),
            issue("bd-hooked-stale", status: "hooked", type: "task", updatedAt: old),
            issue("bd-created-fallback", status: "open", type: "task", createdAt: old),
            issue("bd-recent", status: "open", type: "task", updatedAt: recent),
            issue("bd-closed", status: "closed", type: "task", updatedAt: old, closedAt: old),
            issue("bd-no-activity", status: "open", type: "task")
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: staleSemantics())

        XCTAssertEqual(index.issueIDs(for: BeadBookmark.stale), [
            "bd-open-stale",
            "bd-review-stale",
            "bd-blocked-stale",
            "bd-deferred-stale",
            "bd-created-fallback"
        ])
    }

    func testStaleBookmarkUsesConfiguredCutoffAtSevenFourteenAndThirtyDays() {
        let secondsPerDay: TimeInterval = 24 * 60 * 60

        func staleIDs(cutoffDays: Int) -> Set<String> {
            let olderThanCutoff = Date().addingTimeInterval(-(TimeInterval(cutoffDays) * secondsPerDay + 3_600))
            let newerThanCutoff = Date().addingTimeInterval(-(TimeInterval(cutoffDays) * secondsPerDay - 3_600))
            let issues = [
                issue("bd-stale-\(cutoffDays)", status: "open", type: "task", updatedAt: olderThanCutoff),
                issue("bd-fresh-\(cutoffDays)", status: "open", type: "task", updatedAt: newerThanCutoff)
            ]
            let index = BeadProjectIndex(
                issues: issues,
                dependencies: [],
                semantics: staleSemantics(),
                staleCutoffDays: cutoffDays
            )
            return index.issueIDs(for: .stale)
        }

        XCTAssertEqual(staleIDs(cutoffDays: 7), ["bd-stale-7"])
        XCTAssertEqual(staleIDs(cutoffDays: 14), ["bd-stale-14"])
        XCTAssertEqual(staleIDs(cutoffDays: 30), ["bd-stale-30"])
    }

    func testReadyBookmarkIncludesOpenIssuesWithoutActiveBlockers() {
        let now = Date()
        let issues = [
            issue("bd-ready", status: "open", type: "task"),
            issue("bd-blocked", status: "open", type: "task"),
            issue("bd-blocker", status: "open", type: "task"),
            issue("bd-done-blocked", status: "open", type: "task"),
            issue("bd-done-blocker", status: "closed", type: "task", closedAt: now),
            issue("bd-deferred", status: "open", type: "task", deferUntil: now.addingTimeInterval(3_600)),
            issue("bd-parent", status: "open", type: "epic"),
            issue("bd-child", status: "open", type: "task", parentID: "bd-parent"),
            issue("bd-related", status: "open", type: "task"),
            issue("bd-relates-to", status: "open", type: "task"),
            issue("bd-missing-blocked", status: "open", type: "task"),
            issue("bd-external-blocked", status: "open", type: "task"),
            issue("bd-review", status: "review", type: "task")
        ]
        let dependencies = [
            BeadDependency(issueID: "bd-blocked", dependsOnID: "bd-blocker", type: "blocks", createdAt: nil),
            BeadDependency(issueID: "bd-done-blocked", dependsOnID: "bd-done-blocker", type: "blocks", createdAt: nil),
            BeadDependency(issueID: "bd-child", dependsOnID: "bd-parent", type: "parent-child", createdAt: nil),
            BeadDependency(issueID: "bd-related", dependsOnID: "bd-blocker", type: "related", createdAt: nil),
            BeadDependency(issueID: "bd-relates-to", dependsOnID: "bd-blocker", type: "relates-to", createdAt: nil),
            BeadDependency(issueID: "bd-missing-blocked", dependsOnID: "bd-missing", type: "blocks", createdAt: nil),
            BeadDependency(issueID: "bd-external-blocked", dependsOnID: "external:project:capability", type: "blocks", createdAt: nil)
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: dependencies, semantics: semanticsWithReview())

        XCTAssertEqual(index.issueIDs(for: .ready), [
            "bd-ready",
            "bd-blocker",
            "bd-done-blocked",
            "bd-parent",
            "bd-child",
            "bd-related",
            "bd-relates-to"
        ])
    }

    func testStatusAndTypeFiltersIntersectWithinAllIssues() {
        let semantics = BeadProjectSemantics(
            statuses: [
                BeadStatusDefinition(name: "todo", category: .active, icon: nil, description: nil),
                BeadStatusDefinition(name: "review", category: .wip, icon: nil, description: nil)
            ],
            types: [
                BeadTypeDefinition(name: "story", description: nil),
                BeadTypeDefinition(name: "bug", description: nil)
            ]
        )
        let issues = [
            issue("bd-1", title: "Index navigation", status: "todo", type: "story", labels: ["ui"]),
            issue("bd-2", title: "Parser bug", status: "todo", type: "bug", labels: ["backend"]),
            issue("bd-3", title: "Review polish", status: "review", type: "story", labels: ["ui"])
        ]
        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics)

        let ids = index.filteredIssueIDs(
            within: index.issueIDs(for: .all),
            statusFilters: ["todo"],
            typeFilters: ["story"],
            priorityFilters: [],
            labelFilters: ["ui"],
            searchText: "navigation"
        )

        XCTAssertEqual(ids, ["bd-1"])
    }

    func testSearchIncludesDesignAcceptanceAndMetadataFields() {
        let issues = [
            issue(
                "BD-UX-1",
                title: "Inspector polish",
                status: "open",
                type: "task",
                design: "Workflow diagram for the compact inspector",
                acceptanceCriteria: "Keyboard first editing works",
                notes: "Preserve native sidebar behavior",
                assignee: "Riley",
                owner: "Morgan",
                externalRef: "EXT-42"
            ),
            issue("bd-other", title: "Unrelated", status: "open", type: "task")
        ]
        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics())
        let allIDs = index.issueIDs(for: .all)

        XCTAssertEqual(searchIDs(index, allIDs: allIDs, query: "workflow diagram"), ["BD-UX-1"])
        XCTAssertEqual(searchIDs(index, allIDs: allIDs, query: "keyboard first"), ["BD-UX-1"])
        XCTAssertEqual(searchIDs(index, allIDs: allIDs, query: "morgan"), ["BD-UX-1"])
        XCTAssertEqual(searchIDs(index, allIDs: allIDs, query: "ext-42"), ["BD-UX-1"])
        XCTAssertEqual(searchIDs(index, allIDs: allIDs, query: "bd-ux"), ["BD-UX-1"])
    }

    func testSearchIsCaseAndDiacriticInsensitive() {
        let issues = [
            issue(
                "BD-1",
                title: "Café résumé workflow",
                status: "open",
                type: "task"
            ),
            issue("BD-2", title: "Unrelated", status: "open", type: "task")
        ]
        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics())
        let allIDs = index.issueIDs(for: .all)

        // Plain ASCII, lowercased query still matches accented text (diacritic-insensitive),
        // matching the prior localizedStandardContains behavior.
        XCTAssertEqual(searchIDs(index, allIDs: allIDs, query: "cafe resume"), ["BD-1"])
        XCTAssertEqual(searchIDs(index, allIDs: allIDs, query: "CAFÉ"), ["BD-1"])
    }

    func testLargeDatasetIndexKeepsCountsCorrect() {
        let semantics = BeadProjectSemantics(
            statuses: [
                BeadStatusDefinition(name: "todo", category: .active, icon: nil, description: nil),
                BeadStatusDefinition(name: "doing", category: .wip, icon: nil, description: nil),
                BeadStatusDefinition(name: "done", category: .done, icon: nil, description: nil)
            ],
            types: [
                BeadTypeDefinition(name: "task", description: nil),
                BeadTypeDefinition(name: "bug", description: nil)
            ]
        )
        let issues = (0..<10_000).map { offset in
            issue(
                "bd-\(offset)",
                title: offset.isMultiple(of: 2) ? "Crawler task \(offset)" : "Portal issue \(offset)",
                status: offset.isMultiple(of: 5) ? "done" : (offset.isMultiple(of: 3) ? "doing" : "todo"),
                type: offset.isMultiple(of: 7) ? "bug" : "task",
                labels: [offset.isMultiple(of: 2) ? "crawler" : "portal"]
            )
        }

        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics)
        let crawlerIDs = index.filteredIssueIDs(
            within: index.issueIDs(for: .all),
            statusFilters: ["todo"],
            typeFilters: [],
            priorityFilters: [],
            labelFilters: ["crawler"],
            searchText: "task"
        )

        XCTAssertEqual(index.count(for: .all), 10_000)
        XCTAssertFalse(crawlerIDs.isEmpty)
        XCTAssertTrue(crawlerIDs.allSatisfy { id in
            guard let issue = index.issue(with: id) else { return false }
            return issue.status == "todo" && issue.labels.contains("crawler") && issue.title.contains("task")
        })
    }

    func testOutlineRowsHideChildrenUntilExpanded() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", status: "open", type: "epic"),
                issue("bd-child", status: "open", type: "task", parentID: "bd-parent"),
                issue("bd-root", status: "open", type: "task")
            ],
            dependencies: [],
            semantics: semantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let collapsed = index.issueListRows(
            for: ["bd-parent", "bd-child", "bd-root"],
            mode: .outline,
            expandedIssueIDs: [],
            sortOrder: sortOrder
        )
        let expanded = index.issueListRows(
            for: ["bd-parent", "bd-child", "bd-root"],
            mode: .outline,
            expandedIssueIDs: ["bd-parent"],
            sortOrder: sortOrder
        )

        XCTAssertEqual(collapsed.map(\.issueID), ["bd-parent", "bd-root"])
        XCTAssertEqual(expanded.map(\.issueID), ["bd-parent", "bd-child", "bd-root"])
        XCTAssertEqual(expanded.first { $0.issueID == "bd-child" }?.depth, 1)
    }

    func testParentChildDependencyBuildsOutlineHierarchy() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-child", title: "Child", status: "open", type: "task")
            ],
            dependencies: [
                BeadDependency(issueID: "bd-child", dependsOnID: "bd-parent", type: "parent-child", createdAt: nil)
            ],
            semantics: semantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let rows = index.issueListRows(
            for: ["bd-parent", "bd-child"],
            mode: .outline,
            expandedIssueIDs: ["bd-parent"],
            sortOrder: sortOrder
        )

        XCTAssertEqual(index.parentID(for: "bd-child"), "bd-parent")
        XCTAssertEqual(rows.map(\.issueID), ["bd-parent", "bd-child"])
        XCTAssertEqual(
            rows.first { $0.issueID == "bd-parent" }?.childProgress,
            IssueChildProgress(completedCount: 0, workedCount: 0, totalCount: 1)
        )
        XCTAssertEqual(rows.first { $0.issueID == "bd-child" }?.depth, 1)
    }

    func testIssueListRowsIncludeImmediateChildProgressInFlatAndOutlineModes() {
        let now = Date()
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-open", title: "Open", status: "open", type: "task", parentID: "bd-parent"),
                issue("bd-review", title: "Review", status: "review", type: "task", parentID: "bd-parent"),
                issue("bd-closed", title: "Closed", status: "closed", type: "task", closedAt: now, parentID: "bd-parent"),
                issue("bd-external", title: "External", status: "external", type: "task", closedAt: now, parentID: "bd-parent")
            ],
            dependencies: [],
            semantics: semanticsWithReview()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)
        let expected = IssueChildProgress(completedCount: 2, workedCount: 3, totalCount: 4)

        let outlineRows = index.issueListRows(
            for: ["bd-parent", "bd-open", "bd-review", "bd-closed", "bd-external"],
            mode: .outline,
            expandedIssueIDs: ["bd-parent"],
            sortOrder: sortOrder
        )
        let flatRows = index.issueListRows(
            for: ["bd-parent", "bd-open", "bd-review", "bd-closed", "bd-external"],
            mode: .flat,
            expandedIssueIDs: [],
            sortOrder: sortOrder
        )

        XCTAssertEqual(outlineRows.first { $0.issueID == "bd-parent" }?.childProgress, expected)
        XCTAssertEqual(flatRows.first { $0.issueID == "bd-parent" }?.childProgress, expected)
        XCTAssertNil(outlineRows.first { $0.issueID == "bd-open" }?.childProgress)
    }

    func testIssueListRowsMarkParentAsNotWorkedWhenNoChildrenAreWipOrDone() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-open", title: "Open", status: "open", type: "task", parentID: "bd-parent"),
                issue("bd-deferred", title: "Deferred", status: "deferred", type: "task", parentID: "bd-parent"),
                issue("bd-custom", title: "Custom", status: "custom", type: "task", parentID: "bd-parent")
            ],
            dependencies: [],
            semantics: staleSemantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let rows = index.issueListRows(
            for: ["bd-parent", "bd-open", "bd-deferred", "bd-custom"],
            mode: .outline,
            expandedIssueIDs: [],
            sortOrder: sortOrder
        )

        XCTAssertEqual(
            rows.first { $0.issueID == "bd-parent" }?.childProgress,
            IssueChildProgress(completedCount: 0, workedCount: 0, totalCount: 3)
        )
    }

    func testIssueListRowsDoNotRollGrandchildrenIntoParentChildProgress() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-child", title: "Child", status: "review", type: "task", parentID: "bd-parent"),
                issue("bd-grandchild", title: "Grandchild", status: "closed", type: "task", closedAt: Date(), parentID: "bd-child")
            ],
            dependencies: [],
            semantics: semanticsWithReview()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let rows = index.issueListRows(
            for: ["bd-parent", "bd-child", "bd-grandchild"],
            mode: .outline,
            expandedIssueIDs: ["bd-parent", "bd-child"],
            sortOrder: sortOrder
        )

        XCTAssertEqual(
            rows.first { $0.issueID == "bd-parent" }?.childProgress,
            IssueChildProgress(completedCount: 0, workedCount: 1, totalCount: 1)
        )
        XCTAssertEqual(
            rows.first { $0.issueID == "bd-child" }?.childProgress,
            IssueChildProgress(completedCount: 1, workedCount: 1, totalCount: 1)
        )
    }

    func testFilteredChildStaysUnderAncestorContext() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-child", title: "Needle", status: "open", type: "task", parentID: "bd-parent")
            ],
            dependencies: [],
            semantics: semantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let rows = index.issueListRows(
            for: ["bd-child"],
            mode: .outline,
            expandedIssueIDs: [],
            sortOrder: sortOrder
        )

        XCTAssertEqual(rows.map(\.issueID), ["bd-parent", "bd-child"])
        XCTAssertEqual(rows.map(\.depth), [0, 1])
        XCTAssertEqual(rows.first?.isExpanded, true)
        XCTAssertEqual(rows.map(\.isContext), [true, false])
    }

    func testCollapsedContextParentHidesMatchingDescendants() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-child", title: "Needle", status: "open", type: "task", parentID: "bd-parent")
            ],
            dependencies: [],
            semantics: semantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let rows = index.issueListRows(
            for: ["bd-child"],
            mode: .outline,
            expandedIssueIDs: [],
            collapsedIssueIDs: ["bd-parent"],
            sortOrder: sortOrder
        )

        XCTAssertEqual(rows.map(\.issueID), ["bd-parent"])
        XCTAssertEqual(rows.first?.hasChildren, true)
        XCTAssertEqual(rows.first?.isExpanded, false)
        XCTAssertEqual(rows.first?.isContext, true)
    }

    func testCollapsedIntermediateContextHidesMatchingGrandchildren() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-child", title: "Child", status: "open", type: "task", parentID: "bd-parent"),
                issue("bd-grandchild", title: "Needle", status: "open", type: "task", parentID: "bd-child")
            ],
            dependencies: [],
            semantics: semantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let rows = index.issueListRows(
            for: ["bd-grandchild"],
            mode: .outline,
            expandedIssueIDs: [],
            collapsedIssueIDs: ["bd-child"],
            sortOrder: sortOrder
        )

        XCTAssertEqual(rows.map(\.issueID), ["bd-parent", "bd-child"])
        XCTAssertEqual(rows.map(\.depth), [0, 1])
        XCTAssertEqual(rows.map(\.isContext), [true, true])
        XCTAssertEqual(rows.map(\.isExpanded), [true, false])
    }

    func testExpandedFilteredParentShowsChildrenAsOutlineContext() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-child", title: "Child", status: "open", type: "task", parentID: "bd-parent"),
                issue("bd-other", title: "Other", status: "open", type: "epic")
            ],
            dependencies: [],
            semantics: semantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let collapsed = index.issueListRows(
            for: ["bd-parent", "bd-other"],
            mode: .outline,
            expandedIssueIDs: [],
            sortOrder: sortOrder
        )
        let expanded = index.issueListRows(
            for: ["bd-parent", "bd-other"],
            mode: .outline,
            expandedIssueIDs: ["bd-parent"],
            sortOrder: sortOrder
        )

        XCTAssertEqual(collapsed.map(\.issueID), ["bd-other", "bd-parent"])
        XCTAssertEqual(expanded.map(\.issueID), ["bd-other", "bd-parent", "bd-child"])
        XCTAssertEqual(expanded.first { $0.issueID == "bd-child" }?.depth, 1)
        XCTAssertEqual(expanded.map(\.isContext), [false, false, true])
    }

    func testExpandedFilteredContextChildShowsGrandchildren() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-child", title: "Child", status: "open", type: "task", parentID: "bd-parent"),
                issue("bd-grandchild", title: "Grandchild", status: "open", type: "task", parentID: "bd-child")
            ],
            dependencies: [],
            semantics: semantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let rows = index.issueListRows(
            for: ["bd-parent"],
            mode: .outline,
            expandedIssueIDs: ["bd-parent", "bd-child"],
            sortOrder: sortOrder
        )

        XCTAssertEqual(rows.map(\.issueID), ["bd-parent", "bd-child", "bd-grandchild"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
        XCTAssertEqual(rows.map(\.isContext), [false, true, true])
        XCTAssertEqual(rows.first { $0.issueID == "bd-child" }?.isExpanded, true)
    }

    func testSiblingDependencyOrderingPutsBlockersBeforeBlockedChildren() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-blocked", title: "Alpha", status: "open", type: "task", parentID: "bd-parent"),
                issue("bd-blocker", title: "Zulu", status: "open", type: "task", parentID: "bd-parent")
            ],
            dependencies: [
                BeadDependency(issueID: "bd-blocked", dependsOnID: "bd-blocker", type: "blocks", createdAt: nil)
            ],
            semantics: semantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let rows = index.issueListRows(
            for: ["bd-parent", "bd-blocked", "bd-blocker"],
            mode: .outline,
            expandedIssueIDs: ["bd-parent"],
            sortOrder: sortOrder
        )

        XCTAssertEqual(rows.map(\.issueID), ["bd-parent", "bd-blocker", "bd-blocked"])
    }

    func testParentCycleFallsBackToDeterministicRootRows() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-a", title: "A", status: "open", type: "task", parentID: "bd-b"),
                issue("bd-b", title: "B", status: "open", type: "task", parentID: "bd-a"),
                issue("bd-c", title: "C", status: "open", type: "task", parentID: "bd-missing")
            ],
            dependencies: [],
            semantics: semantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let rows = index.issueListRows(
            for: ["bd-a", "bd-b", "bd-c"],
            mode: .outline,
            expandedIssueIDs: ["bd-a", "bd-b"],
            sortOrder: sortOrder
        )

        XCTAssertEqual(rows.map(\.issueID), ["bd-a", "bd-b", "bd-c"])
        XCTAssertTrue(rows.allSatisfy { $0.depth == 0 })
    }

    func testLargeOutlineDatasetBuildsDeterministicVisibleRows() {
        let issues = (0..<5_000).map { offset in
            issue(
                "bd-\(offset)",
                title: String(format: "Issue %04d", offset),
                status: "open",
                type: offset.isMultiple(of: 50) ? "epic" : "task",
                parentID: offset.isMultiple(of: 50) ? nil : "bd-\((offset / 50) * 50)"
            )
        }
        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics())
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)
        let expandedIDs = Set(stride(from: 0, to: 5_000, by: 50).map { "bd-\($0)" })

        let rows = index.issueListRows(
            for: issues.map(\.id),
            mode: .outline,
            expandedIssueIDs: expandedIDs,
            sortOrder: sortOrder
        )

        XCTAssertEqual(rows.count, 5_000)
        XCTAssertEqual(rows.first?.issueID, "bd-0")
        XCTAssertEqual(rows.first { $0.issueID == "bd-1" }?.depth, 1)
        XCTAssertEqual(rows.first { $0.issueID == "bd-50" }?.depth, 0)
    }

    func testDeepOutlineAncestorContextBuildsDeterministicRows() {
        let issueCount = 2_000
        let issues = (0..<issueCount).map { offset in
            issue(
                "bd-\(offset)",
                title: String(format: "Issue %04d", offset),
                status: "open",
                type: offset == 0 ? "epic" : "task",
                parentID: offset == 0 ? nil : "bd-\(offset - 1)"
            )
        }
        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics())
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let rows = index.issueListRows(
            for: ["bd-\(issueCount - 1)"],
            mode: .outline,
            expandedIssueIDs: [],
            sortOrder: sortOrder
        )

        XCTAssertEqual(rows.count, issueCount)
        XCTAssertEqual(rows.first?.issueID, "bd-0")
        XCTAssertEqual(rows.last?.issueID, "bd-\(issueCount - 1)")
        XCTAssertEqual(rows.last?.depth, issueCount - 1)
        XCTAssertTrue(rows.dropLast().allSatisfy(\.isContext))
        XCTAssertEqual(rows.last?.isContext, false)
    }

    private func issue(
        _ id: String,
        title: String = "Example",
        status: String,
        type: String,
        labels: [String] = [],
        description: String = "",
        design: String = "",
        acceptanceCriteria: String = "",
        notes: String = "",
        assignee: String? = nil,
        owner: String? = nil,
        externalRef: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        closedAt: Date? = nil,
        deferUntil: Date? = nil,
        parentID: String? = nil
    ) -> BeadIssue {
        BeadIssue(
            id: id,
            title: title,
            description: description,
            design: design,
            acceptanceCriteria: acceptanceCriteria,
            notes: notes,
            status: status,
            priority: 2,
            issueType: type,
            assignee: assignee,
            owner: owner,
            createdAt: createdAt,
            updatedAt: updatedAt,
            closedAt: closedAt,
            dueAt: nil,
            deferUntil: deferUntil,
            externalRef: externalRef,
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

    private func searchIDs(_ index: BeadProjectIndex, allIDs: Set<String>, query: String) -> [String] {
        index.filteredIssueIDs(
            within: allIDs,
            statusFilters: [],
            typeFilters: [],
            priorityFilters: [],
            labelFilters: [],
            searchText: query
        )
    }

    private func semantics() -> BeadProjectSemantics {
        BeadProjectSemantics(
            statuses: [
                BeadStatusDefinition(name: "open", category: .active, icon: nil, description: nil),
                BeadStatusDefinition(name: "closed", category: .done, icon: nil, description: nil)
            ],
            types: [
                BeadTypeDefinition(name: "epic", description: nil),
                BeadTypeDefinition(name: "task", description: nil)
            ]
        )
    }

    private func staleSemantics() -> BeadProjectSemantics {
        BeadProjectSemantics(
            statuses: [
                BeadStatusDefinition(name: "open", category: .active, icon: nil, description: nil, isBuiltIn: true),
                BeadStatusDefinition(name: "review", category: .wip, icon: nil, description: nil),
                BeadStatusDefinition(name: "blocked", category: .wip, icon: nil, description: nil, isBuiltIn: true),
                BeadStatusDefinition(name: "deferred", category: .frozen, icon: nil, description: nil, isBuiltIn: true),
                BeadStatusDefinition(name: "pinned", category: .frozen, icon: nil, description: nil, isBuiltIn: true),
                BeadStatusDefinition(name: "hooked", category: .wip, icon: nil, description: nil, isBuiltIn: true),
                BeadStatusDefinition(name: "closed", category: .done, icon: nil, description: nil, isBuiltIn: true)
            ],
            types: [
                BeadTypeDefinition(name: "task", description: nil)
            ]
        )
    }

    private func semanticsWithReview() -> BeadProjectSemantics {
        BeadProjectSemantics(
            statuses: [
                BeadStatusDefinition(name: "open", category: .active, icon: nil, description: nil),
                BeadStatusDefinition(name: "review", category: .wip, icon: nil, description: nil),
                BeadStatusDefinition(name: "closed", category: .done, icon: nil, description: nil)
            ],
            types: [
                BeadTypeDefinition(name: "epic", description: nil),
                BeadTypeDefinition(name: "task", description: nil)
            ]
        )
    }
}
