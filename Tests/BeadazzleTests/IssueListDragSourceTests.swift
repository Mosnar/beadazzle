import XCTest
import UniformTypeIdentifiers
@testable import Beadazzle

@MainActor
final class IssueListDragSourceTests: XCTestCase {
    func testDataSourceAdvertisesNativeTableDragWriter() throws {
        let tableView = NSTableView()
        tableView.addTableColumn(NSTableColumn(identifier: .init("bead")))
        let dataSource = IssueListDiffableDataSource(tableView: tableView) {
            _, _, _, _ in NSView()
        }
        let payload = BeadDragPayload(
            projectIdentity: "/project",
            issueID: "bd-3",
            sourceFolderID: nil
        )
        dataSource.pasteboardWriter = { row in
            row == 0 ? BeadDragPasteboardItem.make(payload: payload) : nil
        }

        XCTAssertTrue(
            dataSource.responds(
                to: NSSelectorFromString("tableView:pasteboardWriterForRow:")
            )
        )
        let writer = try XCTUnwrap(
            dataSource.tableView(tableView, pasteboardWriterForRow: 0)
                as? NSPasteboardItem
        )
        let data = try XCTUnwrap(writer.data(forType: .beadazzleBeadDrag))
        XCTAssertEqual(
            try JSONDecoder().decode(BeadDragPayload.self, from: data),
            payload
        )
        XCTAssertNil(writer.data(forType: .init(UTType.json.identifier)))
        XCTAssertNil(dataSource.tableView(tableView, pasteboardWriterForRow: 1))
    }

    func testFolderDropsAdvertiseOnlyTheAppSpecificPayloadType() {
        XCTAssertEqual(BeadFolderDropHandler.contentTypes, [.beadazzleBeadDrag])
    }

    func testFolderDropCollectorRejectsIncompleteBatchWithoutPartialAcceptance() {
        let first = BeadDragPayload(
            projectIdentity: "/project",
            issueID: "bd-1",
            sourceFolderID: nil
        )
        var completions: [[BeadDragPayload]?] = []
        let collector = BeadFolderDropPayloadCollector(count: 2) {
            completions.append($0)
        }

        collector.receive(first, at: 0)
        XCTAssertTrue(completions.isEmpty)

        collector.receive(nil, at: 1)
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(completions[0])
    }

    func testFolderDropCollectorPreservesProviderOrderAndIgnoresDuplicateCallbacks() {
        let first = BeadDragPayload(
            projectIdentity: "/project",
            issueID: "bd-1",
            sourceFolderID: nil
        )
        let second = BeadDragPayload(
            projectIdentity: "/project",
            issueID: "bd-2",
            sourceFolderID: nil
        )
        var completions: [[BeadDragPayload]?] = []
        let collector = BeadFolderDropPayloadCollector(count: 2) {
            completions.append($0)
        }

        collector.receive(first, at: 0)
        collector.receive(second, at: 0)
        XCTAssertTrue(completions.isEmpty)

        collector.receive(second, at: 1)
        XCTAssertEqual(completions, [[first, second]])
    }

    func testIssueListRowRevisionChangesOnlyWithDerivedRowContent() {
        let store = makeStore()
        let first = row("bd-1")
        let second = row("bd-2")

        XCTAssertEqual(store.workspace.issueListRowsRevision, 0)
        store._issueListRows = [first]
        XCTAssertEqual(store.workspace.issueListRowsRevision, 1)

        store._issueListRows = [first]
        XCTAssertEqual(store.workspace.issueListRowsRevision, 1)

        store._issueListRows = [first, second]
        XCTAssertEqual(store.workspace.issueListRowsRevision, 2)
    }

    func testSelectionOnlyTableUpdateSkipsRowReconciliation() {
        let store = makeStore()
        let rows = [row("bd-1"), row("bd-2")]
        let initial = tableView(
            rows: rows,
            rowRevision: 1,
            selectedIDs: ["bd-1"],
            store: store
        )
        let coordinator = initial.makeCoordinator()

        coordinator.update(force: true)
        XCTAssertEqual(coordinator.rowReconciliationCount, 1)

        coordinator.parent = tableView(
            rows: rows,
            rowRevision: 1,
            selectedIDs: ["bd-2"],
            store: store
        )
        coordinator.update(force: false)
        XCTAssertEqual(coordinator.rowReconciliationCount, 1)

        coordinator.parent = tableView(
            rows: rows,
            rowRevision: 2,
            selectedIDs: ["bd-2"],
            store: store
        )
        coordinator.update(force: false)
        XCTAssertEqual(coordinator.rowReconciliationCount, 2)
    }

    func testBatchPayloadKeepsIssueIDsInSelectionOrder() {
        let payload = BeadDragPayload(
            projectIdentity: "/project",
            issueIDs: ["bd-3", "bd-1", "bd-8"],
            sourceFolderID: nil
        )

        XCTAssertEqual(payload.issueID, "bd-3")
        XCTAssertEqual(payload.issueIDs, ["bd-3", "bd-1", "bd-8"])
    }

    func testBatchPayloadRoundTripsThroughDragEncoding() throws {
        let folderID = UUID()
        let payload = BeadDragPayload(
            projectIdentity: "/project",
            issueIDs: ["bd-3", "bd-1", "bd-8"],
            sourceFolderID: folderID
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(BeadDragPayload.self, from: encoded)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.issueIDs, ["bd-3", "bd-1", "bd-8"])
        XCTAssertEqual(decoded.sourceFolderID, folderID)
    }

    private func row(_ issueID: String) -> IssueListRow {
        IssueListRow(
            issueID: issueID,
            depth: 0,
            hasChildren: false,
            childProgress: nil,
            isExpanded: false,
            isContext: false
        )
    }

    private func tableView(
        rows: [IssueListRow],
        rowRevision: Int,
        selectedIDs: Set<String>,
        store: BeadStore
    ) -> IssueListTableView {
        IssueListTableView(
            rows: rows,
            rowRevision: rowRevision,
            selectedIDs: selectedIDs,
            bookmark: .all,
            mode: .flat,
            displayOptions: .compact,
            contentRevision: 0,
            gateClock: Date(timeIntervalSince1970: 0),
            store: store,
            requestClose: { _ in },
            requestSetStatus: { _, _ in },
            requestBulkEdit: { _, _ in },
            requestDelete: { _ in },
            openDetail: { _ in }
        )
    }

    private func makeStore() -> BeadStore {
        let suiteName = "IssueListDragSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return BeadStore(userDefaults: defaults)
    }
}
