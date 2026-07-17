import Foundation

extension BeadStore {
    func openDefaultProjectIfAvailable() {
        guard projectURL == nil else { return }
        guard let url = recentProjects.first(where: { projectDirectoryExists(at: $0.url) })?.url else { return }
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
        mutations.resetMetadataMutations()
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
        _isInitializingBeads = false
        if projectDirectoryExists(at: url) {
            rememberRecentProject(url)
        }
        clearLoadedProjectData()
        loadProjectPreferences(for: url)
        resetWorkspaceQueryForProjectSwitch()
        // Stash the persisted snapshot; it can only be restored once the index has loaded
        // (selection/saved-view identities are validated against it in applyLoadedProject).
        pendingRestoredWorkspaceSnapshot = workspaceStateRepository.load(projectURL: url)?.snapshot()
        resetWorkspaceHistory()
        _projectReadiness = .ready
        refresh(reason: .initial, showsLoadingIndicator: true)
    }

    func openRecentProject(_ project: RecentProject) {
        openProject(project.url)
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

    private func projectDirectoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func initializeBeads(options: BeadsInitOptions) {
        guard let projectURL, !isInitializingBeads else { return }
        let initializationGeneration = project.beginInitialization()
        _isInitializingBeads = true
        lastError = nil
        let projectLoader = projectLoader
        let staleCutoffDays = staleCutoffDays
        let hidesParentsWithOnlyBlockedChildrenInReady = hidesParentsWithOnlyBlockedChildrenInReady

        initializationTask = Task { @MainActor [weak self] in
            defer { self?.project.finishInitialization(generation: initializationGeneration) }
            do {
                let loadedProject = try await projectLoader.initializeAndLoadProject(
                    projectURL: projectURL,
                    options: options,
                    staleCutoffDays: staleCutoffDays,
                    hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
                )
                guard !Task.isCancelled,
                      let self,
                      self.project.ownsInitialization(
                          projectURL: projectURL,
                          generation: initializationGeneration
                      ) else { return }
                self._isInitializingBeads = false
                self.rememberRecentProject(projectURL)
                self.applyLoadedProject(loadedProject, projectURL: projectURL)
            } catch is CancellationError {
                return
            } catch BeadError.unsupportedProjectMode(let unsupportedURL, let detail) {
                guard !Task.isCancelled,
                      let self,
                      self.project.ownsInitialization(
                          projectURL: projectURL,
                          generation: initializationGeneration
                      ) else { return }
                self._isInitializingBeads = false
                self.setUnsupportedProject(unsupportedURL, detail: detail)
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.project.ownsInitialization(
                          projectURL: projectURL,
                          generation: initializationGeneration
                      ) else { return }
                self._isInitializingBeads = false
                self._projectReadiness = .missingDataSource(projectURL)
                self.lastError = error.localizedDescription
            }
        }
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
        _snapshotFreshness = .unknown
        cachedDefinitions = nil
        lastServerActivationRefreshAt = nil
        _selectedIDs.removeAll()
        _fullPageDetailIssueID = nil
        creationDraft = nil
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

    internal func refresh(reason: RefreshReason, showsLoadingIndicator: Bool) {
        guard let projectURL else { return }
        guard reason == .initial || activeMutationCount == 0 else {
            queueRefreshAfterMutation(reason: reason)
            return
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
        let projectLoader = projectLoader
        let staleCutoffDays = staleCutoffDays
        let hidesParentsWithOnlyBlockedChildrenInReady = hidesParentsWithOnlyBlockedChildrenInReady

        // Mutations and explicit user refreshes must re-export the readable JSONL
        // snapshot first: Dolt-backed (embedded) projects only back it up on a
        // periodic timer, so `bd` writes would otherwise not appear for minutes.
        let forcesSnapshotExport = reason == .reconcile || reason == .manual

        // Status/type definitions rarely change, and reading them costs two `bd`
        // subprocesses. Reuse the cache except when the user explicitly refreshes, on the
        // first load, or after the app edited definitions (which clears the cache) —
        // otherwise every routine reload would re-run `bd`.
        let reloadsDefinitions = reason == .initial || reason == .manual || cachedDefinitions == nil
        let definitionsForLoad = reloadsDefinitions ? nil : cachedDefinitions
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

        refreshTask = Task { @MainActor [weak self] in
            defer { self?.project.finishRefresh(generation: refreshGeneration) }
            do {
                let snapshotTask = Task {
                    if forcesSnapshotExport {
                        return try await projectLoader.refreshSnapshotAndLoadProject(
                            projectURL: projectURL,
                            staleCutoffDays: staleCutoffDays,
                            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
                            cachedDefinitions: definitionsForLoad,
                            cachedEnvironment: environmentForLoad
                        )
                    }
                    return try await projectLoader.loadProject(
                        projectURL: projectURL,
                        staleCutoffDays: staleCutoffDays,
                        hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
                        cachedDefinitions: definitionsForLoad,
                        cachedEnvironment: environmentForLoad
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
                else { return }
                guard reason == .initial
                        || self.mutations.optimisticMutationRevision == optimisticMutationRevision
                else {
                    if showsLoadingIndicator {
                        self._isLoading = false
                    }
                    self.queueRefreshAfterMutation(reason: reason)
                    return
                }
                if reason == .dataSourceChanged, self.currentDataSource == loadedProject.source {
                    if showsLoadingIndicator {
                        self._isLoading = false
                    }
                    self.markSnapshotFreshnessLoaded(
                        projectURL: projectURL,
                        beadsDirectoryURL: loadedProject.environment.beadsDirectoryURL,
                        source: loadedProject.source
                    )
                    return
                }
                self.applyLoadedProject(
                    loadedProject,
                    projectURL: projectURL,
                    queuesInitialExternalRefresh: reason == .initial,
                    metadataBaseline: metadataBaseline
                )
            } catch is CancellationError {
                guard let self,
                      self.project.ownsRefresh(projectURL: projectURL, generation: refreshGeneration)
                else { return }
                self.finishReconcileAfterRefreshTermination(
                    projectURL: projectURL,
                    refreshGeneration: refreshGeneration
                )
                return
            } catch BeadError.projectMissingDataSource(let missingURL) {
                guard let self, !Task.isCancelled, self.projectURL == projectURL else { return }
                let recoveryTask = Task {
                    try await projectLoader.exportAndLoadProject(
                        projectURL: projectURL,
                        staleCutoffDays: self.staleCutoffDays,
                        hidesParentsWithOnlyBlockedChildrenInReady: self.hidesParentsWithOnlyBlockedChildrenInReady,
                        cachedDefinitions: definitionsForLoad,
                        cachedEnvironment: environmentForLoad
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
                    else { return }
                    guard reason == .initial
                            || self.mutations.optimisticMutationRevision == optimisticMutationRevision
                    else {
                        if showsLoadingIndicator {
                            self._isLoading = false
                        }
                        self.queueRefreshAfterMutation(reason: reason)
                        return
                    }
                    self.applyLoadedProject(
                        recoveredProject,
                        projectURL: projectURL,
                        queuesInitialExternalRefresh: reason == .initial,
                        metadataBaseline: metadataBaseline
                    )
                } catch is CancellationError {
                    guard self.project.ownsRefresh(
                        projectURL: projectURL,
                        generation: refreshGeneration
                    ) else { return }
                    self.finishReconcileAfterRefreshTermination(
                        projectURL: projectURL,
                        refreshGeneration: refreshGeneration
                    )
                    return
                } catch BeadError.projectMissingDataSource {
                    guard !Task.isCancelled, self.projectURL == projectURL else { return }
                    self.setMissingDataSource(missingURL)
                } catch BeadError.unsupportedProjectMode(let unsupportedURL, let detail) {
                    guard !Task.isCancelled, self.projectURL == projectURL else { return }
                    self.setUnsupportedProject(unsupportedURL, detail: detail)
                } catch {
                    guard !Task.isCancelled, self.projectURL == projectURL else { return }
                    self.setProjectUnavailable(projectURL, detail: error.localizedDescription)
                    self.markSnapshotFreshnessFailed(error.localizedDescription)
                }
            } catch BeadError.unsupportedProjectMode(let unsupportedURL, let detail) {
                guard !Task.isCancelled, let self, self.projectURL == projectURL else { return }
                self.setUnsupportedProject(unsupportedURL, detail: detail)
                self.finishReconcileAfterRefreshTermination(
                    projectURL: projectURL,
                    refreshGeneration: refreshGeneration
                )
            } catch {
                guard !Task.isCancelled, let self, self.projectURL == projectURL else { return }
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
            }
        }
    }

    private func queueRefreshAfterMutation(reason: RefreshReason) {
        if reason == .manual {
            cachedDefinitions = nil
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
        index = metadataBaseline.map {
            indexPreservingMetadataChanges(in: loadedIndex, since: $0)
        } ?? loadedIndex
        reconcileStateLabelOverrides(
            authoritative: loadedProject.snapshotRefreshWarning == nil
        )
        if loadedProject.snapshotRefreshWarning == nil {
            mutations.confirmAuthoritativeMetadata()
        }
        _contentRevision &+= 1
        scheduleSavedViewCountRebuild()
        if let definitions = loadedProject.definitions {
            cachedDefinitions = definitions
        }
        _projectEnvironment = loadedProject.environment
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
        scheduleReconcileIfIdle()
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
            if let currentIssue = index.issue(with: issueID) {
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
