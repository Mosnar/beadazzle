import SwiftUI

struct SidebarBeadLink: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue
    var label: String? = nil

    var body: some View {
        HoverPersistentPopover {
            store.openIssueFromDetail(issueID: issue.id)
        } label: { isHovered in
            HStack(spacing: 8) {
                Image(systemName: store.statusSymbol(for: issue.status))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(store.statusColor(for: issue.status))
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 18, alignment: .center)
                    .accessibilityHidden(true)

                if let label {
                    Text(label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                }

                Text(issue.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }
            .font(.callout)
            .padding(.horizontal, InspectorChrome.rowHorizontalPadding)
            .padding(.trailing, 18)
            .frame(minHeight: InspectorChrome.rowHeight, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: InspectorChrome.rowCornerRadius, style: .continuous))
            .background(isHovered ? InspectorChrome.rowHoverFill : .clear, in: RoundedRectangle(cornerRadius: InspectorChrome.rowCornerRadius, style: .continuous))
            .overlay(alignment: .trailing) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 15, alignment: .trailing)
                    .padding(.trailing, InspectorChrome.rowHorizontalPadding)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(true)
            }
        } preview: {
            BeadDetailPreview(issue: issue)
        }
        .help("\(issue.id) \(issue.title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(issue.title), \(issue.id)")
        .accessibilityValue("Status: \(issue.status), priority P\(issue.priority), type: \(issue.issueType)")
        .accessibilityHint("Opens the bead")
        .beadFolderSource(issueID: issue.id)
    }
}

struct BeadDetailPreview: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SidebarPreviewIDHeader(issueID: issue.id)

            Text(issue.title)
                .font(.headline)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 12) {
                Label(issue.status, systemImage: store.statusSymbol(for: issue.status))
                    .foregroundStyle(store.statusColor(for: issue.status))

                Label("P\(issue.priority)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(BeadVisualStyle.priorityColor(for: issue.priority))

                Label(issue.issueType, systemImage: "tag")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .lineLimit(1)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}
