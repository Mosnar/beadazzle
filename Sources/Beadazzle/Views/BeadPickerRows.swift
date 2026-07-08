import SwiftUI

struct BeadPickerResultRow: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let pickerRow: BeadPickerRow
    let isSelected: Bool
    let mode: IssueListMode
    let isApplying: Bool
    let toggleExpansion: () -> Void
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            if mode == .outline {
                Spacer()
                    .frame(width: CGFloat(pickerRow.row.depth) * IssueListMetrics.depthIndent)

                Button(action: toggleExpansion) {
                    Image(systemName: pickerRow.row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: IssueListMetrics.disclosureWidth, height: IssueListMetrics.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!pickerRow.row.hasChildren || isApplying)
                .opacity(pickerRow.row.hasChildren ? 1 : 0)
                .accessibilityHidden(!pickerRow.row.hasChildren)
                .accessibilityLabel(pickerRow.row.isExpanded ? "Collapse bead" : "Expand bead")
                .accessibilityValue(pickerRow.issue.title)
            }

            Button(action: select) {
                IssueSummaryRowContent(
                    issue: pickerRow.issue,
                    row: pickerRow.row,
                    statusCategory: store.statusCategory(for: pickerRow.issue.status),
                    titleForegroundStyle: AnyShapeStyle(pickerRow.isSelectable ? .primary : .secondary),
                    issueIDPresentation: .plain,
                    showsOwner: false,
                    showsAssignee: false,
                    showsDueDate: false,
                    showsDependencyCounts: false,
                    showsComments: false,
                    showsLabels: true
                )
                .padding(.trailing, 10)
                .opacity(pickerRow.isSelectable ? 1 : 0.62)
            }
            .buttonStyle(.plain)
            .disabled(!pickerRow.isSelectable || isApplying)
        }
        .padding(.horizontal, 8)
        .frame(height: IssueListMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: BeadPickerChrome.rowCornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pickerRow.issue.title), \(pickerRow.issue.id)")
        .accessibilityValue("Status: \(pickerRow.issue.status), priority P\(pickerRow.issue.priority), type: \(pickerRow.issue.issueType)")
    }

    private var rowBackground: Color {
        if isSelected {
            return BeadPickerChrome.selectedRowFill
        }
        if isHovered {
            return BeadPickerChrome.rowHoverFill
        }
        return .clear
    }
}

struct BeadPickerClearParentRow: View {
    let isApplying: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("No Parent")
                    .foregroundStyle(.primary)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? BeadPickerChrome.rowHoverFill : .clear, in: RoundedRectangle(cornerRadius: BeadPickerChrome.rowCornerRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isApplying)
        .onHover { isHovered = $0 }
    }
}

struct BeadPickerEmptyRow: View {
    let isLoading: Bool

    var body: some View {
        Text(isLoading ? "Searching..." : "No matching beads")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }
}
