import Foundation

extension BeadStore {
    func loadProjectHealthStatus() {
        guard let projectURL else {
            resetProjectHealthStatus()
            return
        }

        let healthGeneration = project.beginProjectHealthLoad()
        let remotesGeneration = project.beginProjectDoltRemotesHealthLoad()
        _isLoadingProjectHealth = true
        _projectHealthActionError = nil

        let commands = commands
        let activeDataSource = currentDataSource
        projectHealthTask = Task { @MainActor [weak self] in
            defer {
                self?.project.finishProjectHealthLoad(generation: healthGeneration)
                self?.project.finishProjectDoltRemotesLoad(generation: remotesGeneration)
            }
            var snapshot = await ProjectHealthSnapshot.load(
                projectURL: projectURL,
                environment: self?.projectEnvironment,
                activeDataSource: activeDataSource,
                commands: commands
            )
            guard !Task.isCancelled, let self, self.projectURL == projectURL else { return }
            if !self.project.ownsProjectDoltRemotesLoad(
                projectURL: projectURL,
                generation: remotesGeneration
            ), let currentRemotes = self.projectDoltRemotes {
                snapshot.doltRemotes = currentRemotes
            }
            self._projectHealthSnapshot = snapshot
            self.project.acceptProjectDoltRemotesFromHealthLoad(
                snapshot.doltRemotes,
                generation: remotesGeneration
            )
            if let environment = self.projectEnvironment,
               let storageConfig = snapshot.storageConfig.value {
                self._projectEnvironment = environment.applying(storageConfig: storageConfig)
            }
            self._isLoadingProjectHealth = false
        }
    }

    /// Loads only the Dolt remote list needed by the workspace sync controls. Project
    /// Settings loads a much broader health snapshot; keeping this probe separate lets the
    /// toolbar become available without making every project open pay for all diagnostics.
    func loadProjectDoltRemotesIfNeeded(force: Bool = false) {
        guard let projectURL,
              projectEnvironment?.storageMode == .embedded else {
            projectDoltRemotesTask?.cancel()
            projectDoltRemotesTask = nil
            _projectDoltRemotes = nil
            _isLoadingProjectDoltRemotes = false
            return
        }
        guard force || (projectDoltRemotes == nil && !isLoadingProjectDoltRemotes) else { return }

        let generation = project.beginProjectDoltRemotesLoad()
        let commands = commands
        projectDoltRemotesTask = Task { @MainActor [weak self] in
            defer { self?.project.finishProjectDoltRemotesLoad(generation: generation) }
            let remotes = await ProjectHealthValue.capture {
                try await commands.loadDoltRemotes(projectURL: projectURL)
            }
            guard !Task.isCancelled,
                  let self,
                  self.project.ownsProjectDoltRemotesLoad(
                    projectURL: projectURL,
                    generation: generation
                  ) else {
                return
            }
            self._projectDoltRemotes = remotes
            if var healthSnapshot = self._projectHealthSnapshot {
                healthSnapshot.doltRemotes = remotes
                self._projectHealthSnapshot = healthSnapshot
            }
        }
    }

    var hasConfiguredProjectDoltRemote: Bool {
        projectEnvironment?.storageMode == .embedded
            && projectDoltRemotes?.value?.remotes.isEmpty == false
    }

    var canSynchronizeProjectIssues: Bool {
        hasReadableProject
            && hasConfiguredProjectDoltRemote
            && !isLoading
            && !isInitializingBeads
            && activeMutationCount == 0
            && projectHealthAction == nil
    }

    /// Intended for tests; production UI observes the remote status as it arrives.
    func waitForPendingProjectDoltRemotesLoad() async {
        while let task = projectDoltRemotesTask {
            await task.value
            if projectDoltRemotesTask == task {
                return
            }
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
            invalidateSemanticDefinitionsCache()
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
    func synchronizeProjectIssues(
        reportsFailureInWorkspace: Bool = false,
        completionRefresh: ProjectHealthCompletionRefresh = .none
    ) async -> Bool {
        guard canSynchronizeProjectIssues else { return false }
        guard let beadsDirectoryURL = projectEnvironment?.beadsDirectoryURL else { return false }
        guard let projectURL = beginProjectHealthAction(.synchronizingIssues) else { return false }
        defer { finishProjectHealthAction(for: projectURL, completionRefresh: completionRefresh) }
        let mutationLifetimeGeneration = beginMutation()
        let exportedMutationRevision = mutations.optimisticMutationRevision
        var mutationLifetimeEnded = false
        defer {
            if !mutationLifetimeEnded {
                endMutation(generation: mutationLifetimeGeneration)
            }
        }

        do {
            let outcome = try await performProjectIssueRemoteWrite(
                projectURL: projectURL,
                beadsDirectoryURL: beadsDirectoryURL,
                pushesAfterPull: true
            )
            guard self.projectURL == projectURL else { return false }
            endMutation(generation: mutationLifetimeGeneration)
            mutationLifetimeEnded = true
            markSemanticDefinitionsCacheStale()
            let snapshotResult = await reloadProjectIssuesAfterRemoteWrite(
                projectURL: projectURL,
                exportFailure: outcome.snapshotExportFailure,
                exportedMutationRevision: exportedMutationRevision,
                exportResult: outcome.snapshotExportResult
            )
            guard self.projectURL == projectURL else { return false }
            if case .projectChanged = snapshotResult { return false }
            let snapshotFailure = snapshotResult.failureMessage
            if let pullFailure = outcome.pullFailure {
                recordProjectIssueCommandFailure(
                    pullFailure,
                    title: "Couldn't sync beads with remote",
                    snapshotFailure: snapshotFailure,
                    reportsFailureInWorkspace: reportsFailureInWorkspace,
                    retry: { [weak self] in
                        _ = await self?.synchronizeProjectIssues(reportsFailureInWorkspace: true)
                    }
                )
                return false
            }
            if let pushFailure = outcome.pushFailure {
                recordProjectIssueCommandFailure(
                    pushFailure,
                    title: "Pulled beads, but couldn't push",
                    snapshotFailure: snapshotFailure,
                    reportsFailureInWorkspace: reportsFailureInWorkspace,
                    retry: { [weak self] in
                        _ = await self?.synchronizeProjectIssues(reportsFailureInWorkspace: true)
                    }
                )
                return false
            }
            if let snapshotFailure {
                let failure = ProjectHealthActionFailure.syncCompletedButSnapshotRefreshFailed(
                    snapshotFailure
                )
                recordProjectIssueSnapshotFailure(
                    failure,
                    reportsFailureInWorkspace: reportsFailureInWorkspace,
                    retry: { [weak self] in
                        await self?.retryProjectIssueSnapshotRefresh()
                    }
                )
                return false
            }
            announceCompletion("Synced beads with remote")
            return true
        } catch is CancellationError {
            return false
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            if reportsFailureInWorkspace, self.projectURL == projectURL {
                reportMutationFailure(
                    error,
                    title: "Couldn't sync beads with remote",
                    retry: { [weak self] in
                        _ = await self?.synchronizeProjectIssues(reportsFailureInWorkspace: true)
                    }
                )
            }
            return false
        }
    }

    @discardableResult
    func pullProjectIssues(
        reportsFailureInWorkspace: Bool = false,
        completionRefresh: ProjectHealthCompletionRefresh = .none
    ) async -> Bool {
        guard canSynchronizeProjectIssues else { return false }
        guard let beadsDirectoryURL = projectEnvironment?.beadsDirectoryURL else { return false }
        guard let projectURL = beginProjectHealthAction(.pullingIssues) else { return false }
        defer { finishProjectHealthAction(for: projectURL, completionRefresh: completionRefresh) }
        let mutationLifetimeGeneration = beginMutation()
        let exportedMutationRevision = mutations.optimisticMutationRevision
        var mutationLifetimeEnded = false
        defer {
            if !mutationLifetimeEnded {
                endMutation(generation: mutationLifetimeGeneration)
            }
        }

        do {
            let outcome = try await performProjectIssueRemoteWrite(
                projectURL: projectURL,
                beadsDirectoryURL: beadsDirectoryURL,
                pushesAfterPull: false
            )
            guard self.projectURL == projectURL else { return false }
            endMutation(generation: mutationLifetimeGeneration)
            mutationLifetimeEnded = true
            markSemanticDefinitionsCacheStale()
            let snapshotResult = await reloadProjectIssuesAfterRemoteWrite(
                projectURL: projectURL,
                exportFailure: outcome.snapshotExportFailure,
                exportedMutationRevision: exportedMutationRevision,
                exportResult: outcome.snapshotExportResult
            )
            guard self.projectURL == projectURL else { return false }
            if case .projectChanged = snapshotResult { return false }
            let snapshotFailure = snapshotResult.failureMessage
            if let pullFailure = outcome.pullFailure {
                recordProjectIssueCommandFailure(
                    pullFailure,
                    title: "Couldn't pull beads from remote",
                    snapshotFailure: snapshotFailure,
                    reportsFailureInWorkspace: reportsFailureInWorkspace,
                    retry: { [weak self] in
                        _ = await self?.pullProjectIssues(reportsFailureInWorkspace: true)
                    }
                )
                return false
            }
            if let snapshotFailure {
                let failure = ProjectHealthActionFailure.pullCompletedButSnapshotRefreshFailed(
                    snapshotFailure
                )
                recordProjectIssueSnapshotFailure(
                    failure,
                    reportsFailureInWorkspace: reportsFailureInWorkspace,
                    retry: { [weak self] in
                        await self?.retryProjectIssueSnapshotRefresh()
                    }
                )
                return false
            }
            announceCompletion("Pulled beads from remote")
            return true
        } catch is CancellationError {
            return false
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            if reportsFailureInWorkspace, self.projectURL == projectURL {
                reportMutationFailure(
                    error,
                    title: "Couldn't pull beads from remote",
                    retry: { [weak self] in
                        _ = await self?.pullProjectIssues(reportsFailureInWorkspace: true)
                    }
                )
            }
            return false
        }
    }

    private func performProjectIssueRemoteWrite(
        projectURL: URL,
        beadsDirectoryURL: URL,
        pushesAfterPull: Bool
    ) async throws -> ProjectIssueRemoteWriteOutcome {
        let commands = commands
        return try await enqueueMutationWrite {
            var pullFailure: ProjectIssueSyncCommandFailure?
            do {
                try await commands.pullDoltRemote(projectURL: projectURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pullFailure = ProjectIssueSyncCommandFailure(error)
            }

            var pushFailure: ProjectIssueSyncCommandFailure?
            if pullFailure == nil, pushesAfterPull {
                do {
                    try await commands.pushDoltRemote(projectURL: projectURL)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    pushFailure = ProjectIssueSyncCommandFailure(error)
                }
            }

            var snapshotExportFailure: String?
            var snapshotExportResult: ReadableSnapshotExportResult?
            do {
                snapshotExportResult = try await commands.exportReadableSnapshotWithResult(
                    projectURL: projectURL,
                    beadsDirectoryURL: beadsDirectoryURL
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                snapshotExportFailure = error.localizedDescription
            }

            return ProjectIssueRemoteWriteOutcome(
                pullFailure: pullFailure,
                pushFailure: pushFailure,
                snapshotExportFailure: snapshotExportFailure,
                snapshotExportResult: snapshotExportResult
            )
        }
    }

    private func reloadProjectIssuesAfterRemoteWrite(
        projectURL: URL,
        exportFailure: String?,
        exportedMutationRevision: Int,
        exportResult: ReadableSnapshotExportResult?
    ) async -> ProjectIssueSnapshotRefreshResult {
        guard self.projectURL == projectURL else { return .projectChanged }
        if let exportFailure {
            let message = "Beadazzle could not export its readable snapshot. The issue list may be stale. \(exportFailure)"
            _snapshotFreshness = snapshotFreshness.possiblyStale(afterFailedRefresh: message)
            return .failed(message)
        }
        while self.projectURL == projectURL {
            await waitForActiveMutationsToFinish()
            guard self.projectURL == projectURL else { return .projectChanged }

            let reloadMutationRevision = mutations.optimisticMutationRevision
            let requiresFreshExport = reloadMutationRevision != exportedMutationRevision
            guard beginImmediateReconcile(trigger: .externalMarker) else {
                if let inFlightRefresh = refreshTask {
                    _ = await inFlightRefresh.value
                    continue
                }
                let message = "Beadazzle could not claim the exported snapshot reload. The issue list may be stale."
                _snapshotFreshness = snapshotFreshness.possiblyStale(afterFailedRefresh: message)
                return .failed(message)
            }
            if !requiresFreshExport,
               exportResult?.didReplaceSnapshot == false,
               let source = exportResult?.loadedSnapshot?.source,
               completeClaimedReconcileWithoutReload(projectURL: projectURL, source: source) {
                return .refreshed
            }
            guard let refreshTask = refresh(
                reason: requiresFreshExport ? .reconcile : .dataSourceChanged,
                showsLoadingIndicator: true,
                preparedSnapshot: requiresFreshExport ? nil : exportResult?.loadedSnapshot
            ) else {
                reconcileState.terminate()
                continue
            }
            let didRefresh = await refreshTask.value
            guard self.projectURL == projectURL else { return .projectChanged }
            if didRefresh {
                return .refreshed
            }
            if activeMutationCount > 0
                || mutations.optimisticMutationRevision != reloadMutationRevision {
                continue
            }
            let detail = lastError?.nilIfBlank ?? "The readable snapshot could not be reloaded."
            return .failed("Beadazzle exported the readable snapshot but could not reload the issue list. \(detail)")
        }
        return .projectChanged
    }

    private func recordProjectIssueCommandFailure(
        _ failure: ProjectIssueSyncCommandFailure,
        title: String,
        snapshotFailure: String?,
        reportsFailureInWorkspace: Bool,
        retry: (() async -> Void)?
    ) {
        let healthMessage = [failure.message, snapshotFailure]
            .compactMap(\.self)
            .joined(separator: " ")
        _projectHealthActionError = ProjectHealthActionFailure(
            title: title,
            message: healthMessage
        )
        guard reportsFailureInWorkspace else { return }
        let workspaceMessage = [
            failure.command == nil ? failure.message : "The Beads command failed.",
            snapshotFailure
        ]
            .compactMap(\.self)
            .joined(separator: " ")
        enqueueFailure(BeadMutationFailure(
            title: title,
            message: workspaceMessage,
            command: failure.command,
            output: failure.output,
            retry: retry
        ))
    }

    private func recordProjectIssueSnapshotFailure(
        _ failure: ProjectHealthActionFailure,
        reportsFailureInWorkspace: Bool,
        retry: (() async -> Void)?
    ) {
        _projectHealthActionError = failure
        guard reportsFailureInWorkspace else { return }
        enqueueFailure(BeadMutationFailure(
            title: failure.title,
            message: failure.message,
            retry: retry
        ))
    }

    private func retryProjectIssueSnapshotRefresh() async {
        guard let projectURL,
              let refreshTask = refresh(reason: .manual, showsLoadingIndicator: true) else {
            return
        }
        let didRefresh = await refreshTask.value
        guard self.projectURL == projectURL else { return }
        if didRefresh {
            _projectHealthActionError = nil
            announceCompletion("Refreshed beads")
            return
        }
        let detail = lastError?.nilIfBlank ?? "The readable snapshot could not be refreshed."
        let failure = ProjectHealthActionFailure(
            title: "Couldn't refresh local beads",
            message: detail
        )
        _projectHealthActionError = failure
        enqueueFailure(BeadMutationFailure(
            title: failure.title,
            message: failure.message,
            retry: { [weak self] in
                await self?.retryProjectIssueSnapshotRefresh()
            }
        ))
    }

    @discardableResult
    func pushProjectIssues(
        reportsFailureInWorkspace: Bool = false,
        completionRefresh: ProjectHealthCompletionRefresh = .none
    ) async -> Bool {
        guard canSynchronizeProjectIssues else { return false }
        guard let projectURL = beginProjectHealthAction(.pushingIssues) else { return false }
        defer { finishProjectHealthAction(for: projectURL, completionRefresh: completionRefresh) }
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }

        do {
            let commands = commands
            try await enqueueMutationWrite {
                try await commands.pushDoltRemote(projectURL: projectURL)
            }
            guard self.projectURL == projectURL else { return false }
            announceCompletion("Pushed beads to remote")
            return true
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            if reportsFailureInWorkspace, self.projectURL == projectURL {
                reportMutationFailure(
                    error,
                    title: "Couldn't push beads to remote",
                    retry: { [weak self] in
                        _ = await self?.pushProjectIssues(reportsFailureInWorkspace: true)
                    }
                )
            }
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

    private func finishProjectHealthAction(
        for actionProjectURL: URL,
        completionRefresh: ProjectHealthCompletionRefresh = .fullHealth
    ) {
        guard projectURL == actionProjectURL else { return }
        let actionError = projectHealthActionError
        _projectHealthAction = nil
        if completionRefresh == .fullHealth {
            loadProjectHealthStatus()
        }
        _projectHealthActionError = actionError
    }

    private func setProjectHealthActionError(_ error: Error, projectURL actionProjectURL: URL) {
        guard projectURL == actionProjectURL else { return }
        _projectHealthActionError = .failed(error)
    }

}

private struct ProjectIssueRemoteWriteOutcome: Sendable {
    var pullFailure: ProjectIssueSyncCommandFailure?
    var pushFailure: ProjectIssueSyncCommandFailure?
    var snapshotExportFailure: String?
    var snapshotExportResult: ReadableSnapshotExportResult?
}

private enum ProjectIssueSnapshotRefreshResult: Sendable {
    case refreshed
    case failed(String)
    case projectChanged

    var failureMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

private struct ProjectIssueSyncCommandFailure: LocalizedError, Sendable {
    let message: String
    let command: String?
    let output: String?

    init(_ error: Error) {
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if case let BeadError.commandFailed(command, output) = error {
            self.command = command
            self.output = output
        } else {
            command = nil
            output = nil
        }
    }

    var errorDescription: String? { message }
}

private enum ProjectDatabaseMaintenanceError: Error, Sendable {
    case snapshotExportFailed(String)
}
