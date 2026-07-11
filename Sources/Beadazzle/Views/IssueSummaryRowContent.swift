import SwiftUI

struct IssueSummaryRowContent: View {
    enum IssueIDPresentation {
        case copyable
        case plain
    }

    let issue: BeadIssue
    let row: IssueListRow
    let statusCategory: BeadStatusCategory
    var titleForegroundStyle = AnyShapeStyle(.primary)
    var issueIDPresentation: IssueIDPresentation = .copyable
    var showsOwner = false
    var showsAssignee = false
    var showsDueDate = false
    var blockedReason: BlockedReasonPresentation?
    var blockedByItems: [BlockingRelationshipItem] = []
    var blockingItems: [BlockingRelationshipItem] = []
    var openRelatedIssue: (String) -> Void = { _ in }
    var showsDependencyCounts = true
    var showsComments = true
    var showsLabels = true

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: BeadVisualStyle.symbol(forCategory: statusCategory))
                .font(.caption.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(BeadVisualStyle.color(forCategory: statusCategory))
                .frame(width: 16, alignment: .center)
                .padding(.trailing, 8)
                .help("Status: \(issue.status)")
                .accessibilityLabel("Status: \(issue.status)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(issue.title)
                        .font(.headline)
                        .foregroundStyle(titleForegroundStyle)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 8)

                    Text("P\(issue.priority)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(BeadVisualStyle.priorityColor(for: issue.priority))
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                        .help("Priority P\(issue.priority)")
                        .accessibilityLabel("Priority P\(issue.priority)")
                }

                HStack(spacing: 8) {
                    issueIDView

                    Text(issue.issueType)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if showsOwner, let owner = issue.owner?.nilIfBlank {
                        Label(owner, systemImage: "person.crop.circle")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Owner: \(owner)")
                    }

                    if showsAssignee, let assignee = issue.assignee?.nilIfBlank {
                        Label(assignee, systemImage: "person")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Assignee: \(assignee)")
                    }

                    if showsDueDate, let dueAt = issue.dueAt {
                        let dueDate = BeadFormatters.displayDateOnly(dueAt)
                        Label(dueDate, systemImage: "calendar")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Due: \(dueDate)")
                    }

                    if let childProgress = row.childProgress {
                        Label(
                            childProgressTitle(for: childProgress),
                            systemImage: childProgressSystemImage(for: childProgress)
                        )
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(childProgressHelp(for: childProgress))
                        .accessibilityLabel(childProgressAccessibilityLabel(for: childProgress))
                    }

                    if let blockedReason {
                        BlockedReasonInlineLabel(reason: blockedReason)
                    }

                    if showsDependencyCounts, !blockedByItems.isEmpty {
                        BlockingRelationshipCountPopover(
                            direction: .blockedBy,
                            items: blockedByItems,
                            openIssue: openRelatedIssue
                        )
                    }

                    if showsDependencyCounts, !blockingItems.isEmpty {
                        BlockingRelationshipCountPopover(
                            direction: .blocking,
                            items: blockingItems,
                            openIssue: openRelatedIssue
                        )
                    }

                    if showsComments, issue.commentCount > 0 {
                        Label(issue.commentCount.formatted(), systemImage: "text.bubble")
                            .foregroundStyle(.secondary)
                    }

                    if showsLabels, !issue.labels.isEmpty {
                        IssueLabelsPopover(labels: issue.labels)
                    }

                    Spacer()

                    Text(BeadFormatters.relative(issue.updatedAt))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.caption)
            }
        }
        .frame(height: IssueListMetrics.rowHeight, alignment: .center)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var issueIDView: some View {
        switch issueIDPresentation {
        case .copyable:
            CopyableIssueIDButton(issueID: issue.id)
        case .plain:
            Text(issue.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: IssueListMetrics.issueIDWidth, alignment: .leading)
        }
    }

    private func childProgressTitle(for progress: IssueChildProgress) -> String {
        guard progress.workedCount > 0 else { return "Not started" }
        return "\(progress.completedCount.formatted())/\(progress.totalCount.formatted())"
    }

    private func childProgressSystemImage(for progress: IssueChildProgress) -> String {
        progress.workedCount > 0 ? "checkmark.circle" : "circle"
    }

    private func childProgressHelp(for progress: IssueChildProgress) -> String {
        guard progress.workedCount > 0 else {
            return "\(progress.totalCount.formatted()) \(childBeadText(for: progress.totalCount)) not started"
        }
        return "\(progress.completedCount.formatted()) of \(progress.totalCount.formatted()) \(childBeadText(for: progress.totalCount)) completed"
    }

    private func childProgressAccessibilityLabel(for progress: IssueChildProgress) -> String {
        "Child progress: \(childProgressHelp(for: progress))"
    }

    private func childBeadText(for count: Int) -> String {
        count == 1 ? "child bead" : "child beads"
    }
}

private struct BlockedReasonInlineLabel: View {
    let reason: BlockedReasonPresentation

    var body: some View {
        Label {
            Text(reason.title)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: reason.systemImage)
        }
        .foregroundStyle(reason.tint.shapeStyle)
        .lineLimit(1)
        .layoutPriority(1)
        .help(reason.help)
        .accessibilityLabel("Blocked reason")
        .accessibilityValue(reason.accessibilityValue)
    }
}

private extension BlockedReasonPresentation.Tint {
    var shapeStyle: AnyShapeStyle {
        switch self {
        case .secondary:
            AnyShapeStyle(.secondary)
        case .action:
            AnyShapeStyle(GatePresentation.actionTint)
        case .warning:
            AnyShapeStyle(Color(nsColor: .systemOrange))
        case .resolved:
            AnyShapeStyle(Color(nsColor: .systemGreen))
        case .unexplained:
            AnyShapeStyle(.tertiary)
        }
    }
}

struct CopyableIssueIDButton: View {
    let issueID: String
    var width: CGFloat? = IssueListMetrics.issueIDWidth

    @State private var isHovered = false
    @State private var didCopy = false
    @State private var resetCopyTask: Task<Void, Never>?

    var body: some View {
        Button(action: copyIssueID) {
            HStack(spacing: 4) {
                Text(issueID)
                    .font(.caption)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 12, alignment: .center)
                    .opacity(isHovered || didCopy ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(foregroundColor)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onDisappear {
            resetCopyTask?.cancel()
        }
        .help(didCopy ? "Copied \(issueID)" : "Copy \(issueID)")
        .accessibilityLabel("Copy bead ID \(issueID)")
    }

    private var foregroundColor: Color {
        if didCopy {
            return Color(nsColor: .systemGreen)
        }
        return Color(nsColor: isHovered ? .labelColor : .secondaryLabelColor)
    }

    private func copyIssueID() {
        IssueClipboard.copyIssueID(issueID)
        didCopy = true
        resetCopyTask?.cancel()
        resetCopyTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}
