import Foundation

extension BeadStore {
    func loadProjectHealthStatus() {
        guard let projectURL else {
            resetProjectHealthStatus()
            return
        }

        let healthGeneration = project.beginProjectHealthLoad()
        _isLoadingProjectHealth = true
        _projectHealthActionError = nil

        let commands = commands
        let activeDataSource = currentDataSource
        projectHealthTask = Task { @MainActor [weak self] in
            defer { self?.project.finishProjectHealthLoad(generation: healthGeneration) }
            let snapshot = await ProjectHealthSnapshot.load(
                projectURL: projectURL,
                environment: self?.projectEnvironment,
                activeDataSource: activeDataSource,
                commands: commands
            )
            guard !Task.isCancelled, let self, self.projectURL == projectURL else { return }
            self._projectHealthSnapshot = snapshot
            if let environment = self.projectEnvironment,
               let storageConfig = snapshot.storageConfig.value {
                self._projectEnvironment = environment.applying(storageConfig: storageConfig)
            }
            self._isLoadingProjectHealth = false
        }
    }

    @discardableResult
    func exportProjectSnapshotNow() async -> Bool {
        guard let projectURL = beginProjectHealthAction(.exportingSnapshot) else { return false }
        defer { finishProjectHealthAction(for: projectURL) }

        do {
            guard let beadsDirectoryURL = projectEnvironment?.beadsDirectoryURL else {
                return false
            }
            try await commands.exportReadableSnapshot(
                projectURL: projectURL,
                beadsDirectoryURL: beadsDirectoryURL
            )
            guard self.projectURL == projectURL else { return false }
            refresh(reason: .dataSourceChanged, showsLoadingIndicator: true)
            return true
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            return false
        }
    }

    @discardableResult
    func installProjectHooks() async -> Bool {
        guard projectEnvironment?.gitIntegration == .enabled else { return false }
        guard projectHealthSnapshot?.hooks.value?.hasMissingHooks == true else { return false }
        guard let projectURL = beginProjectHealthAction(.installingHooks) else { return false }
        defer { finishProjectHealthAction(for: projectURL) }

        do {
            try await commands.installHooks(projectURL: projectURL)
            return self.projectURL == projectURL
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            return false
        }
    }

    @discardableResult
    func syncProjectBackup() async -> Bool {
        guard projectHealthSnapshot?.backup.value?.isConfigured == true else { return false }
        guard let projectURL = beginProjectHealthAction(.syncingBackup) else { return false }
        defer { finishProjectHealthAction(for: projectURL) }

        do {
            try await commands.syncBackup(projectURL: projectURL)
            return self.projectURL == projectURL
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            return false
        }
    }

    internal func refreshAfterDataSourceChange() {
        refresh(reason: .dataSourceChanged, showsLoadingIndicator: false)
    }

    internal func resetProjectHealthStatus() {
        projectHealthTask?.cancel()
        projectHealthTask = nil
        _projectHealthSnapshot = nil
        _isLoadingProjectHealth = false
        _projectHealthAction = nil
        _projectHealthActionError = nil
    }

    private func beginProjectHealthAction(_ action: ProjectHealthAction) -> URL? {
        guard let projectURL, projectHealthAction == nil else { return nil }
        _projectHealthAction = action
        _projectHealthActionError = nil
        return projectURL
    }

    private func finishProjectHealthAction(for actionProjectURL: URL) {
        guard projectURL == actionProjectURL else { return }
        _projectHealthAction = nil
        loadProjectHealthStatus()
    }

    private func setProjectHealthActionError(_ error: Error, projectURL actionProjectURL: URL) {
        guard projectURL == actionProjectURL else { return }
        _projectHealthActionError = error.localizedDescription
    }

}
