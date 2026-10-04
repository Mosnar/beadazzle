import AppKit
import XCTest
@testable import Beadazzle

@MainActor
final class IssueListGateRowsTests: XCTestCase {
    func testBothGateOccurrencesOpenAndDragTheSameBead() async throws {
        let harness = try await makeGateHarness()
        for gateID in ["gate-a", "gate-b"] {
            try harness.select("shared", parentGateID: gateID)
            XCTAssertEqual(harness.store.selectedIDs, ["shared"])
            XCTAssertEqual(harness.selectedRowIDs, [rowID("shared", parentGateID: gateID)])

            harness.coordinator.openRow(harness.table.selectedRow)
            XCTAssertEqual(harness.actions.opened.last, "shared")

            let writer = try XCTUnwrap(
                harness.coordinator.pasteboardWriter(forRow: harness.table.selectedRow) as? NSPasteboardItem
            )
            let data = try XCTUnwrap(writer.data(forType: .beadazzleBeadDrag))
            let payload = try JSONDecoder().decode(BeadDragPayload.self, from: data)
            XCTAssertEqual(payload.issueIDs, ["shared"])
        }
    }

    func testSelectionStaysWithItsGateWhenOtherRowsCollapseAndExpand() async throws {
        let harness = try await makeGateHarness()
        try harness.select("shared", parentGateID: "gate-b")

        harness.store.setIssueExpansion(issueID: "gate-a", isExpanded: false)
        await harness.settle()
        XCTAssertEqual(harness.selectedRowIDs, [rowID("shared", parentGateID: "gate-b")])
        XCTAssertEqual(harness.store.selectedIDs, ["shared"])

        harness.store.setIssueExpansion(issueID: "gate-a", isExpanded: true)
        await harness.settle()
        XCTAssertEqual(harness.selectedRowIDs, [rowID("shared", parentGateID: "gate-b")])

        harness.store.setIssueExpansion(issueID: "gate-b", isExpanded: false)
        await harness.settle()
        XCTAssertEqual(harness.selectedRowIDs, [rowID("shared", parentGateID: "gate-a")])
        XCTAssertEqual(harness.store.selectedIDs, ["shared"])
    }

    func testArrowsNavigateWithinTheSelectedGate() async throws {
        let harness = try await makeGateHarness()
        try harness.select("gate-b")

        XCTAssertTrue(harness.coordinator.navigateOutline(.right))
        harness.refresh()
        XCTAssertEqual(harness.selectedRowIDs, [rowID("shared", parentGateID: "gate-b")])
        XCTAssertEqual(harness.store.selectedIDs, ["shared"])

        XCTAssertTrue(harness.coordinator.navigateOutline(.left))
        harness.refresh()
        XCTAssertEqual(harness.selectedRowIDs, [rowID("gate-b")])

        XCTAssertTrue(harness.coordinator.navigateOutline(.left))
        await harness.settle()
        XCTAssertFalse(harness.visibleRowIDs.contains(rowID("shared", parentGateID: "gate-b")))
        XCTAssertEqual(harness.store.selectedIDs, ["gate-b"])

        XCTAssertTrue(harness.coordinator.navigateOutline(.right))
        await harness.settle()
        XCTAssertTrue(harness.visibleRowIDs.contains(rowID("shared", parentGateID: "gate-b")))
        XCTAssertTrue(harness.coordinator.navigateOutline(.right))
        harness.refresh()
        XCTAssertEqual(harness.selectedRowIDs, [rowID("shared", parentGateID: "gate-b")])
    }

    func testMenuExpansionUsesTheSelectedGateOccurrenceWithAFlatListPreference() async throws {
        let harness = try await makeGateHarness(gateBIsBlocked: true)
        XCTAssertEqual(harness.store.issueListMode, .flat)
        XCTAssertEqual(harness.store.effectiveIssueListMode, .outline)

        try harness.select("gate-b", parentGateID: "gate-a")
        XCTAssertFalse(harness.store.canExpandSelectedIssueChildren)
        XCTAssertFalse(harness.store.canCollapseSelectedIssueChildren)

        // The bead ID is unchanged, but this occurrence owns the gate's children.
        try harness.select("gate-b")
        XCTAssertTrue(harness.store.canCollapseSelectedIssueChildren)
        XCTAssertTrue(harness.store.collapseSelectedIssueChildren())
        await harness.settle()
        XCTAssertFalse(harness.visibleRowIDs.contains(rowID("shared", parentGateID: "gate-b")))
        XCTAssertTrue(harness.visibleRowIDs.contains(rowID("shared", parentGateID: "gate-a")))
        XCTAssertEqual(harness.selectedRowIDs, [rowID("gate-b")])

        XCTAssertTrue(harness.store.canExpandSelectedIssueChildren)
        XCTAssertTrue(harness.store.expandSelectedIssueChildren())
        await harness.settle()
        XCTAssertTrue(harness.visibleRowIDs.contains(rowID("shared", parentGateID: "gate-b")))

        try harness.select("gate-b", parentGateID: "gate-a")
        XCTAssertFalse(harness.store.canCollapseSelectedIssueChildren)
        XCTAssertFalse(harness.store.collapseSelectedIssueChildren())
    }

    func testSelectingBothOccurrencesStillRequestsOneBeadAction() async throws {
        let harness = try await makeGateHarness()
        let sharedRows = Set([rowID("shared", parentGateID: "gate-a"), rowID("shared", parentGateID: "gate-b")])
        let indices = IndexSet(harness.visibleRowIDs.indices.filter { sharedRows.contains(harness.visibleRowIDs[$0]) })
        harness.table.selectRowIndexes(indices, byExtendingSelection: false)
        harness.refresh()
        XCTAssertEqual(harness.selectedRowIDs, sharedRows)
        XCTAssertEqual(harness.store.selectedIDs, ["shared"])

        let menu = try XCTUnwrap(harness.coordinator.contextMenu(forClickedRow: harness.table.selectedRow))
        let deleteIndex = try XCTUnwrap(menu.items.firstIndex {
            $0.action == NSSelectorFromString("deleteContextBeads:")
        })
        menu.performActionForItem(at: deleteIndex)
        harness.coordinator.menuDidClose(menu)

        XCTAssertEqual(harness.actions.deleted, [["shared"]])
        XCTAssertEqual(harness.selectedRowIDs, sharedRows)
    }

    func testMenuSelectionFollowsTheVisibleOccurrenceAfterFiltering() async throws {
        let harness = try await makeGateHarness(gateBIsBlocked: true)
        try harness.select("gate-b")
        XCTAssertTrue(harness.store.canCollapseSelectedIssueChildren)

        harness.store.searchText = "A gate"
        await harness.settle()
        XCTAssertEqual(harness.selectedRowIDs, [rowID("gate-b", parentGateID: "gate-a")])
        XCTAssertFalse(harness.store.canCollapseSelectedIssueChildren)

        harness.store.searchText = ""
        await harness.settle()
        XCTAssertTrue(harness.visibleRowIDs.contains(rowID("gate-b")))
        XCTAssertEqual(harness.selectedRowIDs, [rowID("gate-b", parentGateID: "gate-a")])
        XCTAssertFalse(harness.store.canCollapseSelectedIssueChildren)
        XCTAssertFalse(harness.store.collapseSelectedIssueChildren())
    }

    func testDuplicateInputRowDoesNotCrashOrRemoveTheOtherGateOccurrence() async throws {
        let harness = try await makeGateHarness()
        let originalRows = harness.store.issueListRows
        let repeated = try XCTUnwrap(originalRows.first { $0.issueID == "shared" })
        harness.store._issueListRows += [repeated]
        harness.refresh()

        XCTAssertEqual(harness.visibleRowIDs, originalRows.map(\.id))
        try harness.select("shared", parentGateID: "gate-b")
        harness.coordinator.openRow(harness.table.selectedRow)
        XCTAssertEqual(harness.actions.opened, ["shared"])
    }

    func testOrdinaryOutlineArrowsExpandNavigateAndCollapse() async throws {
        let store = try await makeLoadedBeadStore(issuesJSONL: """
        {"id":"parent","title":"Parent","status":"open","priority":1,"issue_type":"epic"}
        {"id":"child","title":"Child","status":"open","priority":2,"issue_type":"task","parent_id":"parent"}
        """)
        let harness = try IssueListTableHarness(store: store)
        try harness.select("parent")

        XCTAssertTrue(harness.coordinator.navigateOutline(.right))
        await harness.settle()
        XCTAssertTrue(harness.visibleRowIDs.contains(rowID("child")))
        XCTAssertEqual(harness.store.selectedIDs, ["parent"])

        XCTAssertTrue(harness.coordinator.navigateOutline(.right))
        harness.refresh()
        XCTAssertEqual(harness.selectedRowIDs, [rowID("child")])
        XCTAssertFalse(harness.coordinator.navigateOutline(.right))
        XCTAssertTrue(harness.coordinator.navigateOutline(.left))
        harness.refresh()
        XCTAssertEqual(harness.store.selectedIDs, ["parent"])

        XCTAssertTrue(harness.coordinator.navigateOutline(.left))
        await harness.settle()
        XCTAssertEqual(harness.visibleRowIDs, [rowID("parent")])
        XCTAssertFalse(harness.coordinator.navigateOutline(.left))

        store.issueListMode = .flat
        await harness.settle()
        let flatRows = harness.visibleRowIDs
        XCTAssertFalse(harness.coordinator.navigateOutline(.right))
        XCTAssertFalse(harness.coordinator.navigateOutline(.left))
        await harness.settle()
        XCTAssertEqual(harness.visibleRowIDs, flatRows)
        XCTAssertEqual(harness.store.selectedIDs, ["parent"])
    }

    func testFilteringOutSelectionKeepsDetailAndRestoresTheVisibleSelection() async throws {
        let store = try await makeLoadedBeadStore(issuesJSONL: """
        {"id":"selected","title":"Selected","status":"open","priority":1,"issue_type":"epic"}
        {"id":"child","title":"Child","status":"open","priority":1,"issue_type":"task","parent_id":"selected"}
        {"id":"other","title":"Other","status":"open","priority":2,"issue_type":"task"}
        """)
        let harness = try IssueListTableHarness(store: store)
        try harness.select("selected")
        XCTAssertTrue(store.canExpandSelectedIssueChildren)

        store.setPriorityFilter(2, isOn: true)
        await harness.settle()
        XCTAssertEqual(harness.visibleRowIDs, [rowID("other")])
        XCTAssertTrue(harness.selectedRowIDs.isEmpty)
        XCTAssertEqual(store.selectedIssue?.id, "selected")
        XCTAssertFalse(store.canExpandSelectedIssueChildren)
        XCTAssertFalse(store.canCollapseSelectedIssueChildren)

        store.clearFilters()
        await harness.settle()
        XCTAssertEqual(harness.selectedRowIDs, [rowID("selected")])
        XCTAssertTrue(store.canExpandSelectedIssueChildren)
    }

    private func rowID(_ issueID: String, parentGateID: String? = nil) -> IssueListRow.ID {
        IssueListRow.ID(issueID: issueID, parentGateID: parentGateID)
    }

    private func makeGateHarness(gateBIsBlocked: Bool = false) async throws -> IssueListTableHarness {
        let gateDependency = gateBIsBlocked
            ? #", "dependencies":[{"issue_id":"gate-b","depends_on_id":"gate-a","type":"blocks"}]"#
            : ""
        let store = try await makeLoadedBeadStore(issuesJSONL: """
        {"id":"gate-a","title":"A gate","status":"open","priority":2,"issue_type":"gate","await_type":"human"}
        {"id":"gate-b","title":"B gate","status":"open","priority":2,"issue_type":"gate","await_type":"human"\(gateDependency)}
        {"id":"shared","title":"Shared bead","status":"open","priority":2,"issue_type":"task","dependencies":[{"issue_id":"shared","depends_on_id":"gate-a","type":"blocks"},{"issue_id":"shared","depends_on_id":"gate-b","type":"blocks"}]}
        """, requiresVisibleRows: false)
        store.issueListMode = .flat
        store.applyBookmark(.gates)
        await store.waitForPendingQueryRecompute()
        return try IssueListTableHarness(store: store)
    }
}

@MainActor
private final class IssueListTableActions {
    var opened: [String] = []
    var deleted: [Set<String>] = []
}

@MainActor
private final class IssueListTableHarness {
    let store: BeadStore
    let actions: IssueListTableActions
    let coordinator: IssueListTableView.Coordinator
    let scrollView: NSScrollView
    let table: NSTableView
    private let dataSource: IssueListDiffableDataSource

    var visibleRowIDs: [IssueListRow.ID] { dataSource.snapshot().itemIdentifiers }
    var selectedRowIDs: Set<IssueListRow.ID> {
        Set(table.selectedRowIndexes.compactMap { dataSource.itemIdentifier(forRow: $0) })
    }

    init(store: BeadStore) throws {
        self.store = store
        let actions = IssueListTableActions()
        self.actions = actions
        let view = Self.makeView(store: store, actions: actions)
        coordinator = view.makeCoordinator()
        scrollView = view.makeScrollView(coordinator: coordinator)
        table = try XCTUnwrap(scrollView.documentView as? NSTableView)
        dataSource = try XCTUnwrap(table.dataSource as? IssueListDiffableDataSource)
    }

    func select(_ issueID: String, parentGateID: String? = nil) throws {
        let id = IssueListRow.ID(issueID: issueID, parentGateID: parentGateID)
        let row = try XCTUnwrap(visibleRowIDs.firstIndex(of: id))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        refresh()
    }

    func settle() async {
        await store.filterTask?.value
        await store.waitForPendingQueryRecompute()
        refresh()
    }

    func refresh() {
        coordinator.parent = Self.makeView(store: store, actions: actions)
        coordinator.update(force: false)
    }

    private static func makeView(store: BeadStore, actions: IssueListTableActions) -> IssueListTableView {
        IssueListTableView(
            rows: store.issueListRows,
            rowRevision: store.workspace.issueListRowsRevision,
            selectedIDs: store.selectedIDs,
            bookmark: store.effectiveIssueListBookmark,
            mode: store.effectiveIssueListMode,
            displayOptions: .compact,
            contentRevision: store.project.contentRevision,
            gateClock: .distantPast,
            store: store,
            requestClose: { _ in },
            requestSetStatus: { _, _ in },
            requestBulkEdit: { _, _ in },
            requestDelete: { actions.deleted.append($0) },
            openDetail: { actions.opened.append($0) }
        )
    }
}
