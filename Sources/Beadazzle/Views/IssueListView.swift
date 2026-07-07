import SwiftUI

struct IssueListView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let requestClose: (BeadIssue) -> Void
    let requestSetStatus: (Set<String>, String) -> Void
    let openDetail: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            IssueListHeader()

            Divider()

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
                        store: store,
                        requestClose: requestClose,
                        requestSetStatus: requestSetStatus,
                        openDetail: openDetail
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
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
                SortMenu()
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

            if store.hasActiveFilters {
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
    let showsDisclosure: Bool
    let toggleExpansion: () -> Void

    static func == (lhs: GateRowView, rhs: GateRowView) -> Bool {
        lhs.issue == rhs.issue
            && lhs.row == rhs.row
            && lhs.gate == rhs.gate
            && lhs.showsDisclosure == rhs.showsDisclosure
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
                .help(row.isExpanded ? "Collapse blocked beads" : "Expand blocked beads")
            }

            Image(systemName: gate.awaitType.systemImage)
                .font(.caption.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(GatePresentation.tint(isOpen: gate.isOpen))
                .frame(width: 16, alignment: .center)
                .padding(.trailing, 8)
                .help("\(gate.awaitType.title) gate")
                .accessibilityLabel("\(gate.awaitType.title) gate")

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(GatePresentation.conditionHeadline(for: gate))
                        .font(.headline)
                        .lineLimit(1)
                        .layoutPriority(1)

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
    let toggleExpansion: () -> Void

    static func == (lhs: IssueRowView, rhs: IssueRowView) -> Bool {
        lhs.issue == rhs.issue
            && lhs.row == rhs.row
            && lhs.showsDisclosure == rhs.showsDisclosure
            && lhs.displayOptions == rhs.displayOptions
            && lhs.statusCategory == rhs.statusCategory
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
                showsDependencyCounts: true,
                showsComments: displayOptions.showsComments,
                showsLabels: true
            )
        }
        .frame(height: IssueListMetrics.rowHeight, alignment: .center)
        .contentShape(Rectangle())
    }
}
