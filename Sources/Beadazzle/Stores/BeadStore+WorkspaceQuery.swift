import Foundation

extension BeadStore {
    internal func resetWorkspaceQueryForProjectSwitch() {
        suppressesFilterUpdates = true
        _selectedBookmark = .ready
        _activeSavedViewID = nil
        _sourceSavedViewID = nil
        _activeAdvancedPredicate = nil
        searchText = ""
        statusFilters = []
        typeFilters = []
        priorityFilters = []
        labelFilters = []
        _savedViewFilterClock = Date()
        suppressesFilterUpdates = false
    }

    func setStatusFilter(_ status: String, isOn: Bool) {
        setFilter(&statusFilters, value: status, isOn: isOn)
    }

    func setTypeFilter(_ type: String, isOn: Bool) {
        setFilter(&typeFilters, value: type, isOn: isOn)
    }

    func setPriorityFilter(_ priority: Int, isOn: Bool) {
        setFilter(&priorityFilters, value: priority, isOn: isOn)
    }

    func setLabelFilter(_ label: String, isOn: Bool) {
        setFilter(&labelFilters, value: label, isOn: isOn)
    }

    func clearFilters() {
        guard hasActiveFilters else { return }
        _activeSavedViewID = nil
        suppressesFilterUpdates = true
        statusFilters = []
        typeFilters = []
        priorityFilters = []
        labelFilters = []
        suppressesFilterUpdates = false
        applyFilters()
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    private func setFilter<Value: Hashable>(_ filters: inout Set<Value>, value: Value, isOn: Bool) {
        var next = filters
        if isOn {
            next.insert(value)
        } else {
            next.remove(value)
        }
        guard next != filters else { return }
        filters = next
    }

    internal func filterStateDidChange(debounce: Bool = false) {
        guard !suppressesFilterUpdates else { return }
        _activeSavedViewID = nil
        scheduleFilterUpdate(debounce: debounce)
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    internal func sortStateDidChange() {
        guard !suppressesFilterUpdates else { return }
        _activeSavedViewID = nil
        applySortOnly()
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    internal func selectionDidChange() {
        expandAncestorsForSelection(rebuildRows: true, unlessAlreadyVisible: true)
        scheduleSelectionSideDataRefresh()
        recordWorkspaceSnapshotIfNeeded()
    }

    private func makeWorkspaceSnapshot() -> BeadWorkspaceSnapshot {
        BeadWorkspaceSnapshot(
            bookmark: selectedBookmark,
            activeSavedViewID: activeSavedViewID,
            sourceSavedViewID: sourceSavedViewID,
            savedViewOrdering: (activeSavedViewID ?? sourceSavedViewID)
                .flatMap { savedViewTree.savedView(id: $0)?.ordering },
            selectedIDs: selectedIDs,
            fullPageDetailIssueID: fullPageDetailIssueID,
            searchText: searchText,
            statusFilters: statusFilters,
            typeFilters: typeFilters,
            priorityFilters: priorityFilters,
            labelFilters: labelFilters,
            advancedPredicate: activeAdvancedPredicate,
            sort: sort,
            sortDirection: sortDirection,
            issueListMode: issueListMode,
            outlineState: outlineState,
            creationDraft: creationDraft
        )
    }

    internal func resetWorkspaceHistory() {
        workspaceHistory.reset(to: makeWorkspaceSnapshot())
        syncWorkspaceHistoryAvailability()
    }

    internal func recordWorkspaceSnapshotIfNeeded() {
        guard !isRestoringWorkspace, !suppressesHistoryRecording, hasReadableProject else { return }
        workspaceHistory.record(makeWorkspaceSnapshot())
        syncWorkspaceHistoryAvailability()
    }

    internal func syncCurrentWorkspaceSnapshotIfNeeded() {
        guard !isRestoringWorkspace, !suppressesHistoryRecording, hasReadableProject else { return }
        workspaceHistory.updateCurrent(makeWorkspaceSnapshot())
        syncWorkspaceHistoryAvailability()
    }

    internal func restoreWorkspace(_ snapshot: BeadWorkspaceSnapshot) {
        guard hasReadableProject else { return }

        isRestoringWorkspace = true
        suppressesFilterUpdates = true
        _selectedBookmark = snapshot.bookmark
        _activeSavedViewID = validatedSavedViewID(for: snapshot)
        _sourceSavedViewID = validatedSourceSavedViewID(for: snapshot)
        _selectedIDs = snapshot.selectedIDs.intersection(index.allIssueIDs)
        _fullPageDetailIssueID = snapshot.fullPageDetailIssueID
        creationDraft = snapshot.creationDraft
        searchText = snapshot.searchText
        statusFilters = snapshot.statusFilters
        typeFilters = snapshot.typeFilters
        priorityFilters = snapshot.priorityFilters
        labelFilters = snapshot.labelFilters
        _activeAdvancedPredicate = snapshot.advancedPredicate?.normalized
        sort = snapshot.sort
        sortDirection = snapshot.sortDirection
        issueListMode = snapshot.issueListMode
        outlineState = snapshot.outlineState
        suppressesFilterUpdates = false
        isRestoringWorkspace = false

        syncFullPageDetailWithSelection()
        expandAncestorsForSelection()
        applyFilters()
        scheduleSelectionSideDataRefresh()
        syncWorkspaceHistoryAvailability()
    }

    private func validatedSavedViewID(for snapshot: BeadWorkspaceSnapshot) -> UUID? {
        guard let id = snapshot.activeSavedViewID,
              let view = savedViews.first(where: { $0.id == id })
        else { return nil }
        let filter = view.query
        guard filter.basePreset.bookmark == snapshot.bookmark,
              filter.statusFilters == snapshot.statusFilters,
              filter.typeFilters == snapshot.typeFilters,
              filter.priorityFilters == snapshot.priorityFilters,
              filter.labelFilters == snapshot.labelFilters,
              filter.advancedPredicate?.normalized == snapshot.advancedPredicate?.normalized,
              filter.searchText == snapshot.searchText,
              view.ordering == snapshot.savedViewOrdering,
              view.ordering.fallbackSort.field == snapshot.sort,
              view.ordering.fallbackSort.direction == snapshot.sortDirection
        else { return nil }
        return id
    }

    private func validatedSourceSavedViewID(for snapshot: BeadWorkspaceSnapshot) -> UUID? {
        guard let id = snapshot.sourceSavedViewID,
              savedViews.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    internal func syncWorkspaceHistoryAvailability() {
        _canGoBack = workspaceHistory.canGoBack
        _canGoForward = workspaceHistory.canGoForward
    }

    internal func syncFullPageDetailWithSelection() {
        guard let fullPageDetailIssueID else { return }
        if selectedIDs != [fullPageDetailIssueID] || index.issue(with: fullPageDetailIssueID) == nil {
            self._fullPageDetailIssueID = nil
        }
    }

    internal func scheduleSelectionSideDataRefresh() {
        selectionSideDataTask?.cancel()
        let expectedSelectedIDs = selectedIDs

        selectionSideDataTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.selectedIDs == expectedSelectedIDs else { return }
            self.loadDependenciesForSelection()
            self.syncCommentsForSelectionFromCache()
            self.loadWaitersForSelectedGateIfNeeded()
        }
    }

    private func scheduleFilterUpdate(debounce: Bool = false) {
        filterTask?.cancel()
        filterTask = Task { @MainActor [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(140))
            }
            guard !Task.isCancelled else { return }
            self?.applyFilters()
        }
    }

    internal func applyFilters() {
        scheduleQueryRecompute(recomputeCounts: true, pruneExpansion: true)
    }

    private func applySortOnly() {
        scheduleQueryRecompute(recomputeCounts: false, pruneExpansion: false)
    }

    internal var selectedOutlineRow: IssueListRow? {
        guard issueListMode == .outline,
              selectedIDs.count == 1,
              let selectedID = selectedIDs.first else {
            return nil
        }
        return issueListRows.first { $0.issueID == selectedID }
    }

    internal func setSelectedIssueChildrenExpanded(_ isExpanded: Bool) -> Bool {
        guard let selectedRow = selectedOutlineRow,
              selectedRow.hasChildren,
              selectedRow.isExpanded != isExpanded else {
            return false
        }

        setIssueExpansion(issueID: selectedRow.issueID, isExpanded: isExpanded)
        return true
    }

    internal func setIssueExpansion(issueID: String, isExpanded: Bool) {
        outlineState.setExpansion(issueID: issueID, isExpanded: isExpanded)
        rebuildIssueListRows()
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    internal func firstVisibleChildID(of row: IssueListRow) -> String? {
        guard let selectedIndex = issueListRows.firstIndex(where: { $0.issueID == row.issueID }) else {
            return nil
        }
        let childDepth = row.depth + 1
        return issueListRows.dropFirst(selectedIndex + 1).first { $0.depth == childDepth }?.issueID
    }

    internal func visibleParentID(of row: IssueListRow) -> String? {
        guard row.depth > 0,
              let selectedIndex = issueListRows.firstIndex(where: { $0.issueID == row.issueID }) else {
            return nil
        }
        let parentDepth = row.depth - 1
        return issueListRows[..<selectedIndex].reversed().first { $0.depth == parentDepth }?.issueID
    }

    internal func rebuildIssueListRows(pruneExpansion: Bool = false) {
        scheduleQueryRecompute(recomputeCounts: false, pruneExpansion: pruneExpansion)
    }

    /// Computes the filtered/sorted ID list, list rows, and (optionally) filter counts
    /// off the main actor, then applies the result back on the main actor. Successive
    /// calls cancel the in-flight computation and a generation token guards against
    /// applying stale results.
    private func scheduleQueryRecompute(recomputeCounts: Bool, pruneExpansion: Bool) {
        // Keep outline state coherent on the main actor: dropping IDs that no longer
        // exist is cheap and must not race with the background computation.
        _ = outlineState.prune(toValidIssueIDs: index.allIssueIDs)

        queryGeneration &+= 1
        let generation = queryGeneration
        recomputeTask?.cancel()

        let index = index
        let bookmark = selectedBookmark
        let statusFilters = statusFilters
        let typeFilters = typeFilters
        let priorityFilters = priorityFilters
        let labelFilters = labelFilters
        let searchText = searchText
        let advancedPredicate = activeAdvancedPredicate
        let sort = sort
        let direction = sortDirection
        let mode = issueListMode
        let gateClock = gateClock
        let savedViewFilterClock = savedViewFilterClock
        let outlineSnapshot = outlineState

        recomputeTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.queryGeneration == generation {
                    self.recomputeTask = nil
                }
            }
            let worker = Task.detached(priority: .userInitiated) { () -> QueryResults in
                let filteredIDs: [String]
                var counts: BeadFilterCounts?
                if advancedPredicate == nil, recomputeCounts, bookmark != .gates {
                    (filteredIDs, counts) = BeadIssueListQuery.filteredIssueIDsAndCounts(
                        index: index,
                        bookmark: bookmark,
                        statusFilters: statusFilters,
                        typeFilters: typeFilters,
                        priorityFilters: priorityFilters,
                        labelFilters: labelFilters,
                        searchText: searchText,
                        shouldCancel: { Task.isCancelled }
                    )
                } else {
                    filteredIDs = BeadSavedViewQueryEvaluator.filteredIssueIDs(
                        index: index,
                        filter: BeadSavedViewQuery(
                            basePreset: BeadBookmarkToken(bookmark),
                            statusFilters: statusFilters,
                            typeFilters: typeFilters,
                            priorityFilters: priorityFilters,
                            labelFilters: labelFilters,
                            searchText: searchText,
                            advancedPredicate: advancedPredicate
                        ),
                        now: savedViewFilterClock,
                        shouldCancel: { Task.isCancelled }
                    )
                    counts = recomputeCounts
                        ? BeadIssueListQuery.filterCounts(
                            index: index,
                            bookmark: bookmark,
                            statusFilters: statusFilters,
                            typeFilters: typeFilters,
                            priorityFilters: priorityFilters,
                            searchText: searchText,
                            selectedLabels: labelFilters
                        )
                        : nil
                }
                let sortedIDs = BeadIssueListQuery.sortedIssueIDs(
                    index: index,
                    ids: filteredIDs,
                    sort: sort,
                    direction: direction,
                    bookmark: bookmark,
                    now: gateClock
                )

                var outlineState = outlineSnapshot
                var rows = BeadIssueListQuery.rows(
                    index: index,
                    filteredIssueIDs: sortedIDs,
                    mode: mode,
                    outlineState: outlineState,
                    sort: sort,
                    direction: direction,
                    bookmark: bookmark,
                    shouldCancel: { Task.isCancelled }
                )
                let didPruneExpansion = pruneExpansion && outlineState.prune(toVisibleRows: rows)
                if didPruneExpansion {
                    rows = BeadIssueListQuery.rows(
                        index: index,
                        filteredIssueIDs: sortedIDs,
                        mode: mode,
                        outlineState: outlineState,
                        sort: sort,
                        direction: direction,
                        bookmark: bookmark,
                        shouldCancel: { Task.isCancelled }
                    )
                }

                return QueryResults(
                    filteredIssueIDs: sortedIDs,
                    rows: rows,
                    outlineState: didPruneExpansion ? outlineState : nil,
                    filterCounts: counts
                )
            }
            let results = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled, let self, self.queryGeneration == generation else { return }
            self.applyQueryResults(results)
        }
    }

    internal func scheduleSavedViewCountRebuild() {
        savedViewCountGeneration &+= 1
        let generation = savedViewCountGeneration
        savedViewCountTask?.cancel()

        let index = index
        let views = savedViews
        let expectedProjectURL = projectURL
        let expectedContentRevision = contentRevision
        let evaluationNow = Date()
        _isRebuildingSavedViewCounts = !views.isEmpty
        savedViewCountTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.savedViewCountGeneration == generation {
                    self.savedViewCountTask = nil
                }
            }
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { () -> [UUID: Int]? in
                BeadSavedViewQueryEvaluator.matchingIssueCounts(
                    index: index,
                    filters: views.map { (id: $0.id, filter: $0.query) },
                    now: evaluationNow,
                    shouldCancel: { Task.isCancelled }
                )
            }
            let counts = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  let counts,
                  let self,
                  self.savedViewCountGeneration == generation,
                  self.projectURL == expectedProjectURL,
                  self.contentRevision == expectedContentRevision
            else { return }
            self._savedViewCounts = counts
            self._isRebuildingSavedViewCounts = false
        }
    }

    private func applyQueryResults(_ results: QueryResults) {
        if let prunedOutlineState = results.outlineState {
            outlineState = prunedOutlineState
        }
        if filteredIssueIDs != results.filteredIssueIDs {
            _filteredIssueIDs = results.filteredIssueIDs
        }
        if issueListRows != results.rows {
            _issueListRows = results.rows
        }
        if let counts = results.filterCounts, filterCounts != counts {
            _filterCounts = counts
        }
    }

    private struct QueryResults: Sendable {
        var filteredIssueIDs: [String]
        var rows: [IssueListRow]
        var outlineState: BeadOutlineSelectionState?
        var filterCounts: BeadFilterCounts?
    }

    /// Awaits the in-flight filtered/sorted/rows recomputation, if any, so callers can
    /// observe settled derived state (`filteredIssueIDs`, `issueListRows`, `filterCounts`).
    /// Intended for tests; production UI simply re-renders when the recompute lands.
    ///
    /// A recompute superseded mid-flight resolves without applying its results, so
    /// awaiting a single task is not enough: if another schedule lands while we're
    /// suspended (e.g. a debounced monitor event), loop until the task we awaited is
    /// still the current one.
    func waitForPendingQueryRecompute() async {
        while let task = recomputeTask {
            await task.value
            if recomputeTask == task {
                return
            }
        }
    }

    func waitForPendingSavedViewCountRebuild() async {
        while let task = savedViewCountTask {
            await task.value
            if savedViewCountTask == task {
                return
            }
        }
    }

    func waitForPendingSidebarSelection() async {
        await sidebarSelectionTask?.value
    }

    func waitForPendingProjectHealthLoad() async {
        await projectHealthTask?.value
    }

    internal func rebuildIndexForProjectIndexPreferenceChange() {
        guard !index.issues.isEmpty || !index.dependencies.isEmpty || index.semantics != .empty else { return }
        index = BeadProjectIndex(
            issues: index.issues,
            dependencies: index.dependencies,
            semantics: index.semantics,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
            reusingSearchTextFrom: index
        )
        _contentRevision &+= 1
        scheduleSavedViewCountRebuild()
        _selectedIDs = selectedIDs.filter { index.issue(with: $0) != nil }
        pruneExpandedIssueIDs()
        applyFilters()
        loadDependenciesForSelection()
        syncCommentsForSelectionFromCache()
    }

    internal func indexMatchingCurrentProjectPreferences(from loadedIndex: BeadProjectIndex) -> BeadProjectIndex {
        guard loadedIndex.staleCutoffDays != staleCutoffDays
            || loadedIndex.hidesParentsWithOnlyBlockedChildrenInReady != hidesParentsWithOnlyBlockedChildrenInReady
        else {
            return loadedIndex
        }

        return BeadProjectIndex(
            issues: loadedIndex.issues,
            dependencies: loadedIndex.dependencies,
            semantics: loadedIndex.semantics,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
            reusingSearchTextFrom: loadedIndex
        )
    }

    internal func expandAncestorsForSelection(
        rebuildRows: Bool,
        unlessAlreadyVisible: Bool = false
    ) {
        guard let issue = selectedIssue else { return }
        if unlessAlreadyVisible,
           issueListRows.contains(where: { $0.issueID == issue.id }) {
            // Rows already visible through filtered outline context do not need revealing.
            // Treating their ancestors as explicitly expanded would inject non-matching
            // siblings into the filtered list when the row is merely selected.
            return
        }
        expandAncestors(of: issue.id, rebuildRows: rebuildRows)
    }

    internal func expandAncestors(of issueID: String, rebuildRows: Bool) {
        guard outlineState.expandAncestors(of: issueID, in: index) else { return }
        if rebuildRows {
            rebuildIssueListRows()
        }
    }

    internal func pruneExpandedIssueIDs() {
        _ = outlineState.prune(toValidIssueIDs: index.allIssueIDs)
    }

}
