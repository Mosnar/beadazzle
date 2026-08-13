import SwiftUI

struct RecentProjectRow: View {
    let project: RecentProject
    let isOpenInAnotherWindow: Bool
    let isFocused: Bool
    let focusedItem: FocusState<ProjectPickerFocus?>.Binding
    let focusID: ProjectPickerFocus
    let open: (BeadProjectOpenDestination) -> Void
    let remove: () -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                open(ProjectOpenModifier.destination)
            } label: {
                HStack(spacing: 8) {
                    Label(project.name, systemImage: "folder")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(rowForeground)

                    Spacer(minLength: 8)

                    if isOpenInAnotherWindow {
                        Text("Other Window")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isActive ? .white.opacity(0.78) : .secondary)
                            .fixedSize()
                    }
                }
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
                open(ProjectOpenModifier.destination)
                return .handled
            }
            .onDeleteCommand {
                remove()
            }
            .contextMenu {
                if isOpenInAnotherWindow {
                    Button("Bring Window Forward") {
                        open(.currentWindow)
                    }
                } else {
                    Button("Open in This Window") {
                        open(.currentWindow)
                    }
                    Button("Open in New Window") {
                        open(.newWindow)
                    }
                }
                Divider()
                Button("Remove from Recents", role: .destructive) {
                    remove()
                }
            }
            .help(helpText)
            .accessibilityLabel(project.name)
            .accessibilityValue(accessibilityStatus)
            .accessibilityHint(accessibilityHint)

            ProjectPickerRowButton(
                systemImage: "xmark.circle.fill",
                isVisible: isActive,
                isActive: isActive,
                help: "Remove from Recents",
                accessibilityLabel: "Remove \(project.name) from Recents",
                role: .destructive
            ) {
                remove()
            }
        }
        .padding(.horizontal, 7)
        .frame(minHeight: 28)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { isHovered = $0 }
    }

    private var helpText: String {
        guard isOpenInAnotherWindow else { return project.path }
        return "\(project.path)\nAlready open in another window"
    }

    private var accessibilityStatus: String {
        return isOpenInAnotherWindow ? "Open in another window" : ""
    }

    private var accessibilityHint: String {
        if isOpenInAnotherWindow {
            return "Brings the window showing this project forward. Press Delete to remove it from Recents."
        }
        return "Opens the project. Hold Option to open it in a new window. Press Delete to remove it from Recents."
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
