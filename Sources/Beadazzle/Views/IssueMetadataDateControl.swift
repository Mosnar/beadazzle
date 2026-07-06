import SwiftUI

struct IssueMetadataDateControl: View {
    let title: String
    let systemImage: String
    @Binding var value: Date?
    let includesDeferredShortcuts: Bool
    var presentation: IssueMetadataControlPresentation = .inspectorRow
    @State private var isPresented = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private var displayValue: String {
        BeadFormatters.displayDateOnly(value)
    }

    private var labelValue: String {
        guard presentation == .ribbonChip else { return displayValue }
        guard value != nil else { return title }
        return "\(title) \(displayValue)"
    }

    var body: some View {
        let isHighlighted = isHovered || isFocused || isPresented

        Button {
            isPresented.toggle()
        } label: {
            IssueMetadataControlLabel(
                title: title,
                systemImage: systemImage,
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
        .help("Edit \(title.lowercased()) date")
        .accessibilityLabel(title)
        .accessibilityValue(displayValue)
        .accessibilityHint("Opens a calendar")
        .popover(isPresented: $isPresented, arrowEdge: presentation.popoverArrowEdge) {
            DateEditorPopover(
                title: title,
                value: $value,
                includesDeferredShortcuts: includesDeferredShortcuts
            )
        }
        .frame(maxWidth: presentation.maxWidth, alignment: .leading)
    }
}
