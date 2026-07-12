import SwiftUI

struct IssueListView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let requestClose: (BeadIssue) -> Void
    let requestSetStatus: (Set<String>, String) -> Void
    let requestDelete: (Set<String>) -> Void
    let openDetail: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if store.selectedBookmark != .gates {
                IssueListHeader()
                Divider()
            }

            Group {
                if store.projectURL == nil {
                    ContentUnavailableView("Open a Beads Project", systemImage: "folder.badge.plus")
                } else if store.issues.isEmpty && !store.hasActiveFilters && store.searchText.isEmpty {
                    ContentUnavailableView(
                        "No Beads Yet",
                        systemImage: "circle.hexagongrid",
                        description: Text("Create a bead to start tracking work in this project.")
                    )
                } else if store.filteredIssueIDs.isEmpty {
                    ContentUnavailableView("No Beads Match", systemImage: "line.3.horizontal.decrease.circle")
                } else {
                    // Fixed-height NSTableView (see IssueListTableView): SwiftUI's List/Table
                    // measure every row's height via Auto Layout on any wholesale change,
                    // which hangs the main thread for seconds at ~1200 rows.
                    IssueListTableView(
                        rows: store.issueListRows,
                        selectedIDs: store.selectedIDs,
                        mode: store.issueListMode,
                        displayOptions: store.beadListDisplayOptions,
                        contentRevision: store.contentRevision,
                        gateClock: store.gateClock,
                        store: store,
                        requestClose: requestClose,
                        requestSetStatus: requestSetStatus,
                        requestDelete: requestDelete,
                        openDetail: openDetail
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .task(id: GateClockTaskID(bookmark: store.selectedBookmark, contentRevision: store.contentRevision)) {
            await runGateClockIfNeeded()
        }
        .task(id: RelativeFilterClockTaskID(hasRelativeRules: store.hasRelativeSavedViewFilters)) {
            await runRelativeFilterClockIfNeeded()
        }
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
        store.selectedBookmark == .gates || store.selectedBookmark == .blocked
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
}

private struct GateClockTaskID: Hashable {
    var bookmark: BeadBookmark
    var contentRevision: Int
}

private struct RelativeFilterClockTaskID: Hashable {
    var hasRelativeRules: Bool
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

private struct IssueListHeader: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                FilterMenu()
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
                        .disabled(store.sourceSavedViewID == nil)
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
                SortMenu()
                ViewOptionsMenu()
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                // The Gates section always shows gate → blocked beads, so the flat/outline
                // toggle has no meaning there.
                if store.selectedBookmark != .gates {
                    IssueListModePicker()
                }
            }
            .controlSize(.small)
            .frame(height: IssueListMetrics.headerControlHeight, alignment: .center)

            if store.hasActiveFilters || store.advancedFilterCount > 0 {
                ActiveFilterChipsView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var summaryText: String {
        let count = store.filteredIssueCount == store.issues.count
            ? "\(store.issues.count.formatted()) beads"
            : "\(store.filteredIssueCount.formatted()) of \(store.issues.count.formatted())"
        guard !store.selectedIDs.isEmpty else { return count }
        return "\(count), \(store.selectedIDs.count.formatted()) selected"
    }
}

private struct ViewOptionsMenu: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        @Bindable var store = store

        Menu {
            Section("Issue Rows") {
                Toggle("Show owner", isOn: $store.showsOwnerInBeadList)
                Toggle("Show assignee", isOn: $store.showsAssigneeInBeadList)
                Toggle("Show due date", isOn: $store.showsDueDateInBeadList)
                Toggle("Show comments", isOn: $store.showsCommentsInBeadList)
            }
        } label: {
            Label("View", systemImage: "slider.horizontal.3")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .disabled(store.projectURL == nil)
        .help(store.projectURL == nil ? "Open a project to change view options" : "View Options")
        .accessibilityLabel("View Options")
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

private struct SortMenu: View {
    @Environment(BeadStore.self) private var store: BeadStore

    var body: some View {
        Menu {
            Section("Sort By") {
                ForEach(IssueSort.allCases) { sort in
                    Button {
                        store.sort = sort
                    } label: {
                        if store.sort == sort {
                            Label(sort.rawValue, systemImage: "checkmark")
                        } else {
                            Text(sort.rawValue)
                        }
                    }
                }
            }

            Divider()

            Button {
                store.sortDirection = .ascending
            } label: {
                if store.sortDirection == .ascending {
                    Label("Ascending", systemImage: "checkmark")
                } else {
                    Text("Ascending")
                }
            }

            Button {
                store.sortDirection = .descending
            } label: {
                if store.sortDirection == .descending {
                    Label("Descending", systemImage: "checkmark")
                } else {
                    Text("Descending")
                }
            }
        } label: {
            Label(store.sort.rawValue, systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("Sort: \(store.sort.rawValue)")
    }
}

/// Row for a gate bead: type-appropriate icon + the condition it's waiting on, with the
/// reason as the subtitle. Used wherever a gate bead appears (chiefly the Gates section,
/// where its blocked beads nest beneath it).
struct GateRowView: View, Equatable {
    let issue: BeadIssue
    let row: IssueListRow
    let gate: BeadGate
    let now: Date
    let showsDisclosure: Bool
    let toggleExpansion: () -> Void

    nonisolated static func == (lhs: GateRowView, rhs: GateRowView) -> Bool {
        lhs.issue == rhs.issue
            && lhs.row == rhs.row
            && lhs.gate == rhs.gate
            && lhs.now == rhs.now
            && lhs.showsDisclosure == rhs.showsDisclosure
    }

    var body: some View {
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
                        .frame(width: IssueListMetrics.disclosureWidth, height: IssueListMetrics.rowHeight)
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

                    Text(BeadFormatters.relative(issue.updatedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    CopyableIssueIDButton(issueID: issue.id)
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
        .frame(height: IssueListMetrics.rowHeight, alignment: .center)
        .contentShape(Rectangle())
    }
}

struct IssueRowView: View, Equatable {
    let issue: BeadIssue
    let row: IssueListRow
    let showsDisclosure: Bool
    let displayOptions: BeadListDisplayOptions
    let statusCategory: BeadStatusCategory
    let blockedReason: BlockedReasonPresentation?
    let blockedByItems: [BlockingRelationshipItem]
    let blockingItems: [BlockingRelationshipItem]
    let openRelatedIssue: (String) -> Void
    let toggleExpansion: () -> Void

    nonisolated static func == (lhs: IssueRowView, rhs: IssueRowView) -> Bool {
        // Compare only the issue fields the row actually renders (see
        // IssueSummaryRowContent): full `BeadIssue` equality scans description/notes
        // bodies that can be kilobytes, per visible row per update.
        displayedIssueFieldsEqual(lhs.issue, rhs.issue)
            && lhs.row == rhs.row
            && lhs.showsDisclosure == rhs.showsDisclosure
            && lhs.displayOptions == rhs.displayOptions
            && lhs.statusCategory == rhs.statusCategory
            && lhs.blockedReason == rhs.blockedReason
            && lhs.blockedByItems == rhs.blockedByItems
            && lhs.blockingItems == rhs.blockingItems
    }

    nonisolated private static func displayedIssueFieldsEqual(_ lhs: BeadIssue, _ rhs: BeadIssue) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.status == rhs.status
            && lhs.priority == rhs.priority
            && lhs.issueType == rhs.issueType
            && lhs.owner == rhs.owner
            && lhs.assignee == rhs.assignee
            && lhs.dueAt == rhs.dueAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.commentCount == rhs.commentCount
            && lhs.labels == rhs.labels
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
                        .frame(width: IssueListMetrics.disclosureWidth, height: IssueListMetrics.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!row.hasChildren)
                .opacity(row.hasChildren ? 1 : 0)
                .accessibilityHidden(!row.hasChildren)
                .help(row.isExpanded ? "Collapse children" : "Expand children")
            }

            IssueSummaryRowContent(
                issue: issue,
                row: row,
                statusCategory: statusCategory,
                titleForegroundStyle: row.isContext ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary),
                issueIDPresentation: .copyable,
                showsOwner: displayOptions.showsOwner,
                showsAssignee: displayOptions.showsAssignee,
                showsDueDate: displayOptions.showsDueDate,
                blockedReason: blockedReason,
                blockedByItems: blockedByItems,
                blockingItems: blockingItems,
                openRelatedIssue: openRelatedIssue,
                showsDependencyCounts: true,
                showsComments: displayOptions.showsComments,
                showsLabels: true
            )
        }
        .frame(height: IssueListMetrics.rowHeight, alignment: .center)
        .contentShape(Rectangle())
    }
}
