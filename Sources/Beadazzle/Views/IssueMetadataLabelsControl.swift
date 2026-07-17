import SwiftUI

struct IssueMetadataLabelsControl: View {
    @Binding var draft: IssueDraft
    let availableLabels: [String]
    var presentation: IssueMetadataControlPresentation = .inspectorRow
    /// State dimensions managed by pinned inspector property rows. Their
    /// `dimension:value` labels are hidden here and preserved verbatim on edits,
    /// so the label editor can't silently rewrite state without a `set-state` event.
    var managedStateDimensions: [String] = []
    @State private var isPresented = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private func isManaged(_ label: String, dimensions: Set<String>) -> Bool {
        guard !dimensions.isEmpty,
              let dimension = BeadStateLabel.dimension(of: label) else { return false }
        return dimensions.contains(dimension)
    }

    private func ordinaryLabels(_ labels: [String], dimensions: Set<String>) -> [String] {
        labels.filter { !isManaged($0, dimensions: dimensions) }
    }

    private func editableLabels(managedDimensions: Set<String>) -> Binding<[String]> {
        Binding(
            get: { ordinaryLabels(draft.labels, dimensions: managedDimensions) },
            set: { newValue in
                let managed = draft.labels.filter { isManaged($0, dimensions: managedDimensions) }
                draft.labels = newValue + managed
            }
        )
    }

    private func displayValue(for labels: [String]) -> String {
        guard !labels.isEmpty else { return "None" }
        if labels.count <= 2 {
            return labels.joined(separator: ", ")
        }
        return "\(labels.prefix(2).joined(separator: ", ")) +\(labels.count - 2)"
    }

    var body: some View {
        let managedDimensions = Set(managedStateDimensions)
        let visibleLabels = ordinaryLabels(draft.labels, dimensions: managedDimensions)
        let displayValue = displayValue(for: visibleLabels)
        let labelValue = presentation == .ribbonChip && visibleLabels.isEmpty
            ? "Labels"
            : displayValue
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
                labels: editableLabels(managedDimensions: managedDimensions),
                availableLabels: ordinaryLabels(availableLabels, dimensions: managedDimensions)
            )
        }
        .frame(maxWidth: presentation.maxWidth, alignment: .leading)
    }
}
