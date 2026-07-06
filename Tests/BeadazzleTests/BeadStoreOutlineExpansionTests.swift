import Foundation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadStoreOutlineExpansionTests: XCTestCase {
    func testExpandSelectedIssueChildrenShowsChildrenForSingleSelectedParent() async throws {
        let store = try await makeLoadedStore()

        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent"])

        store.select(["bd-parent"])
        XCTAssertTrue(store.canExpandSelectedIssueChildren)
        XCTAssertFalse(store.canCollapseSelectedIssueChildren)

        let didExpand = store.expandSelectedIssueChildren()
        await store.waitForPendingQueryRecompute()

        XCTAssertTrue(didExpand)
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent", "bd-child"])
        XCTAssertFalse(store.canExpandSelectedIssueChildren)
        XCTAssertTrue(store.canCollapseSelectedIssueChildren)
        XCTAssertFalse(store.expandSelectedIssueChildren())
    }

    func testCollapseSelectedIssueChildrenHidesChildrenForSingleSelectedParent() async throws {
        let store = try await makeLoadedStore()

        store.select(["bd-parent"])
        XCTAssertTrue(store.expandSelectedIssueChildren())
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent", "bd-child"])

        let didCollapse = store.collapseSelectedIssueChildren()
        await store.waitForPendingQueryRecompute()

        XCTAssertTrue(didCollapse)
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent"])
        XCTAssertTrue(store.canExpandSelectedIssueChildren)
        XCTAssertFalse(store.canCollapseSelectedIssueChildren)
        XCTAssertFalse(store.collapseSelectedIssueChildren())
    }

    func testLoadedOutlineRowsCarryChildProgressThroughExpansion() async throws {
        let store = try await makeLoadedStore()
        let expected = IssueChildProgress(completedCount: 0, workedCount: 0, totalCount: 1)

        XCTAssertEqual(store.issueListRows.first { $0.issueID == "bd-parent" }?.childProgress, expected)

        store.select(["bd-parent"])
        XCTAssertTrue(store.expandSelectedIssueChildren())
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.issueListRows.first { $0.issueID == "bd-parent" }?.childProgress, expected)
        XCTAssertNil(store.issueListRows.first { $0.issueID == "bd-child" }?.childProgress)
    }

    func testRightArrowNavigationExpandsParentThenSelectsFirstChild() async throws {
        let store = try await makeLoadedStore()

        store.select(["bd-parent"])
        XCTAssertTrue(store.navigateIssueOutlineRight())
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent", "bd-child"])
        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))

        XCTAssertTrue(store.navigateIssueOutlineRight())
        XCTAssertEqual(store.selectedIDs, Set(["bd-child"]))
        XCTAssertFalse(store.navigateIssueOutlineRight())
    }

    func testLeftArrowNavigationSelectsParentThenCollapsesExpandedParent() async throws {
        let store = try await makeLoadedStore()

        store.select(["bd-parent"])
        XCTAssertTrue(store.navigateIssueOutlineRight())
        await store.waitForPendingQueryRecompute()
        XCTAssertTrue(store.navigateIssueOutlineRight())
        XCTAssertEqual(store.selectedIDs, Set(["bd-child"]))

        XCTAssertTrue(store.navigateIssueOutlineLeft())
        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent", "bd-child"])

        XCTAssertTrue(store.navigateIssueOutlineLeft())
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent"])
        XCTAssertFalse(store.navigateIssueOutlineLeft())
    }

    func testSelectedIssueExpansionCommandsIgnoreUnsupportedSelectionsAndModes() async throws {
        let store = try await makeLoadedStore()

        store.select(["bd-parent", "bd-child"])
        XCTAssertFalse(store.canExpandSelectedIssueChildren)
        XCTAssertFalse(store.canCollapseSelectedIssueChildren)
        XCTAssertFalse(store.expandSelectedIssueChildren())
        XCTAssertFalse(store.navigateIssueOutlineRight())
        XCTAssertFalse(store.navigateIssueOutlineLeft())
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent"])

        store.select(["bd-child"])
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent", "bd-child"])
        XCTAssertFalse(store.canExpandSelectedIssueChildren)
        XCTAssertFalse(store.canCollapseSelectedIssueChildren)
        XCTAssertFalse(store.expandSelectedIssueChildren())
        XCTAssertFalse(store.collapseSelectedIssueChildren())
        XCTAssertFalse(store.navigateIssueOutlineRight())

        store.select(["bd-parent"])
        store.issueListMode = .flat
        XCTAssertFalse(store.canExpandSelectedIssueChildren)
        XCTAssertFalse(store.canCollapseSelectedIssueChildren)
        XCTAssertFalse(store.expandSelectedIssueChildren())
        XCTAssertFalse(store.collapseSelectedIssueChildren())
        XCTAssertFalse(store.navigateIssueOutlineRight())
        XCTAssertFalse(store.navigateIssueOutlineLeft())
    }

    private func makeLoadedStore() async throws -> BeadStore {
        let projectURL = try makeProject(
            issuesJSONL: """
            {"_type":"issue","id":"bd-parent","title":"Parent","status":"open","priority":1,"issue_type":"epic"}
            {"_type":"issue","id":"bd-child","title":"Child","status":"open","priority":2,"issue_type":"task","parent_id":"bd-parent"}
            """
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL)
        }

        let store = BeadStore(userDefaults: makeUserDefaults())
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
