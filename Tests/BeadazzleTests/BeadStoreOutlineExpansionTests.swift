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

    func testOutlineChildDisplayPreferenceHidesExpandedChildrenThatDoNotMatchThePreset() async throws {
        let store = try await makeLoadedStore(
            issuesJSONL: """
            {"_type":"issue","id":"bd-parent","title":"Parent","status":"open","priority":1,"issue_type":"epic"}
            {"_type":"issue","id":"bd-closed-child","title":"Closed child","status":"closed","priority":2,"issue_type":"task","parent_id":"bd-parent","closed_at":"2026-07-01T00:00:00Z"}
            """
        )

        store.applyBookmark(.open)
        await store.waitForPendingQueryRecompute()
        store.select(["bd-parent"])
        XCTAssertTrue(store.expandSelectedIssueChildren())
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent", "bd-closed-child"])

        store.showsAllChildrenInOutline = false
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent"])
        XCTAssertEqual(store.issueListRows.first?.hasChildren, false)
        XCTAssertEqual(store.issueListRows.first?.isExpanded, false)
        XCTAssertFalse(store.canExpandSelectedIssueChildren)
        XCTAssertFalse(store.expandSelectedIssueChildren())
    }

    func testSelectedIssueExpansionCommandsIgnoreUnsupportedSelectionsAndModes() async throws {
        let store = try await makeLoadedStore()

        store.select(["bd-parent", "bd-child"])
        XCTAssertFalse(store.canExpandSelectedIssueChildren)
        XCTAssertFalse(store.canCollapseSelectedIssueChildren)
        XCTAssertFalse(store.expandSelectedIssueChildren())
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent"])

        store.select(["bd-child"])
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent", "bd-child"])
        XCTAssertFalse(store.canExpandSelectedIssueChildren)
        XCTAssertFalse(store.canCollapseSelectedIssueChildren)
        XCTAssertFalse(store.expandSelectedIssueChildren())
        XCTAssertFalse(store.collapseSelectedIssueChildren())

        store.select(["bd-parent"])
        store.issueListMode = .flat
        XCTAssertFalse(store.canExpandSelectedIssueChildren)
        XCTAssertFalse(store.canCollapseSelectedIssueChildren)
        XCTAssertFalse(store.expandSelectedIssueChildren())
        XCTAssertFalse(store.collapseSelectedIssueChildren())
    }

    func testSelectingVisibleStaleChildDoesNotRevealFreshSiblings() async throws {
        let store = try await makeLoadedStore(
            issuesJSONL: """
            {"_type":"issue","id":"bd-parent","title":"Parent","status":"open","priority":1,"issue_type":"epic","updated_at":"2099-01-01T00:00:00Z"}
            {"_type":"issue","id":"bd-stale-child","title":"Stale child","status":"open","priority":2,"issue_type":"task","parent_id":"bd-parent","updated_at":"2020-01-01T00:00:00Z"}
            {"_type":"issue","id":"bd-fresh-sibling","title":"Fresh sibling","status":"open","priority":2,"issue_type":"task","parent_id":"bd-parent","updated_at":"2099-01-01T00:00:00Z"}
            """
        )

        store.applyBookmark(.stale)
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent", "bd-stale-child"])

        store.select(["bd-stale-child"])
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.selectedIDs, ["bd-stale-child"])
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-parent", "bd-stale-child"])
        XCTAssertFalse(store.issueListRows.contains { $0.issueID == "bd-fresh-sibling" })
    }

    func testParentIssueUsesParentIDField() async throws {
        let store = try await makeLoadedStore()

        let childParent = store.parentIssue(for: "bd-child")
        let rootParent = store.parentIssue(for: "bd-parent")
        let presentation = ParentBeadPresentation(issue: try XCTUnwrap(childParent))

        XCTAssertEqual(childParent?.id, "bd-parent")
        XCTAssertNil(rootParent)
        XCTAssertEqual(presentation.id, "bd-parent")
        XCTAssertEqual(presentation.helpText, "Open parent bead bd-parent: Parent")
        XCTAssertEqual(presentation.accessibilityValue, "bd-parent: Parent")
    }

    func testParentIssueUsesParentChildDependencyWhenParentIDIsMissing() async throws {
        let store = try await makeLoadedStore(
            issuesJSONL: """
            {"_type":"issue","id":"bd-parent","title":"Parent","status":"open","priority":1,"issue_type":"epic"}
            {"_type":"issue","id":"bd-child","title":"Child","status":"open","priority":2,"issue_type":"task","dependencies":[{"issue_id":"bd-child","depends_on_id":"bd-parent","type":"parent-child"}]}
            """
        )

        XCTAssertEqual(store.parentIssue(for: "bd-child")?.id, "bd-parent")
    }

    func testOpenIssueFromDetailPreservesSplitDetailMode() async throws {
        let store = try await makeLoadedStore()

        store.select(["bd-child"])
        store.openIssueFromDetail(issueID: "bd-parent")

        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))
        XCTAssertNil(store.fullPageDetailIssueID)
    }

    func testOpenIssueFromDetailPreservesFullPageDetailMode() async throws {
        let store = try await makeLoadedStore()

        store.openFullPageDetail(issueID: "bd-child")
        store.openIssueFromDetail(issueID: "bd-parent")

        XCTAssertEqual(store.selectedIDs, Set(["bd-parent"]))
        XCTAssertEqual(store.fullPageDetailIssueID, "bd-parent")
    }

    private func makeLoadedStore() async throws -> BeadStore {
        return try await makeLoadedStore(
            issuesJSONL: """
            {"_type":"issue","id":"bd-parent","title":"Parent","status":"open","priority":1,"issue_type":"epic"}
            {"_type":"issue","id":"bd-child","title":"Child","status":"open","priority":2,"issue_type":"task","parent_id":"bd-parent"}
            """
        )
    }

    private func makeLoadedStore(issuesJSONL: String) async throws -> BeadStore {
        try await makeLoadedBeadStore(issuesJSONL: issuesJSONL)
    }
}
