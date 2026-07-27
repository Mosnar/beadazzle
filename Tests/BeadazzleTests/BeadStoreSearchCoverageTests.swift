import Foundation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadStoreSearchCoverageTests: XCTestCase {
    func testExpandedSearchBypassesCurrentViewWithoutDuplicatingTheQuery() async throws {
        let store = try await makeLoadedStore()
        store.applyBookmark(.open)
        store.setLabelFilter("local", isOn: true)
        store.searchText = "Needle"
        await settleSearch(in: store)

        XCTAssertTrue(store.filteredIssueIDs.isEmpty)
        XCTAssertTrue(store.canExpandCurrentSearchToAllBeads)

        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        XCTAssertEqual(Set(store.filteredIssueIDs), ["bd-open-needle", "bd-closed-needle"])
        XCTAssertEqual(store.searchCoverage, .allBeads)
        XCTAssertTrue(store.isGlobalSearchActive)
        XCTAssertEqual(store.searchText, "Needle")
        XCTAssertEqual(store.selectedBookmark, .open)
        XCTAssertEqual(store.labelFilters, ["local"])
        XCTAssertEqual(store.currentWorkspaceSnapshot?.searchText, "Needle")

        store.searchCurrentViewUsingCurrentSearchText()
        await settleSearch(in: store)

        XCTAssertEqual(store.searchCoverage, .currentView)
        XCTAssertFalse(store.isGlobalSearchActive)
        XCTAssertTrue(store.filteredIssueIDs.isEmpty)
        XCTAssertEqual(store.searchText, "Needle")
    }

    func testClearingExpandedSearchImmediatelyReturnsToTheCurrentView() async throws {
        let store = try await makeLoadedStore()
        store.applyBookmark(.open)
        store.setLabelFilter("local", isOn: true)
        store.searchText = "Needle"
        await settleSearch(in: store)
        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        store.searchText = ""

        XCTAssertEqual(store.searchCoverage, .currentView)
        XCTAssertFalse(store.isGlobalSearchActive)
        await settleSearch(in: store)
        XCTAssertEqual(store.filteredIssueIDs, ["bd-local"])
        XCTAssertEqual(store.currentWorkspaceSnapshot?.searchText, "")
    }

    func testSidebarPresetSelectionKeepsTheQueryAndReturnsToCurrentViewCoverage() async throws {
        let store = try await makeLoadedStore()
        store.applyBookmark(.open)
        store.searchText = "Needle"
        await settleSearch(in: store)
        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        store.scheduleSidebarSelection(.preset(.closed))
        await store.waitForPendingSidebarSelection()
        await settleSearch(in: store)

        XCTAssertEqual(store.searchCoverage, .currentView)
        XCTAssertFalse(store.isGlobalSearchActive)
        XCTAssertEqual(store.searchText, "Needle")
        XCTAssertEqual(store.selectedBookmark, .closed)
        XCTAssertEqual(store.filteredIssueIDs, ["bd-closed-needle"])
    }

    func testSidebarSavedViewSelectionAppliesItsOwnQueryAndCurrentViewCoverage() async throws {
        let store = try await makeLoadedStore()
        store.saveConfiguredView(
            name: "Closed",
            symbolName: "checkmark",
            query: BeadSavedViewQuery(
                basePreset: .closed,
                statusFilters: [],
                typeFilters: [],
                priorityFilters: [],
                labelFilters: [],
                searchText: ""
            ),
            ordering: .sorted(BeadSavedViewSort(field: .priority, direction: .ascending))
        )
        await settleSearch(in: store)
        let savedID = try XCTUnwrap(store.activeSavedViewID)

        store.applyBookmark(.open)
        store.searchText = "Needle"
        await settleSearch(in: store)
        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        store.scheduleSidebarSelection(.savedView(savedID))
        await store.waitForPendingSidebarSelection()
        await settleSearch(in: store)

        XCTAssertEqual(store.searchCoverage, .currentView)
        XCTAssertFalse(store.isGlobalSearchActive)
        XCTAssertEqual(store.searchText, "")
        XCTAssertEqual(store.activeSavedViewID, savedID)
        XCTAssertEqual(store.selectedBookmark, .closed)
        XCTAssertEqual(store.filteredIssueIDs, ["bd-closed-needle"])
    }

    func testExpandedSearchCanBeSavedWithoutBypassedFilters() async throws {
        let store = try await makeLoadedStore()
        store.applyBookmark(.open)
        store.setLabelFilter("local", isOn: true)
        store.searchText = "Needle"
        await settleSearch(in: store)
        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)
        store.selectListSort(.updated)
        await settleSearch(in: store)

        let query = store.currentSavedViewQuery
        XCTAssertEqual(query.basePreset, .all)
        XCTAssertTrue(query.statusFilters.isEmpty)
        XCTAssertTrue(query.typeFilters.isEmpty)
        XCTAssertTrue(query.priorityFilters.isEmpty)
        XCTAssertTrue(query.labelFilters.isEmpty)
        XCTAssertEqual(query.searchText, "Needle")
        XCTAssertNil(query.advancedPredicate)
        XCTAssertEqual(
            store.currentSavedViewOrdering,
            .sorted(BeadSavedViewSort(field: .updated, direction: .ascending))
        )

        store.saveCurrentViewAsBookmark(name: "Needles", symbolName: "magnifyingglass")
        await settleSearch(in: store)

        let saved = try XCTUnwrap(store.savedViews.last)
        XCTAssertEqual(saved.smartQuery, query)
        XCTAssertEqual(saved.savedSort, BeadSavedViewSort(field: .updated, direction: .ascending))
        XCTAssertEqual(store.activeSavedViewID, saved.id)
        XCTAssertEqual(store.selectedBookmark, .all)
        XCTAssertEqual(store.searchText, "Needle")
        XCTAssertEqual(store.searchCoverage, .currentView)
    }

    func testExpandedSearchLeavesFolderMembershipAndManualOrderingIntact() async throws {
        let store = try await makeLoadedStore()
        let folderID = try XCTUnwrap(store.createFolder(name: "Local", issueIDs: ["bd-local"]))
        await settleSearch(in: store)

        XCTAssertEqual(store.activeFolderSavedView?.id, folderID)
        XCTAssertTrue(store.listOrdering.isManual)

        store.searchText = "Needle"
        await settleSearch(in: store)
        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        XCTAssertNil(store.activeIssueListFolderSavedView)
        XCTAssertEqual(store.effectiveIssueListMode, .flat)
        XCTAssertEqual(Set(store.filteredIssueIDs), ["bd-open-needle", "bd-closed-needle"])

        store.selectListSort(.updated)
        await settleSearch(in: store)
        XCTAssertEqual(store.sort, .updated)
        XCTAssertTrue(store.listOrdering.isManual)

        store.searchCurrentViewUsingCurrentSearchText()
        await settleSearch(in: store)

        XCTAssertEqual(store.activeIssueListFolderSavedView?.id, folderID)
        XCTAssertTrue(store.listOrdering.isManual)
        XCTAssertTrue(store.filteredIssueIDs.isEmpty)

        store.searchText = ""
        await settleSearch(in: store)
        XCTAssertEqual(store.filteredIssueIDs, ["bd-local"])
    }

    func testExpandedSearchSortIsTemporaryForSmartBookmark() async throws {
        let store = try await makeLoadedStore()
        store.saveConfiguredView(
            name: "Open Needles",
            symbolName: "magnifyingglass",
            query: BeadSavedViewQuery(
                basePreset: .open,
                statusFilters: [],
                typeFilters: [],
                priorityFilters: [],
                labelFilters: [],
                searchText: "Needle"
            ),
            ordering: .sorted(BeadSavedViewSort(field: .priority, direction: .ascending))
        )
        await settleSearch(in: store)
        let savedViewID = try XCTUnwrap(store.activeSavedViewID)

        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)
        store.selectListSort(.updated)
        store.selectListSortDirection(.descending)
        await settleSearch(in: store)

        XCTAssertEqual(store.activeSavedViewID, savedViewID)
        XCTAssertEqual(store.sourceSavedViewID, savedViewID)
        XCTAssertFalse(store.isSavedViewDrifted)
        XCTAssertEqual(store.sort, .updated)
        XCTAssertEqual(store.sortDirection, .descending)
        XCTAssertEqual(
            store.listOrdering,
            .sorted(BeadSavedViewSort(field: .priority, direction: .ascending))
        )
        XCTAssertEqual(store.currentWorkspaceSnapshot?.sort, .priority)
        XCTAssertEqual(store.currentWorkspaceSnapshot?.sortDirection, .ascending)

        store.searchCurrentViewUsingCurrentSearchText()
        await settleSearch(in: store)

        XCTAssertEqual(store.activeSavedViewID, savedViewID)
        XCTAssertFalse(store.isSavedViewDrifted)
        XCTAssertEqual(store.sort, .priority)
        XCTAssertEqual(store.sortDirection, .ascending)
        XCTAssertEqual(store.filteredIssueIDs, ["bd-open-needle"])
    }

    func testClearingExpandedSearchRestoresOriginatingSort() async throws {
        let store = try await makeLoadedStore()
        store.applyBookmark(.open)
        store.searchText = "Needle"
        await settleSearch(in: store)
        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)
        store.selectListSort(.updated)
        store.selectListSortDirection(.descending)
        await settleSearch(in: store)

        store.searchText = ""

        XCTAssertFalse(store.isGlobalSearchActive)
        XCTAssertEqual(store.sort, .priority)
        XCTAssertEqual(store.sortDirection, .ascending)
        await settleSearch(in: store)
        XCTAssertEqual(Set(store.filteredIssueIDs), ["bd-local", "bd-open-needle"])
    }

    func testExpandedSearchDoesNotReplaceCurrentViewFilterCounts() async throws {
        let store = try await makeLoadedStore()
        store.applyBookmark(.open)
        store.searchText = "Needle"
        await settleSearch(in: store)
        let currentViewCounts = store.filterCounts

        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        XCTAssertEqual(store.filterCounts, currentViewCounts)

        store.searchCurrentViewUsingCurrentSearchText()
        XCTAssertEqual(store.filterCounts, currentViewCounts)
        await settleSearch(in: store)
        XCTAssertEqual(store.filterCounts, currentViewCounts)
    }

    func testSearchAllBeadsIsNoOpWhenCurrentViewHasNoNarrowerScope() async throws {
        let store = try await makeLoadedStore()
        store.applyBookmark(.all)
        store.searchText = "Needle"
        await settleSearch(in: store)

        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        XCTAssertEqual(store.searchCoverage, .currentView)
        XCTAssertFalse(store.isGlobalSearchActive)
        XCTAssertEqual(store.searchText, "Needle")
    }

    func testExpandedSearchSummaryDescribesTheGlobalProjection() async throws {
        let store = try await makeLoadedStore()
        store.applyBookmark(.open)
        store.searchText = "Needle"
        await settleSearch(in: store)
        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        XCTAssertEqual(
            store.currentSavedViewSummary,
            "All Beads · search text · Priority, ascending"
        )
    }

    func testFutureDeferralDoesNotRemoveAResultFromExpandedSearch() async throws {
        let store = try await makeLoadedStore(issuesJSONL: """
        {"_type":"issue","id":"bd-deferred","title":"Needle","status":"deferred","priority":1,"issue_type":"task","defer_until":"2099-01-01","updated_at":"2026-07-27T12:00:00Z"}
        {"_type":"issue","id":"bd-ready","title":"Ready","status":"open","priority":2,"issue_type":"task"}
        """)
        store.applyBookmark(.stale)
        store.searchText = "Needle"
        await settleSearch(in: store)
        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)
        XCTAssertEqual(store.filteredIssueIDs, ["bd-deferred"])

        store.removeActivelyDeferredIssuesFromCurrentList(
            issueIDs: ["bd-deferred"],
            now: Date()
        )

        XCTAssertEqual(store.filteredIssueIDs, ["bd-deferred"])
    }

    func testEmptyFolderSearchCanExpandToAllBeads() async throws {
        let store = try await makeLoadedStore()
        let folderID = try XCTUnwrap(store.createFolder(name: "Empty"))
        await settleSearch(in: store)

        XCTAssertEqual(store.activeIssueListFolderSavedView?.id, folderID)
        XCTAssertTrue(store.filteredIssueIDs.isEmpty)

        store.searchText = "Needle"
        await settleSearch(in: store)

        XCTAssertTrue(store.filteredIssueIDs.isEmpty)
        XCTAssertTrue(store.canExpandCurrentSearchToAllBeads)

        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        XCTAssertTrue(store.isGlobalSearchActive)
        XCTAssertNil(store.activeIssueListFolderSavedView)
        XCTAssertEqual(Set(store.filteredIssueIDs), ["bd-open-needle", "bd-closed-needle"])
    }

    func testMatchingGatesSearchCanExpandToAllBeads() async throws {
        let store = try await makeLoadedStore(issuesJSONL: """
        {"_type":"issue","id":"bd-gate","title":"Needle approval","status":"open","priority":1,"issue_type":"gate","await_type":"human"}
        {"_type":"issue","id":"bd-task","title":"Needle task","status":"open","priority":2,"issue_type":"task"}
        """)
        store.applyBookmark(.gates)
        await settleSearch(in: store)
        store.searchText = "Needle"
        await settleSearch(in: store)

        XCTAssertEqual(store.filteredIssueIDs, ["bd-gate"])
        XCTAssertTrue(store.canExpandCurrentSearchToAllBeads)

        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        XCTAssertTrue(store.isGlobalSearchActive)
        XCTAssertEqual(Set(store.filteredIssueIDs), ["bd-gate", "bd-task"])
    }

    func testExpandedSearchShowsCollapsedDescendantMatchesInAFlatList() async throws {
        let store = try await makeLoadedStore(issuesJSONL: """
        {"_type":"issue","id":"bd-parent","title":"Parent","status":"open","priority":1,"issue_type":"epic"}
        {"_type":"issue","id":"bd-child","title":"Needle","status":"open","priority":2,"issue_type":"task","parent_id":"bd-parent"}
        """)
        store.applyBookmark(.open)
        await settleSearch(in: store)
        store.setIssueExpansion(issueID: "bd-parent", isExpanded: false)
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent"])

        store.searchText = "Needle"
        await settleSearch(in: store)

        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        XCTAssertEqual(store.filteredIssueIDs, ["bd-child"])
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-child"])
        XCTAssertEqual(store.effectiveIssueListMode, .flat)

        store.searchCurrentViewUsingCurrentSearchText()
        await settleSearch(in: store)
        XCTAssertEqual(store.effectiveIssueListMode, .outline)
    }

    func testHistoryNavigationRestoresCurrentViewCoverage() async throws {
        let store = try await makeLoadedStore()
        store.applyBookmark(.open)
        await settleSearch(in: store)
        store.applyBookmark(.closed)
        await settleSearch(in: store)
        store.searchText = "Needle"
        await settleSearch(in: store)
        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        store.goBack()
        await settleSearch(in: store)

        XCTAssertEqual(store.searchCoverage, .currentView)
        XCTAssertFalse(store.isGlobalSearchActive)
        XCTAssertEqual(store.selectedBookmark, .open)
        XCTAssertEqual(store.searchText, "")
        XCTAssertEqual(Set(store.filteredIssueIDs), ["bd-local", "bd-open-needle"])
    }

    func testAllBeadsViewNeedsNoExpansionControl() async throws {
        let store = try await makeLoadedStore()
        store.applyBookmark(.all)
        store.searchText = "Needle"
        await settleSearch(in: store)

        XCTAssertEqual(store.currentViewSearchTitle, "All Beads")
        XCTAssertEqual(store.activeSearchCoverageTitle, "All Beads")
        XCTAssertEqual(store.searchFieldPrompt, "Search All Beads")
        XCTAssertFalse(store.hasCurrentViewConstraintsBeyondSearch)
        XCTAssertFalse(store.canExpandCurrentSearchToAllBeads)
        XCTAssertEqual(Set(store.filteredIssueIDs), ["bd-open-needle", "bd-closed-needle"])
    }

    func testFilteredAllBeadsViewIsClearlyDistinguishedFromExpandedSearch() async throws {
        let store = try await makeLoadedStore()
        store.applyBookmark(.all)
        store.setLabelFilter("local", isOn: true)
        store.searchText = "Needle"
        await settleSearch(in: store)

        XCTAssertEqual(store.currentViewSearchTitle, "Current View")
        XCTAssertEqual(store.searchFieldPrompt, "Search Current View")
        XCTAssertTrue(store.canExpandCurrentSearchToAllBeads)

        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        XCTAssertEqual(store.activeSearchCoverageTitle, "All Beads")
        XCTAssertEqual(Set(store.filteredIssueIDs), ["bd-open-needle", "bd-closed-needle"])
    }

    func testWhitespaceCannotLeaveExpandedCoverageActive() async throws {
        let store = try await makeLoadedStore()
        store.applyBookmark(.open)
        store.searchText = "Needle"
        await settleSearch(in: store)
        store.searchAllBeadsUsingCurrentSearchText()
        await settleSearch(in: store)

        store.searchText = "   "

        XCTAssertEqual(store.searchCoverage, .currentView)
        XCTAssertFalse(store.isGlobalSearchActive)
        await settleSearch(in: store)
        XCTAssertEqual(Set(store.filteredIssueIDs), ["bd-local", "bd-open-needle"])
    }

    private func settleSearch(in store: BeadStore) async {
        await store.filterTask?.value
        await store.waitForPendingQueryRecompute()
    }

    private func makeLoadedStore() async throws -> BeadStore {
        try await makeLoadedStore(issuesJSONL: """
        {"_type":"issue","id":"bd-local","title":"Local task","status":"open","priority":1,"issue_type":"task","labels":["local"]}
        {"_type":"issue","id":"bd-open-needle","title":"Open Needle","status":"open","priority":2,"issue_type":"task","labels":["other"]}
        {"_type":"issue","id":"bd-closed-needle","title":"Closed Needle","status":"closed","priority":3,"issue_type":"bug","labels":["other"]}
        """)
    }

    private func makeLoadedStore(issuesJSONL: String) async throws -> BeadStore {
        let projectURL = try makeProject(issuesJSONL: issuesJSONL)
        addTeardownBlock { try? FileManager.default.removeItem(at: projectURL) }

        let store = BeadStore(
            userDefaults: makeUserDefaults(),
            commands: CurrentDoltTestCommands()
        )
        store.openProject(projectURL)

        let deadline = Date().addingTimeInterval(2)
        while store.isLoading || store.issueListRows.isEmpty {
            if Date() > deadline {
                XCTFail("Timed out waiting for BeadStore to load the search test project")
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(store.lastError)
        return store
    }

    private func makeProject(issuesJSONL: String) throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadazzleSearchTests-\(UUID().uuidString)", isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        try issuesJSONL.write(
            to: beadsURL.appendingPathComponent("issues.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        return projectURL
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "BeadStoreSearchCoverageTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
