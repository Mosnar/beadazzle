import SwiftUI

struct ProjectActionRow: View {
    let title: String
    let isFocused: Bool
    let focusedItem: FocusState<ProjectPickerFocus?>.Binding
    let focusID: ProjectPickerFocus
    let action: (BeadProjectOpenDestination) -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                action(ProjectOpenModifier.destination)
            } label: {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(rowForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .focusable()
            .focused(focusedItem, equals: focusID)
            .onKeyPress(.upArrow) {
                moveUp()
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveDown()
                return .handled
            }
            .onKeyPress(.return) {
                action(ProjectOpenModifier.destination)
                return .handled
            }
            .contextMenu {
                Button("Open Project in Current Window…") {
                    action(.currentWindow)
                }
                Button("Open Project in New Window…") {
                    action(.newWindow)
                }
            }
            .accessibilityHint("Hold Option to open the chosen project in a new window.")

            ProjectPickerRowButton(
                systemImage: "macwindow.badge.plus",
                isVisible: isActive,
                isActive: isActive,
                help: "Open Project in New Window",
                accessibilityLabel: "Open Project in New Window"
            ) {
                action(.newWindow)
            }
        }
        .padding(.horizontal, 7)
        .frame(minHeight: 28)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        isActive ? Color(nsColor: .selectedContentBackgroundColor) : .clear
    }

    private var rowForeground: Color {
        isActive ? .white : .primary
    }

    private var isActive: Bool {
        isHovered || isFocused
    }
}
