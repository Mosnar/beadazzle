import Foundation

extension BeadStore {
    func beginCreatingBead() {
        guard canCreateBead, creationDraft == nil else { return }
        suppressesHistoryRecording = true
        clearSelection()
        _fullPageDetailIssueID = nil
        creationDraft = blankDraft()
        suppressesHistoryRecording = false
        recordWorkspaceSnapshotIfNeeded()
    }

    func canCreateChildBead(parentID: String) -> Bool {
        guard hasReadableProject,
              let parent = index.issue(with: parentID) else {
            return false
        }
        return !parent.isGate
    }

    func beginCreatingChildBead(parentID: String) {
        guard canCreateChildBead(parentID: parentID), creationDraft == nil else { return }
        suppressesHistoryRecording = true
        _selectedIDs.removeAll()
        _fullPageDetailIssueID = nil
        clearSelectionSideData()
        creationDraft = blankDraft(parentID: parentID)
        suppressesHistoryRecording = false
        recordWorkspaceSnapshotIfNeeded()
    }

    func cancelCreation() {
        guard creationDraft != nil else { return }
        creationDraft = nil
        recordWorkspaceSnapshotIfNeeded()
    }

    func goBack() {
        guard let snapshot = workspaceHistory.goBack() else { return }
        syncWorkspaceHistoryAvailability()
        restoreWorkspace(snapshot)
    }

    func goForward() {
        guard let snapshot = workspaceHistory.goForward() else { return }
        syncWorkspaceHistoryAvailability()
        restoreWorkspace(snapshot)
    }

    var selectedIssue: BeadIssue? {
        guard let id = selectedIDs.first, selectedIDs.count == 1 else { return nil }
        return issue(with: id)
    }

    func parentIssue(for issueID: String) -> BeadIssue? {
        guard let parentID = index.parentID(for: issueID) else { return nil }
        return index.issue(with: parentID)
    }

    func subIssueRows(parentID: String) -> [IssueListRow] {
        index.immediateChildRows(
            parentID: parentID,
            sortOrder: BeadIssueSortOrder(sort: sort, direction: sortDirection)
        )
    }

    func beadPickerRows(
        configuration: BeadPickerConfiguration,
        filters: BeadPickerFilters,
        searchText: String,
        mode: IssueListMode,
        outlineState: BeadOutlineSelectionState
    ) async -> BeadPickerQueryResult {
        let index = index
        let sortOrder = BeadIssueSortOrder(sort: sort, direction: sortDirection)
        let queryTask = Task.detached(priority: .userInitiated) {
            BeadPickerQuery.rows(
                index: index,
                configuration: configuration,
                filters: filters,
                searchText: searchText,
                mode: mode,
                outlineState: outlineState,
                sortOrder: sortOrder,
                shouldCancel: { Task.isCancelled }
            )
        }
        return await withTaskCancellationHandler {
            await queryTask.value
        } onCancel: {
            queryTask.cancel()
        }
    }

    func childProgress(parentID: String) -> IssueChildProgress? {
        index.childProgress(for: parentID)
    }

    func activeBlockingIssues(for issueID: String) -> [BeadIssue] {
        index.activeBlockingIssues(
            for: issueID,
            sortOrder: BeadIssueSortOrder(sort: sort, direction: sortDirection)
        )
    }

    func activelyBlockedIssues(by issueID: String) -> [BeadIssue] {
        index.activelyBlockedIssues(
            by: issueID,
            sortOrder: BeadIssueSortOrder(sort: sort, direction: sortDirection)
        )
    }

    func select(_ ids: Set<String>) {
        let nextFullPageDetailIssueID = fullPageDetailIssueID.flatMap { ids == [$0] ? $0 : nil }
        guard selectedIDs != ids || fullPageDetailIssueID != nextFullPageDetailIssueID else { return }
        if !ids.isEmpty, creationDraft != nil {
            suppressesHistoryRecording = true
            creationDraft = nil
            suppressesHistoryRecording = false
        }
        _selectedIDs = ids
        _fullPageDetailIssueID = nextFullPageDetailIssueID
        selectionDidChange()
    }

    func clearSelection() {
        select([])
    }

    func openIssueFromDetail(issueID: String) {
        guard index.issue(with: issueID) != nil else { return }
        if fullPageDetailIssueID != nil {
            openFullPageDetail(issueID: issueID)
        } else {
            select([issueID])
        }
    }

    func openFullPageDetail(issueID: String) {
        guard index.issue(with: issueID) != nil else { return }
        let targetSelection: Set<String> = [issueID]
        guard selectedIDs != targetSelection || fullPageDetailIssueID != issueID else { return }

        let wasSuppressingHistory = suppressesHistoryRecording
        suppressesHistoryRecording = true
        if creationDraft != nil {
            creationDraft = nil
        }
        _selectedIDs = targetSelection
        _fullPageDetailIssueID = issueID
        selectionDidChange()
        suppressesHistoryRecording = wasSuppressingHistory
        recordWorkspaceSnapshotIfNeeded()
    }

    func toggleIssueExpansion(issueID: String, isExpanded: Bool) {
        setIssueExpansion(issueID: issueID, isExpanded: !isExpanded)
    }

    @discardableResult
    func expandSelectedIssueChildren() -> Bool {
        setSelectedIssueChildrenExpanded(true)
    }

    @discardableResult
    func collapseSelectedIssueChildren() -> Bool {
        setSelectedIssueChildrenExpanded(false)
    }

    @discardableResult
    func navigateIssueOutlineRight() -> Bool {
        guard let selectedRow = selectedOutlineRow,
              selectedRow.hasChildren else {
            return false
        }

        if !selectedRow.isExpanded {
            setIssueExpansion(issueID: selectedRow.issueID, isExpanded: true)
            return true
        }

        guard let firstChildID = firstVisibleChildID(of: selectedRow) else {
            return false
        }
        select([firstChildID])
        return true
    }

    @discardableResult
    func navigateIssueOutlineLeft() -> Bool {
        guard let selectedRow = selectedOutlineRow else {
            return false
        }

        if selectedRow.hasChildren, selectedRow.isExpanded {
            setIssueExpansion(issueID: selectedRow.issueID, isExpanded: false)
            return true
        }

        guard let parentID = visibleParentID(of: selectedRow) else {
            return false
        }
        select([parentID])
        return true
    }

    func expandAncestorsForSelection() {
        expandAncestorsForSelection(rebuildRows: true)
    }

    func revealIssue(id: String) {
        guard index.issue(with: id) != nil else { return }
        _selectedIDs = [id]
        _fullPageDetailIssueID = nil
        expandAncestors(of: id, rebuildRows: false)

        if !index.issueIDs(for: selectedBookmark).contains(id) {
            _selectedBookmark = .all
        }

        // Compute membership directly rather than reading `filteredIssueIDs`, which is
        // now updated asynchronously and may be stale at this point.
        let matchesCurrentFilters = BeadIssueListQuery.filteredIssueIDs(
            index: index,
            bookmark: selectedBookmark,
            statusFilters: statusFilters,
            typeFilters: typeFilters,
            priorityFilters: priorityFilters,
            labelFilters: labelFilters,
            searchText: searchText
        ).contains(id)

        if !matchesCurrentFilters {
            clearFilters()
            searchText = ""
            applyFilters()
        } else {
            rebuildIssueListRows()
        }
        loadDependenciesForSelection()
        syncCommentsForSelectionFromCache()
        recordWorkspaceSnapshotIfNeeded()
    }

    func applyBookmark(_ bookmark: BeadBookmark) {
        let changedSelectionIdentity = activeSavedViewID != nil
        let clearedAdvancedPredicate = activeAdvancedPredicate != nil
        _activeSavedViewID = nil
        _sourceSavedViewID = nil
        _activeAdvancedPredicate = nil
        guard selectedBookmark != bookmark else {
            if clearedAdvancedPredicate {
                applyFilters()
            }
            if changedSelectionIdentity || clearedAdvancedPredicate {
                recordWorkspaceSnapshotIfNeeded()
            }
            return
        }
        _selectedBookmark = bookmark
        if bookmark == .gates {
            _gateClock = Date()
        }
        // Choosing a bookmark returns you to the list: drop any detail selection so the
        // detail pane collapses back to the bead list instead of stranding you on a page.
        // Recompute exactly once afterward — a stray `applyFilters()` before this would be
        // canceled by the selection change's generation guard, dropping the filter-counts pass.
        if !selectedIDs.isEmpty {
            _selectedIDs = []
            _fullPageDetailIssueID = nil
            scheduleSelectionSideDataRefresh()
        }
        applyFilters()
        recordWorkspaceSnapshotIfNeeded()
    }

    /// Opens an exact, reversible workspace view for one state value. The
    /// existing label index performs the match; this does not scan issues or
    /// mutate Beads data.
    @discardableResult
    func showBeads(withStateValue value: String, in dimension: String) -> Bool {
        let label = BeadStateLabel.label(dimension: dimension, value: value)
        guard index.count(forLabel: label) > 0 else { return false }

        let targetLabels: Set<String> = [label]
        let isAlreadyShowingTarget = selectedBookmark == .all
            && activeSavedViewID == nil
            && sourceSavedViewID == nil
            && activeAdvancedPredicate == nil
            && statusFilters.isEmpty
            && typeFilters.isEmpty
            && priorityFilters.isEmpty
            && labelFilters == targetLabels
            && searchText.isEmpty
            && selectedIDs.isEmpty
            && fullPageDetailIssueID == nil
            && creationDraft == nil
        guard !isAlreadyShowingTarget else { return true }

        suppressesHistoryRecording = true
        suppressesFilterUpdates = true
        _selectedBookmark = .all
        _activeSavedViewID = nil
        _sourceSavedViewID = nil
        _activeAdvancedPredicate = nil
        statusFilters = []
        typeFilters = []
        priorityFilters = []
        labelFilters = targetLabels
        searchText = ""
        suppressesFilterUpdates = false

        let hadSelection = !selectedIDs.isEmpty || fullPageDetailIssueID != nil
        _selectedIDs = []
        _fullPageDetailIssueID = nil
        creationDraft = nil
        suppressesHistoryRecording = false
        if hadSelection {
            scheduleSelectionSideDataRefresh()
        }
        applyFilters()
        recordWorkspaceSnapshotIfNeeded()
        return true
    }

    func saveCurrentViewAsBookmark(name: String, symbolName: String) {
        guard hasReadableProject, canMutateSavedViews else { return }
        let view = normalizedSavedView(BeadSavedView(
            id: UUID(),
            name: name,
            symbolName: symbolName,
            query: makeCurrentSavedViewQuery(),
            ordering: currentSavedViewOrdering
        ))
        var tree = savedViewTree
        tree.append(view)
        _savedViewTree = tree
        persistSavedViews()
        scheduleSavedViewCountRebuild(for: [view.id])
        applySavedView(id: view.id)
    }

    func saveConfiguredView(
        name: String,
        symbolName: String,
        query: BeadSavedViewQuery,
        ordering: BeadSavedViewOrdering
    ) {
        guard hasReadableProject, canMutateSavedViews, query.advancedPredicate?.isValid != false else { return }
        let view = normalizedSavedView(BeadSavedView(
            id: UUID(),
            name: name,
            symbolName: symbolName,
            query: query,
            ordering: ordering
        ))
        var tree = savedViewTree
        tree.append(view)
        _savedViewTree = tree
        persistSavedViews()
        scheduleSavedViewCountRebuild(for: [view.id])
        applySavedView(id: view.id)
    }

    func updateConfiguredView(
        id: UUID,
        name: String,
        symbolName: String,
        query: BeadSavedViewQuery,
        ordering: BeadSavedViewOrdering
    ) {
        guard canMutateSavedViews, query.advancedPredicate?.isValid != false else { return }
        var tree = savedViewTree
        guard tree.updateSavedView(id: id, { view in
            view = normalizedSavedView(BeadSavedView(
                id: id,
                name: name,
                symbolName: symbolName,
                query: query,
                ordering: ordering
            ))
        }) else { return }
        _savedViewTree = tree
        persistSavedViews()
        scheduleSavedViewCountRebuild(for: [id])
        applySavedView(id: id)
    }

    var suggestedSavedViewName: String {
        let baseName: String
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearch.isEmpty {
            baseName = "Search: \(trimmedSearch)"
        } else if hasActiveFilters {
            baseName = "\(selectedBookmark.title) — Filtered"
        } else {
            baseName = selectedBookmark.title
        }
        return uniqueSavedViewName(baseName)
    }

    var currentSavedViewSummary: String {
        var parts = [selectedBookmark.title]
        if !statusFilters.isEmpty { parts.append("\(statusFilters.count) status filter\(statusFilters.count == 1 ? "" : "s")") }
        if !typeFilters.isEmpty { parts.append("\(typeFilters.count) type filter\(typeFilters.count == 1 ? "" : "s")") }
        if !priorityFilters.isEmpty { parts.append("\(priorityFilters.count) priorit\(priorityFilters.count == 1 ? "y" : "ies")") }
        if !labelFilters.isEmpty { parts.append("\(labelFilters.count) label\(labelFilters.count == 1 ? "" : "s")") }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("search text") }
        parts.append("\(sort.rawValue), \(sortDirection.rawValue.lowercased())")
        return parts.joined(separator: " · ")
    }

    func scheduleSidebarSelection(_ selection: BeadSidebarSelection) {
        sidebarSelectionTask?.cancel()
        sidebarSelectionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            switch selection {
            case .preset(let bookmark):
                self.applyBookmark(bookmark)
            case .savedView(let id):
                self.applySavedView(id: id)
            }
        }
    }

    func applySavedView(id: UUID) {
        guard let view = savedViews.first(where: { $0.id == id }) else { return }
        guard view.hasValidQuery else {
            lastError = "“\(view.name)” contains an invalid filter and was not applied."
            return
        }
        suppressesFilterUpdates = true
        _selectedBookmark = view.query.basePreset.bookmark
        statusFilters = view.query.statusFilters
        typeFilters = view.query.typeFilters
        priorityFilters = view.query.priorityFilters
        labelFilters = view.query.labelFilters
        searchText = view.query.searchText
        sort = view.ordering.fallbackSort.field
        sortDirection = view.ordering.fallbackSort.direction
        suppressesFilterUpdates = false
        _activeSavedViewID = id
        _sourceSavedViewID = id
        _activeAdvancedPredicate = view.query.advancedPredicate?.validatedNormalized
        _savedViewFilterClock = Date()
        _selectedIDs = []
        _fullPageDetailIssueID = nil
        scheduleSelectionSideDataRefresh()
        applyFilters()
        recordWorkspaceSnapshotIfNeeded()
    }

    func renameSavedView(id: UUID, to name: String) {
        updateSavedView(id: id, invalidatesCount: false) { view in
            view.name = name
        }
    }

    func setSavedViewSymbol(id: UUID, symbolName: String) {
        updateSavedView(id: id, invalidatesCount: false) { view in
            view.symbolName = symbolName
        }
    }

    func duplicateSavedView(id: UUID) {
        guard canMutateSavedViews, var duplicate = savedViewTree.savedView(id: id) else { return }
        let sourceCount = savedViewCounts[id]
        duplicate.id = UUID()
        duplicate.name = uniqueSavedViewName("\(duplicate.name) Copy")
        let duplicateID = duplicate.id
        var tree = savedViewTree
        guard tree.insertSavedView(normalizedSavedView(duplicate), after: id) else { return }
        _savedViewTree = tree
        if let sourceCount {
            _savedViewCounts[duplicateID] = sourceCount
        }
        persistSavedViews()
        if sourceCount == nil || savedViewCountTask != nil {
            scheduleSavedViewCountRebuild(for: [duplicateID])
        }
    }

    func updateSavedViewFilterFromCurrentState(id: UUID) {
        let wasActive = activeSavedViewID == id
        let wasSource = sourceSavedViewID == id
        updateSavedView(id: id, invalidatesCount: true) { view in
            view.query = makeCurrentSavedViewQuery()
            view.ordering.fallbackSort = BeadSavedViewSort(field: sort, direction: sortDirection)
        }
        if wasActive || wasSource {
            _activeSavedViewID = id
            _sourceSavedViewID = id
            syncCurrentWorkspaceSnapshotIfNeeded()
        }
    }

    func deleteSavedView(id: UUID) {
        guard canMutateSavedViews, savedViews.contains(where: { $0.id == id }) else { return }
        let wasRebuildingCounts = savedViewCountTask != nil
        let wasActive = activeSavedViewID == id
        let wasSource = sourceSavedViewID == id
        var tree = savedViewTree
        guard tree.removeSavedView(id: id) else { return }
        _savedViewTree = tree
        _savedViewCounts[id] = nil
        if wasActive {
            _activeSavedViewID = nil
        }
        if sourceSavedViewID == id {
            _sourceSavedViewID = nil
        }
        persistSavedViews()
        if wasRebuildingCounts {
            scheduleSavedViewCountRebuild()
        }
        if wasActive {
            recordWorkspaceSnapshotIfNeeded()
        } else if wasSource {
            syncCurrentWorkspaceSnapshotIfNeeded()
        }
    }

    func moveSavedViews(fromOffsets: IndexSet, toOffset: Int) {
        guard canMutateSavedViews, !savedViewTree.containsFolders else { return }
        var tree = savedViewTree
        tree.moveRootNodes(fromOffsets: fromOffsets, toOffset: toOffset)
        _savedViewTree = tree
        persistSavedViews()
    }

    func moveSavedViewUp(id: UUID) {
        guard canMutateSavedViews else { return }
        var tree = savedViewTree
        guard tree.moveRootNodeUp(id: id) else { return }
        _savedViewTree = tree
        persistSavedViews()
    }

    func moveSavedViewDown(id: UUID) {
        guard canMutateSavedViews else { return }
        var tree = savedViewTree
        guard tree.moveRootNodeDown(id: id) else { return }
        _savedViewTree = tree
        persistSavedViews()
    }

    func canMoveSavedViewUp(id: UUID) -> Bool {
        savedViewTree.canMoveRootNodeUp(id: id)
    }

    func canMoveSavedViewDown(id: UUID) -> Bool {
        savedViewTree.canMoveRootNodeDown(id: id)
    }

    func count(forSavedViewID id: UUID) -> Int? {
        savedViewCounts[id]
    }

    var advancedFilterCount: Int {
        activeAdvancedPredicate?.conditionCount ?? 0
    }

    func clearAdvancedFilters() {
        guard activeAdvancedPredicate != nil else { return }
        _activeSavedViewID = nil
        _sourceSavedViewID = nil
        _activeAdvancedPredicate = nil
        applyFilters()
        recordWorkspaceSnapshotIfNeeded()
    }

    func requestEditingActiveSavedView() {
        _requestedSavedViewEditorID = activeSavedViewID ?? sourceSavedViewID
    }

    var isSavedViewDrifted: Bool {
        sourceSavedViewID != nil && activeSavedViewID == nil
    }

    func updateWouldReplaceAdvancedRules(id: UUID) -> Bool {
        guard let saved = savedViews.first(where: { $0.id == id }) else { return false }
        return saved.query.advancedPredicate?.normalized != activeAdvancedPredicate?.normalized
    }

    func revertToSourceSavedView() {
        guard let sourceSavedViewID else { return }
        applySavedView(id: sourceSavedViewID)
    }

    var hasRelativeSavedViewFilters: Bool {
        activeAdvancedPredicate?.containsRelativeDateRule == true
            || savedViews.contains { $0.query.advancedPredicate?.containsRelativeDateRule == true }
    }

    func refreshRelativeSavedViewFilters(now: Date = Date()) {
        guard hasRelativeSavedViewFilters else { return }
        _savedViewFilterClock = now
        scheduleSavedViewCountRebuild()
        if activeAdvancedPredicate?.containsRelativeDateRule == true {
            applyFilters()
        }
    }

    private func updateSavedView(
        id: UUID,
        invalidatesCount: Bool,
        update: (inout BeadSavedView) -> Void
    ) {
        guard canMutateSavedViews else { return }
        var tree = savedViewTree
        guard tree.updateSavedView(id: id, { view in
            update(&view)
            view = normalizedSavedView(view)
        }) else { return }
        _savedViewTree = tree
        persistSavedViews()
        if invalidatesCount {
            scheduleSavedViewCountRebuild(for: [id])
        }
    }

    private var canMutateSavedViews: Bool {
        guard savedViewPersistenceState.canMutate else {
            lastError = savedViewsPersistenceMessage ?? "Bookmarks are read-only because their saved data could not be interpreted."
            return false
        }
        return true
    }

    var canCreateSavedView: Bool {
        hasReadableProject && savedViewPersistenceState.canMutate
    }

    private func makeCurrentSavedViewQuery() -> BeadSavedViewQuery {
        BeadSavedViewQuery(
            basePreset: BeadBookmarkToken(selectedBookmark),
            statusFilters: statusFilters,
            typeFilters: typeFilters,
            priorityFilters: priorityFilters,
            labelFilters: labelFilters,
            searchText: searchText,
            advancedPredicate: activeAdvancedPredicate
        )
    }

    var currentSavedViewOrdering: BeadSavedViewOrdering {
        .sorted(BeadSavedViewSort(field: sort, direction: sortDirection))
    }

    var currentSavedViewQuery: BeadSavedViewQuery {
        makeCurrentSavedViewQuery()
    }

    func previewSavedView(_ query: BeadSavedViewQuery) async -> BeadSavedViewPreview {
        let index = index
        let now = Date()
        let worker = Task.detached(priority: .userInitiated) {
            BeadSavedViewQueryEvaluator.filteredIssueIDs(
                index: index,
                filter: query,
                now: now,
                shouldCancel: { Task.isCancelled }
            )
        }
        let ids = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return BeadSavedViewPreview(count: 0, sample: []) }
        let sample = ids.prefix(5).compactMap { id in
            index.issue(with: id).map { BeadSavedViewPreview.Item(id: $0.id, title: $0.title) }
        }
        return BeadSavedViewPreview(count: ids.count, sample: sample)
    }

    private func uniqueSavedViewName(_ proposedName: String) -> String {
        let normalized = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = normalized.isEmpty ? "Saved View" : normalized
        let existingNames = Set(savedViews.map { $0.name.localizedLowercase })
        guard existingNames.contains(base.localizedLowercase) else { return base }
        var suffix = 2
        while existingNames.contains("\(base) \(suffix)".localizedLowercase) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

}
