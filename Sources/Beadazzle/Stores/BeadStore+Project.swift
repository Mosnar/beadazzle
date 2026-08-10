import Foundation

private enum SemanticDefinitionsRefreshResult: Sendable {
    case unchanged
    case rebuilt(BeadProjectIndex)
}

extension BeadStore {
    /// Opens the most recent project that still exists on disk. `excludedProjectPaths`
    /// lets the caller skip projects another window already shows, so restoring several
    /// windows doesn't land two of them on the same tracker.
    func openDefaultProjectIfAvailable(excludingProjectPaths excludedProjectPaths: Set<String> = []) {
        guard projectURL == nil else { return }
        guard let url = recentProjects.map(\.url).first(where: { url in
            !excludedProjectPaths.contains(url.standardizedFileURL.path)
                && projectDirectoryExists(at: url)
        }) else {
            return
        }
        openProject(url)
    }

    func openProject(_ url: URL) {
        let url = url.standardizedFileURL
        let outgoingProjectURL = projectURL
        let outgoingBeadsDirectoryURL = projectEnvironment?.beadsDirectoryURL
        // Persist the outgoing project's state now, while its URL and live workspace are still
        // current, so a pending debounce can't be dropped by the switch.
        flushPendingWorkspaceState()
        project.cancelLifecycleWork()
        mutations.writeQueue.invalidatePending()
        mutations.resetMetadataMutations()
        folderAutomationSummary = nil
        folderAutomationProgress = nil
        workspace.cancelQueryWork()
        detail.cancelSelectionWork()
        if let outgoingProjectURL, outgoingProjectURL != url {
            let activityHistoryRepository = activityHistoryRepository
            Task {
                await activityHistoryRepository.discard(
                    projectURL: outgoingProjectURL,
                    beadsDirectoryURL: outgoingBeadsDirectoryURL
                )
            }
        }
        stopDataSourceMonitor()
        _projectURL = url
        resetProjectHealthStatus()
        _isApplyingBeadsSetup = false
        _beadsSetupIntent = beadsSetupPreferenceRepository.loadIntent(projectURL: url)
        beadsSetupDismissedFingerprint = beadsSetupPreferenceRepository.dismissedFingerprint(projectURL: url)
        _beadsSetupAssessment = nil
        _beadsSetupFindings = []
        project.cacheProjectConfigurationInspection(nil)
        if projectDirectoryExists(at: url) {
            rememberRecentProject(url)
        }
        clearLoadedProjectData()
        if let definitionsCache = semanticDefinitionsRepository.load(projectURL: url) {
            cachedDefinitions = definitionsCache.entry.definitions
            cachedDefinitionsTrackerDirectoryURL = definitionsCache.trackerDirectoryURL
            cachedDefinitionsLastCheckedAt = definitionsCache.entry.refreshedAt
        }
        // The persisted value accelerates first paint only. Always verify it in the
        // background after resolving the current tracker so relaunches see CLI edits.
        cachedDefinitionsNeedRefresh = true
        loadProjectPreferences(for: url)
        resetWorkspaceQueryForProjectSwitch()
        // Stash the persisted snapshot; it can only be restored once the index has loaded
        // (selection/saved-view identities are validated against it in applyLoadedProject).
        pendingRestoredWorkspaceSnapshot = workspaceStateRepository.load(projectURL: url)?.snapshot()
        resetWorkspaceHistory()
        _projectReadiness = .ready
        refresh(reason: .initial, showsLoadingIndicator: true)
    }

    /// Retires everything this store owns when its window goes away: pending workspace
    /// state is persisted first, then the in-flight tasks and file-system monitors are
    /// cancelled so a closed window stops watching the tracker directory.
    ///
    /// Queued `bd` writes are deliberately left to drain: each one is a user edit that the
    /// optimistic UI already showed as applied, so unlike a project switch — where the
    /// store is being rebound and stale writes are rejected — closing the window must not
    /// silently drop them. The registry keeps the tracker reserved until
    /// `finishRetirementAfterWindowClose()` completes.
    func prepareForWindowClose() {
        isRetiredAfterWindowClose = true
        flushPendingWorkspaceState()
        project.cancelLifecycleWork()
        cancelSemanticDefinitionsRefresh()
        workspace.cancelQueryWork()
        detail.cancelSelectionWork()
        stopDataSourceMonitor()
    }

    var hasPendingMutationWrites: Bool {
        mutations.writeQueue.hasPendingOperations
    }

    /// Completes a closed window's write handoff: waits for the serialized queue to
    /// drain, then exports one final readable snapshot so the drained writes are visible
    /// to the next window that opens this tracker. The reconcile pipeline is suppressed
    /// once the window closes — there is no UI left to reconcile — so this is the export
    /// half a reconcile would otherwise have run.
    func finishRetirementAfterWindowClose() async {
        await mutations.writeQueue.drainPending()
        guard let projectURL else { return }
        try? await commands.exportReadableSnapshot(projectURL: projectURL)
    }

    /// Releases a project whose tracker resolved to one another window already owns,
    /// then falls back to the recents like a duplicate restoration — or to the empty
    /// state when every remaining recent is taken or gone.
    internal func resignProjectWithDuplicateTracker(excludingProjectPaths: Set<String>) {
        guard let duplicateURL = projectURL else { return }
        let duplicatePath = duplicateURL.standardizedFileURL.path
        let fallbackURL = recentProjects.map(\.url).first { url in
            let path = url.standardizedFileURL.path
            return path != duplicatePath
                && !excludingProjectPaths.contains(path)
                && projectDirectoryExists(at: url)
        }
        if let fallbackURL {
            openProject(fallbackURL)
        } else {
            closeProject()
        }
    }

    /// Tears the current project down to the no-project state: the outgoing half of
    /// `openProject` without an incoming project.
    internal func closeProject() {
        guard let outgoingProjectURL = projectURL else { return }
        let outgoingBeadsDirectoryURL = projectEnvironment?.beadsDirectoryURL
        flushPendingWorkspaceState()
        project.cancelLifecycleWork()
        mutations.writeQueue.invalidatePending()
        mutations.resetMetadataMutations()
        folderAutomationSummary = nil
        folderAutomationProgress = nil
        workspace.cancelQueryWork()
        detail.cancelSelectionWork()
        let activityHistoryRepository = activityHistoryRepository
        Task {
            await activityHistoryRepository.discard(
                projectURL: outgoingProjectURL,
                beadsDirectoryURL: outgoingBeadsDirectoryURL
            )
        }
        stopDataSourceMonitor()
        _projectURL = nil
        resetProjectHealthStatus()
        _isApplyingBeadsSetup = false
        _beadsSetupIntent = nil
        beadsSetupDismissedFingerprint = nil
        _beadsSetupAssessment = nil
        _beadsSetupFindings = []
        project.cacheProjectConfigurationInspection(nil)
        clearLoadedProjectData()
        resetWorkspaceQueryForProjectSwitch()
        pendingRestoredWorkspaceSnapshot = nil
        resetWorkspaceHistory()
        _projectReadiness = .noProject
        _isLoading = false
        lastError = nil
    }

    func removeRecentProject(_ project: RecentProject) {
        _recentProjects.removeAll { $0.id == project.id }
        persistRecentProjects()
    }

    private func rememberRecentProject(_ url: URL) {
        let project = RecentProject(url: url)
        var nextProjects = recentProjects.filter { $0.id != project.id }
        nextProjects.insert(project, at: 0)
        _recentProjects = Array(nextProjects.prefix(Self.maxRecentProjectCount))
        persistRecentProjects()
    }

    internal func persistRecentProjects() {
        userDefaults.set(recentProjects.map(\.path), forKey: Self.recentProjectPathsKey)

        if let lastProjectPath = recentProjects.first?.path {
            userDefaults.set(lastProjectPath, forKey: Self.lastProjectPathKey)
        } else {
            userDefaults.removeObject(forKey: Self.lastProjectPathKey)
        }

        guard !isReloadingSharedAppState else { return }
        appStateBroadcaster?.recentProjectsDidChange(from: self)
    }

    /// Re-reads the shared recents list after a sibling window opened or removed a project.
    internal func reloadRecentProjects() {
        _recentProjects = Self.loadRecentProjects(from: userDefaults)
    }

    internal static func loadRecentProjects(from userDefaults: UserDefaults) -> [RecentProject] {
        let paths = userDefaults.stringArray(forKey: recentProjectPathsKey) ?? []
        var seenIDs: Set<String> = []
        var projects: [RecentProject] = []

        for path in paths where !path.isEmpty {
            let project = RecentProject(url: URL(fileURLWithPath: path))
            guard seenIDs.insert(project.id).inserted else { continue }
            projects.append(project)
            if projects.count == maxRecentProjectCount {
                break
            }
        }

        return projects
    }

    internal func projectDirectoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func setMissingDataSource(_ url: URL) {
        _projectReadiness = .missingDataSource(url)
        _isLoading = false
        lastError = nil
        stopDataSourceMonitor()
        clearLoadedProjectData()
        resetWorkspaceHistory()
    }

    private func setUnsupportedProject(_ url: URL, detail: String) {
        _projectReadiness = .unsupportedProject(url.standardizedFileURL, detail)
        _isLoading = false
        stopDataSourceMonitor()
        clearLoadedProjectData()
        resetWorkspaceHistory()
    }

    private func setProjectUnavailable(_ url: URL, detail: String) {
        _projectReadiness = .projectUnavailable(url.standardizedFileURL, detail)
        _isLoading = false
        stopDataSourceMonitor()
        clearLoadedProjectData()
        resetWorkspaceHistory()
    }

    private func clearLoadedProjectData() {
        project.cancelReconciliationWork()
        reconcileState.reset()
        projectionGeneration &+= 1
        projectionMaterializationTask?.cancel()
        projectionMaterializationTask = nil
        mutations.projection.reset()
        authoritativeIndex = .empty
        index = .empty
        stateLabelOverridesByIssueID = [:]
        _filteredIssueIDs = []
        _issueListRows = []
        _dependencies = []
        _dependencyIssueID = nil
        _comments = []
        _commentsIssueID = nil
        commentCache = [:]
        _commentRefreshIssueID = nil
        _commentLoadError = nil
        _activityItems = []
        _activityIssueID = nil
        _activityRefreshIssueID = nil
        _activityLoadError = nil
        _isLoadingActivity = false
        activityEvents = []
        activityLoadedIssueID = nil
        pendingFailures.removeAll()
        detail.cancelSelectionWork()
        _gatesByID = [:]
        _currentDataSource = nil
        _projectEnvironment = nil
        _beadsSetupAssessment = nil
        _beadsSetupFindings = []
        projectDoltRemotesTask?.cancel()
        projectDoltRemotesTask = nil
        _projectDoltRemotes = nil
        _isLoadingProjectDoltRemotes = false
        project.cancelDoltRemoteFreshnessCheck()
        _doltRemoteFreshness = .unknown
        _ownerIdentity = .unavailable
        _snapshotFreshness = .unknown
        cachedDefinitions = nil
        cachedDefinitionsTrackerDirectoryURL = nil
        cachedDefinitionsLastCheckedAt = nil
        cachedDefinitionsNeedRefresh = false
        lastServerActivationRefreshAt = nil
        _selectedIDs.removeAll()
        _fullPageDetailIssueID = nil
        creationDraft = nil
        creationValidationSettings = .beadsDefault
        creationValidationLoadState = .idle
        isSavingCreationValidationSettings = false
        outlineState.clear()
        _filterCounts = .empty
        _savedViewCounts = [:]
        _isRebuildingSavedViewCounts = false
        _isLoadingComments = false
        _isAddingComment = false
        syncWorkspaceHistoryAvailability()
    }

    func refresh() {
        refresh(reason: .manual, showsLoadingIndicator: true)
    }

    private func refreshOwnerIdentity(for projectURL: URL, showsResolvingState: Bool) {
        let generation = project.beginOwnerIdentityLoad()
        if showsResolvingState {
            _ownerIdentity = .resolving
        }
        let resolver = ownerIdentityResolver
        ownerIdentityTask = Task { @MainActor [weak self] in
            defer { self?.project.finishOwnerIdentityLoad(generation: generation) }
            let identity = await resolver.resolve(projectURL: projectURL)
            guard !Task.isCancelled,
                  let self,
                  self.project.ownsOwnerIdentityLoad(
                      projectURL: projectURL,
                      generation: generation
                  )
            else {
                return
            }
            self._ownerIdentity = identity
        }
    }

    /// Server-backed trackers can change without touching this Mac's snapshot files.
    /// Refresh once when the app becomes active, with a short guard against duplicate
    /// scene notifications. Embedded projects stay entirely event-driven.
    func refreshServerProjectOnActivation(now: Date = Date()) {
        guard automaticallyRefreshesExternalChanges,
              projectReadiness.isReady,
              projectEnvironment?.storageMode.refreshesWhenAppActivates == true,
              !isLoading,
              activeMutationCount == 0 else {
            return
        }
        if let lastServerActivationRefreshAt {
            let elapsed = now.timeIntervalSince(lastServerActivationRefreshAt)
            if elapsed >= 0, elapsed < 5 {
                return
            }
        }
        lastServerActivationRefreshAt = now
        refresh(reason: .reconcile, showsLoadingIndicator: false)
    }

    @discardableResult
    internal func refresh(
        reason: RefreshReason,
        showsLoadingIndicator: Bool,
        preparedSnapshot: LoadedBeadsSnapshot? = nil
    ) -> Task<Bool, Never>? {
        guard let projectURL else { return nil }
        guard reason == .initial || activeMutationCount == 0 else {
            queueRefreshAfterMutation(reason: reason)
            return nil
        }
        if reason == .manual {
            cancelSemanticDefinitionsRefresh()
            loadProjectDoltRemotesIfNeeded(force: true)
        }
        if reason == .initial || reason == .manual {
            refreshOwnerIdentity(for: projectURL, showsResolvingState: reason == .initial)
        }
        let refreshGeneration = project.beginRefresh()
        // A manual refresh or project (re)load reads authoritative state directly, so any
        // queued coalesced reconcile would just be a redundant reload — drop it.
        if reason == .manual || reason == .initial {
            reconcileDebounceTask?.cancel()
            reconcileDebounceTask = nil
            reconcileState.reset()
        }
        if showsLoadingIndicator {
            _isLoading = true
        }
        if reason != .dataSourceChanged {
            lastError = nil
        }
        if reason == .dataSourceChanged,
           cachedDefinitionsLastCheckedAt.map({
               Date().timeIntervalSince($0) >= 60
           }) != false {
            cachedDefinitionsNeedRefresh = true
        }
        let projectLoader = projectLoader
        let staleCutoffDays = staleCutoffDays
        let hidesParentsWithOnlyBlockedChildrenInReady = hidesParentsWithOnlyBlockedChildrenInReady

        // Mutations and explicit user refreshes must re-export the readable JSONL
        // snapshot first: automatic export is optional and may be throttled, so
        // recent `bd` writes may not appear immediately.
        let forcesSnapshotExport = reason == .reconcile || reason == .manual

        // Status/type definitions rarely change, and reading them costs two `bd`
        // subprocesses. Reuse the cache except when the user explicitly refreshes, on the
        // first load, or after the app edited definitions (which clears the cache) —
        // otherwise every routine reload would re-run `bd`.
        let usesProvisionalDefinitions = reason == .initial
        let reloadsDefinitions = reason == .manual
            || (!usesProvisionalDefinitions && cachedDefinitions == nil)
        let definitionsForLoad = reloadsDefinitions ? nil : cachedDefinitions
        let definitionsTrackerForLoad = reloadsDefinitions
            ? nil
            : cachedDefinitionsTrackerDirectoryURL
        let loadsDefinitionsIfMissing = !usesProvisionalDefinitions
        let reloadsEnvironment = reason == .initial || reason == .manual || projectEnvironment == nil
        let environmentForLoad = reloadsEnvironment ? nil : projectEnvironment
        let metadataBaseline = mutations.reloadBaseline()
        let optimisticMutationRevision = mutations.optimisticMutationRevision
        if let currentDataSource {
            _snapshotFreshness = snapshotFreshness.refreshing(
                projectURL: projectURL,
                beadsDirectoryURL: projectEnvironment?.beadsDirectoryURL,
                source: currentDataSource
            )
        }

        let task = Task { @MainActor [weak self] in
            defer { self?.project.finishRefresh(generation: refreshGeneration) }
            do {
                let snapshotTask = Task {
                    if forcesSnapshotExport {
                        return try await projectLoader.refreshSnapshotAndLoadProject(
                            projectURL: projectURL,
                            staleCutoffDays: staleCutoffDays,
                            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
                            cachedDefinitions: definitionsForLoad,
                            cachedDefinitionsTrackerDirectoryURL: definitionsTrackerForLoad,
                            cachedEnvironment: environmentForLoad,
                            loadsDefinitionsIfMissing: loadsDefinitionsIfMissing
                        )
                    }
                    return try await projectLoader.loadProject(
                        projectURL: projectURL,
                        staleCutoffDays: staleCutoffDays,
                        hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
                        cachedDefinitions: definitionsForLoad,
                        cachedDefinitionsTrackerDirectoryURL: definitionsTrackerForLoad,
                        cachedEnvironment: environmentForLoad,
                        loadsDefinitionsIfMissing: loadsDefinitionsIfMissing,
                        preparedSnapshot: preparedSnapshot
                    )
                }
                let loadedProject = try await withTaskCancellationHandler {
                    try await snapshotTask.value
                } onCancel: {
                    snapshotTask.cancel()
                }
                guard !Task.isCancelled,
                      let self,
                      self.projectURL == projectURL,
                      self.project.ownsRefresh(projectURL: projectURL, generation: refreshGeneration)
                else { return false }
                guard reason == .initial
                        || self.mutations.optimisticMutationRevision == optimisticMutationRevision
                else {
                    if showsLoadingIndicator {
                        self._isLoading = false
                    }
                    self.queueRefreshAfterMutation(reason: reason)
                    return false
                }
                if reason == .dataSourceChanged,
                   self.currentDataSource == loadedProject.source,
                   self.mutations.projection.isEmpty {
                    let deferredMonitorRoles = self.reconcileState.complete(
                        replaysDeferredEvents: true
                    )
                    if showsLoadingIndicator {
                        self._isLoading = false
                    }
                    self.markSnapshotFreshnessLoaded(
                        projectURL: projectURL,
                        beadsDirectoryURL: loadedProject.environment.beadsDirectoryURL,
                        source: loadedProject.source
                    )
                    self.refreshSemanticDefinitionsIfNeeded(projectURL: projectURL)
                    if !deferredMonitorRoles.isEmpty {
                        self.handleDataSourceMonitorEvent(
                            BeadsDataSourceMonitor.Event(roles: deferredMonitorRoles),
                            projectURL: projectURL
                        )
                    }
                    self.scheduleReconcileIfIdle()
                    return true
                }
                self.applyLoadedProject(
                    loadedProject,
                    projectURL: projectURL,
                    queuesInitialExternalRefresh: reason == .initial,
                    metadataBaseline: metadataBaseline
                )
                self.refreshSemanticDefinitionsIfNeeded(projectURL: projectURL)
                return true
            } catch is CancellationError {
                guard let self,
                      self.project.ownsRefresh(projectURL: projectURL, generation: refreshGeneration)
                else { return false }
                self.finishReconcileAfterRefreshTermination(
                    projectURL: projectURL,
                    refreshGeneration: refreshGeneration
                )
                return false
            } catch BeadError.projectMissingDataSource(let missingURL) {
                guard let self, !Task.isCancelled, self.projectURL == projectURL else { return false }
                let recoveryTask = Task {
                    try await projectLoader.exportAndLoadProject(
                        projectURL: projectURL,
                        staleCutoffDays: self.staleCutoffDays,
                        hidesParentsWithOnlyBlockedChildrenInReady: self.hidesParentsWithOnlyBlockedChildrenInReady,
                        cachedDefinitions: definitionsForLoad,
                        cachedDefinitionsTrackerDirectoryURL: definitionsTrackerForLoad,
                        cachedEnvironment: environmentForLoad,
                        loadsDefinitionsIfMissing: loadsDefinitionsIfMissing
                    )
                }
                do {
                    let recoveredProject = try await withTaskCancellationHandler(operation: {
                        try await recoveryTask.value
                    }, onCancel: {
                        recoveryTask.cancel()
                    })
                    guard !Task.isCancelled,
                          self.projectURL == projectURL,
                          self.project.ownsRefresh(projectURL: projectURL, generation: refreshGeneration)
                    else { return false }
                    guard reason == .initial
                            || self.mutations.optimisticMutationRevision == optimisticMutationRevision
                    else {
                        if showsLoadingIndicator {
                            self._isLoading = false
                        }
                        self.queueRefreshAfterMutation(reason: reason)
                        return false
                    }
                    self.applyLoadedProject(
                        recoveredProject,
                        projectURL: projectURL,
                        queuesInitialExternalRefresh: reason == .initial,
                        metadataBaseline: metadataBaseline
                    )
                    self.refreshSemanticDefinitionsIfNeeded(projectURL: projectURL)
                    return true
                } catch is CancellationError {
                    guard self.project.ownsRefresh(
                        projectURL: projectURL,
                        generation: refreshGeneration
                    ) else { return false }
                    self.finishReconcileAfterRefreshTermination(
                        projectURL: projectURL,
                        refreshGeneration: refreshGeneration
                    )
                    return false
                } catch BeadError.projectMissingDataSource {
                    guard !Task.isCancelled, self.projectURL == projectURL else { return false }
                    self.setMissingDataSource(missingURL)
                    return false
                } catch BeadError.unsupportedProjectMode(let unsupportedURL, let detail) {
                    guard !Task.isCancelled, self.projectURL == projectURL else { return false }
                    self.setUnsupportedProject(unsupportedURL, detail: detail)
                    return false
                } catch {
                    guard !Task.isCancelled, self.projectURL == projectURL else { return false }
                    self.setProjectUnavailable(projectURL, detail: error.localizedDescription)
                    self.markSnapshotFreshnessFailed(error.localizedDescription)
                    return false
                }
            } catch BeadError.unsupportedProjectMode(let unsupportedURL, let detail) {
                guard !Task.isCancelled, let self, self.projectURL == projectURL else { return false }
                self.setUnsupportedProject(unsupportedURL, detail: detail)
                self.finishReconcileAfterRefreshTermination(
                    projectURL: projectURL,
                    refreshGeneration: refreshGeneration
                )
                return false
            } catch {
                guard !Task.isCancelled, let self, self.projectURL == projectURL else { return false }
                if self.currentDataSource == nil {
                    self.setProjectUnavailable(projectURL, detail: error.localizedDescription)
                } else {
                    self.lastError = error.localizedDescription
                    self._isLoading = false
                }
                self.markSnapshotFreshnessFailed(error.localizedDescription)
                self.finishReconcileAfterRefreshTermination(
                    projectURL: projectURL,
                    refreshGeneration: refreshGeneration
                )
                return false
            }
        }
        refreshTask = task
        return task
    }

    private func queueRefreshAfterMutation(reason: RefreshReason) {
        if reason == .manual {
            invalidateSemanticDefinitionsCache()
        }
        requestReconcile(
            trigger: reason == .dataSourceChanged ? .externalMarker : .mutation
        )
    }

    internal func applyLoadedProject(
        _ loadedProject: LoadedProject,
        projectURL: URL,
        queuesInitialExternalRefresh: Bool = false,
        metadataBaseline: BeadMetadataReloadBaseline? = nil
    ) {
        let deferredMonitorRoles = reconcileState.complete(
            replaysDeferredEvents: loadedProject.snapshotRefreshWarning == nil
        )
        _projectReadiness = .ready
        let loadedIndex = indexMatchingCurrentProjectPreferences(from: loadedProject.index)
        let refreshedAuthoritativeIndex = metadataBaseline.map {
            indexPreservingMetadataChanges(in: loadedIndex, since: $0)
        } ?? loadedIndex
        authoritativeIndex = refreshedAuthoritativeIndex
        mutations.projection.reconcile(
            authoritative: loadedProject.snapshotRefreshWarning == nil
        )
        index = refreshedAuthoritativeIndex
        reconcileStateLabelOverrides(
            authoritative: loadedProject.snapshotRefreshWarning == nil
        )
        if loadedProject.snapshotRefreshWarning == nil {
            mutations.confirmAuthoritativeMetadata()
        }
        _contentRevision &+= 1
        if loadedProject.snapshotRefreshWarning == nil {
            pruneMissingFolderIssueIDs(validIssueIDs: refreshedAuthoritativeIndex.allIssueIDs)
        }
        scheduleSavedViewCountRebuild()
        let trackerDirectoryURL = loadedProject.environment.beadsDirectoryURL.standardizedFileURL
        if let cachedDefinitionsTrackerDirectoryURL,
           cachedDefinitionsTrackerDirectoryURL.standardizedFileURL.path != trackerDirectoryURL.path {
            cachedDefinitions = nil
            cachedDefinitionsLastCheckedAt = nil
            cachedDefinitionsNeedRefresh = true
        }
        if let definitions = loadedProject.definitions {
            cachedDefinitions = definitions
            cachedDefinitionsTrackerDirectoryURL = trackerDirectoryURL
            if loadedProject.definitionsLoadedFromCommands {
                let refreshedAt = Date()
                semanticDefinitionsRepository.save(
                    definitions,
                    projectURL: projectURL,
                    trackerDirectoryURL: trackerDirectoryURL,
                    refreshedAt: refreshedAt
                )
                cachedDefinitionsLastCheckedAt = refreshedAt
                cachedDefinitionsNeedRefresh = false
            }
        } else if cachedDefinitions == nil {
            cachedDefinitionsTrackerDirectoryURL = trackerDirectoryURL
        }
        _projectEnvironment = loadedProject.environment
        // Exclusivity is by resolved tracker identity, not project path: two roots can
        // route to one tracker. The registry defers its duplicate repair to a fresh turn,
        // so this cannot reenter the store mid-apply.
        appStateBroadcaster?.projectTrackerDidResolve(from: self)
        if isApplyingBeadsSetup {
            // Setup schedules one audit after the applied project is installed. Avoid
            // racing it with a duplicate remote inspection during this intermediate load.
        } else if beadsSetupIntent != nil,
           beadsSetupAssessment == nil,
           !isInspectingBeadsSetup,
           !isApplyingBeadsSetup {
            refreshBeadsSetupAudit()
        } else {
            loadProjectDoltRemotesIfNeeded()
        }
        _currentDataSource = loadedProject.source
        markSnapshotFreshnessLoaded(
            projectURL: projectURL,
            beadsDirectoryURL: loadedProject.environment.beadsDirectoryURL,
            source: loadedProject.source
        )
        if let warning = loadedProject.snapshotRefreshWarning {
            _snapshotFreshness = snapshotFreshness.possiblyStale(afterFailedRefresh: warning)
        }
        _selectedIDs = selectedIDs.filter(index.isUserFacingIssueID)
        pruneExpandedIssueIDs()
        expandAncestorsForSelection(rebuildRows: false)
        reconcileCommentCache(with: loadedProject.snapshot.issues)
        applyFilters()
        loadDependenciesForSelection()
        syncCommentsForSelectionFromCache()
        prepareActivityForSelection()
        loadActivityForSelection(force: true)
        _isLoading = false
        lastError = nil
        synchronizeDataSourceMonitor(
            projectURL: projectURL,
            beadsDirectoryURL: loadedProject.environment.beadsDirectoryURL,
            source: loadedProject.source
        )
        pruneGateDetailsForCurrentSnapshot()
        loadWaitersForSelectedGateIfNeeded()
        // Restore persisted workspace state exactly once per open, now that the index is available
        // to validate selection and saved-view references. Live reloads leave `pending` nil and so
        // preserve the current live workspace instead.
        if let restoredSnapshot = pendingRestoredWorkspaceSnapshot {
            pendingRestoredWorkspaceSnapshot = nil
            restoreWorkspace(restoredSnapshot)
        }
        resetWorkspaceHistory()
        if !deferredMonitorRoles.isEmpty {
            handleDataSourceMonitorEvent(
                BeadsDataSourceMonitor.Event(roles: deferredMonitorRoles),
                projectURL: projectURL
            )
        }
        if queuesInitialExternalRefresh,
           loadedProject.snapshotRefreshWarning == nil,
           loadedProject.source.kind == .jsonl,
           snapshotFreshness.state == .possiblyStale,
           automaticallyRefreshesExternalChanges {
            _snapshotFreshness = snapshotFreshness.refreshing(
                projectURL: projectURL,
                beadsDirectoryURL: loadedProject.environment.beadsDirectoryURL,
                source: loadedProject.source
            )
            requestReconcile(trigger: .externalMarker)
        }
        if !mutations.projection.isEmpty {
            scheduleProjectionMaterialization()
        }
        scheduleReconcileIfIdle()
    }

    /// Completes a reconcile whose export was byte-identical to the source already in
    /// memory. This retires monitor bookkeeping and freshness state without decoding or
    /// rebuilding the same large snapshot again.
    internal func completeClaimedReconcileWithoutReload(
        projectURL: URL,
        source: BeadsDataSource
    ) -> Bool {
        guard self.projectURL == projectURL,
              currentDataSource == source,
              mutations.projection.isEmpty,
              let beadsDirectoryURL = projectEnvironment?.beadsDirectoryURL else {
            return false
        }
        let deferredMonitorRoles = reconcileState.complete(replaysDeferredEvents: true)
        markSnapshotFreshnessLoaded(
            projectURL: projectURL,
            beadsDirectoryURL: beadsDirectoryURL,
            source: source
        )
        refreshSemanticDefinitionsIfNeeded(projectURL: projectURL)
        if !deferredMonitorRoles.isEmpty {
            handleDataSourceMonitorEvent(
                BeadsDataSourceMonitor.Event(roles: deferredMonitorRoles),
                projectURL: projectURL
            )
        }
        scheduleReconcileIfIdle()
        return true
    }

    internal func refreshSemanticDefinitionsIfNeeded(projectURL: URL) {
        guard cachedDefinitionsNeedRefresh,
              semanticDefinitionsRefreshTask == nil,
              let trackerDirectoryURL = projectEnvironment?.beadsDirectoryURL.standardizedFileURL
        else {
            return
        }
        semanticDefinitionsRefreshGeneration &+= 1
        let generation = semanticDefinitionsRefreshGeneration
        let projectLoader = projectLoader
        semanticDefinitionsRefreshTask = Task(priority: .utility) { @MainActor [weak self] in
            defer {
                if let self, self.semanticDefinitionsRefreshGeneration == generation {
                    self.semanticDefinitionsRefreshTask = nil
                }
            }
            let refreshedDefinitions = await projectLoader.loadDefinitions(projectURL: projectURL)
            guard !Task.isCancelled,
                  let self,
                  self.projectURL == projectURL,
                  self.semanticDefinitionsRefreshGeneration == generation,
                  self.projectEnvironment?.beadsDirectoryURL.standardizedFileURL.path
                    == trackerDirectoryURL.path
            else {
                return
            }
            guard let refreshedDefinitions else { return }

            if self.cachedDefinitions == refreshedDefinitions {
                let refreshedAt = Date()
                self.cachedDefinitionsTrackerDirectoryURL = trackerDirectoryURL
                self.cachedDefinitionsLastCheckedAt = refreshedAt
                self.cachedDefinitionsNeedRefresh = false
                self.semanticDefinitionsRepository.save(
                    refreshedDefinitions,
                    projectURL: projectURL,
                    trackerDirectoryURL: trackerDirectoryURL,
                    refreshedAt: refreshedAt
                )
                return
            }

            let sourceIndex = self.authoritativeIndex
            let sourceRefreshGeneration = self.project.currentRefreshGeneration
            let staleCutoffDays = self.staleCutoffDays
            let hidesParentsWithOnlyBlockedChildrenInReady =
                self.hidesParentsWithOnlyBlockedChildrenInReady
            let rebuildTask = Task.detached(priority: .utility) {
                () -> SemanticDefinitionsRefreshResult? in
                guard !Task.isCancelled else { return nil }
                let refreshedSemantics = BeadsMetadataService().loadSemantics(
                    projectURL: projectURL,
                    issues: sourceIndex.issues,
                    statusDefinitions: refreshedDefinitions.statuses,
                    typeDefinitions: refreshedDefinitions.types
                )
                guard !Task.isCancelled else { return nil }
                guard refreshedSemantics.excludingSystemRecordTypes != sourceIndex.semantics else {
                    return .unchanged
                }
                let refreshedIndex = BeadProjectIndex(
                    issues: sourceIndex.issues,
                    dependencies: sourceIndex.dependencies,
                    semantics: refreshedSemantics,
                    staleCutoffDays: staleCutoffDays,
                    hidesParentsWithOnlyBlockedChildrenInReady:
                        hidesParentsWithOnlyBlockedChildrenInReady,
                    reusingSearchTextFrom: sourceIndex
                )
                guard !Task.isCancelled else { return nil }
                return .rebuilt(refreshedIndex)
            }
            let rebuilt = await withTaskCancellationHandler {
                await rebuildTask.value
            } onCancel: {
                rebuildTask.cancel()
            }
            guard let rebuilt,
                  !Task.isCancelled,
                  self.projectURL == projectURL,
                  self.semanticDefinitionsRefreshGeneration == generation,
                  self.project.currentRefreshGeneration == sourceRefreshGeneration,
                  self.projectEnvironment?.beadsDirectoryURL.standardizedFileURL.path
                    == trackerDirectoryURL.path
            else {
                return
            }
            self.cachedDefinitions = refreshedDefinitions
            self.cachedDefinitionsTrackerDirectoryURL = trackerDirectoryURL
            let refreshedAt = Date()
            self.cachedDefinitionsLastCheckedAt = refreshedAt
            self.cachedDefinitionsNeedRefresh = false
            self.semanticDefinitionsRepository.save(
                refreshedDefinitions,
                projectURL: projectURL,
                trackerDirectoryURL: trackerDirectoryURL,
                refreshedAt: refreshedAt
            )

            if case .rebuilt(let refreshedIndex) = rebuilt {
                self.applyRefreshedSemantics(refreshedIndex)
            }
        }
    }

    internal func cancelSemanticDefinitionsRefresh() {
        semanticDefinitionsRefreshGeneration &+= 1
        semanticDefinitionsRefreshTask?.cancel()
        semanticDefinitionsRefreshTask = nil
    }

    internal func invalidateSemanticDefinitionsCache() {
        cancelSemanticDefinitionsRefresh()
        cachedDefinitions = nil
        cachedDefinitionsLastCheckedAt = nil
        cachedDefinitionsNeedRefresh = true
        if let projectURL {
            semanticDefinitionsRepository.reset(
                projectURL: projectURL,
                trackerDirectoryURL: cachedDefinitionsTrackerDirectoryURL
                    ?? projectEnvironment?.beadsDirectoryURL
            )
        }
        cachedDefinitionsTrackerDirectoryURL = projectEnvironment?.beadsDirectoryURL
    }

    /// Keeps the last known-good definitions available for the immediate issue reload while
    /// ensuring a pull that changed custom statuses or types is verified in the background.
    internal func markSemanticDefinitionsCacheStale() {
        cancelSemanticDefinitionsRefresh()
        cachedDefinitionsLastCheckedAt = nil
        cachedDefinitionsNeedRefresh = true
    }

    private func applyRefreshedSemantics(_ refreshedAuthoritativeIndex: BeadProjectIndex) {
        authoritativeIndex = refreshedAuthoritativeIndex
        if mutations.projection.isEmpty {
            index = refreshedAuthoritativeIndex
            _contentRevision &+= 1
            scheduleSavedViewCountRebuild()
            applyFilters()
            loadDependenciesForSelection()
            pruneGateDetailsForCurrentSnapshot()
        } else {
            scheduleProjectionMaterialization()
        }
    }

    private func indexPreservingMetadataChanges(
        in loadedIndex: BeadProjectIndex,
        since baseline: BeadMetadataReloadBaseline
    ) -> BeadProjectIndex {
        var changed = false
        let mergedIssues = loadedIndex.issues.map { loadedIssue -> BeadIssue in
            let issueID = loadedIssue.id
            let currentWriteVersions = mutations.metadataFieldWriteVersions(for: issueID)
            let baselineWriteVersions = baseline.fieldWriteVersions[issueID] ?? .init()
            let writeFields = currentWriteVersions.differingFields(from: baselineWriteVersions)
            let currentSettlementRevisions = mutations.metadataSettlement(for: issueID)?.revisions ?? .init()
            let baselineSettlementRevisions = baseline.settlementRevisions[issueID] ?? .init()
            let settlementFields = currentSettlementRevisions.differingFields(
                from: baselineSettlementRevisions
            )
            let pendingState = mutations.metadataMutations[issueID]
            let pendingFields = pendingState?.pendingFields ?? []
            guard !writeFields.isEmpty || !settlementFields.isEmpty || !pendingFields.isEmpty else {
                return loadedIssue
            }

            var mergedIssue = loadedIssue
            if let currentIssue = issue(with: issueID) {
                mergedIssue = replacingMetadata(writeFields, in: mergedIssue, with: currentIssue)
            }
            if let settlement = mutations.metadataSettlement(for: issueID) {
                mergedIssue = replacingMetadata(settlementFields, in: mergedIssue, with: settlement.issue)
            }
            if let pendingState {
                mergedIssue = replacingMetadata(pendingFields, in: mergedIssue, with: pendingState.resolvedIssue)
            }
            changed = changed || mergedIssue != loadedIssue
            return mergedIssue
        }
        guard changed else { return loadedIndex }
        return BeadProjectIndex(
            issues: mergedIssues,
            dependencies: loadedIndex.dependencies,
            semantics: loadedIndex.semantics,
            staleCutoffDays: loadedIndex.staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: loadedIndex.hidesParentsWithOnlyBlockedChildrenInReady,
            reusingSearchTextFrom: loadedIndex
        )
    }

    internal func pruneGateDetailsForCurrentSnapshot() {
        let gateIssueIDs = index.issueIDsByType[BeadProjectIndex.gateIssueType, default: []]
        let pruned = gatesByID.filter { id, detail in
            guard gateIssueIDs.contains(id),
                  let issue = index.issue(with: id),
                  let gate = BeadGate(issue: issue) else {
                return false
            }
            return detail.updatedAt == gate.updatedAt
        }
        if pruned != gatesByID {
            _gatesByID = pruned
        }
        if gateIssueIDs.isEmpty {
            gateDetailTask?.cancel()
            gateDetailTask = nil
        }
    }

    /// Enrich the selected gate with waiters via `bd gate show`, skipping unchanged gates.
    internal func loadWaitersForSelectedGateIfNeeded() {
        guard let projectURL,
              let id = selectedIDs.first, selectedIDs.count == 1,
              let gate = gate(for: id) else {
            gateDetailTask?.cancel()
            gateDetailTask = nil
            return
        }
        guard gatesByID[id]?.updatedAt != gate.updatedAt else {
            return
        }
        gateDetailTask?.cancel()
        let commands = commands
        gateDetailTask = Task { @MainActor [weak self] in
            let detail = try? await commands.loadGateDetail(projectURL: projectURL, id: id)
            guard !Task.isCancelled, let self, let detail,
                  self.projectURL == projectURL,
                  self.selectedIDs.first == id else {
                return
            }
            self._gatesByID[id] = detail
        }
    }

    private func synchronizeDataSourceMonitor(
        projectURL: URL,
        beadsDirectoryURL: URL,
        source: BeadsDataSource
    ) {
        guard monitoredSourceFingerprint != source.fingerprint else { return }
        stopDataSourceMonitor()
        let expectedProjectURL = projectURL
        let expectedSourceFingerprint = source.fingerprint
        let monitor = BeadsDataSourceMonitor(
            projectURL: projectURL,
            beadsDirectoryURL: beadsDirectoryURL,
            source: source
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self,
                      self.projectURL == expectedProjectURL,
                      self.monitoredSourceFingerprint == expectedSourceFingerprint else {
                    return
                }
                self.handleDataSourceMonitorEvent(event, projectURL: expectedProjectURL)
            }
        }
        dataSourceMonitor = monitor
        monitoredSourceFingerprint = source.fingerprint
        monitor.start()
    }

    private func stopDataSourceMonitor() {
        dataSourceMonitor?.stop()
        dataSourceMonitor = nil
        monitoredSourceFingerprint = nil
    }

    private func handleDataSourceMonitorEvent(_ event: BeadsDataSourceMonitor.Event, projectURL: URL) {
        guard !event.roles.isEmpty, self.projectURL == projectURL, let currentDataSource else { return }
        let beadsDirectoryURL = projectEnvironment?.beadsDirectoryURL
        if reconcileState.deferMonitorEvent(event.roles) {
            return
        }
        if currentDataSource.kind == .jsonl, event.roles.contains(.beadsDirectory) {
            // Directory events can arrive in bursts around atomic snapshot replacement,
            // so source rediscovery stays off the main actor.
            let expectedSource = currentDataSource
            Task { [weak self] in
                let discoveredSource = await Task.detached(priority: .utility) {
                    try? BeadsDataSourceDiscovery().discover(
                        projectURL: projectURL,
                        beadsDirectoryURL: beadsDirectoryURL
                    )
                }.value
                guard let self,
                      self.projectURL == projectURL,
                      self.currentDataSource == expectedSource else {
                    return
                }
                if let discoveredSource, discoveredSource != expectedSource {
                    self.satisfyPendingExternalRefreshFromSourceChange()
                    self._snapshotFreshness = self.snapshotFreshness.refreshing(
                        projectURL: projectURL,
                        beadsDirectoryURL: beadsDirectoryURL,
                        source: expectedSource
                    )
                    self.refreshAfterDataSourceChange()
                } else {
                    self.evaluateMonitorFreshness(projectURL: projectURL, source: expectedSource)
                }
            }
            return
        }
        evaluateMonitorFreshness(projectURL: projectURL, source: currentDataSource)
    }

    private func evaluateMonitorFreshness(projectURL: URL, source currentDataSource: BeadsDataSource) {
        let evaluation = snapshotFreshness.evaluatingCurrentFiles(
            projectURL: projectURL,
            beadsDirectoryURL: projectEnvironment?.beadsDirectoryURL,
            source: currentDataSource
        )
        if evaluation.requiresReload {
            _snapshotFreshness = evaluation.freshness
            satisfyPendingExternalRefreshFromSourceChange()
            refreshAfterDataSourceChange()
        } else if currentDataSource.kind == .jsonl,
                  evaluation.freshness.state == .possiblyStale,
                  automaticallyRefreshesExternalChanges {
            _snapshotFreshness = evaluation.freshness.refreshing(
                projectURL: projectURL,
                beadsDirectoryURL: projectEnvironment?.beadsDirectoryURL,
                source: currentDataSource
            )
            requestReconcile(trigger: .externalMarker)
        } else {
            _snapshotFreshness = evaluation.freshness
        }
    }

    private func markSnapshotFreshnessLoaded(
        projectURL: URL,
        beadsDirectoryURL: URL,
        source: BeadsDataSource
    ) {
        _snapshotFreshness = .loaded(
            projectURL: projectURL,
            beadsDirectoryURL: beadsDirectoryURL,
            source: source
        )
    }

    private func markSnapshotFreshnessFailed(_ message: String) {
        _snapshotFreshness = snapshotFreshness.failed(message)
    }

    private func reconcileCommentCache(with loadedIssues: [BeadIssue]) {
        let commentCountsByIssueID = Dictionary(uniqueKeysWithValues: loadedIssues.map { ($0.id, $0.commentCount) })
        commentCache = commentCache.filter { issueID, comments in
            commentCountsByIssueID[issueID] == comments.count
        }
    }

    internal func cacheOptimisticComment(issueID: String, text: String) {
        let comment = BeadComment(
            id: "local-\(UUID().uuidString)",
            issueID: issueID,
            author: nil,
            text: text,
            createdAt: Date(),
            updatedAt: nil
        )
        commentCache[issueID, default: []].append(comment)
        if selectedIssue?.id == issueID {
            _commentsIssueID = issueID
            _comments = commentCache[issueID] ?? []
            rebuildActivityItemsForSelection()
        }
    }}
