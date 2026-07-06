import SwiftUI

struct IssueMetadataRibbon: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Binding var draft: IssueDraft

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                IssueMetadataOptionControl(
                    title: "Status",
                    systemImage: store.statusSymbol(for: draft.status),
                    tint: store.statusColor(for: draft.status),
                    options: store.statusOptions(including: draft.status),
                    selected: $draft.status,
                    presentation: .ribbonChip,
                    displayValue: { $0 }
                )

                IssueMetadataOptionControl(
                    title: "Type",
                    systemImage: "tag",
                    options: store.typeOptions(including: draft.issueType),
                    selected: $draft.issueType,
                    presentation: .ribbonChip,
                    displayValue: { $0 }
                )

                IssueMetadataOptionControl(
                    title: "Priority",
                    systemImage: "exclamationmark.triangle",
                    tint: BeadVisualStyle.priorityColor(for: draft.priority),
                    options: Array(0...4),
                    selected: $draft.priority,
                    presentation: .ribbonChip,
                    displayValue: { "P\($0)" }
                )

                IssueMetadataLabelsControl(
                    draft: $draft,
                    availableLabels: store.availableLabels,
                    presentation: .ribbonChip
                )

                if let issueID = draft.id {
                    ForEach(store.gatesBlocking(issueID: issueID)) { gate in
                        Button {
                            store.select([gate.id])
                        } label: {
                            IssueMetadataRibbonChipLabel(
                                systemImage: gate.awaitType.systemImage,
                                tint: GatePresentation.tint(isOpen: gate.isOpen),
                                value: gate.id,
                                showsChevron: false,
                                isHighlighted: false
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Blocked by \(gate.awaitType.title) gate \(gate.id) — open it")
                    }
                }

                IssueMetadataDateControl(
                    title: "Due",
                    systemImage: "calendar",
                    value: $draft.dueAt,
                    includesDeferredShortcuts: false,
                    presentation: .ribbonChip
                )

                IssueMetadataDateControl(
                    title: "Deferred",
                    systemImage: "pause.circle",
                    value: $draft.deferUntil,
                    includesDeferredShortcuts: true,
                    presentation: .ribbonChip
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InspectorChrome.ribbonFill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bead metadata")
    }
}
