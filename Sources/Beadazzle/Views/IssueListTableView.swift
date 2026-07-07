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
    let selectedIDs: Set<String>
    let mode: IssueListMode
    let displayOptions: BeadListDisplayOptions
    let contentRevision: Int
    let store: BeadStore
    let requestClose: (BeadIssue) -> Void
    let requestSetStatus: (Set<String>, String) -> Void
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
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.openClickedRow(_:))
        tableView.onNavigateOutline = { [weak coordinator] direction in
            coordinator?.navigateOutline(direction) ?? false
        }

        let column = NSTableColumn(identifier: Coordinator.columnID)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let dataSource = NSTableViewDiffableDataSource<Int, String>(tableView: tableView) {
            [weak coordinator] table, _, _, itemID in
            coordinator?.makeCell(for: itemID, in: table) ?? NSView()
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
        weak var tableView: NSTableView?
        var dataSource: NSTableViewDiffableDataSource<Int, String>?

        private var orderedIDs: [String] = []
        private var indexByID: [String: Int] = [:]
        private var rowByID: [String: IssueListRow] = [:]
        private var isSyncingSelection = false
        private var isHandlingContextClick = false
        private var contextFocusedIssueID: String?

        // Last-applied inputs, so an update that only changed the selection skips the
        // (expensive) SwiftUI relayout of every visible row.
        private var lastRows: [IssueListRow] = []
        private var lastMode: IssueListMode?
        private var lastDisplayOptions: BeadListDisplayOptions?
        private var lastContentRevision = -1

        init(_ parent: IssueListTableView) {
            self.parent = parent
        }

        /// Reconciles the table with `parent`. Reapplies the diffable snapshot only when the
        /// row identity/order changed, reconfigures visible cells only when row-derived or
        /// issue content changed, and always syncs selection. A selection-only update thus
        /// costs nothing beyond the AppKit selection change.
        func update(force: Bool) {
            let rows = parent.rows
            let ids = rows.map(\.issueID)
            let previousRowByID = rowByID
            let previousIDs = orderedIDs

            orderedIDs = ids
            indexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.issueID, $0) })
            if let contextFocusedIssueID, indexByID[contextFocusedIssueID] == nil {
                self.contextFocusedIssueID = nil
            }

            var rebuiltAllVisible = false
            if force || ids != previousIDs {
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(ids, toSection: 0)
                dataSource?.apply(snapshot, animatingDifferences: false)
                // A wholesale turnover (bookmark switch / sort / filter) deletes every old
                // item and inserts every new one, so `apply` already rebuilds all visible
                // cells fresh — the reconfigure pass below would just build them a second time.
                rebuiltAllVisible = force || isWholesaleChange(from: previousIDs, to: ids)
            }

            // Only cells the snapshot did NOT already rebuild need reconfiguring: rows that
            // survived (same id) but whose content changed — an edit (contentRevision), a
            // display-option/mode toggle, or a row field like expansion state.
            if !rebuiltAllVisible {
                let globalChange = force
                    || parent.mode != lastMode
                    || parent.displayOptions != lastDisplayOptions
                    || parent.contentRevision != lastContentRevision
                reconfigureVisibleRows { id in
                    guard let previous = previousRowByID[id] else { return false }
                    return globalChange || rowByID[id] != previous
                }
            }

            lastRows = rows
            lastMode = parent.mode
            lastDisplayOptions = parent.displayOptions
            lastContentRevision = parent.contentRevision

            syncSelection(parent.selectedIDs)
            updateVisibleFocusOutlines()
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
            let host: RowHostingView
            if let reused = table.makeView(withIdentifier: Self.cellID, owner: self) as? RowHostingView {
                host = reused
            } else {
                host = RowHostingView()
                host.identifier = Self.cellID
            }
            host.representedIssueID = itemID
            host.onContextFocusChange = { [weak self] issueID in
                self?.setContextFocusedIssueID(issueID)
            }
            host.onContextClickChange = { [weak self] isActive in
                self?.isHandlingContextClick = isActive
            }
            host.rootView = rowView(for: itemID)
            return host
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
                      let host = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? RowHostingView
                else { continue }
                host.rootView = rowView(for: id)
            }
        }

        private func rowView(for itemID: String) -> AnyView {
            guard let issue = parent.store.issue(with: itemID), let row = rowByID[itemID] else {
                return AnyView(Color.clear)
            }
            let store = parent.store
            let rowContent: AnyView
            if let gate = store.gate(for: itemID) {
                rowContent = AnyView(
                    GateRowView(
                        issue: issue,
                        row: row,
                        gate: gate,
                        // Gate rows disclose their blocked beads in the Gates section.
                        showsDisclosure: parent.mode == .outline || parent.store.selectedBookmark == .gates,
                        toggleExpansion: { store.toggleIssueExpansion(issueID: itemID, isExpanded: row.isExpanded) }
                    )
                    .equatable()
                )
            } else {
                rowContent = AnyView(
                    IssueRowView(
                        issue: issue,
                        row: row,
                        showsDisclosure: parent.mode == .outline,
                        displayOptions: parent.displayOptions,
                        statusCategory: store.statusCategory(for: issue.status),
                        toggleExpansion: { store.toggleIssueExpansion(issueID: itemID, isExpanded: row.isExpanded) }
                    )
                    .equatable()
                )
            }
            return AnyView(
                rowContent
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Targets resolve when the menu opens, using the current selection — so a
                    // selection change never requires reconfiguring this cell.
                    .contextMenu { self.contextMenu(forClicked: itemID) }
            )
        }

        // MARK: Selection

        func syncSelection(_ ids: Set<String>) {
            guard let tableView else { return }
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
            return rowView
        }

        @objc func openClickedRow(_ sender: NSTableView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
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

        private func setContextFocusedIssueID(_ issueID: String?) {
            guard contextFocusedIssueID != issueID else { return }
            let previousID = contextFocusedIssueID
            contextFocusedIssueID = issueID
            updateFocusOutline(for: previousID)
            updateFocusOutline(for: issueID)
        }

        private func updateVisibleFocusOutlines() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location..<(visible.location + visible.length) {
                guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? IssueListTableRowView else {
                    continue
                }
                rowView.showsFocusOutline = shouldShowFocusOutline(forRow: row)
            }
        }

        private func updateFocusOutline(for issueID: String?) {
            guard let issueID,
                  let row = indexByID[issueID],
                  let tableView,
                  let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? IssueListTableRowView
            else { return }
            rowView.showsFocusOutline = shouldShowFocusOutline(forRow: row)
        }

        private func shouldShowFocusOutline(forRow row: Int) -> Bool {
            guard row >= 0,
                  row < orderedIDs.count,
                  contextFocusedIssueID == orderedIDs[row]
            else { return false }
            return !parent.selectedIDs.contains(orderedIDs[row])
        }

        // MARK: Context menu

        @ViewBuilder
        private func contextMenu(forClicked itemID: String) -> some View {
            let ids: Set<String> = parent.selectedIDs.contains(itemID) ? parent.selectedIDs : [itemID]
            if !ids.isEmpty {
                let store = parent.store
                let requestClose = parent.requestClose
                Button {
                    IssueClipboard.copyIssueID(ids.sorted().joined(separator: "\n"))
                } label: {
                    Label(ids.count == 1 ? "Copy Bead ID" : "Copy \(ids.count) Bead IDs", systemImage: "doc.on.doc")
                }

                Divider()

                Menu("Set Status") {
                    ForEach(store.availableStatuses, id: \.self) { status in
                        Button(status) {
                            self.parent.requestSetStatus(ids, status)
                        }
                    }
                }

                if ids.count == 1, let id = ids.first, let issue = store.issue(with: id) {
                    Button("Close Bead...") {
                        requestClose(issue)
                    }
                }

                Divider()

                Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) Beads", role: .destructive) {
                    Task { await store.delete(issueIDs: Array(ids)) }
                }
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsFocusOutline, !isSelected else { return }

        let outlineRect = bounds.insetBy(dx: 4, dy: 3)
        let path = NSBezierPath(
            roundedRect: outlineRect,
            xRadius: IssueListMetrics.focusOutlineCornerRadius,
            yRadius: IssueListMetrics.focusOutlineCornerRadius
        )
        path.lineWidth = IssueListMetrics.focusOutlineLineWidth
        NSColor.keyboardFocusIndicatorColor.setStroke()
        path.stroke()
    }
}

/// `NSTableView` that routes left/right arrows to outline expand/collapse (matching the
/// prior SwiftUI `.onKeyPress` handlers) while leaving up/down selection to AppKit.
private final class IssueKeyboardTableView: NSTableView {
    var onNavigateOutline: ((OutlineNavigationDirection) -> Bool)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // left arrow
            if onNavigateOutline?(.left) == true { return }
        case 124: // right arrow
            if onNavigateOutline?(.right) == true { return }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

/// Reusable fixed-size host for a SwiftUI row. `sizingOptions = []` stops `NSHostingView`
/// from installing intrinsic-content-size constraints, so it never triggers the automatic
/// row-height Auto Layout pass — the row's frame comes from the table's fixed `rowHeight`.
private final class RowHostingView: NSHostingView<AnyView> {
    var representedIssueID: String?
    var onContextFocusChange: ((String?) -> Void)?
    var onContextClickChange: ((Bool) -> Void)?

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = []
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
    }

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
        return super.menu(for: event)
    }

    private func focusContextTarget() {
        guard let representedIssueID else { return }
        enclosingTableView?.window?.makeFirstResponder(enclosingTableView)
        onContextFocusChange?(representedIssueID)
    }

    private func clearContextTarget() {
        onContextFocusChange?(nil)
    }

    private var enclosingTableView: NSTableView? {
        var view: NSView? = self
        while let current = view {
            if let tableView = current as? NSTableView {
                return tableView
            }
            view = current.superview
        }
        return nil
    }
}
