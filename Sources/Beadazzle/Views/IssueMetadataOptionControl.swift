import SwiftUI

struct IssueMetadataOptionControl<Option: Hashable>: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    let options: [Option]
    @Binding var selected: Option
    var presentation: IssueMetadataControlPresentation = .inspectorRow
    let displayValue: (Option) -> String
    @State private var isPresented = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let value = displayValue(selected)
        let isHighlighted = isHovered || isFocused || isPresented

        Button {
            isPresented.toggle()
        } label: {
            IssueMetadataControlLabel(
                title: title,
                systemImage: systemImage,
                tint: tint,
                value: value,
                presentation: presentation,
                showsChevron: true,
                isHighlighted: isHighlighted
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help("Change \(title.lowercased())")
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("Opens a menu")
        .popover(isPresented: $isPresented, arrowEdge: presentation.popoverArrowEdge) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options, id: \.self) { option in
                    InspectorOptionItemRow(
                        title: displayValue(option),
                        isSelected: option == selected
                    ) {
                        selected = option
                        isPresented = false
                    }
                }
            }
            .padding(8)
            .frame(width: 220, alignment: .leading)
        }
        .frame(maxWidth: presentation.maxWidth, alignment: .leading)
    }
}
