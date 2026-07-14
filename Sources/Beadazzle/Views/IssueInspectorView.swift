import SwiftUI

struct IssueInspector: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue
    @Binding var draft: IssueDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorGroup("Properties") {
                ParentBeadPickerControl(issue: issue, draft: $draft)
                InspectorRowDivider()

                IssueInspectorProperties(draft: $draft, includesStatus: true)
                InspectorRowDivider()

                InspectorAssigneeRow(
                    assignee: $draft.assignee,
                    availableAssignees: store.availableAssignees
                )
                InspectorRowDivider()
                InspectorValueRow(title: "Owner", systemImage: "person.text.rectangle", value: issue.owner ?? "None")
                InspectorRowDivider()
                InspectorLabelsRow(
                    draft: $draft,
                    availableLabels: store.availableLabels
                )

                let resolvedGates = store.resolvedGatesForStaleBlockedIssue(issueID: issue.id)
                if !resolvedGates.isEmpty {
                    InspectorRowDivider()
                    ResolvedGateStatusRepairRow(
                        gates: resolvedGates,
                        statusOptions: store.statusChangeOptions(excluding: draft.status),
                        selectedStatus: $draft.status
                    )
                }

                if issue.pinned {
                    InspectorRowDivider()
                    InspectorValueRow(title: "Pinned", systemImage: "pin", value: "Yes")
                }

                if issue.ephemeral {
                    InspectorRowDivider()
                    InspectorValueRow(title: "Ephemeral", systemImage: "sparkle", value: "Yes")
                }
            }

            InspectorGroup("Dates") {
                InspectorValueRow(title: "Created", systemImage: "calendar.badge.plus", value: BeadFormatters.displayDate(issue.createdAt))
                InspectorRowDivider()
                InspectorValueRow(title: "Updated", systemImage: "clock", value: BeadFormatters.displayDate(issue.updatedAt))
                InspectorRowDivider()
                InspectorDateRow(
                    title: "Due",
                    systemImage: "calendar",
                    value: $draft.dueAt,
                    includesDeferredShortcuts: false
                )
                InspectorRowDivider()
                InspectorDateRow(
                    title: "Deferred",
                    systemImage: "pause.circle",
                    value: $draft.deferUntil,
                    includesDeferredShortcuts: true
                )
            }

            let blockedByIssues = store.activeBlockingIssues(for: issue.id)
            let blockingIssues = store.activelyBlockedIssues(by: issue.id)
            if !blockedByIssues.isEmpty || !blockingIssues.isEmpty {
                InspectorGroup("Relations") {
                    InspectorRelationRows(direction: .blockedBy, issues: blockedByIssues)
                    if !blockedByIssues.isEmpty && !blockingIssues.isEmpty {
                        InspectorRowDivider()
                    }
                    InspectorRelationRows(direction: .blocking, issues: blockingIssues)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct InspectorRelationRows: View {
    let direction: BlockingRelationshipDirection
    let issues: [BeadIssue]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Label(direction.title, systemImage: direction.systemImage)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Rectangle()
                        .fill(InspectorChrome.dividerFill.opacity(0.75))
                        .frame(height: 1)
                }
                    .padding(.horizontal, InspectorChrome.rowHorizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ForEach(issues) { issue in
                    InspectorRelationRow(issue: issue)
                }
            }
        }
    }
}

private struct InspectorRelationRow: View {
    let issue: BeadIssue

    var body: some View {
        if let gate = BeadGate(issue: issue) {
            SidebarGateLink(issue: issue, gate: gate)
        } else {
            SidebarBeadLink(issue: issue)
        }
    }
}

struct ResolvedGateStatusRepairRow: View {
    let gates: [BeadGate]
    let statusOptions: [String]
    @Binding var selectedStatus: String
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            InspectorRowLabel(
                title: gates.count == 1 ? "Resolved Gate" : "Resolved Gates",
                systemImage: "checkmark.seal",
                tint: .secondary,
                value: "Set Status...",
                showsChevron: true,
                isHighlighted: isHovered || isPresented
            )
        }
        .buttonStyle(.plain)
        .disabled(statusOptions.isEmpty)
        .onHover { isHovered = $0 }
        .help(helpText)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 2) {
                if statusOptions.isEmpty {
                    Text("No statuses available")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(8)
                } else {
                    ForEach(statusOptions, id: \.self) { status in
                        InspectorOptionItemRow(
                            title: status,
                            isSelected: status == selectedStatus
                        ) {
                            selectedStatus = status
                            isPresented = false
                        }
                    }
                }
            }
            .padding(8)
            .frame(width: 220, alignment: .leading)
        }
        .accessibilityLabel(gates.count == 1 ? "Resolved gate" : "Resolved gates")
        .accessibilityValue("Set status")
    }

    private var helpText: String {
        let gateIDs = gates.map(\.id).joined(separator: ", ")
        guard !statusOptions.isEmpty else {
            return "Gate \(gateIDs) is closed, but no other statuses are available."
        }
        return "Gate \(gateIDs) is closed; choose a status to update the bead."
    }
}

struct IssueCreationInspector: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Binding var draft: IssueDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorGroup("Properties") {
                if let parentID = draft.parentID,
                   let parentIssue = store.issue(with: parentID) {
                    SidebarBeadLink(issue: parentIssue, label: "Parent")
                    InspectorRowDivider()
                }

                IssueInspectorProperties(
                    draft: $draft,
                    includesStatus: false,
                    typeOptions: store.mutableTypeOptions(including: draft.issueType)
                )
                InspectorRowDivider()
                InspectorAssigneeRow(
                    assignee: $draft.assignee,
                    availableAssignees: store.availableAssignees
                )
                InspectorRowDivider()
                InspectorLabelsRow(
                    draft: $draft,
                    availableLabels: store.availableLabels
                )
            }

            InspectorGroup("Dates") {
                InspectorDateRow(
                    title: "Due",
                    systemImage: "calendar",
                    value: $draft.dueAt,
                    includesDeferredShortcuts: false
                )
                InspectorRowDivider()
                InspectorDateRow(
                    title: "Deferred",
                    systemImage: "pause.circle",
                    value: $draft.deferUntil,
                    includesDeferredShortcuts: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
