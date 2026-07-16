import Foundation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadStoreWorkspaceRestoreTests: XCTestCase {
    private let issuesJSONL = """
    {"_type":"issue","id":"bd-parent","title":"Parent","status":"open","priority":1,"issue_type":"epic"}
    {"_type":"issue","id":"bd-child","title":"Child","status":"open","priority":2,"issue_type":"task","parent_id":"bd-parent"}
    {"_type":"issue","id":"bd-sibling","title":"Sibling","status":"open","priority":3,"issue_type":"task"}
    """

    func testReopeningProjectRestoresPersistedWorkspaceState() async throws {
        let projectURL = try makeProject(issuesJSONL: issuesJSONL)
        let defaults = makeUserDefaults()

        let firstStore = BeadStore(userDefaults: defaults)
        firstStore.openProject(projectURL)
        try await waitForStoreToLoad(firstStore)

        firstStore.issueListMode = .flat
        firstStore.sort = .title
        firstStore.sortDirection = .descending
        firstStore.setStatusFilter("open", isOn: true)
        firstStore.setIssueExpansion(issueID: "bd-parent", isExpanded: true)
        firstStore.select(["bd-child"])
        await firstStore.waitForPendingQueryRecompute()

        try await waitForPersistedWorkspaceState(firstStore, projectURL: projectURL) {
            $0.selectedIDs.contains("bd-child") && $0.issueListMode == .flat
        }

        let secondStore = BeadStore(userDefaults: defaults)
        secondStore.openProject(projectURL)
        try await waitForStoreToLoad(secondStore)

        XCTAssertEqual(secondStore.issueListMode, .flat)
        XCTAssertEqual(secondStore.sort, .title)
        XCTAssertEqual(secondStore.sortDirection, .descending)
        XCTAssertEqual(secondStore.statusFilters, Set(["open"]))
        XCTAssertEqual(secondStore.selectedIDs, Set(["bd-child"]))
        XCTAssertTrue(secondStore.outlineState.expandedIssueIDs.contains("bd-parent"))
    }

    func testPartialRestorationDropsDeletedReferences() async throws {
        let projectURL = try makeProject(issuesJSONL: issuesJSONL)
        let defaults = makeUserDefaults()

        // Persist a payload that points at an issue that no longer exists.
        var outline = BeadOutlineSelectionState()
        outline.setExpansion(issueID: "bd-deleted", isExpanded: true)
        outline.setExpansion(issueID: "bd-parent", isExpanded: true)
        let snapshot = BeadWorkspaceSnapshot(
            bookmark: .all,
            activeSavedViewID: nil,
            sourceSavedViewID: nil,
            savedViewOrdering: nil,
            selectedIDs: ["bd-deleted", "bd-child"],
            fullPageDetailIssueID: "bd-deleted",
            searchText: "",
            statusFilters: ["open"],
            typeFilters: [],
            priorityFilters: [],
            labelFilters: [],
            advancedPredicate: nil,
            sort: .priority,
            sortDirection: .ascending,
            issueListMode: .outline,
            outlineState: outline,
            creationDraft: nil
        )
        BeadWorkspaceStateRepository(userDefaults: defaults)
            .save(BeadWorkspaceStatePayload(snapshot: snapshot), projectURL: projectURL)

        let store = BeadStore(userDefaults: defaults)
        store.openProject(projectURL)
        try await waitForStoreToLoad(store)

        XCTAssertEqual(store.selectedIDs, Set(["bd-child"]))
        XCTAssertNil(store.fullPageDetailIssueID)
        XCTAssertEqual(store.statusFilters, Set(["open"]))
        XCTAssertTrue(store.outlineState.expandedIssueIDs.contains("bd-parent"))
        XCTAssertFalse(store.outlineState.expandedIssueIDs.contains("bd-deleted"))
        XCTAssertFalse(store.issueListRows.isEmpty)
    }

    func testResetSavedWorkspaceStateClearsPersistenceAndLiveState() async throws {
        let projectURL = try makeProject(issuesJSONL: issuesJSONL)
        let defaults = makeUserDefaults()

        let store = BeadStore(userDefaults: defaults)
        store.openProject(projectURL)
        try await waitForStoreToLoad(store)

        store.issueListMode = .flat
        store.setStatusFilter("open", isOn: true)
        store.select(["bd-child"])
        await store.waitForPendingQueryRecompute()
        try await waitForPersistedWorkspaceState(store, projectURL: projectURL) {
            $0.selectedIDs.contains("bd-child")
        }

        store.resetSavedWorkspaceState()
        await store.waitForPendingQueryRecompute()

        XCTAssertNil(store.workspaceStateRepository.load(projectURL: projectURL))
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertTrue(store.statusFilters.isEmpty)
        XCTAssertEqual(store.issueListMode, .outline)
        XCTAssertEqual(store.selectedBookmark, .ready)
    }

    func testSwitchingProjectsKeepsWorkspaceStateIndependent() async throws {
        let projectA = try makeProject(issuesJSONL: issuesJSONL)
        let projectB = try makeProject(issuesJSONL: issuesJSONL)
        let defaults = makeUserDefaults()

        let store = BeadStore(userDefaults: defaults)
        store.openProject(projectA)
        try await waitForStoreToLoad(store)
        store.searchText = "Sibling"
        await store.waitForPendingQueryRecompute()
        try await waitForPersistedWorkspaceState(store, projectURL: projectA) { $0.searchText == "Sibling" }

        store.openProject(projectB)
        try await waitForStoreToLoad(store)
        XCTAssertEqual(store.searchText, "")

        store.openProject(projectA)
        try await waitForStoreToLoad(store)
        XCTAssertEqual(store.searchText, "Sibling")
    }

    func testFlushPersistsPendingStateImmediatelyWithoutWaitingForDebounce() async throws {
        let projectURL = try makeProject(issuesJSONL: issuesJSONL)
        let defaults = makeUserDefaults()

        let store = BeadStore(userDefaults: defaults)
        store.openProject(projectURL)
        try await waitForStoreToLoad(store)

        store.searchText = "Sibling"
        store.flushPendingWorkspaceState()

        // No debounce wait: the flush must have written synchronously.
        XCTAssertEqual(store.workspaceStateRepository.load(projectURL: projectURL)?.searchText, "Sibling")
    }

    func testSwitchingProjectsFlushesOutgoingStateSynchronously() async throws {
        let projectA = try makeProject(issuesJSONL: issuesJSONL)
        let projectB = try makeProject(issuesJSONL: issuesJSONL)
        let defaults = makeUserDefaults()

        let store = BeadStore(userDefaults: defaults)
        store.openProject(projectA)
        try await waitForStoreToLoad(store)
        store.searchText = "Sibling"

        // Switch away before the 400ms debounce could fire; the switch must flush A first.
        store.openProject(projectB)

        XCTAssertEqual(store.workspaceStateRepository.load(projectURL: projectA)?.searchText, "Sibling")
    }

    // MARK: - Helpers

    private func waitForPersistedWorkspaceState(
        _ store: BeadStore,
        projectURL: URL,
        where predicate: (BeadWorkspaceStatePayload) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while true {
            if let payload = store.workspaceStateRepository.load(projectURL: projectURL), predicate(payload) {
                return
            }
            if Date() > deadline {
                XCTFail("Timed out waiting for workspace state to persist", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
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
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL)
        }
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
