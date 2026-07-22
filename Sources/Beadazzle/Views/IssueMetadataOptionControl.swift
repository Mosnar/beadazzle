import SwiftUI

struct IssueMetadataOptionControl<Option: Hashable>: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    let options: [Option]
    @Binding var selected: Option
    var presentation: IssueMetadataControlPresentation = .inspectorRow
    var numericShortcutStart: Int? = nil
    let displayValue: (Option) -> String
    @State private var isPresented = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let value = displayValue(selected)
        let isHighlighted = isHovered || isFocused || isPresented
        let hasAlternativeOptions = options.contains { $0 != selected }

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
        .disabled(!hasAlternativeOptions)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .help(hasAlternativeOptions ? "Change \(title.lowercased())" : "No other \(title.lowercased()) options")
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("Opens a menu")
        .popover(isPresented: $isPresented, arrowEdge: presentation.popoverArrowEdge) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options, id: \.self) { option in
                    let shortcut = numericShortcutStart.flatMap { firstNumber in
                        InspectorOptionShortcut.numeric(
                            at: options.firstIndex(of: option),
                            startingAt: firstNumber
                        )
                    }
                    InspectorOptionItemRow(
                        title: displayValue(option),
                        shortcut: shortcut,
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

struct InspectorOptionShortcut: Equatable {
    let number: Int

    var label: String {
        String(number)
    }

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(label))
    }

    static func numeric(at index: Int?, startingAt firstNumber: Int = 1) -> InspectorOptionShortcut? {
        guard let index, index >= 0, (0...9).contains(firstNumber) else { return nil }
        let (number, overflow) = firstNumber.addingReportingOverflow(index)
        guard !overflow, (0...9).contains(number) else { return nil }
        return InspectorOptionShortcut(number: number)
    }
}
