import Foundation

extension BeadStore {
    var activeSavedView: BeadSavedView? {
        guard let activeSavedViewID else { return nil }
        return savedViews.first { $0.id == activeSavedViewID }
    }

    var activeFolderSavedView: BeadSavedView? {
        guard let activeSavedView, activeSavedView.isFolder else { return nil }
        return activeSavedView
    }

    var folderSavedViews: [BeadSavedView] {
        savedViews.filter(\.isFolder)
    }

    var isShowingFolder: Bool {
        activeFolderSavedView != nil
    }

    var effectiveIssueListMode: IssueListMode {
        isShowingFolder ? .flat : issueListMode
    }

    var canSaveCurrentViewAsSmartBookmark: Bool {
        canCreateSavedView && !isShowingFolder
    }

    var suggestedFolderName: String {
        uniqueSavedViewName("Folder")
    }

    var canReorderActiveFolder: Bool {
        isShowingFolder
            && effectiveIssueListMode == .flat
            && listOrdering.isManual
            && !hasActiveFilters
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && activeAdvancedPredicate == nil
    }

    var beadDragProjectIdentity: String? {
        projectURL?.standardizedFileURL.path
    }

    func beadDragPayload(issueID: String) -> BeadDragPayload? {
        beadDragPayload(issueIDs: [issueID])
    }

    func beadDragPayload(issueIDs: [String]) -> BeadDragPayload? {
        guard let projectIdentity = beadDragProjectIdentity,
              !issueIDs.isEmpty,
              issueIDs.allSatisfy({
                  index.isUserFacingIssueID($0) && issue(with: $0)?.isSystemRecord != true
              })
        else { return nil }
        return BeadDragPayload(
            projectIdentity: projectIdentity,
            issueIDs: issueIDs,
            sourceFolderID: activeFolderSavedView?.id
        )
    }

    func canAcceptBeadDragPayloads(_ payloads: [BeadDragPayload]) -> Bool {
        guard let projectIdentity = beadDragProjectIdentity, !payloads.isEmpty else { return false }
        return payloads.allSatisfy {
            $0.projectIdentity == projectIdentity
                && $0.issueIDs.allSatisfy(index.isUserFacingIssueID)
        }
    }

    @discardableResult
    func addBeadDragPayloads(_ payloads: [BeadDragPayload], toFolder id: UUID) -> Bool {
        guard canAcceptBeadDragPayloads(payloads) else { return false }
        return addIssueIDs(payloads.flatMap(\.issueIDs), toFolder: id)
    }

    func folderIssueIDs(id: UUID, resolvedOnly: Bool = true) -> [String] {
        guard let folder = savedViews.first(where: { $0.id == id })?.folder else { return [] }
        guard resolvedOnly else { return folder.orderedIssueIDs }
        return folder.orderedIssueIDs.filter(index.isUserFacingIssueID)
    }

    func orderedIssueIDsForCurrentRows(_ issueIDs: Set<String>) -> [String] {
        guard !issueIDs.isEmpty else { return [] }
        var remaining = issueIDs
        var ordered: [String] = []
        ordered.reserveCapacity(issueIDs.count)
        for row in issueListRows where remaining.remove(row.issueID) != nil {
            ordered.append(row.issueID)
        }
        ordered.append(contentsOf: remaining.sorted())
        return ordered
    }

    func requestNewFolder(issueIDs: [String] = []) {
        guard canCreateSavedView else { return }
        _requestedFolderIssueIDs = eligibleFolderIssueIDs(issueIDs)
    }

    func clearRequestedFolder() {
        _requestedFolderIssueIDs = nil
    }

    @discardableResult
    func createFolder(
        name: String,
        symbolName: String = "folder",
        issueIDs: [String] = []
    ) -> UUID? {
        guard hasReadableProject, canMutateSavedViews else { return nil }
        let folderID = UUID()
        let view = normalizedSavedView(BeadSavedView(
            id: folderID,
            name: uniqueSavedViewName(name),
            symbolName: symbolName,
            content: .folder(BeadFolderBookmark(
                orderedIssueIDs: eligibleFolderIssueIDs(issueIDs)
            ))
        ))
        _savedViews.append(view)
        persistSavedViews()
        scheduleSavedViewCountRebuild(for: [folderID])
        applySavedView(id: folderID)
        return folderID
    }

    @discardableResult
    func addIssueIDs(_ issueIDs: [String], toFolder id: UUID) -> Bool {
        guard canMutateSavedViews,
              let viewIndex = savedViews.firstIndex(where: { $0.id == id }),
              var folder = savedViews[viewIndex].folder
        else { return false }

        let existing = Set(folder.orderedIssueIDs)
        let additions = eligibleFolderIssueIDs(issueIDs).filter { !existing.contains($0) }
        guard !additions.isEmpty else { return false }

        folder.orderedIssueIDs.append(contentsOf: additions)
        var views = savedViews
        views[viewIndex].content = .folder(folder)
        _savedViews = views
        persistSavedViews()
        scheduleSavedViewCountRebuild(for: [id])
        if activeSavedViewID == id {
            applyFilters()
            syncCurrentWorkspaceSnapshotIfNeeded()
        }
        announceCompletion(
            additions.count == 1
                ? "Added \(additions[0]) to \(views[viewIndex].name)"
                : "Added \(additions.count) beads to \(views[viewIndex].name)"
        )
        return true
    }

    @discardableResult
    func removeIssueIDs(_ issueIDs: Set<String>, fromFolder id: UUID) -> Bool {
        guard canMutateSavedViews,
              !issueIDs.isEmpty,
              let viewIndex = savedViews.firstIndex(where: { $0.id == id }),
              var folder = savedViews[viewIndex].folder
        else { return false }

        let previousCount = folder.orderedIssueIDs.count
        folder.orderedIssueIDs.removeAll { issueIDs.contains($0) }
        let removedCount = previousCount - folder.orderedIssueIDs.count
        guard removedCount > 0 else { return false }

        var views = savedViews
        views[viewIndex].content = .folder(folder)
        _savedViews = views
        persistSavedViews()
        scheduleSavedViewCountRebuild(for: [id])
        if activeSavedViewID == id {
            _selectedIDs.subtract(issueIDs)
            syncFullPageDetailWithSelection()
            scheduleSelectionSideDataRefresh()
            applyFilters()
            syncCurrentWorkspaceSnapshotIfNeeded()
        }
        announceCompletion(
            removedCount == 1
                ? "Removed bead from \(views[viewIndex].name)"
                : "Removed \(removedCount) beads from \(views[viewIndex].name)"
        )
        return true
    }

    @discardableResult
    func moveIssueIDs(
        _ issueIDs: [String],
        inFolder id: UUID,
        toOffset proposedOffset: Int
    ) -> Bool {
        guard canMutateSavedViews,
              canReorderActiveFolder,
              activeSavedViewID == id,
              let viewIndex = savedViews.firstIndex(where: { $0.id == id }),
              var folder = savedViews[viewIndex].folder
        else { return false }

        let movingSet = Set(issueIDs)
        let moving = folder.orderedIssueIDs.filter(movingSet.contains)
        guard !moving.isEmpty else { return false }

        let original = folder.orderedIssueIDs
        let clampedOffset = min(max(proposedOffset, 0), original.count)
        let removedBeforeOffset = original.prefix(clampedOffset).reduce(into: 0) { count, id in
            if movingSet.contains(id) {
                count += 1
            }
        }
        var remaining = original.filter { !movingSet.contains($0) }
        let insertionOffset = min(
            max(clampedOffset - removedBeforeOffset, 0),
            remaining.count
        )
        remaining.insert(contentsOf: moving, at: insertionOffset)
        guard remaining != original else { return false }

        folder.orderedIssueIDs = remaining
        var views = savedViews
        views[viewIndex].content = .folder(folder)
        _savedViews = views
        persistSavedViews()
        applyFilters()
        syncCurrentWorkspaceSnapshotIfNeeded()
        announceCompletion(
            moving.count == 1
                ? "Moved bead in \(views[viewIndex].name)"
                : "Moved \(moving.count) beads in \(views[viewIndex].name)"
        )
        return true
    }

    func selectManualFolderOrdering() {
        guard isShowingFolder, !listOrdering.isManual else { return }
        _listOrdering = .manual
        applyFilters()
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    func selectListSort(_ selectedSort: IssueSort) {
        let savedSort = BeadSavedViewSort(field: selectedSort, direction: sortDirection)
        if isShowingFolder {
            _listOrdering = .sorted(savedSort)
        }
        if sort == selectedSort {
            applySortOnly()
            syncCurrentWorkspaceSnapshotIfNeeded()
        } else {
            sort = selectedSort
        }
    }

    func selectListSortDirection(_ selectedDirection: SortDirection) {
        let savedSort = BeadSavedViewSort(field: sort, direction: selectedDirection)
        if isShowingFolder {
            _listOrdering = .sorted(savedSort)
        }
        if sortDirection == selectedDirection {
            applySortOnly()
            syncCurrentWorkspaceSnapshotIfNeeded()
        } else {
            sortDirection = selectedDirection
        }
    }

    /// Removes dead references only after the caller has a complete authoritative index.
    /// The entire cleanup is persisted once, regardless of the number of folders affected.
    @discardableResult
    func pruneMissingFolderIssueIDs(validIssueIDs: Set<String>) -> Bool {
        guard savedViewPersistenceState.canMutate else { return false }
        var views = savedViews
        var changedFolderIDs: Set<UUID> = []
        for index in views.indices {
            guard var folder = views[index].folder else { continue }
            let originalCount = folder.orderedIssueIDs.count
            folder.orderedIssueIDs.removeAll { !validIssueIDs.contains($0) }
            guard folder.orderedIssueIDs.count != originalCount else { continue }
            views[index].content = .folder(folder)
            changedFolderIDs.insert(views[index].id)
        }
        guard !changedFolderIDs.isEmpty else { return false }

        _savedViews = views
        persistSavedViews()
        scheduleSavedViewCountRebuild(for: changedFolderIDs)
        if let activeSavedViewID, changedFolderIDs.contains(activeSavedViewID) {
            applyFilters()
        }
        return true
    }

    private func eligibleFolderIssueIDs(_ issueIDs: [String]) -> [String] {
        var seen: Set<String> = []
        return issueIDs.compactMap { rawID in
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                  seen.insert(id).inserted,
                  index.isUserFacingIssueID(id),
                  issue(with: id)?.isSystemRecord != true
            else { return nil }
            return id
        }
    }
}
