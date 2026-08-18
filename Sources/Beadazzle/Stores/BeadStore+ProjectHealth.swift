import Foundation

extension BeadStore {
    func loadProjectHealthStatus(allowsCachedConfiguration: Bool = false) {
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
        let availableCachedConfiguration = project.takeCachedProjectConfigurationInspection()
        let cachedConfiguration = allowsCachedConfiguration ? availableCachedConfiguration : nil
        projectHealthTask = Task { @MainActor [weak self] in
            defer {
                self?.project.finishProjectHealthLoad(generation: healthGeneration)
                self?.project.finishProjectDoltRemotesLoad(generation: remotesGeneration)
            }
            var snapshot = await ProjectHealthSnapshot.load(
                projectURL: projectURL,
                environment: self?.projectEnvironment,
                activeDataSource: activeDataSource,
                commands: commands,
                preloadedConfiguration: cachedConfiguration
            )
            guard !Task.isCancelled, let self, self.projectURL == projectURL else { return }
            if !self.project.ownsProjectDoltRemotesLoad(
                projectURL: projectURL,
                generation: remotesGeneration
            ), let currentRemotes = self.projectDoltRemotes {
                snapshot.doltRemotes = currentRemotes
            }
            self._projectHealthSnapshot = snapshot
            let previousRemote = self.projectDoltRemotes?.value.flatMap {
                self.doltRemoteFreshnessRemote(in: $0)
            }
            self.project.acceptProjectDoltRemotesFromHealthLoad(
                snapshot.doltRemotes,
                generation: remotesGeneration
            )
            if let environment = self.projectEnvironment,
               let storageConfig = snapshot.storageConfig.value {
                self._projectEnvironment = environment.applying(storageConfig: storageConfig)
            }
            self.projectDoltRemotesDidLoad(previousRemote: previousRemote)
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
            let previousRemote = self.projectDoltRemotes?.value.flatMap {
                self.doltRemoteFreshnessRemote(in: $0)
            }
            self._projectDoltRemotes = remotes
            if var healthSnapshot = self._projectHealthSnapshot {
                healthSnapshot.doltRemotes = remotes
                self._projectHealthSnapshot = healthSnapshot
            }
            self.projectDoltRemotesDidLoad(previousRemote: previousRemote)
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
            && !isApplyingBeadsSetup
            && activeMutationCount == 0
            && projectHealthAction == nil
            && !trackerMigration.blocksWrites
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
        await performProjectIssuePullAction(
            .synchronize,
            reportsFailureInWorkspace: reportsFailureInWorkspace,
            completionRefresh: completionRefresh
        )
    }

    @discardableResult
    func pullProjectIssues(
        reportsFailureInWorkspace: Bool = false,
        completionRefresh: ProjectHealthCompletionRefresh = .none
    ) async -> Bool {
        await performProjectIssuePullAction(
            .pull,
            reportsFailureInWorkspace: reportsFailureInWorkspace,
            completionRefresh: completionRefresh
        )
    }

    private func performProjectIssuePullAction(
        _ pullAction: ProjectIssuePullAction,
        reportsFailureInWorkspace: Bool,
        completionRefresh: ProjectHealthCompletionRefresh
    ) async -> Bool {
        guard canSynchronizeProjectIssues else { return false }
        guard let beadsDirectoryURL = projectEnvironment?.beadsDirectoryURL else { return false }
        let remoteAction = pullAction.remoteAction
        guard let projectURL = beginProjectHealthAction(remoteAction.healthAction) else { return false }
        var succeeded = false
        var cancelled = false
        defer {
            finishProjectDoltSyncAction(
                remoteAction,
                for: projectURL,
                succeeded: succeeded,
                cancelled: cancelled,
                completionRefresh: completionRefresh
            )
        }
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
                pushesAfterPull: pullAction.pushesAfterPull
            )
            guard self.projectURL == projectURL else { return false }
            let remoteWriteSucceeded = outcome.pullFailure == nil && outcome.pushFailure == nil
            if outcome.cancelledBeforeRemoteWrite {
                cancelled = true
                return false
            }
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
            let cancellationRequested = outcome.cancellationRequested
                || projectDoltSyncShouldStop(for: projectURL)
            if remoteWriteSucceeded, !cancellationRequested {
                setProjectDoltSyncPhase(
                    .recordingRemoteCheckpoint(remoteName: projectDoltSyncRemoteName),
                    for: projectURL
                )
                await establishProjectDoltRemoteFreshnessCheckpoint()
                guard self.projectURL == projectURL else { return false }
            }
            let snapshotFailure = snapshotResult.failureMessage
            if let pullFailure = outcome.pullFailure {
                recordProjectIssueCommandFailure(
                    pullFailure,
                    title: remoteAction.failureTitle,
                    snapshotFailure: snapshotFailure,
                    reportsFailureInWorkspace: reportsFailureInWorkspace,
                    retry: { [weak self] in
                        await self?.retryProjectIssuePullAction(pullAction)
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
                        await self?.retryProjectIssuePullAction(pullAction)
                    }
                )
                return false
            }
            if let snapshotFailure {
                let failure = pullAction.snapshotRefreshFailure(snapshotFailure)
                recordProjectIssueSnapshotFailure(
                    failure,
                    reportsFailureInWorkspace: reportsFailureInWorkspace,
                    retry: { [weak self] in
                        await self?.retryProjectIssueSnapshotRefresh()
                    }
                )
                return false
            }
            if cancellationRequested {
                cancelled = true
                return false
            }
            announceCompletion(remoteAction.completionAnnouncement)
            succeeded = true
            return true
        } catch is CancellationError {
            cancelled = true
            return false
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            if reportsFailureInWorkspace, self.projectURL == projectURL {
                reportMutationFailure(
                    error,
                    title: remoteAction.failureTitle,
                    retry: { [weak self] in
                        await self?.retryProjectIssuePullAction(pullAction)
                    }
                )
            }
            return false
        }
    }

    private func retryProjectIssuePullAction(_ action: ProjectIssuePullAction) async {
        switch action {
        case .synchronize:
            _ = await synchronizeProjectIssues(reportsFailureInWorkspace: true)
        case .pull:
            _ = await pullProjectIssues(reportsFailureInWorkspace: true)
        }
    }

    private func performProjectIssueRemoteWrite(
        projectURL: URL,
        beadsDirectoryURL: URL,
        pushesAfterPull: Bool
    ) async throws -> ProjectIssueRemoteWriteOutcome {
        let commands = commands
        let remote = projectDoltSyncRemote
        let remoteName = remote?.name ?? "configured remote"
        let shouldStop: @Sendable () async -> Bool = { [weak self] in
            await self?.projectDoltSyncShouldStop(for: projectURL) ?? true
        }
        let reportPhase: @Sendable (ProjectDoltSyncPhase) async -> Void = { [weak self] phase in
            await self?.setProjectDoltSyncPhase(phase, for: projectURL)
        }
        return try await enqueueMutationWrite {
            if await shouldStop() {
                return ProjectIssueRemoteWriteOutcome(cancelledBeforeRemoteWrite: true)
            }
            if let remote {
                await reportPhase(.checkingRemoteAccess(remoteName: remoteName))
                do {
                    try await commands.verifyDoltRemoteAccess(
                        projectURL: projectURL,
                        remote: remote
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return ProjectIssueRemoteWriteOutcome(
                        pullFailure: ProjectIssueSyncCommandFailure(error)
                    )
                }
                if await shouldStop() {
                    return ProjectIssueRemoteWriteOutcome(cancelledBeforeRemoteWrite: true)
                }
            }
            await reportPhase(.pulling(remoteName: remoteName))
            var pullFailure: ProjectIssueSyncCommandFailure?
            do {
                try await commands.pullDoltRemote(projectURL: projectURL, remote: remote)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pullFailure = ProjectIssueSyncCommandFailure(error)
            }

            var pushFailure: ProjectIssueSyncCommandFailure?
            let cancellationAfterPull = await shouldStop()
            if pullFailure == nil, pushesAfterPull, !cancellationAfterPull {
                await reportPhase(.pushing(remoteName: remoteName))
                do {
                    try await commands.pushDoltRemote(projectURL: projectURL, remote: remote)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    pushFailure = ProjectIssueSyncCommandFailure(error)
                }
            }

            var snapshotExportFailure: String?
            var snapshotExportResult: ReadableSnapshotExportResult?
            await reportPhase(.exportingSnapshot)
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

            let cancellationAfterExport = await shouldStop()
            return ProjectIssueRemoteWriteOutcome(
                pullFailure: pullFailure,
                pushFailure: pushFailure,
                snapshotExportFailure: snapshotExportFailure,
                snapshotExportResult: snapshotExportResult,
                cancellationRequested: cancellationAfterPull || cancellationAfterExport
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
            if activeMutationCount > 0 {
                setProjectDoltSyncPhase(.waitingForLocalChanges, for: projectURL)
            }
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
            setProjectDoltSyncPhase(
                .reloadingIssueList(includesNewExport: requiresFreshExport),
                for: projectURL
            )
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
        let healthMessage = [
            failure.command == nil ? failure.message : "The Beads command failed.",
            snapshotFailure
        ]
            .compactMap(\.self)
            .joined(separator: " ")
        _projectHealthActionError = ProjectHealthActionFailure(
            title: title,
            message: healthMessage,
            command: failure.command,
            output: failure.output
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
            if let outcome = project.projectDoltSyncOutcome,
               outcome.result == .failed,
               (outcome.action == .synchronizingIssues || outcome.action == .pullingIssues) {
                presentProjectDoltSyncOutcome(
                    .succeeded(outcome.action, elapsed: outcome.elapsed),
                    for: projectURL
                )
            }
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
        let remoteAction = ProjectDoltRemoteAction.pushingIssues
        guard let projectURL = beginProjectHealthAction(remoteAction.healthAction) else { return false }
        var succeeded = false
        var cancelled = false
        defer {
            finishProjectDoltSyncAction(
                remoteAction,
                for: projectURL,
                succeeded: succeeded,
                cancelled: cancelled,
                completionRefresh: completionRefresh
            )
        }
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }

        do {
            let commands = commands
            let remote = projectDoltSyncRemote
            let remoteName = remote?.name ?? "configured remote"
            let shouldStop: @Sendable () async -> Bool = { [weak self] in
                await self?.projectDoltSyncShouldStop(for: projectURL) ?? true
            }
            let reportPhase: @Sendable (ProjectDoltSyncPhase) async -> Void = { [weak self] phase in
                await self?.setProjectDoltSyncPhase(phase, for: projectURL)
            }
            try await enqueueMutationWrite {
                guard !(await shouldStop()) else {
                    return
                }
                if let remote {
                    await reportPhase(.checkingRemoteAccess(remoteName: remoteName))
                    try await commands.verifyDoltRemoteAccess(
                        projectURL: projectURL,
                        remote: remote
                    )
                    guard !(await shouldStop()) else {
                        return
                    }
                }
                await reportPhase(.pushing(remoteName: remoteName))
                try await commands.pushDoltRemote(projectURL: projectURL, remote: remote)
            }
            guard self.projectURL == projectURL else { return false }
            if projectDoltSyncShouldStop(for: projectURL) {
                cancelled = true
                return false
            }
            setProjectDoltSyncPhase(
                .recordingRemoteCheckpoint(remoteName: remoteName),
                for: projectURL
            )
            await establishProjectDoltRemoteFreshnessCheckpoint()
            guard self.projectURL == projectURL else { return false }
            if projectDoltSyncShouldStop(for: projectURL) {
                cancelled = true
                return false
            }
            announceCompletion(remoteAction.completionAnnouncement)
            succeeded = true
            return true
        } catch is CancellationError {
            cancelled = true
            return false
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            if reportsFailureInWorkspace, self.projectURL == projectURL {
                reportMutationFailure(
                    error,
                    title: remoteAction.failureTitle,
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
        project.projectDoltSyncOutcomeDismissalTask?.cancel()
        project.projectDoltSyncOutcomeDismissalTask = nil
        _projectHealthSnapshot = nil
        _isLoadingProjectHealth = false
        _projectHealthAction = nil
        project.projectHealthActionStartedAt = nil
        project.projectDoltSyncPhase = nil
        project.projectDoltSyncPhaseStartedAt = nil
        project.isProjectDoltSyncCancellationRequested = false
        _projectHealthActionError = nil
        project.projectDoltSyncOutcome = nil
    }

    private func beginProjectHealthAction(_ action: ProjectHealthAction) -> URL? {
        guard let projectURL,
              projectHealthAction == nil,
              !trackerMigration.blocksWrites else { return nil }
        _projectHealthAction = action
        project.projectHealthActionStartedAt = Date()
        _projectHealthActionError = nil
        if action.isDoltSync {
            project.projectDoltSyncOutcomeDismissalTask?.cancel()
            project.projectDoltSyncOutcomeDismissalTask = nil
            project.projectDoltSyncOutcome = nil
            project.projectDoltSyncPhase = .waitingForWriteQueue
            project.projectDoltSyncPhaseStartedAt = project.projectHealthActionStartedAt
            project.isProjectDoltSyncCancellationRequested = false
        }
        return projectURL
    }

    private var projectDoltSyncRemoteName: String {
        projectDoltSyncRemote?.name ?? "configured remote"
    }

    private var projectDoltSyncRemote: BeadsDoltRemote? {
        projectDoltRemotes?.value.flatMap { doltRemoteFreshnessRemote(in: $0) }
    }

    private func setProjectDoltSyncPhase(
        _ phase: ProjectDoltSyncPhase,
        for actionProjectURL: URL
    ) {
        guard projectURL == actionProjectURL,
              projectHealthAction?.isDoltSync == true,
              project.projectDoltSyncPhase != phase else {
            return
        }
        project.projectDoltSyncPhase = phase
        project.projectDoltSyncPhaseStartedAt = Date()
    }

    func cancelProjectDoltSync() {
        guard projectHealthAction?.isDoltSync == true else {
            return
        }
        project.isProjectDoltSyncCancellationRequested = true
    }

    func dismissProjectDoltSyncOutcome(id: UUID? = nil) {
        guard id == nil || project.projectDoltSyncOutcome?.id == id else { return }
        project.projectDoltSyncOutcomeDismissalTask?.cancel()
        project.projectDoltSyncOutcomeDismissalTask = nil
        project.projectDoltSyncOutcome = nil
    }

    private func projectDoltSyncShouldStop(for actionProjectURL: URL) -> Bool {
        projectURL != actionProjectURL || project.isProjectDoltSyncCancellationRequested
    }

    private func finishProjectDoltSyncAction(
        _ action: ProjectDoltRemoteAction,
        for actionProjectURL: URL,
        succeeded: Bool,
        cancelled: Bool,
        completionRefresh: ProjectHealthCompletionRefresh
    ) {
        guard projectURL == actionProjectURL else { return }
        let failure = projectHealthActionError
        let elapsed = project.projectHealthActionStartedAt.map { Date().timeIntervalSince($0) }
        finishProjectHealthAction(
            for: actionProjectURL,
            completionRefresh: completionRefresh
        )
        let outcome: ProjectDoltSyncOutcome?
        if succeeded {
            outcome = .succeeded(action, elapsed: elapsed)
        } else if cancelled {
            outcome = .cancelled(action, elapsed: elapsed)
        } else if let failure {
            outcome = .failed(action, failure: failure, elapsed: elapsed)
        } else {
            outcome = nil
        }
        if let outcome {
            presentProjectDoltSyncOutcome(outcome, for: actionProjectURL)
        }
    }

    private func finishProjectHealthAction(
        for actionProjectURL: URL,
        completionRefresh: ProjectHealthCompletionRefresh = .fullHealth
    ) {
        guard projectURL == actionProjectURL else { return }
        let actionError = projectHealthActionError
        _projectHealthAction = nil
        project.projectHealthActionStartedAt = nil
        project.projectDoltSyncPhase = nil
        project.projectDoltSyncPhaseStartedAt = nil
        project.isProjectDoltSyncCancellationRequested = false
        if completionRefresh == .fullHealth {
            loadProjectHealthStatus()
        }
        _projectHealthActionError = actionError
    }

    private func presentProjectDoltSyncOutcome(
        _ outcome: ProjectDoltSyncOutcome,
        for actionProjectURL: URL
    ) {
        project.projectDoltSyncOutcomeDismissalTask?.cancel()
        project.projectDoltSyncOutcomeDismissalTask = nil
        project.projectDoltSyncOutcome = outcome
        guard let delay = outcome.automaticDismissDelay else { return }
        project.projectDoltSyncOutcomeDismissalTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  self.projectURL == actionProjectURL,
                  self.project.projectDoltSyncOutcome?.id == outcome.id else {
                return
            }
            self.project.projectDoltSyncOutcome = nil
            self.project.projectDoltSyncOutcomeDismissalTask = nil
        }
    }

    private func setProjectHealthActionError(_ error: Error, projectURL actionProjectURL: URL) {
        guard projectURL == actionProjectURL else { return }
        _projectHealthActionError = .failed(error)
    }

}

private struct ProjectIssueRemoteWriteOutcome: Sendable {
    var pullFailure: ProjectIssueSyncCommandFailure? = nil
    var pushFailure: ProjectIssueSyncCommandFailure? = nil
    var snapshotExportFailure: String? = nil
    var snapshotExportResult: ReadableSnapshotExportResult? = nil
    var cancellationRequested = false
    var cancelledBeforeRemoteWrite = false
}

private enum ProjectIssuePullAction: Sendable {
    case synchronize
    case pull

    var remoteAction: ProjectDoltRemoteAction {
        switch self {
        case .synchronize: .synchronizingIssues
        case .pull: .pullingIssues
        }
    }

    var pushesAfterPull: Bool {
        self == .synchronize
    }

    func snapshotRefreshFailure(_ message: String) -> ProjectHealthActionFailure {
        switch self {
        case .synchronize:
            .syncCompletedButSnapshotRefreshFailed(message)
        case .pull:
            .pullCompletedButSnapshotRefreshFailed(message)
        }
    }
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
