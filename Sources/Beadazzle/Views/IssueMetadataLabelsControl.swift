import SwiftUI

struct IssueMetadataLabelsControl: View {
    @Binding var draft: IssueDraft
    let availableLabels: [String]
    var presentation: IssueMetadataControlPresentation = .inspectorRow
    @State private var isPresented = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var displayValue: String {
        let labels = draft.labels
        guard !labels.isEmpty else { return "None" }
        if labels.count <= 2 {
            return labels.joined(separator: ", ")
        }
        return "\(labels.prefix(2).joined(separator: ", ")) +\(labels.count - 2)"
    }

    private var labelValue: String {
        if presentation == .ribbonChip, draft.labels.isEmpty {
            return "Labels"
        }
        return displayValue
    }

    var body: some View {
        let isHighlighted = isHovered || isFocused || isPresented

        Button {
            isPresented.toggle()
        } label: {
            IssueMetadataControlLabel(
                title: "Labels",
                systemImage: "tag",
                tint: .secondary,
                value: labelValue,
                presentation: presentation,
                showsChevron: true,
                isHighlighted: isHighlighted
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help("Edit labels")
        .accessibilityLabel("Labels")
        .accessibilityValue(displayValue)
        .accessibilityHint("Opens the label editor")
        .popover(isPresented: $isPresented, arrowEdge: presentation.popoverArrowEdge) {
            LabelEditorPopover(
                labels: $draft.labels,
                availableLabels: availableLabels
            )
        }
        .frame(maxWidth: presentation.maxWidth, alignment: .leading)
    }
}
