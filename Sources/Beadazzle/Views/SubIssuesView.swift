import SwiftUI

struct SubIssuesView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue

    var body: some View {
        let rows = store.subIssueRows(parentID: issue.id)
        let items = rows.compactMap { row -> SubIssueListItem? in
            guard let child = store.issue(with: row.issueID) else { return nil }
            return SubIssueListItem(issue: child, row: row)
        }

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Sub-issues")
                    .font(.headline)

                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    store.beginCreatingChildBead(parentID: issue.id)
                } label: {
                    Label("New Sub-issue", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!store.canCreateChildBead(parentID: issue.id))
                .help("Create sub-issue")
                .accessibilityLabel("Create sub-issue")
            }

            if items.isEmpty {
                Text("No sub-issues.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        SubIssueRow(issue: item.issue, row: item.row)
                        Divider()
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }

    private var progressText: String {
        guard let progress = store.childProgress(parentID: issue.id) else { return "0/0" }
        return "\(progress.completedCount.formatted())/\(progress.totalCount.formatted())"
    }
}

private struct SubIssueListItem: Identifiable {
    var id: String { issue.id }
    let issue: BeadIssue
    let row: IssueListRow
}

private struct SubIssueRow: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue
    let row: IssueListRow
    @State private var isHovered = false

    var body: some View {
        let statusCategory = store.statusCategory(for: issue.status)

        Button {
            store.openIssueFromDetail(issueID: issue.id)
        } label: {
            IssueSummaryRowContent(
                issue: issue,
                row: row,
                statusCategory: statusCategory,
                titleForegroundStyle: AnyShapeStyle(.primary),
                issueIDPresentation: .plain,
                showsOwner: false,
                showsAssignee: false,
                showsDueDate: false,
                showsDependencyCounts: false,
                showsComments: false,
                showsLabels: false
            )
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: InspectorChrome.rowCornerRadius, style: .continuous))
            .background(isHovered ? InspectorChrome.rowHoverFill : .clear, in: RoundedRectangle(cornerRadius: InspectorChrome.rowCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(issue.title), \(issue.id)")
        .accessibilityValue("Status: \(issue.status), priority P\(issue.priority), type: \(issue.issueType)")
        .accessibilityHint("Opens the sub-issue")
    }
}
