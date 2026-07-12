import SwiftUI

struct SavedViewIconPicker: View {
    @Binding var selection: String

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 8), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(BeadSavedViewSymbols.choices, id: \.self) { symbolName in
                Button {
                    selection = symbolName
                } label: {
                    Image(systemName: symbolName)
                        .frame(width: 30, height: 30)
                        .background(selection == symbolName ? Color.accentColor.opacity(0.2) : .clear)
                        .clipShape(.rect(cornerRadius: 5))
                        .overlay(alignment: .bottomTrailing) {
                            if selection == symbolName {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                                    .offset(x: 3, y: 3)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(BeadSavedViewSymbols.title(for: symbolName))
                .accessibilityLabel(BeadSavedViewSymbols.title(for: symbolName))
                .accessibilityAddTraits(selection == symbolName ? .isSelected : [])
            }
        }
    }
}
