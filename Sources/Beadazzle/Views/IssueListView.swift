import SwiftUI

struct IssueListView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var emptyFolderIsDropTargeted = false
    private var project: BeadProjectStore { store.project }
    private var workspace: BeadWorkspaceStore { store.workspace }
    private var detail: BeadDetailStore { store.detail }
    let openProject: () -> Void
    let requestClose: (BeadIssue) -> Void
    let requestSetStatus: (Set<String>, String) -> Void
    let requestBulkEdit: (Set<String>, BulkEditTarget) -> Void
    let requestDelete: (Set<String>) -> Void
    let openDetail: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if IssueListSurfacePolicy.showsHeader(
                bookmark: store.effectiveIssueListBookmark,
                hasSearchText: !store.trimmedSearchText.isEmpty
            ) {
                IssueListHeader()
                Divider()
            }

            Group {
                if project.projectURL == nil {
                    ContentUnavailableView {
                        Label("Open a Project", systemImage: "folder.badge.plus")
                    } description: {
                        Text("Choose a project that uses a current Dolt-backed Beads tracker.")
                    } actions: {
                        Button("Open Project…", systemImage: "folder", action: openProject)
                    }
                } else if store.issues.isEmpty && !store.hasActiveFilters && store.searchText.isEmpty {
                    ContentUnavailableView {
                        Label("No Beads Yet", systemImage: "circle.hexagongrid")
                    } description: {
                        Text("Create a bead to start tracking work in this project.")
                    } actions: {
                        Button("New Bead", systemImage: "plus", action: store.beginCreatingBead)
                            .disabled(!store.canCreateBead)
                    }
                } else if store.isShowingFolderInIssueList,
                          let folder = store.activeIssueListFolderSavedView,
                          IssueListSurfacePolicy.showsEmptyFolderPlaceholder(
                              folderIsEmpty: folder.folder?.orderedIssueIDs.isEmpty == true,
                              hasSearchText: !store.trimmedSearchText.isEmpty
                          ) {
                    ContentUnavailableView {
                        Label("Folder is Empty", systemImage: "folder")
                    } description: {
                        Text("Drag beads here or use Add to Folder from any bead menu.")
                    } actions: {
                        Button("Show All Beads", systemImage: "circle.hexagongrid") {
                            store.applyBookmark(.all)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if workspace.filteredIssueIDs.isEmpty {
                    noMatchesView
                } else {
                    // Fixed-height NSTableView (see IssueListTableView): SwiftUI's List/Table
                    // measure every row's height via Auto Layout on any wholesale change,
                    // which hangs the main thread for seconds at ~1200 rows.
                    IssueListTableView(
                        rows: workspace.issueListRows,
                        rowRevision: workspace.issueListRowsRevision,
                        selectedIDs: workspace.selectedIDs,
                        bookmark: store.effectiveIssueListBookmark,
                        mode: store.effectiveIssueListMode,
                        displayOptions: store.beadListDisplayOptions,
                        rowHeight: store.beadListDensity.rowHeight,
                        contentRevision: project.contentRevision,
                        gateClock: detail.gateClock,
                        store: store,
                        requestClose: requestClose,
                        requestSetStatus: requestSetStatus,
                        requestBulkEdit: requestBulkEdit,
                        requestDelete: requestDelete,
                        openDetail: openDetail
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay {
                if emptyFolderIsDropTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.tint, lineWidth: 2)
                        .padding(12)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(
                of: emptyFolderDropTarget == nil ? [] : BeadFolderDropHandler.contentTypes,
                isTargeted: emptyFolderDropTargetBinding
            ) { providers in
                guard let folderID = emptyFolderDropTarget?.id else { return false }
                return BeadFolderDropHandler.accept(
                    providers,
                    into: folderID,
                    store: store
                )
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .task(id: GateClockTaskID(bookmark: store.effectiveIssueListBookmark, contentRevision: project.contentRevision)) {
            await runGateClockIfNeeded()
        }
        .task(id: RelativeFilterClockTaskID(hasRelativeRules: store.hasRelativeSavedViewFilters)) {
            await runRelativeFilterClockIfNeeded()
        }
        .task(id: TimeSensitiveBookmarkClockTaskID(
            bookmark: store.effectiveIssueListBookmark,
            contentRevision: project.contentRevision
        )) {
            await runTimeSensitiveBookmarkClockIfNeeded()
        }
        .onChange(of: emptyFolderDropTarget?.id) {
            if emptyFolderDropTarget == nil {
                emptyFolderIsDropTargeted = false
            }
        }
    }

    private var emptyFolderDropTarget: BeadSavedView? {
        guard let folder = store.activeIssueListFolderSavedView,
              IssueListSurfacePolicy.showsEmptyFolderDropTarget(
                  folderIsEmpty: folder.folder?.orderedIssueIDs.isEmpty == true,
                  isGlobalSearchActive: store.isGlobalSearchActive
              ) else {
            return nil
        }
        return folder
    }

    private var emptyFolderDropTargetBinding: Binding<Bool> {
        Binding(
            get: { emptyFolderIsDropTargeted },
            set: { emptyFolderIsDropTargeted = emptyFolderDropTarget != nil && $0 }
        )
    }

    @MainActor
    private func runGateClockIfNeeded() async {
        guard usesGateClock else { return }
        while !Task.isCancelled, usesGateClock {
            let now = Date()
            store.refreshGateClock(now)
            guard let nextExpiry = store.nextGateTimerExpiry(after: now) else { return }

            let delayMilliseconds = max(1_000, Int64(ceil(nextExpiry.timeIntervalSince(Date()) * 1_000)))
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        }
    }

    private var usesGateClock: Bool {
        store.effectiveIssueListBookmark == .gates || store.effectiveIssueListBookmark == .blocked
    }

    @MainActor
    private func runTimeSensitiveBookmarkClockIfNeeded() async {
        guard store.effectiveIssueListBookmark == .ready || store.effectiveIssueListBookmark == .stale else { return }
        while !Task.isCancelled,
              (store.effectiveIssueListBookmark == .ready || store.effectiveIssueListBookmark == .stale) {
            guard let boundary = store.index.nextTimeSensitiveBookmarkBoundary(
                for: store.effectiveIssueListBookmark
            ) else {
                return
            }
            let delay = max(1, boundary.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await store.refreshTimeSensitiveBookmarkMembership(at: Date())
        }
    }

    @MainActor
    private func runRelativeFilterClockIfNeeded() async {
        guard store.hasRelativeSavedViewFilters else { return }
        while !Task.isCancelled, store.hasRelativeSavedViewFilters {
            let now = Date()
            let nextDay = Calendar.current.nextDate(
                after: now,
                matching: DateComponents(hour: 0, minute: 0, second: 1),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(86_400)
            try? await Task.sleep(for: .seconds(max(1, nextDay.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            store.refreshRelativeSavedViewFilters(now: Date())
        }
    }

    @ViewBuilder
    private var noMatchesView: some View {
        let query = store.trimmedSearchText
        if query.isEmpty {
            ContentUnavailableView {
                Label("No Beads Match", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Adjust the active view or filters to show more beads.")
            } actions: {
                noMatchFilterActions
            }
        } else {
            ContentUnavailableView {
                Label("No Beads Match", systemImage: "magnifyingglass")
            } description: {
                Text("No beads match “\(query)” in \(store.activeSearchCoverageTitle).")
            } actions: {
                SearchCoverageActionButton()
                if store.hasActiveFilters || store.advancedFilterCount > 0 {
                    Button("Clear Filters", action: clearAllFilters)
                }
                Button("Clear Search") {
                    store.searchText = ""
                }
            }
        }
    }

    @ViewBuilder
    private var noMatchFilterActions: some View {
        if store.isSavedViewDrifted {
            Button("Revert to Bookmark", action: store.revertToSourceSavedView)
        }
        if store.hasActiveFilters || store.advancedFilterCount > 0 {
            Button("Clear Filters", action: clearAllFilters)
        } else if store.effectiveIssueListBookmark != .all || store.isShowingFolderInIssueList {
            Button("Show All Beads") {
                store.applyBookmark(.all)
            }
        }
    }

    private func clearAllFilters() {
        store.clearFilters()
        store.clearAdvancedFilters()
    }
}

private struct GateClockTaskID: Hashable {
    var bookmark: BeadBookmark
    var contentRevision: Int
}

private struct RelativeFilterClockTaskID: Hashable {
    var hasRelativeRules: Bool
}

private struct TimeSensitiveBookmarkClockTaskID: Hashable {
    var bookmark: BeadBookmark
    var contentRevision: Int
}

enum IssueListMetrics {
    static let rowHeight: CGFloat = 54
    static let depthIndent: CGFloat = 18
    static let disclosureWidth: CGFloat = 16
    static let issueIDWidth: CGFloat = 82
    static let headerControlHeight: CGFloat = 26
    static let focusOutlineCornerRadius: CGFloat = 6
    static let focusOutlineLineWidth: CGFloat = 2
}

enum IssueListSurfacePolicy {
    static func showsHeader(bookmark: BeadBookmark, hasSearchText: Bool) -> Bool {
        bookmark != .gates || hasSearchText
    }

    static func showsEmptyFolderPlaceholder(folderIsEmpty: Bool, hasSearchText: Bool) -> Bool {
        folderIsEmpty && !hasSearchText
    }

    static func showsEmptyFolderDropTarget(
        folderIsEmpty: Bool,
        isGlobalSearchActive: Bool
    ) -> Bool {
        folderIsEmpty && !isGlobalSearchActive
    }
}

private struct IssueListHeader: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var workspace: BeadWorkspaceStore { store.workspace }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if !store.isGlobalSearchActive,
                   store.effectiveIssueListBookmark != .gates {
                    if store.advancedFilterCount > 0 || store.isSavedViewDrifted {
                        Menu {
                            if store.advancedFilterCount > 0 {
                                Text("\(store.advancedFilterCount) saved-view rule\(store.advancedFilterCount == 1 ? "" : "s") active")
                            }
                            if store.isSavedViewDrifted {
                                Text("Bookmark filters have been modified")
                            }
                            Divider()
                            Button("Edit Bookmark...") {
                                store.requestEditingActiveSavedView()
                            }
                            .disabled(workspace.sourceSavedViewID == nil)
                            if store.isSavedViewDrifted {
                                Button("Revert to Bookmark") {
                                    store.revertToSourceSavedView()
                                }
                            }
                            if store.advancedFilterCount > 0 {
                                Button("Clear Advanced Filters", role: .destructive) {
                                    store.clearAdvancedFilters()
                                }
                            }
                        } label: {
                            Label(
                                store.isSavedViewDrifted ? "Modified" : "Advanced \(store.advancedFilterCount)",
                                systemImage: "line.3.horizontal.decrease.circle.fill"
                            )
                        }
                        .menuStyle(.button)
                        .help(store.isSavedViewDrifted ? "Bookmark filters have been modified" : "Advanced saved-view filters are active")
                    }
                }
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if showsSearchCoverageAction {
                    searchCoverageAction
                }

                Spacer(minLength: 8)

                // The Gates section always shows gate → blocked beads, so the flat/outline
                // toggle has no meaning there.
                if !store.isGlobalSearchActive,
                   store.effectiveIssueListBookmark != .gates,
                   !store.isShowingFolderInIssueList {
                    IssueListModePicker()
                }
            }
            .controlSize(.small)
            .frame(height: IssueListMetrics.headerControlHeight, alignment: .center)

            if !store.isGlobalSearchActive,
               store.effectiveIssueListBookmark != .gates,
               (store.hasActiveFilters || store.advancedFilterCount > 0) {
                ActiveFilterChipsView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: ContentLayout.workspaceToolbarHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var showsSearchCoverageAction: Bool {
        !store.trimmedSearchText.isEmpty
            && store.filteredIssueCount > 0
            && (store.canExpandCurrentSearchToAllBeads || store.canReturnSearchToCurrentView)
    }

    private var searchCoverageAction: some View {
        SearchCoverageActionButton()
            .buttonStyle(.link)
            .fixedSize()
    }

    private var summaryText: String {
        let count: String
        if !store.trimmedSearchText.isEmpty {
            let noun = store.filteredIssueCount == 1 ? "match" : "matches"
            count = "\(store.filteredIssueCount.formatted()) \(noun) in \(store.activeSearchCoverageTitle)"
        } else {
            let totalCount = store.activeIssueListFolderSavedView.map {
                store.count(forSavedViewID: $0.id) ?? store.folderIssueIDs(id: $0.id).count
            } ?? store.issues.count
            count = store.filteredIssueCount == totalCount
                ? "\(totalCount.formatted()) beads"
                : "\(store.filteredIssueCount.formatted()) of \(totalCount.formatted())"
        }
        guard !workspace.selectedIDs.isEmpty else { return count }
        return "\(count), \(workspace.selectedIDs.count.formatted()) selected"
    }
}

private struct SearchCoverageActionButton: View {
    @Environment(BeadStore.self) private var store: BeadStore

    @ViewBuilder
    var body: some View {
        if store.canExpandCurrentSearchToAllBeads {
            Button("Search All Beads") {
                store.searchAllBeadsUsingCurrentSearchText()
            }
            .help("Search the entire project")
            .accessibilityHint("Keeps this search text and searches the entire project.")
        } else if store.canReturnSearchToCurrentView {
            Button("Back to \(store.currentViewSearchTitle)") {
                store.searchCurrentViewUsingCurrentSearchText()
            }
            .help("Search only \(store.currentViewSearchTitle)")
            .accessibilityHint("Searches only the selected view again.")
        }
    }
}

private struct IssueListModePicker: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        @Bindable var store = store

        Picker("List Mode", selection: $store.issueListMode) {
            ForEach(IssueListMode.allCases) { mode in
                Image(systemName: mode.systemImage)
                    .accessibilityLabel(mode.rawValue)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 70, height: IssueListMetrics.headerControlHeight)
        .help("View as \(store.issueListMode.rawValue.lowercased())")
    }
}

/// Row for a gate bead: type-appropriate icon + the condition it's waiting on, with the
/// reason as the subtitle. Used wherever a gate bead appears (chiefly the Gates section,
/// where its blocked beads nest beneath it).
struct GateRowView: View, Equatable {
    let presentation: GateSummaryRowPresentation
    let row: IssueListRow
    let now: Date
    let showsDisclosure: Bool
    let allowsHoverPresentation: Bool
    var rowHeight = IssueListMetrics.rowHeight
    let toggleExpansion: () -> Void

    nonisolated static func == (lhs: GateRowView, rhs: GateRowView) -> Bool {
        lhs.presentation == rhs.presentation
            && lhs.row == rhs.row
            && lhs.now == rhs.now
            && lhs.showsDisclosure == rhs.showsDisclosure
            && lhs.allowsHoverPresentation == rhs.allowsHoverPresentation
            && lhs.rowHeight == rhs.rowHeight
    }

    var body: some View {
        let gate = presentation.gate
        let actionState = gate.actionState(now: now)
        let tint = GatePresentation.tint(for: actionState, isOpen: gate.isOpen)

        HStack(spacing: 0) {
            if showsDisclosure {
                Spacer()
                    .frame(width: CGFloat(row.depth) * IssueListMetrics.depthIndent)

                Button(action: toggleExpansion) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: IssueListMetrics.disclosureWidth, height: rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!row.hasChildren)
                .opacity(row.hasChildren ? 1 : 0)
                .accessibilityHidden(!row.hasChildren)
                .help(row.isExpanded ? "Collapse blocked beads" : "Expand blocked beads")
            }

            Image(systemName: gate.systemImage)
                .font(.caption.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .center)
                .padding(.trailing, 8)
                .help("\(gate.awaitType.title) gate")
                .accessibilityLabel("\(gate.awaitType.title) gate")

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(GatePresentation.conditionHeadline(for: gate, now: now))
                        .font(.headline)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if let actionLabel = GatePresentation.actionStateLabel(for: actionState) {
                        let labelTint = GatePresentation.readyLabelTint
                        Text(actionLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(labelTint)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(labelTint.opacity(0.14), in: Capsule())
                    }

                    Spacer(minLength: 8)

                    Text(BeadFormatters.relative(presentation.updatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    CopyableIssueIDButton(
                        issueID: gate.id,
                        allowsHoverPresentation: allowsHoverPresentation
                    )
                    if let subtitle = gate.reason?.nilIfBlank {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .font(.caption)
            }
        }
        .frame(height: rowHeight, alignment: .center)
        .contentShape(Rectangle())
    }
}

struct IssueRowView: View, Equatable {
    let presentation: IssueSummaryRowPresentation
    let row: IssueListRow
    let showsDisclosure: Bool
    let displayOptions: BeadListDisplayOptions
    let blockedReason: BlockedReasonPresentation?
    let allowsHoverPresentation: Bool
    var rowHeight = IssueListMetrics.rowHeight
    let openRelatedIssue: (String) -> Void
    let toggleExpansion: () -> Void

    nonisolated static func == (lhs: IssueRowView, rhs: IssueRowView) -> Bool {
        lhs.presentation == rhs.presentation
            && lhs.row == rhs.row
            && lhs.showsDisclosure == rhs.showsDisclosure
            && lhs.displayOptions == rhs.displayOptions
            && lhs.blockedReason == rhs.blockedReason
            && lhs.allowsHoverPresentation == rhs.allowsHoverPresentation
            && lhs.rowHeight == rhs.rowHeight
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsDisclosure {
                Spacer()
                    .frame(width: CGFloat(row.depth) * IssueListMetrics.depthIndent)

                Button(action: toggleExpansion) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: IssueListMetrics.disclosureWidth, height: rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!row.hasChildren)
                .opacity(row.hasChildren ? 1 : 0)
                .accessibilityHidden(!row.hasChildren)
                .help(row.isExpanded ? "Collapse children" : "Expand children")
            }

            IssueSummaryRowContent(
                presentation: presentation,
                row: row,
                statusCategory: presentation.statusCategory,
                titleForegroundStyle: row.isContext ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary),
                issueIDPresentation: .copyable,
                showsOwner: displayOptions.showsOwner,
                showsAssignee: displayOptions.showsAssignee,
                showsDueDate: displayOptions.showsDueDate,
                blockedReason: blockedReason,
                blockedByItems: presentation.blockedByItems,
                blockingItems: presentation.blockingItems,
                openRelatedIssue: openRelatedIssue,
                showsDependencyCounts: true,
                showsComments: displayOptions.showsComments,
                showsLabels: true,
                allowsHoverPresentation: allowsHoverPresentation,
                rowHeight: rowHeight
            )
        }
        .frame(height: rowHeight, alignment: .center)
        .contentShape(Rectangle())
    }
}
