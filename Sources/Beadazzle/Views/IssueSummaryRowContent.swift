import SwiftUI

struct IssueSummaryRowContent: View {
    enum IssueIDPresentation {
        case copyable
        case plain
    }

    let presentation: IssueSummaryRowPresentation
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
    var allowsHoverPresentation = true

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: BeadVisualStyle.symbol(forCategory: statusCategory))
                .font(.caption.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(BeadVisualStyle.color(forCategory: statusCategory))
                .frame(width: 16, alignment: .center)
                .padding(.trailing, 8)
                .help("Status: \(presentation.status)")
                .accessibilityLabel("Status: \(presentation.status)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(presentation.title)
                        .font(.headline)
                        .foregroundStyle(titleForegroundStyle)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 8)

                    Text("P\(presentation.priority)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(BeadVisualStyle.priorityColor(for: presentation.priority))
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                        .help("Priority P\(presentation.priority)")
                        .accessibilityLabel("Priority P\(presentation.priority)")
                }

                HStack(spacing: 8) {
                    issueIDView

                    Text(presentation.issueType)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if showsOwner, let owner = presentation.owner {
                        Label(owner, systemImage: "person.crop.circle")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Owner: \(owner)")
                    }

                    if showsAssignee, let assignee = presentation.assignee {
                        Label(assignee, systemImage: "person")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Assignee: \(assignee)")
                    }

                    if showsDueDate, let dueAt = presentation.dueAt {
                        let dueDate = BeadFormatters.displayDateOnly(dueAt)
                        Label(dueDate, systemImage: "calendar")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("Due: \(dueDate)")
                    }

                    if let childProgress = row.childProgress {
                        Label(
                            childProgressTitle(for: childProgress),
                            systemImage: BeadIconography.children
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
                            openIssue: openRelatedIssue,
                            allowsHoverPresentation: allowsHoverPresentation
                        )
                    }

                    if showsDependencyCounts, !blockingItems.isEmpty {
                        BlockingRelationshipCountPopover(
                            direction: .blocking,
                            items: blockingItems,
                            openIssue: openRelatedIssue,
                            allowsHoverPresentation: allowsHoverPresentation
                        )
                    }

                    if showsComments, presentation.commentCount > 0 {
                        Label(presentation.commentCount.formatted(), systemImage: "text.bubble")
                            .foregroundStyle(.secondary)
                    }

                    if showsLabels, !presentation.labels.isEmpty {
                        IssueLabelsPopover(
                            labels: presentation.labels,
                            allowsHoverPresentation: allowsHoverPresentation
                        )
                    }

                    Spacer()

                    Text(BeadFormatters.relative(presentation.updatedAt))
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
            CopyableIssueIDButton(
                issueID: presentation.id,
                allowsHoverPresentation: allowsHoverPresentation
            )
        case .plain:
            Text(presentation.id)
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
    var allowsHoverPresentation = true

    @State private var isHovered = false
    @State private var isPointerInside = false
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
        .onHover { hovering in
            isPointerInside = hovering
            guard allowsHoverPresentation else { return }
            isHovered = hovering
        }
        .onChange(of: allowsHoverPresentation) {
            if !allowsHoverPresentation {
                isHovered = false
            } else if isPointerInside {
                isHovered = true
            }
        }
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
