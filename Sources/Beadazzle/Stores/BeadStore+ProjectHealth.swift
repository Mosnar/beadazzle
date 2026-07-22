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

    @discardableResult
    func performDoltMaintenance(
        _ kind: BeadsDoltMaintenanceKind,
        allowsProceedingWithoutBackup: Bool
    ) async -> Bool {
        guard let beadsDirectoryURL = projectEnvironment?.beadsDirectoryURL else { return false }
        let action: ProjectHealthAction = kind == .compact ? .compactingDatabase : .flatteningDatabase
        guard let projectURL = beginProjectHealthAction(action) else { return false }
        defer { finishProjectHealthAction(for: projectURL) }
        let mutationLifetimeGeneration = beginMutation()
        var mutationLifetimeEnded = false
        defer {
            if !mutationLifetimeEnded {
                endMutation(generation: mutationLifetimeGeneration)
            }
        }

        let commands = commands
        let backupIsConfigured = projectHealthSnapshot?.backup.value?.isConfigured == true
        do {
            try await enqueueMutationWrite {
                let preview = await commands.loadDoltMaintenancePreview(projectURL: projectURL)
                let previewError: String?
                switch kind {
                case .compact:
                    previewError = preview.compact.value == nil
                        ? preview.compact.errorMessage ?? "Compaction is unavailable for this database mode."
                        : nil
                case .flatten:
                    previewError = preview.flatten.value == nil
                        ? preview.flatten.errorMessage ?? "Flattening is unavailable for this database mode."
                        : nil
                }
                if let previewError {
                    throw BeadError.commandFailed(
                        command: kind == .compact ? "bd compact --dry-run" : "bd flatten --dry-run",
                        output: previewError
                    )
                }
                switch kind {
                case .compact:
                    guard let compact = preview.compact.value, compact.oldCommits > 1 else {
                        throw BeadError.commandFailed(
                            command: "bd compact --dry-run",
                            output: "There are fewer than two commits older than the retention window, so compaction would not reduce history."
                        )
                    }
                case .flatten:
                    guard let flatten = preview.flatten.value,
                          flatten.wouldFlatten,
                          flatten.commitCount > 1 else {
                        throw BeadError.commandFailed(
                            command: "bd flatten --dry-run",
                            output: "The database history is already flat."
                        )
                    }
                }

                if backupIsConfigured {
                    do {
                        try await commands.syncBackup(projectURL: projectURL)
                    } catch {
                        guard allowsProceedingWithoutBackup else { throw error }
                    }
                } else if !allowsProceedingWithoutBackup {
                    throw BeadError.commandFailed(
                        command: "bd backup sync",
                        output: "Configure a backup, or explicitly allow maintenance without a current backup."
                    )
                }

                switch kind {
                case .compact:
                    try await commands.compactDoltDatabase(projectURL: projectURL, retainingDays: 30)
                case .flatten:
                    try await commands.flattenDoltDatabase(projectURL: projectURL)
                }
                do {
                    try await commands.exportReadableSnapshot(
                        projectURL: projectURL,
                        beadsDirectoryURL: beadsDirectoryURL
                    )
                } catch {
                    throw ProjectDatabaseMaintenanceError.snapshotExportFailed(error.localizedDescription)
                }
            }
            guard self.projectURL == projectURL else { return false }
            endMutation(generation: mutationLifetimeGeneration)
            mutationLifetimeEnded = true
            cachedDefinitions = nil
            refresh(reason: .dataSourceChanged, showsLoadingIndicator: true)
            announceCompletion(kind == .compact ? "Database compacted" : "Database history flattened")
            return true
        } catch is CancellationError {
            return false
        } catch ProjectDatabaseMaintenanceError.snapshotExportFailed(let message) {
            guard self.projectURL == projectURL else { return false }
            _snapshotFreshness = snapshotFreshness.possiblyStale(afterFailedRefresh: message)
            _projectHealthActionError = .maintenanceCompletedButSnapshotRefreshFailed(message)
            return false
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            return false
        }
    }

    @discardableResult
    func pullProjectIssues() async -> Bool {
        guard projectHealthSnapshot?.doltRemotes.value?.remotes.isEmpty == false else { return false }
        guard let beadsDirectoryURL = projectEnvironment?.beadsDirectoryURL else { return false }
        guard let projectURL = beginProjectHealthAction(.pullingIssues) else { return false }
        defer { finishProjectHealthAction(for: projectURL) }
        let mutationLifetimeGeneration = beginMutation()
        var mutationLifetimeEnded = false
        defer {
            if !mutationLifetimeEnded {
                endMutation(generation: mutationLifetimeGeneration)
            }
        }

        do {
            let commands = commands
            try await enqueueMutationWrite {
                try await commands.pullDoltRemote(projectURL: projectURL)
                do {
                    try await commands.exportReadableSnapshot(
                        projectURL: projectURL,
                        beadsDirectoryURL: beadsDirectoryURL
                    )
                } catch {
                    throw ProjectIssuePullError.snapshotExportFailed(error.localizedDescription)
                }
            }
            guard self.projectURL == projectURL else { return false }
            endMutation(generation: mutationLifetimeGeneration)
            mutationLifetimeEnded = true
            cachedDefinitions = nil
            refresh(reason: .dataSourceChanged, showsLoadingIndicator: true)
            return true
        } catch ProjectIssuePullError.snapshotExportFailed(let message) {
            guard self.projectURL == projectURL else { return false }
            _snapshotFreshness = snapshotFreshness.possiblyStale(afterFailedRefresh: message)
            _projectHealthActionError = .pullCompletedButSnapshotRefreshFailed(message)
            return false
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            return false
        }
    }

    @discardableResult
    func pushProjectIssues() async -> Bool {
        guard projectHealthSnapshot?.doltRemotes.value?.remotes.isEmpty == false else { return false }
        guard let projectURL = beginProjectHealthAction(.pushingIssues) else { return false }
        defer { finishProjectHealthAction(for: projectURL) }
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }

        do {
            let commands = commands
            try await enqueueMutationWrite {
                try await commands.pushDoltRemote(projectURL: projectURL)
            }
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
        let actionError = projectHealthActionError
        _projectHealthAction = nil
        loadProjectHealthStatus()
        _projectHealthActionError = actionError
    }

    private func setProjectHealthActionError(_ error: Error, projectURL actionProjectURL: URL) {
        guard projectURL == actionProjectURL else { return }
        _projectHealthActionError = .failed(error)
    }

}

private enum ProjectIssuePullError: Error, Sendable {
    case snapshotExportFailed(String)
}

private enum ProjectDatabaseMaintenanceError: Error, Sendable {
    case snapshotExportFailed(String)
}
