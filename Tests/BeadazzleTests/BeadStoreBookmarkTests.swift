import Foundation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadStoreBookmarkTests: XCTestCase {
    /// Regression: switching bookmarks used to schedule a counts-bearing recompute in
    /// `applyFilters()`, then — when the pruned selection collapsed to a single descendant
    /// whose ancestor needed expanding — fire a second (counts-less) recompute that
    /// canceled the first via the generation guard, leaving `filterCounts` stale from the
    /// previous bookmark. `applyBookmark` now settles selection + expansion first and
    /// recomputes exactly once (with counts).
    func testSwitchingBookmarksRefreshesFilterCountsWhenPrunedSelectionExpandsAnAncestor() async throws {
        let store = try await makeLoadedStore(
            issuesJSONL: """
            {"_type":"issue","id":"bd-parent","title":"Parent","status":"open","priority":1,"issue_type":"task"}
            {"_type":"issue","id":"bd-child","title":"Child","status":"open","priority":2,"issue_type":"task","parent_id":"bd-parent"}
            {"_type":"issue","id":"bd-closed","title":"Closed bug","status":"closed","priority":2,"issue_type":"bug"}
            """
        )

        store.applyBookmark(.all)
        await store.waitForPendingQueryRecompute()
        let allTypeTotal = store.filterCounts.typeCounts.reduce(0) { $0 + $1.1 }
        XCTAssertEqual(allTypeTotal, 3, "sanity: .all should count all three issues")

        // Multi-select a collapsed child + the closed bug. Multi-selection does not expand
        // ancestors, so bd-parent stays collapsed here.
        store.select(["bd-child", "bd-closed"])
        await store.waitForPendingQueryRecompute()

        // Switching bookmarks returns to the list, clearing the detail selection, and must
        // still refresh filterCounts exactly once (historically a second recompute here
        // canceled the first via the generation guard, leaving counts stale).
        store.applyBookmark(.open)
        await store.waitForPendingQueryRecompute()

        XCTAssertTrue(store.selectedIDs.isEmpty, "switching bookmarks returns to the list")

        let openTypeTotal = store.filterCounts.typeCounts.reduce(0) { $0 + $1.1 }
        XCTAssertEqual(
            openTypeTotal,
            2,
            "filterCounts must refresh to .open (parent+child = 2), not stay stale at .all's 3"
        )
    }

    func testDisclosureChangePreservesPendingFilterAndCountRecompute() async throws {
        let store = try await makeLoadedStore(
            issuesJSONL: """
            {"_type":"issue","id":"bd-parent","title":"Parent","status":"open","priority":1,"issue_type":"task"}
            {"_type":"issue","id":"bd-child","title":"Child","status":"open","priority":2,"issue_type":"task","parent_id":"bd-parent"}
            {"_type":"issue","id":"bd-closed","title":"Closed bug","status":"closed","priority":2,"issue_type":"bug"}
            """
        )

        store.applyBookmark(.all)
        // This rows-only request lands in the same main-actor turn as the full request.
        // It must carry the pending filtering, counts, and pruning work forward when it
        // cancels and replaces that task.
        store.setIssueExpansion(issueID: "bd-parent", isExpanded: true)
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.filteredIssueIDs.count, 3)
        XCTAssertEqual(store.filterCounts.typeCounts.reduce(0) { $0 + $1.1 }, 3)
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent", "bd-child", "bd-closed"])
    }

    func testSwitchingBookmarksClearsDetailSelectionToReturnToList() async throws {
        let store = try await makeLoadedStore(
            issuesJSONL: """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task"}
            {"_type":"issue","id":"bd-2","title":"Two","status":"closed","priority":2,"issue_type":"task"}
            """
        )

        store.applyBookmark(.all)
        await store.waitForPendingQueryRecompute()
        store.select(["bd-1"])
        await store.waitForPendingQueryRecompute()
        XCTAssertNotNil(store.selectedIssue, "sanity: on a detail page")

        // bd-1 is still present under .open, but choosing a bookmark should still return to
        // the list rather than stranding the user on the detail page.
        store.applyBookmark(.open)
        await store.waitForPendingQueryRecompute()

        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertNil(store.selectedIssue)
    }

    // MARK: - Harness

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
                XCTFail("Timed out waiting for BeadStore to load test project")
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(store.lastError)
        return store
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
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
