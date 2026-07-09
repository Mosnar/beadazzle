import SwiftUI

struct ProjectSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let store: BeadStore

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Project Settings...") {
                openCurrentProjectSettings()
            }
            .disabled(projectSettingsURL == nil)
        }
    }

    private var projectSettingsURL: URL? {
        store.projectURL?.standardizedFileURL
    }

    private func openCurrentProjectSettings() {
        guard let projectSettingsURL else { return }
        openWindow(value: projectSettingsURL)
    }
}
