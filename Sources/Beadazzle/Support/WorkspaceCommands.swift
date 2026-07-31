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

/// A focused, reference-based target for project synchronization commands. Keeping the
/// store here instead of action closures lets the menu read current availability while
/// still ensuring shortcuts only affect the key workspace window.
struct ProjectSyncCommandContext {
    let store: BeadStore
    let canSynchronize: Bool
}

enum ProjectDoltSyncCommand {
    case pull
    case push

    var title: String {
        switch self {
        case .pull:
            "Pull Beads from Remote"
        case .push:
            "Push Beads to Remote"
        }
    }

    var systemImage: String {
        switch self {
        case .pull:
            "arrow.down.circle"
        case .push:
            "arrow.up.circle"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .pull:
            KeyboardShortcut(.downArrow, modifiers: [.command, .option])
        case .push:
            KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        }
    }
}

private struct WorkspaceCommandActionsKey: FocusedValueKey {
    typealias Value = WorkspaceCommandActions
}

extension FocusedValues {
    var workspaceCommands: WorkspaceCommandActions? {
        get { self[WorkspaceCommandActionsKey.self] }
        set { self[WorkspaceCommandActionsKey.self] = newValue }
    }

    @Entry var projectSyncCommands: ProjectSyncCommandContext?
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceCommands) private var actions
    @FocusedValue(\.beadFindActions) private var findActions
    @FocusedValue(\.projectSyncCommands) private var projectSync

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

            Divider()

            Menu("Beads Sync") {
                Button("Sync Beads with Remote", systemImage: "arrow.triangle.2.circlepath") {
                    performProjectSync()
                }
                .disabled(projectSync?.canSynchronize != true)

                Divider()

                projectSyncButton(.pull)
                projectSyncButton(.push)
            }
            .disabled(projectSync?.canSynchronize != true)
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

    private func performProjectSync() {
        guard let store = projectSync?.store else { return }
        Task { @MainActor in
            _ = await store.synchronizeProjectIssues(reportsFailureInWorkspace: true)
        }
    }

    private func projectSyncButton(_ command: ProjectDoltSyncCommand) -> some View {
        Button(command.title, systemImage: command.systemImage) {
            performProjectSync(command)
        }
        .keyboardShortcut(command.shortcut)
        .disabled(projectSync?.canSynchronize != true)
    }

    private func performProjectSync(_ command: ProjectDoltSyncCommand) {
        guard let store = projectSync?.store else { return }
        Task { @MainActor in
            switch command {
            case .pull:
                _ = await store.pullProjectIssues(reportsFailureInWorkspace: true)
            case .push:
                _ = await store.pushProjectIssues(reportsFailureInWorkspace: true)
            }
        }
    }
}
