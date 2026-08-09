import SwiftUI

struct ProjectSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspaceCommands) private var actions

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Project Settings...") {
                openCurrentProjectSettings()
            }
            .disabled(projectSettingsURL == nil)
        }
    }

    /// Resolved from the focused scene rather than a single app-wide store, so the command
    /// targets whichever workspace window is key.
    private var projectSettingsURL: URL? {
        actions?.projectSettingsURL
    }

    private func openCurrentProjectSettings() {
        guard let projectSettingsURL else { return }
        openWindow(value: projectSettingsURL)
    }
}
