import AppKit
import SwiftUI

/// AppKit-backed issue list. SwiftUI's `List`/`Table` on macOS both drive `NSTableView`
/// with automatic row heights, so replacing the row set (bookmark switch, sort change)
/// runs an Auto Layout + SwiftUI sizing pass over *every* row — profiled as multi-second
/// main-thread hangs at ~1200 rows. This uses a fixed `rowHeight` with automatic heights
/// disabled, so updates are O(visible): total height is arithmetic and only on-screen
/// cells are ever realized. Rows reuse the existing SwiftUI `IssueRowView` inside a
/// reused `NSHostingView`; updates flow through an `NSTableViewDiffableDataSource`.
struct IssueListTableView: NSViewRepresentable {
    let rows: [IssueListRow]
    let rowRevision: Int
    let selectedIDs: Set<String>
    let bookmark: BeadBookmark
    let mode: IssueListMode
    let displayOptions: BeadListDisplayOptions
    let contentRevision: Int
    let gateClock: Date
    let store: BeadStore
    let requestClose: (BeadIssue) -> Void
    let requestSetStatus: (Set<String>, String) -> Void
    let requestBulkEdit: (Set<String>, BulkEditTarget) -> Void
    let requestDelete: (Set<String>) -> Void
    let openDetail: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let tableView = IssueKeyboardTableView()
        tableView.rowHeight = IssueListMetrics.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.headerView = nil
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.style = .inset
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.openClickedRow(_:))
        tableView.onNavigateOutline = { [weak coordinator] direction in
            coordinator?.navigateOutline(direction) ?? false
        }
        tableView.onContextTargetRowChange = { [weak coordinator] row in
            coordinator?.setContextFocusedRow(row)
        }
        tableView.onContextClickChange = { [weak coordinator] isActive in
            coordinator?.setContextClickActive(isActive)
        }
        tableView.contextMenuProvider = { [weak coordinator] row in
            coordinator?.contextMenu(forClickedRow: row)
        }
        tableView.registerForDraggedTypes([.beadazzleBeadDrag])
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let column = NSTableColumn(identifier: Coordinator.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let dataSource = IssueListDiffableDataSource(tableView: tableView) {
            [weak coordinator] table, _, _, itemID in
            coordinator?.makeCell(for: itemID, in: table) ?? NSView()
        }
        dataSource.pasteboardWriter = { [weak coordinator] row in
            coordinator?.pasteboardWriter(forRow: row)
        }
        tableView.onPrimaryMouseInteractionEnded = { [weak coordinator] in
            coordinator?.commitTableSelectionAfterPrimaryMouseInteraction()
        }
        dataSource.validateDrop = { [weak coordinator] info, row, operation in
            coordinator?.validateDrop(info, row: row, operation: operation) ?? []
        }
        dataSource.acceptDrop = { [weak coordinator] info, row, operation in
            coordinator?.acceptDrop(info, row: row, operation: operation) ?? false
        }
        tableView.dataSource = dataSource
        coordinator.tableView = tableView
        coordinator.dataSource = dataSource

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = true

        coordinator.update(force: true)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(force: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate {
        static let columnID = NSUserInterfaceItemIdentifier("bead")
        private static let cellID = NSUserInterfaceItemIdentifier("IssueRowCell")
        private static let rowViewID = NSUserInterfaceItemIdentifier("IssueListRowView")

        var parent: IssueListTableView
        fileprivate weak var tableView: IssueKeyboardTableView?
        fileprivate var dataSource: IssueListDiffableDataSource?

        private var orderedIDs: [String] = []
        private var indexByID: [String: Int] = [:]
        private var rowByID: [String: IssueListRow] = [:]
        private var readyGateGroupRange: Range<Int>?
        private var isSyncingSelection = false
        private var isHandlingContextClick = false
        private var contextFocusedIssueID: String?

        private var lastUpdateKey: UpdateKey?
        private(set) var rowReconciliationCount = 0

        init(_ parent: IssueListTableView) {
            self.parent = parent
        }

        /// Reconciles the table with `parent`. Reapplies the diffable snapshot only when the
        /// row identity/order changed, reconfigures visible cells only when row-derived or
        /// issue content changed, and always syncs selection. A selection-only update thus
        /// stays inside AppKit's native selection invalidation path.
        func update(force: Bool) {
            let updateKey = UpdateKey(parent: parent)
            let previousUpdateKey = lastUpdateKey
            guard force || updateKey != previousUpdateKey else {
                syncSelection(parent.selectedIDs)
                return
            }

            let rowsChanged = force || updateKey.rowRevision != previousUpdateKey?.rowRevision
            let globalPresentationChanged = force
                || updateKey.bookmark != previousUpdateKey?.bookmark
                || updateKey.mode != previousUpdateKey?.mode
                || updateKey.displayOptions != previousUpdateKey?.displayOptions
                || updateKey.contentRevision != previousUpdateKey?.contentRevision
                || updateKey.gateClock != previousUpdateKey?.gateClock
            let rows = parent.rows
            let previousRowByID = rowByID
            let previousIDs = orderedIDs

            if rowsChanged {
                rowReconciliationCount &+= 1
                let ids = rows.map(\.issueID)
                orderedIDs = ids
                indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
                rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.issueID, $0) })
                readyGateGroupRange = computeReadyGateGroupRange(rows)
                if let contextFocusedIssueID, indexByID[contextFocusedIssueID] == nil {
                    self.contextFocusedIssueID = nil
                }
            }

            var rebuiltAllVisible = false
            if rowsChanged, force || orderedIDs != previousIDs {
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(orderedIDs, toSection: 0)
                dataSource?.apply(snapshot, animatingDifferences: false)
                // A wholesale turnover (bookmark switch / sort / filter) deletes every old
                // item and inserts every new one, so `apply` already rebuilds all visible
                // cells fresh — the reconfigure pass below would just build them a second time.
                rebuiltAllVisible = force || isWholesaleChange(from: previousIDs, to: orderedIDs)
            }

            // Only cells the snapshot did NOT already rebuild need reconfiguring: rows that
            // survived (same id) but whose content changed — an edit (contentRevision), a
            // display-option/mode toggle, or a row field like expansion state.
            if !rebuiltAllVisible {
                reconfigureVisibleRows { id in
                    guard rowsChanged else { return globalPresentationChanged }
                    guard let previous = previousRowByID[id] else { return true }
                    return globalPresentationChanged || rowByID[id] != previous
                }
            }

            lastUpdateKey = updateKey

            syncSelection(parent.selectedIDs)
            updateVisibleFocusOutlines()
        }

        private struct UpdateKey: Equatable {
            let rowRevision: Int
            let bookmark: BeadBookmark
            let mode: IssueListMode
            let displayOptions: BeadListDisplayOptions
            let contentRevision: Int
            let gateClock: Date

            init(parent: IssueListTableView) {
                rowRevision = parent.rowRevision
                bookmark = parent.bookmark
                mode = parent.mode
                displayOptions = parent.displayOptions
                contentRevision = parent.contentRevision
                gateClock = parent.gateClock
            }
        }

        /// True when the old and new row sets overlap little (bookmark/filter change) or are
        /// the same set in a different order (sort) — cases where diffing costs more than a
        /// plain reload and scroll position isn't worth preserving.
        private func isWholesaleChange(from oldIDs: [String], to newIDs: [String]) -> Bool {
            let oldSet = Set(oldIDs)
            let newSet = Set(newIDs)
            if oldSet == newSet { return true } // pure reorder (sort)
            let common = oldSet.intersection(newSet).count
            return common * 2 < max(oldSet.count, newSet.count)
        }

        func makeCell(for itemID: String, in table: NSTableView) -> NSView {
            let cell: RowCellView
            if let reused = table.makeView(withIdentifier: Self.cellID, owner: self) as? RowCellView {
                cell = reused
            } else {
                cell = RowCellView()
                cell.identifier = Self.cellID
            }
            cell.representedIssueID = itemID
            cell.onContextFocusChange = { [weak self] issueID in
                self?.setContextFocusedIssueID(issueID)
            }
            cell.onContextClickChange = { [weak self] isActive in
                self?.setContextClickActive(isActive)
            }
            cell.rootView = rowView(for: itemID)
            return cell
        }

        /// Re-pushes fresh SwiftUI content into the on-screen cells matching `shouldReconfigure`.
        /// Handles content changes (e.g. a title/status edit, an expansion toggle) that leave a
        /// row's identity in place, which a diffable snapshot alone would not refresh.
        func reconfigureVisibleRows(where shouldReconfigure: (String) -> Bool) {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location..<(visible.location + visible.length) {
                guard row >= 0, row < orderedIDs.count else { continue }
                let id = orderedIDs[row]
                guard shouldReconfigure(id),
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? RowCellView
                else { continue }
                cell.rootView = rowView(for: id)
            }
        }

        private func rowView(for itemID: String) -> AnyView {
            guard let issue = parent.store.issue(with: itemID), let row = rowByID[itemID] else {
                return AnyView(Color.clear)
            }
            let isContextFocused = shouldShowFocusOutline(for: itemID)
            let store = parent.store
            if let gate = store.gate(for: itemID) {
                return chromedRowView(
                    content: GateRowView(
                        issue: issue,
                        row: row,
                        gate: gate,
                        now: parent.gateClock,
                        // Gate rows disclose their blocked beads in the Gates section.
                        showsDisclosure: parent.mode == .outline || parent.bookmark == .gates,
                        toggleExpansion: { store.toggleIssueExpansion(issueID: itemID, isExpanded: row.isExpanded) }
                    ),
                    itemID: itemID,
                    isContextFocused: isContextFocused
                )
            } else {
                let blockedByItems = store.activeBlockingIssues(for: itemID).map {
                    BlockingRelationshipItem(
                        issue: $0,
                        statusCategory: store.statusCategory(for: $0.status)
                    )
                }
                let blockingItems = store.activelyBlockedIssues(by: itemID).map {
                    BlockingRelationshipItem(
                        issue: $0,
                        statusCategory: store.statusCategory(for: $0.status)
                    )
                }
                return chromedRowView(
                    content: IssueRowView(
                        issue: issue,
                        row: row,
                        showsDisclosure: parent.mode == .outline,
                        displayOptions: parent.displayOptions,
                        statusCategory: store.statusCategory(for: issue.status),
                        blockedReason: store.blockedReasonPresentation(
                            for: itemID,
                            bookmark: parent.bookmark,
                            now: parent.gateClock
                        ),
                        blockedByItems: blockedByItems,
                        blockingItems: blockingItems,
                        openRelatedIssue: { store.openIssueFromDetail(issueID: $0) },
                        toggleExpansion: { store.toggleIssueExpansion(issueID: itemID, isExpanded: row.isExpanded) }
                    ),
                    itemID: itemID,
                    isContextFocused: isContextFocused
                )
            }
        }

        /// Erases once for `NSHostingView<AnyView>`; the row content itself stays
        /// concrete (and `.equatable()`-diffable) instead of double-wrapping in AnyView.
        private func chromedRowView(
            content: some View & Equatable,
            itemID: String,
            isContextFocused: Bool
        ) -> AnyView {
            AnyView(
                content
                    .equatable()
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .readyGateGroupChrome(position: readyGateGroupPosition(for: itemID))
                    .contextFocusChrome(isVisible: isContextFocused)
            )
        }

        private func computeReadyGateGroupRange(_ rows: [IssueListRow]) -> Range<Int>? {
            guard parent.bookmark == .gates else { return nil }

            var groupStart: Int?
            var groupEnd: Int?
            var currentGateIsReady = false
            for (index, row) in rows.enumerated() {
                if row.depth == 0 {
                    guard let gate = parent.store.gate(for: row.issueID),
                          gate.actionState(now: parent.gateClock).isReady
                    else {
                        if groupStart != nil { break }
                        currentGateIsReady = false
                        continue
                    }

                    if groupStart == nil {
                        groupStart = index
                    }
                    currentGateIsReady = true
                    groupEnd = index + 1
                } else if currentGateIsReady {
                    groupEnd = index + 1
                } else if groupStart != nil {
                    break
                }
            }

            guard let groupStart, let groupEnd, groupStart < groupEnd else { return nil }
            return groupStart..<groupEnd
        }

        private func readyGateGroupPosition(for itemID: String) -> ReadyGateGroupPosition {
            guard let rowIndex = indexByID[itemID],
                  let readyGateGroupRange,
                  readyGateGroupRange.contains(rowIndex)
            else {
                return .none
            }
            if readyGateGroupRange.count == 1 { return .single }
            if rowIndex == readyGateGroupRange.lowerBound { return .first }
            if rowIndex == readyGateGroupRange.upperBound - 1 { return .last }
            return .middle
        }

        // MARK: Selection

        func syncSelection(_ ids: Set<String>) {
            guard let tableView, !tableView.isHandlingPrimaryMouseInteraction else { return }
            var target = IndexSet()
            for id in ids {
                if let index = indexByID[id] { target.insert(index) }
            }
            guard target != tableView.selectedRowIndexes else { return }
            isSyncingSelection = true
            tableView.selectRowIndexes(target, byExtendingSelection: false)
            isSyncingSelection = false
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let tableView else { return }
            if isHandlingContextClick {
                syncSelection(parent.selectedIDs)
                return
            }
            guard !tableView.isHandlingPrimaryMouseInteraction else { return }
            commitTableSelection()
        }

        func commitTableSelectionAfterPrimaryMouseInteraction() {
            guard !isSyncingSelection, !isHandlingContextClick else { return }
            commitTableSelection()
        }

        private func commitTableSelection() {
            guard let tableView else { return }
            let ids = Set(tableView.selectedRowIndexes.compactMap { index -> String? in
                index >= 0 && index < orderedIDs.count ? orderedIDs[index] : nil
            })
            guard ids != parent.selectedIDs else { return }
            setContextFocusedIssueID(nil)
            parent.store.select(ids)
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView: IssueListTableRowView
            if let reused = tableView.makeView(withIdentifier: Self.rowViewID, owner: self) as? IssueListTableRowView {
                rowView = reused
            } else {
                rowView = IssueListTableRowView()
                rowView.identifier = Self.rowViewID
            }
            rowView.showsFocusOutline = shouldShowFocusOutline(forRow: row)
            rowView.readyGateGroupPosition = readyGateGroupPosition(forRow: row)
            rowView.selectionHighlightStyle = .regular
            return rowView
        }

        @objc func openClickedRow(_ sender: NSTableView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            openRow(row)
        }

        func openRow(_ row: Int) {
            guard row >= 0, row < orderedIDs.count else { return }
            let issueID = orderedIDs[row]
            setContextFocusedIssueID(nil)
            if parent.selectedIDs != [issueID] {
                parent.store.select([issueID])
            }
            parent.openDetail(issueID)
        }

        func navigateOutline(_ direction: OutlineNavigationDirection) -> Bool {
            switch direction {
            case .left: return parent.store.navigateIssueOutlineLeft()
            case .right: return parent.store.navigateIssueOutlineRight()
            }
        }

        // MARK: Drag and drop

        func pasteboardWriter(forRow row: Int) -> (any NSPasteboardWriting)? {
            guard row >= 0,
                  row < orderedIDs.count,
                  let payload = parent.store.beadDragPayload(issueID: orderedIDs[row])
            else { return nil }
            return BeadDragPasteboardItem.make(payload: payload)
        }

        func validateDrop(
            _ info: any NSDraggingInfo,
            row: Int,
            operation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard parent.store.canReorderActiveFolder,
                  let folderID = parent.store.activeFolderSavedView?.id,
                  operation == .above,
                  let payloads = dragPayloads(from: info),
                  parent.store.canAcceptBeadDragPayloads(payloads),
                  payloads.allSatisfy({ $0.sourceFolderID == folderID })
            else { return [] }
            return .move
        }

        func acceptDrop(
            _ info: any NSDraggingInfo,
            row: Int,
            operation: NSTableView.DropOperation
        ) -> Bool {
            guard validateDrop(info, row: row, operation: operation) == .move,
                  let folderID = parent.store.activeFolderSavedView?.id,
                  let payloads = dragPayloads(from: info)
            else { return false }
            return parent.store.moveIssueIDs(
                payloads.flatMap(\.issueIDs),
                inFolder: folderID,
                toOffset: row
            )
        }

        private func dragPayloads(from info: any NSDraggingInfo) -> [BeadDragPayload]? {
            guard let items = info.draggingPasteboard.pasteboardItems, !items.isEmpty else {
                return nil
            }
            let decoder = JSONDecoder()
            let payloads = items.compactMap { item -> BeadDragPayload? in
                guard let data = item.data(forType: .beadazzleBeadDrag) else { return nil }
                return try? decoder.decode(BeadDragPayload.self, from: data)
            }
            return payloads.count == items.count ? payloads : nil
        }

        func setContextClickActive(_ isActive: Bool) {
            isHandlingContextClick = isActive
        }

        func setContextFocusedRow(_ row: Int?) {
            guard let row, row >= 0, row < orderedIDs.count else {
                setContextFocusedIssueID(nil)
                return
            }
            setContextFocusedIssueID(orderedIDs[row])
        }

        private func setContextFocusedIssueID(_ issueID: String?) {
            guard contextFocusedIssueID != issueID else { return }
            let previousID = contextFocusedIssueID
            contextFocusedIssueID = issueID
            updateFocusPresentation(for: previousID)
            updateFocusPresentation(for: issueID)
        }

        private func updateVisibleFocusOutlines() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location..<(visible.location + visible.length) {
                let shouldShow = shouldShowFocusOutline(forRow: row)
                if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? IssueListTableRowView {
                    rowView.showsFocusOutline = shouldShow
                    rowView.readyGateGroupPosition = readyGateGroupPosition(forRow: row)
                }
            }
        }

        private func updateFocusPresentation(for issueID: String?) {
            guard let issueID,
                  let row = indexByID[issueID],
                  let tableView
            else { return }
            let shouldShow = shouldShowFocusOutline(forRow: row)
            if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? IssueListTableRowView {
                rowView.showsFocusOutline = shouldShow
                rowView.readyGateGroupPosition = readyGateGroupPosition(forRow: row)
                rowView.displayIfNeeded()
            }
            if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? RowCellView {
                cell.rootView = rowView(for: issueID)
                cell.layoutSubtreeIfNeeded()
                cell.displayIfNeeded()
            }
        }

        private func shouldShowFocusOutline(forRow row: Int) -> Bool {
            guard row >= 0,
                  row < orderedIDs.count,
                  contextFocusedIssueID == orderedIDs[row]
            else { return false }
            return true
        }

        private func shouldShowFocusOutline(for issueID: String) -> Bool {
            contextFocusedIssueID == issueID
        }

        private func readyGateGroupPosition(forRow row: Int) -> ReadyGateGroupPosition {
            guard row >= 0,
                  row < orderedIDs.count
            else {
                return .none
            }
            return readyGateGroupPosition(for: orderedIDs[row])
        }

        // MARK: Context menu

        func contextMenu(forClickedRow row: Int) -> NSMenu? {
            guard row >= 0, row < orderedIDs.count else { return nil }
            let itemID = orderedIDs[row]
            setContextFocusedIssueID(itemID)
            setContextClickActive(true)

            let ids = parent.selectedIDs.contains(itemID) ? parent.selectedIDs : [itemID]
            guard !ids.isEmpty else { return nil }

            let menu = NSMenu()
            menu.delegate = self
            menu.addItem(contextMenuItem(
                title: ids.count == 1 ? "Copy Bead ID" : "Copy \(ids.count) Bead IDs",
                systemSymbolName: "doc.on.doc",
                action: #selector(copyContextBeadIDs(_:)),
                ids: ids
            ))
            menu.addItem(.separator())

            if parent.store.canCreateSavedView {
                let addToFolderItem = NSMenuItem(title: "Add to Folder", action: nil, keyEquivalent: "")
                let addToFolderMenu = NSMenu()
                for folder in parent.store.folderSavedViews {
                    addToFolderMenu.addItem(contextMenuItem(
                        title: folder.name,
                        action: #selector(addContextBeadsToFolder(_:)),
                        ids: ids,
                        folderID: folder.id
                    ))
                }
                if !parent.store.folderSavedViews.isEmpty {
                    addToFolderMenu.addItem(.separator())
                }
                addToFolderMenu.addItem(contextMenuItem(
                    title: "New Folder from Selection…",
                    action: #selector(createFolderFromContextBeads(_:)),
                    ids: ids
                ))
                menu.addItem(addToFolderItem)
                menu.setSubmenu(addToFolderMenu, for: addToFolderItem)

                if let folderID = parent.store.activeFolderSavedView?.id {
                    menu.addItem(contextMenuItem(
                        title: "Remove from Folder",
                        action: #selector(removeContextBeadsFromFolder(_:)),
                        ids: ids,
                        folderID: folderID
                    ))
                    if parent.store.canReorderActiveFolder {
                        let moveItem = NSMenuItem(title: "Move in Folder", action: nil, keyEquivalent: "")
                        let moveMenu = NSMenu()
                        moveMenu.addItem(contextMenuItem(
                            title: "Move to Top",
                            action: #selector(moveContextBeadsToTop(_:)),
                            ids: ids,
                            folderID: folderID
                        ))
                        moveMenu.addItem(contextMenuItem(
                            title: "Move to Bottom",
                            action: #selector(moveContextBeadsToBottom(_:)),
                            ids: ids,
                            folderID: folderID
                        ))
                        menu.addItem(moveItem)
                        menu.setSubmenu(moveMenu, for: moveItem)
                    }
                }
                menu.addItem(.separator())
            }

            menu.addItem(contextMenuItem(
                title: "Add Labels…",
                systemSymbolName: "tag",
                action: #selector(bulkEditContextBeads(_:)),
                ids: ids,
                bulkEditTarget: .addLabels
            ))

            let propertySections = BulkEditPropertySections(store: parent.store)
            if !propertySections.isEmpty {
                let propertyItem = NSMenuItem(title: "Set Property", action: nil, keyEquivalent: "")
                let propertyMenu = NSMenu()
                appendPropertyItems(propertySections.pinned, to: propertyMenu, ids: ids)
                if !propertySections.pinned.isEmpty, !propertySections.other.isEmpty {
                    propertyMenu.addItem(.separator())
                }
                if !propertySections.other.isEmpty {
                    let otherItem = NSMenuItem(title: "Other", action: nil, keyEquivalent: "")
                    let otherMenu = NSMenu()
                    appendPropertyItems(propertySections.other, to: otherMenu, ids: ids)
                    propertyMenu.addItem(otherItem)
                    propertyMenu.setSubmenu(otherMenu, for: otherItem)
                }
                menu.addItem(propertyItem)
                menu.setSubmenu(propertyMenu, for: propertyItem)
            }

            menu.addItem(.separator())

            let statusOptions = parent.store.statusChangeOptions(forIssueIDs: ids)
            if !statusOptions.isEmpty {
                let statusItem = NSMenuItem(title: "Set Status", action: nil, keyEquivalent: "")
                let statusMenu = NSMenu()
                for status in statusOptions {
                    statusMenu.addItem(contextMenuItem(
                        title: status,
                        action: #selector(setContextStatus(_:)),
                        ids: ids,
                        status: status
                    ))
                }
                menu.addItem(statusItem)
                menu.setSubmenu(statusMenu, for: statusItem)
            }

            if ids.count == 1, let id = ids.first, parent.store.issue(with: id) != nil {
                menu.addItem(contextMenuItem(
                    title: parent.store.completionActionTitle(for: [id]),
                    action: #selector(closeContextBead(_:)),
                    ids: ids
                ))
            }

            menu.addItem(.separator())
            menu.addItem(contextMenuItem(
                title: ids.count == 1 ? "Delete" : "Delete \(ids.count) Beads",
                action: #selector(deleteContextBeads(_:)),
                ids: ids
            ))
            return menu
        }

        private func contextMenuItem(
            title: String,
            systemSymbolName: String? = nil,
            action: Selector,
            ids: Set<String>,
            status: String? = nil,
            bulkEditTarget: BulkEditTarget? = nil,
            folderID: UUID? = nil
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = ContextMenuAction(
                ids: Array(ids),
                status: status,
                bulkEditTarget: bulkEditTarget,
                folderID: folderID
            )
            if let systemSymbolName {
                item.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
            }
            return item
        }

        private func appendPropertyItems(_ dimensions: [String], to menu: NSMenu, ids: Set<String>) {
            for dimension in dimensions {
                menu.addItem(contextMenuItem(
                    title: parent.store.stateDimensionDisplayName(for: dimension),
                    action: #selector(bulkEditContextBeads(_:)),
                    ids: ids,
                    bulkEditTarget: .setProperty(dimension: dimension)
                ))
            }
        }

        @objc private func bulkEditContextBeads(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? ContextMenuAction,
                  let target = action.bulkEditTarget
            else { return }
            parent.requestBulkEdit(Set(action.ids), target)
        }

        @objc private func copyContextBeadIDs(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? ContextMenuAction else { return }
            IssueClipboard.copyIssueID(action.ids.sorted().joined(separator: "\n"))
        }

        @objc private func addContextBeadsToFolder(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? ContextMenuAction,
                  let folderID = action.folderID
            else { return }
            parent.store.addIssueIDs(
                orderedContextIssueIDs(action.ids),
                toFolder: folderID
            )
        }

        @objc private func createFolderFromContextBeads(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? ContextMenuAction else { return }
            parent.store.requestNewFolder(issueIDs: orderedContextIssueIDs(action.ids))
        }

        @objc private func removeContextBeadsFromFolder(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? ContextMenuAction,
                  let folderID = action.folderID
            else { return }
            parent.store.removeIssueIDs(Set(action.ids), fromFolder: folderID)
        }

        @objc private func moveContextBeadsToTop(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? ContextMenuAction,
                  let folderID = action.folderID
            else { return }
            parent.store.moveIssueIDs(action.ids, inFolder: folderID, toOffset: 0)
        }

        @objc private func moveContextBeadsToBottom(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? ContextMenuAction,
                  let folderID = action.folderID
            else { return }
            parent.store.moveIssueIDs(
                action.ids,
                inFolder: folderID,
                toOffset: parent.store.folderIssueIDs(id: folderID, resolvedOnly: false).count
            )
        }

        private func orderedContextIssueIDs(_ ids: [String]) -> [String] {
            let idSet = Set(ids)
            return orderedIDs.filter(idSet.contains)
        }

        @objc private func setContextStatus(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? ContextMenuAction,
                  let status = action.status
            else { return }
            parent.requestSetStatus(Set(action.ids), status)
        }

        @objc private func closeContextBead(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? ContextMenuAction,
                  let id = action.ids.first,
                  let issue = parent.store.issue(with: id)
            else { return }
            parent.requestClose(issue)
        }

        @objc private func deleteContextBeads(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? ContextMenuAction else { return }
            parent.requestDelete(Set(action.ids))
        }
    }
}

@MainActor
final class IssueListDiffableDataSource: NSTableViewDiffableDataSource<Int, String> {
    var pasteboardWriter: ((Int) -> (any NSPasteboardWriting)?)?
    var validateDrop: ((any NSDraggingInfo, Int, NSTableView.DropOperation) -> NSDragOperation)?
    var acceptDrop: ((any NSDraggingInfo, Int, NSTableView.DropOperation) -> Bool)?

    @objc func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        pasteboardWriter?(row)
    }

    @objc func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let result = validateDrop?(info, row, .above) ?? []
        if result != [] {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return result
    }

    @objc func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        acceptDrop?(info, row, .above) ?? false
    }
}

extension IssueListTableView.Coordinator: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        setContextClickActive(false)
        setContextFocusedRow(nil)
    }
}

private final class ContextMenuAction {
    let ids: [String]
    let status: String?
    let bulkEditTarget: BulkEditTarget?
    let folderID: UUID?

    init(
        ids: [String],
        status: String? = nil,
        bulkEditTarget: BulkEditTarget? = nil,
        folderID: UUID? = nil
    ) {
        self.ids = ids
        self.status = status
        self.bulkEditTarget = bulkEditTarget
        self.folderID = folderID
    }
}

private enum ReadyGateGroupPosition: Equatable {
    case none
    case single
    case first
    case middle
    case last

    var isVisible: Bool {
        self != .none
    }

    var chromeInsets: EdgeInsets {
        EdgeInsets(
            top: hasTopEdge ? 3 : 0,
            leading: 4,
            bottom: hasBottomEdge ? 3 : 0,
            trailing: 4
        )
    }

    private var hasTopEdge: Bool {
        self == .single || self == .first
    }

    private var hasBottomEdge: Bool {
        self == .single || self == .last
    }
}

private struct ReadyGateGroupFillShape: Shape {
    let position: ReadyGateGroupPosition

    func path(in rect: CGRect) -> Path {
        let radius = min(IssueListMetrics.focusOutlineCornerRadius + 2, rect.height / 2)
        switch position {
        case .none:
            return Path()
        case .single:
            return Path(roundedRect: rect, cornerRadius: radius)
        case .first:
            return topRoundedPath(in: rect, radius: radius)
        case .middle:
            return Path(rect)
        case .last:
            return bottomRoundedPath(in: rect, radius: radius)
        }
    }

    private func topRoundedPath(in rect: CGRect, radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private func bottomRoundedPath(in rect: CGRect, radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct ReadyGateGroupBorderShape: Shape {
    let position: ReadyGateGroupPosition

    func path(in rect: CGRect) -> Path {
        let radius = min(IssueListMetrics.focusOutlineCornerRadius + 2, rect.height / 2)
        switch position {
        case .none:
            return Path()
        case .single:
            return Path(roundedRect: rect, cornerRadius: radius)
        case .first:
            return topBorderPath(in: rect, radius: radius)
        case .middle:
            return sideBorderPath(in: rect)
        case .last:
            return bottomBorderPath(in: rect, radius: radius)
        }
    }

    private func topBorderPath(in rect: CGRect, radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }

    private func sideBorderPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }

    private func bottomBorderPath(in rect: CGRect, radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private extension View {
    func readyGateGroupChrome(position: ReadyGateGroupPosition) -> some View {
        background {
            if position.isVisible {
                ReadyGateGroupFillShape(position: position)
                    .fill(Color(nsColor: .controlAccentColor).opacity(0.045))
                    .padding(position.chromeInsets)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if position.isVisible {
                ReadyGateGroupBorderShape(position: position)
                    .stroke(
                        Color(nsColor: .controlAccentColor).opacity(0.75),
                        lineWidth: IssueListMetrics.focusOutlineLineWidth
                    )
                    .padding(position.chromeInsets)
                    .allowsHitTesting(false)
            }
        }
    }

    func contextFocusChrome(isVisible: Bool) -> some View {
        background {
            if isVisible {
                RoundedRectangle(cornerRadius: IssueListMetrics.focusOutlineCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .labelColor).opacity(0.10))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isVisible {
                RoundedRectangle(cornerRadius: IssueListMetrics.focusOutlineCornerRadius, style: .continuous)
                    .stroke(Color(nsColor: .labelColor).opacity(0.30), lineWidth: IssueListMetrics.focusOutlineLineWidth)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .allowsHitTesting(false)
            }
        }
    }
}

enum OutlineNavigationDirection {
    case left
    case right
}

private final class IssueListTableRowView: NSTableRowView {
    var showsFocusOutline = false {
        didSet {
            guard oldValue != showsFocusOutline else { return }
            needsDisplay = true
        }
    }

    var readyGateGroupPosition: ReadyGateGroupPosition = .none {
        didSet {
            guard oldValue != readyGateGroupPosition else { return }
            needsDisplay = true
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let path = NSBezierPath(
            roundedRect: rowChromeRect(),
            xRadius: IssueListMetrics.focusOutlineCornerRadius + 2,
            yRadius: IssueListMetrics.focusOutlineCornerRadius + 2
        )
        selectionFillColor.setFill()
        path.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard showsFocusOutline else { return }

        let path = NSBezierPath(
            roundedRect: rowChromeRect(),
            xRadius: IssueListMetrics.focusOutlineCornerRadius,
            yRadius: IssueListMetrics.focusOutlineCornerRadius
        )
        if !isSelected {
            NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.45).setFill()
            path.fill()
        }
        path.lineWidth = IssueListMetrics.focusOutlineLineWidth
        NSColor.tertiaryLabelColor.setStroke()
        path.stroke()
    }

    private func rowChromeRect() -> NSRect {
        let baseRect: NSRect
        if readyGateGroupPosition.isVisible,
           let cell = subviews.compactMap({ $0 as? RowCellView }).first {
            baseRect = cell.frame
        } else {
            baseRect = bounds
        }
        return baseRect.insetBy(dx: 4, dy: 3)
    }

    private var selectionFillColor: NSColor {
        isEmphasized
            ? .selectedContentBackgroundColor
            : .unemphasizedSelectedContentBackgroundColor
    }
}

/// `NSTableView` that routes left/right arrows to outline expand/collapse (matching the
/// prior SwiftUI `.onKeyPress` handlers) while leaving up/down selection to AppKit.
private final class IssueKeyboardTableView: NSTableView {
    var onNavigateOutline: ((OutlineNavigationDirection) -> Bool)?
    var onContextTargetRowChange: ((Int?) -> Void)?
    var onContextClickChange: ((Bool) -> Void)?
    var contextMenuProvider: ((Int) -> NSMenu?)?
    var onPrimaryMouseInteractionEnded: (() -> Void)?
    private(set) var isHandlingPrimaryMouseInteraction = false

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyCode.leftArrow:
            if onNavigateOutline?(.left) == true { return }
        case KeyCode.rightArrow:
            if onNavigateOutline?(.right) == true { return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        prepareContextTarget(for: event)
        super.rightMouseDown(with: event)
        onContextClickChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            prepareContextTarget(for: event)
            super.mouseDown(with: event)
            onContextClickChange?(false)
        } else {
            onContextTargetRowChange?(nil)
            // Keep AppKit's selection live through its click/drag tracking loop. SwiftUI
            // receives the resolved selection only after the native interaction returns.
            isHandlingPrimaryMouseInteraction = true
            defer {
                isHandlingPrimaryMouseInteraction = false
                onPrimaryMouseInteractionEnded?()
            }
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = prepareContextTarget(for: event)
        guard row >= 0 else { return nil }
        return contextMenuProvider?(row)
    }

    func contextMenu(for event: NSEvent) -> NSMenu? {
        menu(for: event)
    }

    @discardableResult
    private func prepareContextTarget(for event: NSEvent) -> Int {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            onContextTargetRowChange?(nil)
            return -1
        }
        let row = row(at: point)
        onContextClickChange?(true)
        window?.makeFirstResponder(self)
        onContextTargetRowChange?(row >= 0 ? row : nil)
        displayIfNeeded()
        return row
    }
}

/// Reusable fixed-size host for a SwiftUI row. `sizingOptions = []` stops `NSHostingView`
/// from installing intrinsic-content-size constraints, so it never triggers the automatic
/// row-height Auto Layout pass — the row's frame comes from the table's fixed `rowHeight`.
private final class RowCellView: NSView {
    private let hostingView = RowHostingView()

    var representedIssueID: String? {
        get { hostingView.representedIssueID }
        set { hostingView.representedIssueID = newValue }
    }

    var onContextFocusChange: ((String?) -> Void)? {
        get { hostingView.onContextFocusChange }
        set { hostingView.onContextFocusChange = newValue }
    }

    var onContextClickChange: ((Bool) -> Void)? {
        get { hostingView.onContextClickChange }
        set { hostingView.onContextClickChange = newValue }
    }

    var rootView: AnyView {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(hostingView)
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }
}

private final class RowHostingView: NSHostingView<AnyView> {
    var representedIssueID: String?
    var onContextFocusChange: ((String?) -> Void)?
    var onContextClickChange: ((Bool) -> Void)?

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
    }

    override var isOpaque: Bool { false }

    convenience init() {
        self.init(rootView: AnyView(Color.clear))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextClickChange?(true)
        focusContextTarget()
        super.rightMouseDown(with: event)
        onContextClickChange?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onContextClickChange?(true)
            focusContextTarget()
            super.mouseDown(with: event)
            onContextClickChange?(false)
        } else {
            clearContextTarget()
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        focusContextTarget()
        if let tableView = enclosingIssueTableView {
            return tableView.contextMenu(for: event)
        }
        return super.menu(for: event)
    }

    private func focusContextTarget() {
        guard let representedIssueID else { return }
        enclosingIssueTableView?.window?.makeFirstResponder(enclosingIssueTableView)
        onContextFocusChange?(representedIssueID)
    }

    private func clearContextTarget() {
        onContextFocusChange?(nil)
    }

    private var enclosingIssueTableView: IssueKeyboardTableView? {
        var view: NSView? = self
        while let current = view {
            if let tableView = current as? IssueKeyboardTableView {
                return tableView
            }
            view = current.superview
        }
        return nil
    }
}
