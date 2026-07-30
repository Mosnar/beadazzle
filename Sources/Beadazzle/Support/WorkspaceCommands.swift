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
    var searchCoverageTitle: String?
    var toggleSearchCoverage: (() -> Void)?
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
    @FocusedValue(\.beadFindActions) private var findActions

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

        // Find lives in Edit, after the Cut/Copy/Paste/Select All group, which
        // is where macOS apps put it.
        CommandGroup(after: .pasteboard) {
            Menu("Find") {
                Button("Find...") {
                    performFind()
                }
                .keyboardShortcut("f")
                .disabled(actions?.find == nil && findActions?.canFindInCurrent != true)

                Button("Find in Current Bead...") {
                    findActions?.findInCurrent()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(findActions?.canFindInCurrent != true)

                Divider()

                Button("Find Next") {
                    findActions?.findNext()
                }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(findActions?.canStepBetweenMatches != true)

                Button("Find Previous") {
                    findActions?.findPrevious()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(findActions?.canStepBetweenMatches != true)

                Divider()

                Button(actions?.searchCoverageTitle ?? "Search All Beads") {
                    actions?.toggleSearchCoverage?()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(actions?.toggleSearchCoverage == nil)
            }
        }

        CommandGroup(after: .saveItem) {
            Button("Save View as Bookmark...") {
                actions?.saveCurrentViewAsBookmark?()
            }
            .disabled(actions?.saveCurrentViewAsBookmark == nil)
        }
    }

    /// ⌘F escalates: focus the bead-list search field, then — pressed again
    /// while that field still holds focus — open the in-bead find bar. Once
    /// focus moves elsewhere ⌘F goes back to the list search, so it stays a
    /// reliable way to reach it.
    private func performFind() {
        if SearchFieldFocusProbe.isSearchFieldFocused, findActions?.canFindInCurrent == true {
            findActions?.findInCurrent()
            return
        }
        actions?.find?()
    }
}
