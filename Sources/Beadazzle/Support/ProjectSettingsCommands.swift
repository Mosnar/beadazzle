import SwiftUI

struct ProjectSettingsCommands: Commands {
    let registry: BeadWorkspaceWindowRegistry
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

    /// Resolved from the focused scene so the command targets whichever workspace window
    /// is key. When a non-workspace window is key (Settings, Project Settings itself), no
    /// scene publishes workspace values, so fall back to the frontmost workspace window's
    /// project rather than disabling a command that has an unambiguous target.
    private var projectSettingsURL: URL? {
        actions?.projectSettingsURL ?? registry.frontmostProjectURL?.standardizedFileURL
    }

    private func openCurrentProjectSettings() {
        guard let projectSettingsURL else { return }
        openWindow(value: projectSettingsURL)
    }
}
