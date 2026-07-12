import SwiftUI

/// Actions the key workspace window publishes for the app menu. Focused values
/// scope these commands to the focused scene — a NotificationCenter broadcast
/// reached every window, so ⌘N/⌘R fired while Settings or Project Settings was
/// key still targeted the main window, and the menu items never disabled.
struct WorkspaceCommandActions {
    var newBead: (() -> Void)?
    var openProject: () -> Void
    var refresh: (() -> Void)?
    var find: (() -> Void)?
    var saveCurrentViewAsBookmark: (() -> Void)?
}

private struct WorkspaceCommandActionsKey: FocusedValueKey {
    typealias Value = WorkspaceCommandActions
}

extension FocusedValues {
    var workspaceCommands: WorkspaceCommandActions? {
        get { self[WorkspaceCommandActionsKey.self] }
        set { self[WorkspaceCommandActionsKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceCommands) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Bead") {
                actions?.newBead?()
            }
            .keyboardShortcut("n")
            .disabled(actions?.newBead == nil)
        }

        CommandGroup(after: .importExport) {
            Button("Open Beads Project...") {
                actions?.openProject()
            }
            .keyboardShortcut("o")
            .disabled(actions == nil)

            Button("Refresh") {
                actions?.refresh?()
            }
            .keyboardShortcut("r")
            .disabled(actions?.refresh == nil)
        }

        CommandMenu("Find") {
            Button("Find") {
                actions?.find?()
            }
            .keyboardShortcut("f")
            .disabled(actions?.find == nil)
        }

        CommandGroup(after: .saveItem) {
            Button("Save View as Bookmark...") {
                actions?.saveCurrentViewAsBookmark?()
            }
            .disabled(actions?.saveCurrentViewAsBookmark == nil)
        }
    }
}
