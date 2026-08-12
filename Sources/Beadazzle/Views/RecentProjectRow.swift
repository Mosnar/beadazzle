import SwiftUI

struct RecentProjectRow: View {
    let project: RecentProject
    let isCurrent: Bool
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
                    // One fixed-width slot for both states: a project can be the current
                    // window's or another window's, never both, and a stable column keeps
                    // the names aligned down the list.
                    Image(systemName: statusSymbol ?? "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(rowForeground)
                        .opacity(statusSymbol == nil ? 0 : 1)
                        .frame(width: 12)
                        .accessibilityHidden(true)

                    Label(project.name, systemImage: "folder")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(rowForeground)
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
                Button(primaryActionTitle) {
                    open(.currentWindow)
                }
                .disabled(isCurrent)
                Button("Open in New Window") {
                    open(.newWindow)
                }
                .disabled(isCurrent || isOpenInAnotherWindow)
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
                systemImage: "macwindow.badge.plus",
                isVisible: isActive && canOpenInNewWindow,
                isActive: isActive,
                help: "Open in New Window",
                accessibilityLabel: "Open \(project.name) in New Window"
            ) {
                open(.newWindow)
            }

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
        .frame(height: 24)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { isHovered = $0 }
    }

    /// Neither the current window's project nor one already open elsewhere can go to a new
    /// window — the first is already here, and the second would be a duplicate.
    private var canOpenInNewWindow: Bool {
        !isCurrent && !isOpenInAnotherWindow
    }

    private var statusSymbol: String? {
        if isCurrent {
            return "checkmark"
        }
        return isOpenInAnotherWindow ? "macwindow" : nil
    }

    private var primaryActionTitle: String {
        isOpenInAnotherWindow ? "Bring Window Forward" : "Open"
    }

    private var helpText: String {
        guard isOpenInAnotherWindow else { return project.path }
        return "\(project.path)\nAlready open in another window"
    }

    private var accessibilityStatus: String {
        if isCurrent {
            return "Current Project"
        }
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
