import Foundation

extension BeadStore {
    func loadCreationValidationSettingsIfNeeded(force: Bool = false) async {
        guard let projectURL else { return }
        if !force {
            switch creationValidationLoadState {
            case .loading, .loaded:
                return
            case .idle, .failed:
                break
            }
        }

        creationValidationLoadState = .loading
        let commands = commands
        do {
            let settings = try await commands.loadCreationValidationSettings(projectURL: projectURL)
            guard self.projectURL == projectURL else { return }
            creationValidationSettings = settings
            creationValidationLoadState = .loaded
        } catch {
            guard self.projectURL == projectURL else { return }
            creationValidationLoadState = .failed(error.localizedDescription)
        }
    }

    func saveCreationValidationSettings(_ settings: BeadsCreationValidationSettings) async {
        guard let projectURL, !isSavingCreationValidationSettings else { return }
        let previous = creationValidationSettings
        creationValidationSettings = settings
        isSavingCreationValidationSettings = true
        let commands = commands
        do {
            try await enqueueMutationWrite {
                try await commands.saveCreationValidationSettings(
                    projectURL: projectURL,
                    settings: settings
                )
            }
            guard self.projectURL == projectURL else { return }
            creationValidationLoadState = .loaded
        } catch {
            guard self.projectURL == projectURL else { return }
            creationValidationSettings =
                (try? await commands.loadCreationValidationSettings(projectURL: projectURL))
                ?? previous
            creationValidationLoadState = .failed(error.localizedDescription)
            reportMutationFailure(
                error,
                title: "Couldn't save creation validation"
            )
        }
        if self.projectURL == projectURL {
            isSavingCreationValidationSettings = false
        }
    }
}
