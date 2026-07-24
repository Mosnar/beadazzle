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
            "Gates",
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

    func testStateCatalogRequiresRecordedEventProvenance() {
        let issues = [
            issue(
                "bd-1",
                status: "open",
                type: "task",
                labels: ["area:ui", "phase:implementation"]
            ),
            issue(
                "bd-state-event",
                title: "State change: phase → design",
                status: "closed",
                type: "event",
                parentID: "bd-1"
            ),
            issue(
                "bd-orphan-state-event",
                title: "State change: orphan → ignored",
                status: "closed",
                type: "event"
            )
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics())

        XCTAssertEqual(index.stateDimensionNames, ["phase"])
        XCTAssertEqual(index.stateValuesByDimension["phase"], ["design", "implementation"])
        XCTAssertNil(index.stateValuesByDimension["area"])
        XCTAssertNil(index.stateValuesByDimension["orphan"])
        XCTAssertEqual(index.count(forLabel: "phase:implementation"), 1)
        XCTAssertEqual(index.count(forLabel: "phase:design"), 0)
    }

    func testStateClearEventPreservesDimensionWithoutAddingNoneValue() {
        let issues = [
            issue("bd-1", status: "open", type: "task"),
            issue(
                "bd-state-event",
                title: "State change: phase → implementation",
                status: "closed",
                type: "event",
                parentID: "bd-1"
            ),
            issue(
                "bd-clear-event",
                title: "State cleared: phase",
                status: "closed",
                type: "event",
                parentID: "bd-1"
            )
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics())

        XCTAssertEqual(index.stateDimensionNames, ["phase"])
        XCTAssertEqual(index.stateValuesByDimension["phase"], ["implementation"])
        let changes = index.recordedStateChanges(for: "bd-1")
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes.contains { $0.value == "implementation" })
        XCTAssertTrue(changes.contains { $0.value == nil })
    }

    func testSystemEventRecordsStayAvailableWithoutEnteringUserFacingIndexesOrHierarchy() throws {
        var projectSemantics = semantics()
        projectSemantics.types.append(BeadTypeDefinition(name: "event", description: "Internal history"))
        let eventDate = Date(timeIntervalSince1970: 3_000)
        let issues = [
            issue("bd-parent", title: "Parent", status: "open", type: "epic"),
            issue("bd-child", title: "Child", status: "open", type: "task", parentID: "bd-parent"),
            issue(
                "bd-event",
                title: "State change: Phase → Testing",
                status: "closed",
                type: "event",
                labels: ["internal:event"],
                description: "Set Phase to Testing\n\nReason: Update test",
                createdAt: eventDate,
                closedAt: eventDate
            )
        ]
        let dependencies = [
            BeadDependency(
                issueID: "bd-event",
                dependsOnID: "bd-parent",
                type: "parent-child",
                createdAt: eventDate
            )
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: dependencies, semantics: projectSemantics)

        XCTAssertNotNil(index.issue(with: "bd-event"), "Activity provenance remains addressable")
        XCTAssertEqual(index.userFacingIssues.map(\.id), ["bd-parent", "bd-child"])
        XCTAssertEqual(index.allIssueIDs, ["bd-parent", "bd-child"])
        XCTAssertEqual(index.issueIDs(for: .all), ["bd-parent", "bd-child"])
        XCTAssertNil(index.issueIDsByType["event"])
        XCTAssertFalse(index.semantics.typeNames.contains("event"))
        XCTAssertFalse(index.baseFilterCountsByBookmark[.all]?.typeCounts.contains { $0.0 == "event" } == true)
        XCTAssertFalse(index.labelNames.contains("internal:event"))
        XCTAssertEqual(
            index.filteredIssueIDs(
                within: index.issueIDs(for: .all),
                statusFilters: [],
                typeFilters: [],
                priorityFilters: [],
                labelFilters: [],
                searchText: "State change"
            ),
            []
        )
        XCTAssertEqual(index.childIDsByParentID["bd-parent"], ["bd-child"])
        XCTAssertEqual(
            index.childProgress(for: "bd-parent"),
            IssueChildProgress(completedCount: 0, workedCount: 0, totalCount: 1)
        )
        XCTAssertEqual(index.systemRecordIssueIDs(ownedBy: ["bd-parent"]), ["bd-event"])

        let stateChange = try XCTUnwrap(index.recordedStateChanges(for: "bd-parent").first)
        XCTAssertEqual(stateChange.eventID, "bd-event")
        XCTAssertEqual(stateChange.dimension, "Phase")
        XCTAssertEqual(stateChange.value, "Testing")
        XCTAssertEqual(stateChange.date, eventDate)
        XCTAssertEqual(stateChange.reason, "Update test")
    }

    func testStateCatalogDisambiguatesRecordedDimensionContainingArrow() {
        let issues = [
            issue(
                "bd-1",
                status: "open",
                type: "task",
                labels: ["release → phase:ready", "release:ordinary"]
            ),
            issue(
                "bd-state-event",
                title: "State change: release → phase → ready",
                status: "closed",
                type: "event",
                parentID: "bd-1"
            )
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics())

        XCTAssertEqual(index.stateDimensionNames, ["release → phase"])
        XCTAssertEqual(index.stateValuesByDimension["release → phase"], ["ready"])
        XCTAssertNil(index.stateValuesByDimension["release"])
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

    func testReadyBookmarkTreatsDeferredStatusAndDeferredDateIndependently() {
        let now = Date()
        let issues = [
            issue("bd-open-undated", status: "open", type: "task"),
            issue("bd-open-past-defer", status: "open", type: "task", deferUntil: now.addingTimeInterval(-3_600)),
            issue("bd-open-future-defer", status: "open", type: "task", deferUntil: now.addingTimeInterval(3_600)),
            issue("bd-deferred-undated", status: "deferred", type: "task"),
            issue("bd-deferred-past", status: "deferred", type: "task", deferUntil: now.addingTimeInterval(-3_600)),
            issue("bd-deferred-future", status: "deferred", type: "task", deferUntil: now.addingTimeInterval(3_600))
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics())

        XCTAssertEqual(index.issueIDs(for: .ready), [
            "bd-open-undated",
            "bd-open-past-defer"
        ])
    }

    func testReadyBookmarkExcludesOpenGates() {
        let issues = [
            issue("bd-ready", status: "open", type: "task"),
            issue("bd-gate", status: "open", type: "gate"),
            issue("bd-closed-gate", status: "closed", type: "gate", closedAt: Date())
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics())

        XCTAssertEqual(index.issueIDs(for: .ready), ["bd-ready"])
        XCTAssertEqual(index.issueIDs(for: .gates), ["bd-gate"])
    }

    func testReadyBookmarkHidesParentWhenAllUnfinishedImmediateChildrenAreBlocked() {
        let issues = [
            issue("bd-parent", status: "open", type: "task"),
            issue("bd-status-blocked", status: "blocked", type: "task", parentID: "bd-parent"),
            issue("bd-dependency-blocked", status: "open", type: "task", parentID: "bd-parent"),
            issue("bd-blocker", status: "open", type: "task"),
            issue("bd-closed-child", status: "closed", type: "task", closedAt: Date(), parentID: "bd-parent")
        ]
        let dependencies = [
            BeadDependency(issueID: "bd-dependency-blocked", dependsOnID: "bd-blocker", type: "blocks", createdAt: nil)
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: dependencies, semantics: staleSemantics())

        XCTAssertFalse(index.issueIDs(for: .ready).contains("bd-parent"))
        XCTAssertTrue(index.issueIDs(for: .ready).contains("bd-blocker"))
    }

    func testReadyBookmarkKeepsParentWhenAnyUnfinishedImmediateChildIsReady() {
        let issues = [
            issue("bd-parent", status: "open", type: "task"),
            issue("bd-status-blocked", status: "blocked", type: "task", parentID: "bd-parent"),
            issue("bd-ready-child", status: "open", type: "task", parentID: "bd-parent")
        ]

        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: staleSemantics())

        XCTAssertTrue(index.issueIDs(for: .ready).contains("bd-parent"))
    }

    func testReadyBookmarkKeepsParentWhenUnfinishedImmediateChildrenAreDeferredOrInProgress() {
        let issues = [
            issue("bd-parent", status: "open", type: "task"),
            issue("bd-in-progress-child", status: "in_progress", type: "task", parentID: "bd-parent"),
            issue("bd-deferred-child", status: "deferred", type: "task", parentID: "bd-parent")
        ]
        let semantics = BeadProjectSemantics(
            statuses: [
                BeadStatusDefinition(name: "open", category: .active, icon: nil, description: nil, isBuiltIn: true),
                BeadStatusDefinition(name: "in_progress", category: .wip, icon: nil, description: nil, isBuiltIn: true),
                BeadStatusDefinition(name: "deferred", category: .frozen, icon: nil, description: nil, isBuiltIn: true),
                BeadStatusDefinition(name: "blocked", category: .wip, icon: nil, description: nil, isBuiltIn: true),
                BeadStatusDefinition(name: "closed", category: .done, icon: nil, description: nil, isBuiltIn: true)
            ],
            types: [
                BeadTypeDefinition(name: "task", description: nil)
            ]
        )

        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics)

        XCTAssertTrue(index.issueIDs(for: .ready).contains("bd-parent"))
    }

    func testReadyBookmarkCanKeepParentsWhoseChildrenAreAllBlockedWhenRollUpIsDisabled() {
        let issues = [
            issue("bd-parent", status: "open", type: "task"),
            issue("bd-status-blocked", status: "blocked", type: "task", parentID: "bd-parent"),
            issue("bd-missing-blocked", status: "open", type: "task", parentID: "bd-parent")
        ]
        let dependencies = [
            BeadDependency(issueID: "bd-missing-blocked", dependsOnID: "external:blocked", type: "blocks", createdAt: nil)
        ]

        let index = BeadProjectIndex(
            issues: issues,
            dependencies: dependencies,
            semantics: staleSemantics(),
            hidesParentsWithOnlyBlockedChildrenInReady: false
        )

        XCTAssertTrue(index.issueIDs(for: .ready).contains("bd-parent"))
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

    func testFolderScopeFiltersOneThousandOrderedIDsInsideTenThousandIssueProject() {
        let issues = (0..<10_000).map { offset in
            issue(
                "bd-\(offset)",
                title: offset.isMultiple(of: 2) ? "Cleanup \(offset)" : "Feature \(offset)",
                status: offset.isMultiple(of: 3) ? "closed" : "open",
                type: offset.isMultiple(of: 5) ? "epic" : "task",
                priority: offset % 4,
                labels: [offset.isMultiple(of: 2) ? "cleanup" : "feature"]
            )
        }
        let projectIndex = BeadProjectIndex(
            issues: issues,
            dependencies: [],
            semantics: semantics()
        )
        let orderedFolderIDs = (9_000..<10_000).reversed().map { "bd-\($0)" }

        let result = projectIndex.filteredIssueIDsAndCounts(
            within: orderedFolderIDs,
            statusFilters: ["open"],
            typeFilters: ["task"],
            priorityFilters: [0, 2],
            labelFilters: ["cleanup"],
            searchText: "cleanup"
        )
        let expected = orderedFolderIDs.filter { id in
            let offset = Int(id.dropFirst(3))!
            return !offset.isMultiple(of: 3)
                && !offset.isMultiple(of: 5)
                && (offset % 4 == 0 || offset % 4 == 2)
                && offset.isMultiple(of: 2)
        }

        XCTAssertEqual(result.matchingIDs, expected)
        XCTAssertEqual(result.counts.statusCounts.reduce(0) { $0 + $1.1 }, 1_000)
        XCTAssertEqual(result.counts.typeCounts.reduce(0) { $0 + $1.1 }, 1_000)
        XCTAssertEqual(result.counts.priorityCounts.reduce(0) { $0 + $1.1 }, 1_000)
        XCTAssertEqual(Set(result.matchingIDs).count, result.matchingIDs.count)
    }

    func testLargeDatasetPartitionsSystemRecordsOnceDuringIndexing() {
        let userIssues = (0..<5_000).map { offset in
            issue("bd-\(offset)", title: "Work \(offset)", status: "open", type: "task")
        }
        let eventIssues = (0..<5_000).map { offset in
            issue(
                "bd-\(offset).1",
                title: "Audit event \(offset)",
                status: "closed",
                type: "event",
                parentID: "bd-\(offset)"
            )
        }

        let index = BeadProjectIndex(
            issues: userIssues + eventIssues,
            dependencies: [],
            semantics: semantics()
        )
        let userIssueIDs = userIssues.map(\.id)

        XCTAssertEqual(index.issueByID.count, 10_000)
        XCTAssertEqual(index.allIssueIDs.count, 5_000)
        XCTAssertEqual(index.foldedSearchBytesByID.count, 5_000)
        XCTAssertEqual(index.count(for: .all), 5_000)
        XCTAssertEqual(index.systemRecordIssueIDs(ownedBy: userIssueIDs).count, 5_000)
        XCTAssertTrue(index.childIDsByParentID.isEmpty)
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

    func testImmediateChildRowsUseSiblingDependencyOrderingAndExcludeGrandchildren() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-blocked", title: "A Blocked child", status: "open", type: "task", parentID: "bd-parent"),
                issue("bd-blocker", title: "Z Blocker child", status: "open", type: "task", parentID: "bd-parent"),
                issue("bd-grandchild", title: "Grandchild", status: "open", type: "task", parentID: "bd-blocked")
            ],
            dependencies: [
                BeadDependency(issueID: "bd-blocked", dependsOnID: "bd-blocker", type: "blocks", createdAt: nil)
            ],
            semantics: semantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let rows = index.immediateChildRows(parentID: "bd-parent", sortOrder: sortOrder)

        XCTAssertEqual(rows.map(\.issueID), ["bd-blocker", "bd-blocked"])
        XCTAssertEqual(rows.first { $0.issueID == "bd-blocked" }?.childProgress, IssueChildProgress(completedCount: 0, workedCount: 0, totalCount: 1))
        XCTAssertEqual(index.childProgress(for: "bd-parent"), IssueChildProgress(completedCount: 0, workedCount: 0, totalCount: 2))
    }

    func testActiveBlockingRelationshipHelpersSeparateDirectionAndResolvedEdges() {
        let closedAt = Date()
        let index = BeadProjectIndex(
            issues: [
                issue("bd-target", title: "Target", status: "open", type: "task"),
                issue("bd-blocker", title: "B Blocker", status: "open", type: "task"),
                issue("g-1", title: "A Gate", status: "open", type: "gate"),
                issue("bd-closed-blocker", title: "Closed Blocker", status: "closed", type: "task", closedAt: closedAt),
                issue("g-closed", title: "Closed Gate", status: "closed", type: "gate", closedAt: closedAt),
                issue("bd-dependent", title: "Dependent", status: "open", type: "task"),
                issue("bd-closed-dependent", title: "Closed Dependent", status: "closed", type: "task", closedAt: closedAt),
                issue("bd-related", title: "Related", status: "open", type: "task"),
                issue("bd-closed-target", title: "Closed Target", status: "closed", type: "task", closedAt: closedAt)
            ],
            dependencies: [
                BeadDependency(issueID: "bd-target", dependsOnID: "bd-blocker", type: "blocks", createdAt: nil),
                BeadDependency(issueID: "bd-target", dependsOnID: "g-1", type: "blocks", createdAt: nil),
                BeadDependency(issueID: "bd-target", dependsOnID: "bd-closed-blocker", type: "blocks", createdAt: nil),
                BeadDependency(issueID: "bd-target", dependsOnID: "g-closed", type: "blocks", createdAt: nil),
                BeadDependency(issueID: "bd-dependent", dependsOnID: "bd-target", type: "blocks", createdAt: nil),
                BeadDependency(issueID: "bd-closed-dependent", dependsOnID: "bd-target", type: "blocks", createdAt: nil),
                BeadDependency(issueID: "bd-closed-target", dependsOnID: "bd-blocker", type: "blocks", createdAt: nil),
                BeadDependency(issueID: "bd-related", dependsOnID: "bd-target", type: "related", createdAt: nil)
            ],
            semantics: semantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        XCTAssertEqual(index.activeBlockingIssues(for: "bd-target", sortOrder: sortOrder).map(\.id), ["g-1", "bd-blocker"])
        XCTAssertEqual(index.activeBlockingIssues(for: "bd-closed-target", sortOrder: sortOrder).map(\.id), [])
        XCTAssertEqual(index.activelyBlockedIssues(by: "bd-target", sortOrder: sortOrder).map(\.id), ["bd-dependent"])
        XCTAssertEqual(index.activelyBlockedIssues(by: "bd-closed-blocker", sortOrder: sortOrder).map(\.id), [])
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

    func testOpenChildIssuesForClosingIncludesOpenDescendantsAndSkipsAlreadyClosingIDs() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-child", title: "Child", status: "open", type: "task", parentID: "bd-parent"),
                issue("bd-grandchild", title: "Grandchild", status: "review", type: "task", parentID: "bd-child"),
                issue("bd-closed", title: "Closed", status: "closed", type: "task", closedAt: Date(), parentID: "bd-parent")
            ],
            dependencies: [],
            semantics: semanticsWithReview()
        )

        let childrenForParent = index.openChildIssues(forClosing: ["bd-parent"])
        let childrenForParentAndChild = index.openChildIssues(forClosing: ["bd-parent", "bd-child"])

        XCTAssertEqual(childrenForParent.map(\.id), ["bd-child", "bd-grandchild"])
        XCTAssertEqual(childrenForParentAndChild.map(\.id), ["bd-grandchild"])
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

    func testSiblingNonBlockingRelationshipsPreserveRequestedSort() {
        let index = BeadProjectIndex(
            issues: [
                issue("bd-parent", title: "Parent", status: "open", type: "epic"),
                issue("bd-alpha", title: "Alpha", status: "open", type: "task", parentID: "bd-parent"),
                issue("bd-zulu", title: "Zulu", status: "open", type: "task", parentID: "bd-parent")
            ],
            dependencies: [
                BeadDependency(issueID: "bd-alpha", dependsOnID: "bd-zulu", type: "related", createdAt: nil)
            ],
            semantics: semantics()
        )
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        let rows = index.issueListRows(
            for: ["bd-parent", "bd-alpha", "bd-zulu"],
            mode: .outline,
            expandedIssueIDs: ["bd-parent"],
            sortOrder: sortOrder
        )

        XCTAssertEqual(rows.map(\.issueID), ["bd-parent", "bd-alpha", "bd-zulu"])
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
            sortOrder: sortOrder,
            filteredIssueIDsAreSorted: true
        )

        XCTAssertEqual(rows.count, issueCount)
        XCTAssertEqual(rows.first?.issueID, "bd-0")
        XCTAssertEqual(rows.last?.issueID, "bd-\(issueCount - 1)")
        XCTAssertEqual(rows.last?.depth, issueCount - 1)
        XCTAssertTrue(rows.dropLast().allSatisfy(\.isContext))
        XCTAssertEqual(rows.last?.isContext, false)
    }

    func testGatesBookmarkReturnsOnlyOpenGateBeads() {
        let issues = [
            issue("t-1", status: "open", type: "task"),
            issue("g-open", status: "open", type: "gate"),
            issue("g-closed", status: "closed", type: "gate")
        ]
        let index = BeadProjectIndex(issues: issues, dependencies: [], semantics: semantics())

        XCTAssertEqual(index.issueIDs(for: .gates), ["g-open"])
        XCTAssertEqual(index.count(for: .gates), 1)
    }

    func testGatesOutlineNestsBlockedBeadsUnderTheGate() {
        let issues = [
            issue("g-1", status: "open", type: "gate"),
            issue("bead-a", status: "open", type: "task"),
            issue("bead-b", status: "open", type: "task"),
            issue("unrelated", status: "open", type: "task")
        ]
        let dependencies = [
            BeadDependency(issueID: "bead-a", dependsOnID: "g-1", type: "blocks", createdAt: nil),
            BeadDependency(issueID: "bead-b", dependsOnID: "g-1", type: "blocks", createdAt: nil)
        ]
        let index = BeadProjectIndex(issues: issues, dependencies: dependencies, semantics: semantics())
        let sortOrder = BeadIssueSortOrder(sort: .title, direction: .ascending)

        // Default (nothing collapsed): the gate is expanded, blocked beads are context children.
        let expanded = index.issueListRows(
            for: ["g-1"],
            mode: .outline,
            expandedIssueIDs: [],
            sortOrder: sortOrder,
            bookmark: .gates
        )
        XCTAssertEqual(expanded.map(\.issueID), ["g-1", "bead-a", "bead-b"])
        XCTAssertEqual(expanded.map(\.depth), [0, 1, 1])
        XCTAssertTrue(expanded[0].hasChildren)
        XCTAssertTrue(expanded[0].isExpanded)
        XCTAssertTrue(expanded[1].isContext)
        XCTAssertTrue(expanded[2].isContext)

        // Collapsing the gate hides the blocked beads.
        let collapsed = index.issueListRows(
            for: ["g-1"],
            mode: .outline,
            expandedIssueIDs: [],
            collapsedIssueIDs: ["g-1"],
            sortOrder: sortOrder,
            bookmark: .gates
        )
        XCTAssertEqual(collapsed.map(\.issueID), ["g-1"])
        XCTAssertFalse(collapsed[0].isExpanded)

        // The Gates section nests blocked beads regardless of the global list mode — the
        // flat/outline toggle is hidden there, so flat must produce the same tree.
        let flat = index.issueListRows(
            for: ["g-1"],
            mode: .flat,
            expandedIssueIDs: [],
            sortOrder: sortOrder,
            bookmark: .gates
        )
        XCTAssertEqual(flat.map(\.issueID), ["g-1", "bead-a", "bead-b"])
        XCTAssertTrue(flat[0].hasChildren)
    }

    func testGatesSortReadyFirstThenBestBlockedPriorityAndChildrenByPriority() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oneHour: Int64 = 3_600_000_000_000
        let issues = [
            issue("g-pending-p0", title: "A Pending", status: "open", type: "gate", gateAwaitType: .timer, gateTimeoutNanoseconds: oneHour, createdAt: now),
            issue("g-elapsed-p1", title: "B Elapsed", status: "open", type: "gate", gateAwaitType: .timer, gateTimeoutNanoseconds: oneHour, createdAt: now.addingTimeInterval(-7200)),
            issue("g-human-p0", title: "C Human", status: "open", type: "gate", gateAwaitType: .human),
            issue("human-p3", title: "Human low", status: "open", type: "task", priority: 3),
            issue("human-p0", title: "Human high", status: "open", type: "task", priority: 0),
            issue("elapsed-p1", title: "Elapsed", status: "open", type: "task", priority: 1),
            issue("pending-p0", title: "Pending", status: "open", type: "task", priority: 0)
        ]
        let dependencies = [
            BeadDependency(issueID: "human-p3", dependsOnID: "g-human-p0", type: "blocks", createdAt: nil),
            BeadDependency(issueID: "human-p0", dependsOnID: "g-human-p0", type: "blocks", createdAt: nil),
            BeadDependency(issueID: "elapsed-p1", dependsOnID: "g-elapsed-p1", type: "blocks", createdAt: nil),
            BeadDependency(issueID: "pending-p0", dependsOnID: "g-pending-p0", type: "blocks", createdAt: nil)
        ]
        let index = BeadProjectIndex(issues: issues, dependencies: dependencies, semantics: semantics())

        let sortedGateIDs = BeadIssueListQuery.sortedIssueIDs(
            index: index,
            ids: ["g-pending-p0", "g-elapsed-p1", "g-human-p0"],
            sort: .title,
            direction: .descending,
            bookmark: .gates,
            now: now
        )
        let rows = index.issueListRows(
            for: sortedGateIDs,
            mode: .flat,
            expandedIssueIDs: [],
            sortOrder: BeadIssueSortOrder(sort: .priority, direction: .ascending),
            bookmark: .gates
        )

        XCTAssertEqual(sortedGateIDs, ["g-human-p0", "g-elapsed-p1", "g-pending-p0"])
        XCTAssertEqual(rows.map(\.issueID), [
            "g-human-p0",
            "human-p0",
            "human-p3",
            "g-elapsed-p1",
            "elapsed-p1",
            "g-pending-p0",
            "pending-p0"
        ])
    }

    func testGatesSortPendingByBlockedPriorityBeforeOrphans() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oneHour: Int64 = 3_600_000_000_000
        let issues = [
            issue("g-orphan", title: "A Orphan", status: "open", type: "gate", priority: 0, gateAwaitType: .githubRun),
            issue("g-pending-p1", title: "B Pending P1", status: "open", type: "gate", gateAwaitType: .timer, gateTimeoutNanoseconds: oneHour, createdAt: now),
            issue("g-pending-p0", title: "C Pending P0", status: "open", type: "gate", gateAwaitType: .githubPR),
            issue("blocked-p1", title: "Blocked P1", status: "open", type: "task", priority: 1),
            issue("blocked-p0", title: "Blocked P0", status: "open", type: "task", priority: 0)
        ]
        let dependencies = [
            BeadDependency(issueID: "blocked-p1", dependsOnID: "g-pending-p1", type: "blocks", createdAt: nil),
            BeadDependency(issueID: "blocked-p0", dependsOnID: "g-pending-p0", type: "blocks", createdAt: nil)
        ]
        let index = BeadProjectIndex(issues: issues, dependencies: dependencies, semantics: semantics())

        let sortedGateIDs = BeadIssueListQuery.sortedIssueIDs(
            index: index,
            ids: ["g-orphan", "g-pending-p1", "g-pending-p0"],
            sort: .title,
            direction: .ascending,
            bookmark: .gates,
            now: now
        )

        XCTAssertEqual(sortedGateIDs, ["g-pending-p0", "g-pending-p1", "g-orphan"])
    }

    private func issue(
        _ id: String,
        title: String = "Example",
        status: String,
        type: String,
        priority: Int = 2,
        labels: [String] = [],
        description: String = "",
        design: String = "",
        acceptanceCriteria: String = "",
        notes: String = "",
        gateAwaitType: GateAwaitType? = nil,
        gateAwaitID: String? = nil,
        gateTimeoutNanoseconds: Int64? = nil,
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
            priority: priority,
            issueType: type,
            gateAwaitType: gateAwaitType,
            gateAwaitID: gateAwaitID,
            gateTimeoutNanoseconds: gateTimeoutNanoseconds,
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
