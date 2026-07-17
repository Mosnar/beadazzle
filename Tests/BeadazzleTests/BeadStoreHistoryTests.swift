import Foundation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadStoreHistoryTests: XCTestCase {
    func testBackAndForwardTraverseSelectionHistoryInOrder() async throws {
        let store = try await makeLoadedStore()

        XCTAssertFalse(store.canGoBack)
        XCTAssertFalse(store.canGoForward)
        XCTAssertTrue(store.selectedIDs.isEmpty)

        store.select(["bd-parent"])
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))
        XCTAssertTrue(store.canGoBack)
        XCTAssertFalse(store.canGoForward)

        store.select(["bd-child"])
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedIDs, Set(["bd-child"]))
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent", "bd-child", "bd-sibling"])

        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))
        XCTAssertTrue(store.canGoBack)
        XCTAssertTrue(store.canGoForward)

        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertFalse(store.canGoBack)
        XCTAssertTrue(store.canGoForward)

        store.goForward()
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))

        store.goForward()
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.selectedIDs, Set(["bd-child"]))
        XCTAssertTrue(store.canGoBack)
        XCTAssertFalse(store.canGoForward)
    }

    func testAdjacentDuplicateSelectionDoesNotCreateExtraHistoryStep() async throws {
        let store = try await makeLoadedStore()

        store.select(["bd-parent"])
        await store.waitForPendingQueryRecompute()

        store.select(["bd-parent"])
        await store.waitForPendingQueryRecompute()

        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertFalse(store.canGoBack)
        XCTAssertTrue(store.canGoForward)
    }

    func testNewNavigationAfterBackClearsForwardHistory() async throws {
        let store = try await makeLoadedStore()

        store.select(["bd-parent"])
        await store.waitForPendingQueryRecompute()

        store.select(["bd-child"])
        await store.waitForPendingQueryRecompute()

        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))
        XCTAssertTrue(store.canGoForward)

        store.select(["bd-sibling"])
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedIDs, Set(["bd-sibling"]))
        XCTAssertTrue(store.canGoBack)
        XCTAssertFalse(store.canGoForward)

        store.goForward()
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.selectedIDs, Set(["bd-sibling"]))
    }

    func testBackRestoresCapturedWorkspaceSnapshotState() async throws {
        let store = try await makeLoadedStore()

        store.select(["bd-child"])
        await store.waitForPendingQueryRecompute()

        store.searchText = "Child"
        await store.waitForPendingQueryRecompute()
        let searchedSnapshot = try XCTUnwrap(store.currentWorkspaceSnapshot)

        store.issueListMode = .flat
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.issueListMode, .flat)

        let contextSnapshot = try XCTUnwrap(store.currentWorkspaceSnapshot)

        store.applyBookmark(.closed)
        await store.waitForPendingQueryRecompute()

        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertNotEqual(store.currentWorkspaceSnapshot, searchedSnapshot)
        XCTAssertEqual(store.currentWorkspaceSnapshot, contextSnapshot)
        XCTAssertEqual(store.issueListMode, .flat)
        XCTAssertEqual(store.searchText, "Child")
        XCTAssertEqual(store.selectedIDs, Set(["bd-child"]))
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-child"])
    }

    func testSearchTextUpdatesCurrentSnapshotWithoutAddingStandaloneHistoryStep() async throws {
        let store = try await makeLoadedStore()

        store.select(["bd-parent"])
        await store.waitForPendingQueryRecompute()

        store.searchText = "Parent"
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.currentWorkspaceSnapshot?.searchText, "Parent")

        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertEqual(store.searchText, "")
        XCTAssertTrue(store.canGoForward)

        store.goForward()
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))
        XCTAssertEqual(store.searchText, "Parent")
    }

    func testBookmarkChangeRecordsReversibleHistoryStep() async throws {
        let store = try await makeLoadedStore()

        store.select(["bd-child"])
        await store.waitForPendingQueryRecompute()

        store.applyBookmark(.closed)
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedBookmark, .closed)
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertTrue(store.canGoBack)

        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedBookmark, .ready)
        XCTAssertEqual(store.selectedIDs, Set(["bd-child"]))
    }

    func testSavedViewIdentityAndIdenticalPresetAreSeparateHistorySteps() async throws {
        let store = try await makeLoadedStore()
        store.saveCurrentViewAsBookmark(name: "Ready View", symbolName: "bookmark")
        await store.waitForPendingQueryRecompute()
        let savedID = try XCTUnwrap(store.activeSavedViewID)

        store.applyBookmark(.ready)
        XCTAssertNil(store.activeSavedViewID)

        store.goBack()
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.activeSavedViewID, savedID)
    }

    func testBackDoesNotRestoreSavedViewIdentityAfterManualOrderingChanges() async throws {
        let store = try await makeLoadedStore()
        let firstOrdering = BeadSavedViewOrdering.manual(BeadSavedViewManualOrdering(
            issueIDs: ["bd-child", "bd-parent"],
            fallback: BeadSavedViewSort(field: .priority, direction: .ascending)
        ))
        store.saveConfiguredView(
            name: "Manual",
            symbolName: "bookmark",
            query: store.currentSavedViewQuery,
            ordering: firstOrdering
        )
        await store.waitForPendingQueryRecompute()
        let savedID = try XCTUnwrap(store.activeSavedViewID)

        store.applyBookmark(.ready)
        let changedOrdering = BeadSavedViewOrdering.manual(BeadSavedViewManualOrdering(
            issueIDs: ["bd-parent", "bd-child"],
            fallback: BeadSavedViewSort(field: .priority, direction: .ascending)
        ))
        store.updateConfiguredView(
            id: savedID,
            name: "Manual",
            symbolName: "bookmark",
            query: store.currentSavedViewQuery,
            ordering: changedOrdering
        )
        await store.waitForPendingQueryRecompute()

        store.goBack()
        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertNil(store.activeSavedViewID)
        XCTAssertEqual(store.currentWorkspaceSnapshot?.savedViewOrdering, firstOrdering)
    }

    func testSavedViewMetadataChangesDoNotCreateHistorySteps() async throws {
        let store = try await makeLoadedStore()
        store.saveCurrentViewAsBookmark(name: "Ready View", symbolName: "bookmark")
        await store.waitForPendingQueryRecompute()
        let savedID = try XCTUnwrap(store.activeSavedViewID)

        store.renameSavedView(id: savedID, to: "Renamed")
        store.setSavedViewSymbol(id: savedID, symbolName: "star")
        store.duplicateSavedView(id: savedID)

        store.goBack()
        await store.waitForPendingQueryRecompute()
        XCTAssertNil(store.activeSavedViewID)
        XCTAssertFalse(store.canGoBack)
    }

    func testLatestScheduledSidebarSelectionWins() async throws {
        let store = try await makeLoadedStore()

        store.scheduleSidebarSelection(.preset(.closed))
        store.scheduleSidebarSelection(.preset(.all))
        await store.waitForPendingSidebarSelection()
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedBookmark, .all)
    }

    func testBackDoesNotRestoreDeletedSavedViewIdentity() async throws {
        let store = try await makeLoadedStore()
        store.saveCurrentViewAsBookmark(name: "Ready View", symbolName: "bookmark")
        await store.waitForPendingQueryRecompute()
        let savedID = try XCTUnwrap(store.activeSavedViewID)

        store.deleteSavedView(id: savedID)
        XCTAssertNil(store.activeSavedViewID)

        store.goBack()
        await store.waitForPendingQueryRecompute()
        XCTAssertNil(store.activeSavedViewID)
    }

    func testDeletingDriftedSavedViewClearsItsIdentityFromCurrentHistorySnapshot() async throws {
        let store = try await makeLoadedStore()
        store.saveCurrentViewAsBookmark(name: "Ready View", symbolName: "bookmark")
        await store.waitForPendingQueryRecompute()
        let savedID = try XCTUnwrap(store.activeSavedViewID)

        store.searchText = "Parent"
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.sourceSavedViewID, savedID)

        store.deleteSavedView(id: savedID)
        XCTAssertNil(store.sourceSavedViewID)
        store.applyBookmark(.all)
        await store.waitForPendingQueryRecompute()
        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertNil(store.activeSavedViewID)
        XCTAssertNil(store.sourceSavedViewID)
        XCTAssertEqual(store.searchText, "Parent")
    }

    func testCreatingBeadRecordsReversibleHistoryStep() async throws {
        let store = try await makeLoadedStore()

        store.select(["bd-parent"])
        await store.waitForPendingQueryRecompute()

        store.beginCreatingBead()
        await store.waitForPendingQueryRecompute()

        XCTAssertNotNil(store.creationDraft)
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertTrue(store.canGoBack)

        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertNil(store.creationDraft)
        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))
    }

    func testEditedCreationDraftIsRestoredAcrossHistoryTraversal() async throws {
        let store = try await makeLoadedStore()

        store.beginCreatingBead()
        var draft = try XCTUnwrap(store.creationDraft)
        draft.title = "Draft bead"
        store.creationDraft = draft

        store.select(["bd-parent"])
        await store.waitForPendingQueryRecompute()

        XCTAssertNil(store.creationDraft)
        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))

        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertEqual(store.creationDraft?.title, "Draft bead")
        XCTAssertTrue(store.canGoForward)

        store.goForward()
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))
        XCTAssertNil(store.creationDraft)
    }

    func testRevealIssueRecordsReversibleHistoryStep() async throws {
        let store = try await makeLoadedStore()

        store.applyBookmark(.closed)
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.selectedBookmark, .closed)

        store.revealIssue(id: "bd-child")
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedBookmark, .all)
        XCTAssertEqual(store.selectedIDs, Set(["bd-child"]))
        XCTAssertTrue(store.canGoBack)

        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedBookmark, .closed)
        XCTAssertTrue(store.selectedIDs.isEmpty)
    }

    func testShowStateValueBeadsCreatesExactReversibleWorkspaceStep() async throws {
        let store = try await makeLoadedStore()

        store.searchText = "Parent"
        store.statusFilters = ["open"]
        await store.waitForPendingQueryRecompute()
        let previousSnapshot = try XCTUnwrap(store.currentWorkspaceSnapshot)

        XCTAssertTrue(store.showBeads(withStateValue: "implementation", in: "phase"))
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedBookmark, .all)
        XCTAssertEqual(store.labelFilters, ["phase:implementation"])
        XCTAssertTrue(store.statusFilters.isEmpty)
        XCTAssertTrue(store.typeFilters.isEmpty)
        XCTAssertTrue(store.priorityFilters.isEmpty)
        XCTAssertEqual(store.searchText, "")
        XCTAssertEqual(store.filteredIssueIDs, ["bd-child"])

        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.currentWorkspaceSnapshot, previousSnapshot)
        XCTAssertEqual(store.searchText, "Parent")
        XCTAssertEqual(store.statusFilters, ["open"])

        store.goForward()
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedBookmark, .all)
        XCTAssertEqual(store.labelFilters, ["phase:implementation"])
        XCTAssertTrue(store.statusFilters.isEmpty)
        XCTAssertEqual(store.filteredIssueIDs, ["bd-child"])
    }

    func testFullPageDetailRecordsReversibleHistoryStep() async throws {
        let store = try await makeLoadedStore()

        store.openFullPageDetail(issueID: "bd-parent")
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))
        XCTAssertEqual(store.fullPageDetailIssueID, "bd-parent")
        XCTAssertTrue(store.canGoBack)
        XCTAssertFalse(store.canGoForward)

        store.goBack()
        await store.waitForPendingQueryRecompute()

        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertNil(store.fullPageDetailIssueID)
        XCTAssertFalse(store.canGoBack)
        XCTAssertTrue(store.canGoForward)

        store.goForward()
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))
        XCTAssertEqual(store.fullPageDetailIssueID, "bd-parent")
    }

    func testSelectionClearsFullPageDetailMode() async throws {
        let store = try await makeLoadedStore()

        store.openFullPageDetail(issueID: "bd-parent")
        await store.waitForPendingQueryRecompute()

        store.select(["bd-child"])
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedIDs, Set(["bd-child"]))
        XCTAssertNil(store.fullPageDetailIssueID)
    }

    private func makeLoadedStore() async throws -> BeadStore {
        let projectURL = try makeProject(
            issuesJSONL: """
            {"_type":"issue","id":"bd-parent","title":"Parent","status":"open","priority":1,"issue_type":"epic"}
            {"_type":"issue","id":"bd-child","title":"Child","status":"open","priority":2,"issue_type":"task","parent_id":"bd-parent","labels":["phase:implementation"]}
            {"_type":"issue","id":"bd-sibling","title":"Sibling","status":"open","priority":3,"issue_type":"task"}
            """
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL)
        }

        let store = BeadStore(
            userDefaults: makeUserDefaults(),
            commands: CurrentDoltTestCommands()
        )
        store.openProject(projectURL)
        try await waitForStoreToLoad(store)
        return store
    }

    private func waitForStoreToLoad(
        _ store: BeadStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while store.isLoading || store.issueListRows.isEmpty {
            if Date() > deadline {
                XCTFail("Timed out waiting for BeadStore to load test project", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(store.lastError, file: file, line: line)
    }

    private func makeProject(issuesJSONL: String) throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadazzleTests-\(UUID().uuidString)", isDirectory: true)
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
        let suiteName = "BeadazzleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
