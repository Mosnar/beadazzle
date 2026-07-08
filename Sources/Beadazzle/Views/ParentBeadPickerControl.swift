import SwiftUI

struct ParentBeadPickerControl: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let issue: BeadIssue
    @Binding var draft: IssueDraft
    var presentation: IssueMetadataControlPresentation = .inspectorRow
    @State private var isPresented = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let parent = store.parentIssue(for: issue.id)
        let isHighlighted = isHovered || isFocused || isPresented

        Button {
            isPresented.toggle()
        } label: {
            IssueMetadataControlLabel(
                title: "Parent",
                systemImage: parent.map { store.statusSymbol(for: $0.status) } ?? "arrow.triangle.branch",
                tint: parent.map { store.statusColor(for: $0.status) } ?? .secondary,
                value: valueText(parent),
                presentation: presentation,
                showsChevron: true,
                isHighlighted: isHighlighted
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help(parent.map { ParentBeadPresentation(issue: $0).helpText } ?? "Choose parent bead")
        .accessibilityLabel("Parent")
        .accessibilityValue(parent.map { ParentBeadPresentation(issue: $0).accessibilityValue } ?? "No parent")
        .accessibilityHint("Opens bead picker")
        .popover(isPresented: $isPresented, arrowEdge: presentation.popoverArrowEdge) {
            BeadPickerPopover(
                configuration: .parent(issue: issue),
                onApplied: { parentID in
                    draft.parentID = parentID
                },
                onDismiss: {
                    isPresented = false
                }
            )
        }
        .frame(maxWidth: presentation.maxWidth, alignment: .leading)
    }

    private func valueText(_ parent: BeadIssue?) -> String {
        guard let parent else { return "No Parent" }
        switch presentation {
        case .inspectorRow:
            return parent.title.nilIfBlank ?? parent.id
        case .ribbonChip:
            return parent.id
        }
    }
}
