import SwiftUI

struct IssueMetadataRibbon: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Binding var draft: IssueDraft
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                IssueMetadataOptionControl(
                    title: "Status",
                    systemImage: store.statusSymbol(for: draft.status),
                    tint: store.statusColor(for: draft.status),
                    options: store.statusOptions(including: draft.status),
                    selected: $draft.status,
                    presentation: .ribbonChip,
                    numericShortcutStart: 1,
                    displayValue: { $0 }
                )
                IssueMetadataOptionControl(
                    title: "Type",
                    systemImage: "tag",
                    options: store.mutableTypeOptions(including: draft.issueType),
                    selected: $draft.issueType,
                    presentation: .ribbonChip,
                    numericShortcutStart: 1,
                    displayValue: { $0 }
                )
                IssueMetadataOptionControl(
                    title: "Priority",
                    systemImage: "exclamationmark.triangle",
                    tint: BeadVisualStyle.priorityColor(for: draft.priority),
                    options: Array(0...4),
                    selected: $draft.priority,
                    presentation: .ribbonChip,
                    numericShortcutStart: 0,
                    displayValue: { "P\($0)" }
                )
                if let issueID = draft.id, let issue = store.issue(with: issueID) {
                    ParentBeadPickerControl(
                        issue: issue,
                        draft: $draft,
                        presentation: .ribbonChip
                    )
                }
                IssueMetadataAssigneeControl(
                    assignee: $draft.assignee,
                    availableAssignees: store.availableAssignees,
                    presentation: .ribbonChip
                )
                IssueMetadataLabelsControl(
                    draft: $draft,
                    availableLabels: store.availableLabels,
                    presentation: .ribbonChip,
                    managedStateDimensions: store.pinnedStateDimensions
                )
                if let issueID = draft.id {
                    ForEach(store.gatesBlocking(issueID: issueID)) { gate in
                        Button {
                            store.select([gate.id])
                        } label: {
                            IssueMetadataRibbonChipLabel(
                                systemImage: gate.systemImage,
                                tint: GatePresentation.tint(for: gate),
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
                // Local progress: appears only when this bead's write outlives the
                // perceptible-latency threshold. Quiet, non-blocking — navigation stays live.
                if let issueID = draft.id, store.isPerceptiblyBusy(issueID: issueID) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 2)
                        .accessibilityLabel("Saving \(issueID)")
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MetadataRibbonContentWidthKey.self,
                        value: proxy.size.width
                    )
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 42)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        // A horizontal `ScrollView` is greedy in both axes. Left unconstrained in the
        // compact detail layout it claimed a share of the page's height and floated the
        // chips in the middle of a tall empty band, so pin it to the row's own height.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHint(
            showsOverflowCue ? "Scroll horizontally for more metadata controls." : ""
        )
        .overlay(alignment: .trailing) {
            if showsOverflowCue {
                LinearGradient(
                    colors: [.clear, InspectorChrome.ribbonFill],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 42)
                .overlay(alignment: .trailing) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 9)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MetadataRibbonViewportWidthKey.self,
                    value: proxy.size.width
                )
            }
        }
        .onPreferenceChange(MetadataRibbonContentWidthKey.self) { contentWidth = $0 }
        .onPreferenceChange(MetadataRibbonViewportWidthKey.self) { viewportWidth = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InspectorChrome.ribbonFill)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bead metadata")
    }

    private var showsOverflowCue: Bool {
        viewportWidth > 0 && contentWidth + 56 > viewportWidth
    }
}

private struct MetadataRibbonContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MetadataRibbonViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ParentBeadRibbonButton: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let parent: BeadIssue
    let onSelect: (String) -> Void
    @State private var isHovered = false

    var body: some View {
        let presentation = ParentBeadPresentation(issue: parent)
        Button {
            onSelect(parent.id)
        } label: {
            IssueMetadataRibbonChipLabel(
                systemImage: store.statusSymbol(for: parent.status),
                tint: store.statusColor(for: parent.status),
                value: presentation.id,
                showsChevron: false,
                isHighlighted: isHovered
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(presentation.helpText)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }
}
