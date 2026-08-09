import SwiftUI

enum BeadNavigationDirection {
    case back
    case forward

    var title: String {
        switch self {
        case .back:
            return "Back"
        case .forward:
            return "Forward"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .back:
            return KeyboardShortcut("[", modifiers: [.command])
        case .forward:
            return KeyboardShortcut("]", modifiers: [.command])
        }
    }
}

/// A focused, reference-based target for navigation commands. Each workspace window has
/// its own history and outline state, so the Navigate menu has to follow the key window
/// rather than a single app-wide store.
struct BeadNavigationCommandContext {
    let store: BeadStore
}

extension FocusedValues {
    @Entry var beadNavigationCommands: BeadNavigationCommandContext?
}

/// The Navigate menu's items. Declared as a view so the app body stays declarative while
/// the items resolve their target from the focused scene.
struct BeadNavigationMenuItems: View {
    @FocusedValue(\.beadNavigationCommands) private var navigation

    var body: some View {
        Button(BeadNavigationDirection.back.title) {
            navigation?.store.goBack()
        }
        .keyboardShortcut(BeadNavigationDirection.back.shortcut)
        .disabled(navigation?.store.canGoBack != true)

        Button(BeadNavigationDirection.forward.title) {
            navigation?.store.goForward()
        }
        .keyboardShortcut(BeadNavigationDirection.forward.shortcut)
        .disabled(navigation?.store.canGoForward != true)

        Divider()

        Button("Expand Children") {
            navigation?.store.expandSelectedIssueChildren()
        }
        .disabled(navigation?.store.canExpandSelectedIssueChildren != true)

        Button("Collapse Children") {
            navigation?.store.collapseSelectedIssueChildren()
        }
        .disabled(navigation?.store.canCollapseSelectedIssueChildren != true)
    }
}

