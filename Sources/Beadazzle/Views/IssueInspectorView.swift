import SwiftUI

struct IssueInspector: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue
    @Binding var draft: IssueDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorGroup("Properties") {
                IssueInspectorProperties(draft: $draft, includesStatus: true)
                InspectorRowDivider()

                InspectorValueRow(title: "Assignee", systemImage: "person.crop.circle", value: issue.assignee ?? "None")
                InspectorRowDivider()
                InspectorValueRow(title: "Owner", systemImage: "person.text.rectangle", value: issue.owner ?? "None")
                InspectorRowDivider()
                InspectorLabelsRow(
                    draft: $draft,
                    availableLabels: store.availableLabels
                )

                let blockingGates = store.gatesBlocking(issueID: issue.id)
                if !blockingGates.isEmpty {
                    InspectorRowDivider()
                    InspectorGatesRow(gates: blockingGates) { store.select([$0]) }
                }
                let resolvedGates = store.resolvedGatesForStaleBlockedIssue(issueID: issue.id)
                if !resolvedGates.isEmpty {
                    InspectorRowDivider()
                    ResolvedGateStatusRepairRow(
                        gates: resolvedGates,
                        statusOptions: store.statusOptions(including: draft.status),
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

            InspectorGroup("Relationships") {
                InspectorValueRow(title: "Dependencies", systemImage: "arrow.down.right", value: "\(issue.dependencyCount)")
                InspectorRowDivider()
                InspectorValueRow(title: "Dependents", systemImage: "arrow.up.forward", value: "\(issue.dependentCount)")
                InspectorRowDivider()
                InspectorValueRow(title: "Comments", systemImage: "text.bubble", value: "\(max(issue.commentCount, store.comments(for: issue.id).count))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Lists the gate(s) blocking a bead as clickable rows that jump to the gate.
struct InspectorGatesRow: View {
    let gates: [BeadGate]
    let onSelect: (String) -> Void
    @State private var hoveredID: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(gates.enumerated()), id: \.element.id) { index, gate in
                Button {
                    onSelect(gate.id)
                } label: {
                    InspectorRowLabel(
                        title: index == 0 ? "Gates" : "",
                        systemImage: gate.awaitType.systemImage,
                        tint: GatePresentation.tint(isOpen: gate.isOpen),
                        value: gate.id,
                        showsChevron: true,
                        isHighlighted: hoveredID == gate.id,
                        chevronSymbol: "arrow.up.right"
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    hoveredID = isHovering ? gate.id : (hoveredID == gate.id ? nil : hoveredID)
                }
                .help("Blocked by \(gate.awaitType.title) gate \(gate.id) — open it")
            }
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
        return "Gate \(gateIDs) is closed; choose a status, then save the bead."
    }
}

struct IssueCreationInspector: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Binding var draft: IssueDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorGroup("Properties") {
                IssueInspectorProperties(draft: $draft, includesStatus: false)
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
