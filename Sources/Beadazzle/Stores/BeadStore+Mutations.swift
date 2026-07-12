import Foundation

extension BeadStore {
    // MARK: Optimistic mutations

    /// Built-in status `bd close` moves an issue to; used for optimistic close patches.
    internal static let closedStatusName = "closed"
    internal static let deferredStatusName = "deferred"

    /// The in-memory issues/dependencies captured before an optimistic mutation, so a
    /// failed `bd` write can be rolled back to the last authoritative state.
    internal struct MutationSnapshot {
        internal let issues: [BeadIssue]
        internal let dependencies: [BeadDependency]
    }

    internal func currentMutationSnapshot() -> MutationSnapshot {
        MutationSnapshot(issues: index.issues, dependencies: index.dependencies)
    }

    /// Rebuilds the in-memory index from patched issues/dependencies and refreshes derived
    /// state immediately — no disk access, no loading indicator. This is what makes edits
    /// feel instant: the UI reflects the change before `bd` has even run. Correctness is
    /// preserved by writing through `bd` afterward and reconciling silently.
    internal func applyOptimisticState(issues: [BeadIssue], dependencies: [BeadDependency]) {
        index = BeadProjectIndex(
            issues: issues,
            dependencies: dependencies,
            semantics: index.semantics,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
            reusingSearchTextFrom: index
        )
        _contentRevision &+= 1
        scheduleSavedViewCountRebuild()
        _selectedIDs = selectedIDs.filter { index.issue(with: $0) != nil }
        syncFullPageDetailWithSelection()
        pruneExpandedIssueIDs()
        expandAncestorsForSelection(rebuildRows: false)
        applyFilters()
        loadDependenciesForSelection()
        syncCommentsForSelectionFromCache()
        pruneGateDetailsForCurrentSnapshot()
    }

    internal func rollbackOptimisticState(to snapshot: MutationSnapshot) {
        applyOptimisticState(issues: snapshot.issues, dependencies: snapshot.dependencies)
    }

    /// Debounce window after the last mutation settles before a single reconcile runs.
    private static let reconcileDebounce: Duration = .milliseconds(600)

    /// Marks the start of an optimistic mutation. Increments the in-flight count and
    /// supersedes any queued or running reconcile: a fresh edit must not be clobbered by
    /// a reload of pre-edit state (that was the rapid-edit flicker). The mutation's own
    /// completion reschedules a reconcile.
    internal func beginMutation() {
        activeMutationCount += 1
        reconcileDebounceTask?.cancel()
        reconcileDebounceTask = nil
        if reconcileState.cancelInFlightForMutation() {
            refreshTask?.cancel()
        }
    }

    internal func endMutation() {
        activeMutationCount = max(0, activeMutationCount - 1)
        scheduleReconcileIfIdle()
    }

    /// Serializes the `bd` writes behind optimistic mutations. The optimistic patch still
    /// happens immediately, but the subprocesses commit in the same order the user made
    /// changes so a slow earlier write cannot overwrite a newer live metadata edit.
    internal func enqueueMutationWrite(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await mutations.writeQueue.enqueue(operation)
    }

    /// Requests a coalesced reconcile without participating in the in-flight count —
    /// used by non-optimistic mutations that have already awaited their `bd` write.
    internal func requestReconcile(trigger: SnapshotReconcileTrigger = .mutation) {
        reconcileState.request(trigger)
        scheduleReconcileIfIdle()
    }

    internal func externalRefreshPreferenceDidChange() {
        guard automaticallyRefreshesExternalChanges else {
            reconcileState.removeExternalMarkerRequest()
            if !reconcileState.hasPendingRequest {
                reconcileDebounceTask?.cancel()
                reconcileDebounceTask = nil
            }
            return
        }
        guard currentDataSource?.kind == .jsonl,
              snapshotFreshness.state == .possiblyStale else { return }
        requestReconcile(trigger: .externalMarker)
    }

    internal func satisfyPendingExternalRefreshFromSourceChange() {
        reconcileState.removeExternalMarkerRequest()
        if !reconcileState.hasPendingRequest {
            reconcileDebounceTask?.cancel()
            reconcileDebounceTask = nil
        }
    }

    /// Coalesces mutation reconciliation and external marker changes into one silent
    /// export + reload after `reconcileDebounce`. Optimistic patches already show app
    /// mutations immediately; external writes wait for active app mutations to settle so
    /// the shared export cannot replace newer in-memory state with a pre-mutation snapshot.
    internal func scheduleReconcileIfIdle() {
        guard reconcileState.hasPendingRequest,
              activeMutationCount == 0,
              !reconcileState.isInFlight else { return }
        reconcileDebounceTask?.cancel()
        reconcileDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.reconcileDebounce)
            guard let self, !Task.isCancelled else { return }
            guard self.reconcileState.beginIfPossible(activeMutationCount: self.activeMutationCount) else {
                return
            }
            self.refresh(reason: .reconcile, showsLoadingIndicator: false)
        }
    }

    internal func finishReconcileAfterRefreshTermination(projectURL: URL, refreshGeneration: Int) {
        guard project.ownsRefresh(projectURL: projectURL, generation: refreshGeneration) else { return }
        guard reconcileState.isInFlight else { return }
        reconcileState.terminate()
        scheduleReconcileIfIdle()
    }

    private func optimisticallyUpdatedIssue(_ issue: BeadIssue, from draft: IssueDraft) -> BeadIssue {
        var copy = issue
        copy.title = draft.title
        copy.description = draft.description
        copy.design = draft.design
        copy.acceptanceCriteria = draft.acceptanceCriteria
        copy.notes = draft.notes
        copy.status = draft.status
        copy.priority = draft.priority
        copy.issueType = draft.issueType
        copy.assignee = draft.assignee.nilIfBlank
        copy.labels = draft.labels
        copy.dueAt = draft.dueAt
        copy.deferUntil = draft.deferUntil
        copy.updatedAt = Date()
        if statusClosesBeads(draft.status) {
            copy.closedAt = copy.closedAt ?? Date()
        } else {
            copy.closedAt = nil
        }
        return copy
    }

    @discardableResult
    func save(_ draft: IssueDraft) async -> Bool {
        await save(draft, closingChildIssueIDs: [], reopeningAncestorIssueIDs: [])
    }

    @discardableResult
    func save(_ draft: IssueDraft, closingChildIssueIDs childIssueIDs: [String]) async -> Bool {
        await save(draft, closingChildIssueIDs: childIssueIDs, reopeningAncestorIssueIDs: [])
    }

    @discardableResult
    func save(_ draft: IssueDraft, reopeningAncestorIssueIDs ancestorIssueIDs: [String]) async -> Bool {
        await save(draft, closingChildIssueIDs: [], reopeningAncestorIssueIDs: ancestorIssueIDs)
    }

    @discardableResult
    func save(
        _ draft: IssueDraft,
        closingChildIssueIDs childIssueIDs: [String],
        reopeningAncestorIssueIDs ancestorIssueIDs: [String]
    ) async -> Bool {
        guard let projectURL else { return false }

        // Create can't be optimistic — the id is minted by `bd`. Await the write, then
        // reconcile silently and reveal the new bead (no full-screen loading indicator).
        guard let draftID = draft.id, let originalIssue = index.issue(with: draftID) else {
            guard BeadIssueWorkflowPolicy.isNormalMutableIssueType(draft.issueType) else {
                lastError = BeadIssueWorkflowPolicy.reservedIssueTypeError
                return false
            }

            return await createBead(draft, revealCreated: true) != nil
        }

        guard BeadIssueWorkflowPolicy.canChangeIssueTypeThroughNormalMutation(
            originalIssue,
            to: draft.issueType
        ) else {
            lastError = BeadIssueWorkflowPolicy.reservedIssueTypeError
            return false
        }

        let childIDs = Array(Set(childIssueIDs).subtracting([draftID])).sorted()
        let ancestorIDs = Array(Set(ancestorIssueIDs).subtracting([draftID]).subtracting(childIDs)).sorted()
        let makesDone = statusClosesBeads(draft.status)
        let originalIsDone = isDone(originalIssue)
        if makesDone && !originalIsDone {
            guard guardHierarchyAllowsCompletion(
                issueIDs: [draftID],
                includedIssueIDs: [draftID] + childIDs
            ) else { return false }
        } else if !makesDone && originalIsDone {
            guard guardHierarchyAllowsUncompletion(
                issueIDs: [draftID],
                includedIssueIDs: [draftID] + ancestorIDs
            ) else { return false }
        }
        let ancestorReopenStatus: String?
        if ancestorIDs.isEmpty {
            ancestorReopenStatus = nil
        } else if let status = reopenStatusName {
            ancestorReopenStatus = status
        } else {
            lastError = "No active status is configured for reopened beads."
            return false
        }
        let childIDSet = Set(childIDs)
        let ancestorIDSet = Set(ancestorIDs)
        let snapshot = currentMutationSnapshot()
        let now = Date()
        let optimisticIssues = snapshot.issues.map { issue -> BeadIssue in
            if issue.id == draftID {
                return optimisticallyUpdatedIssue(issue, from: draft)
            }
            if ancestorIDSet.contains(issue.id), let ancestorReopenStatus {
                var copy = issue
                copy.status = ancestorReopenStatus
                copy.closedAt = nil
                copy.updatedAt = now
                return copy
            }
            guard childIDSet.contains(issue.id) else { return issue }
            var copy = issue
            copy.status = draft.status
            copy.closedAt = copy.closedAt ?? now
            copy.updatedAt = now
            return copy
        }
        beginMutation()
        defer { endMutation() }
        applyOptimisticState(issues: optimisticIssues, dependencies: snapshot.dependencies)

        let ancestorIDsForWrite = hierarchyReopenWriteOrder(ancestorIDs)
        let childIDsForWrite = hierarchyCompletionWriteOrder(childIDs)
        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                if !ancestorIDsForWrite.isEmpty, let ancestorReopenStatus {
                    try await commands.bulkUpdate(
                        projectURL: projectURL,
                        ids: ancestorIDsForWrite,
                        status: ancestorReopenStatus,
                        type: nil,
                        priority: nil
                    )
                }
                if !childIDsForWrite.isEmpty {
                    try await commands.bulkUpdate(
                        projectURL: projectURL,
                        ids: childIDsForWrite,
                        status: draft.status,
                        type: nil,
                        priority: nil
                    )
                }
                try await commands.update(projectURL: projectURL, draft: draft, originalIssue: originalIssue)
            }
            guard self.projectURL == projectURL else { return false }
            reconcileState.request(.mutation)
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            if attemptedWrite {
                reconcileState.request(.mutation)
            }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func createBead(_ draft: IssueDraft, revealCreated: Bool) async -> String? {
        guard let projectURL else { return nil }
        guard draft.id == nil else { return nil }
        guard BeadIssueWorkflowPolicy.isNormalMutableIssueType(draft.issueType) else {
            lastError = BeadIssueWorkflowPolicy.reservedIssueTypeError
            return nil
        }

        do {
            let createdIssueID = try await commands.create(projectURL: projectURL, draft: draft)
            guard self.projectURL == projectURL else { return nil }
            _ = try await reloadProjectAfterMutation(
                projectURL: projectURL,
                revealIssueID: createdIssueID,
                revealCreated: revealCreated
            )
            return createdIssueID
        } catch {
            guard self.projectURL == projectURL else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    private func reloadProjectAfterMutation(projectURL: URL, revealIssueID: String) async throws -> Bool {
        try await reloadProjectAfterMutation(projectURL: projectURL, revealIssueID: revealIssueID, revealCreated: true)
    }

    private func reloadProjectAfterMutation(projectURL: URL, revealIssueID: String, revealCreated: Bool) async throws -> Bool {
        refreshTask?.cancel()
        lastError = nil

        let loadedProject = try await loadProjectRecoveringMissingDataSource(projectURL: projectURL)
        guard self.projectURL == projectURL else { return false }

        applyLoadedProject(loadedProject, projectURL: projectURL)
        guard index.issue(with: revealIssueID) != nil else {
            throw BeadError.commandFailed(
                command: "bd create --silent",
                output: "Created bead \(revealIssueID) was not found after refresh."
            )
        }
        if revealCreated {
            revealIssue(id: revealIssueID)
        }
        return true
    }

    private func loadProjectRecoveringMissingDataSource(projectURL: URL) async throws -> LoadedProject {
        do {
            return try await projectLoader.refreshSnapshotAndLoadProject(
                projectURL: projectURL,
                staleCutoffDays: staleCutoffDays,
                hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
            )
        } catch BeadError.projectMissingDataSource(let missingURL) {
            guard Self.beadsDirectoryExists(at: projectURL) else {
                throw BeadError.projectMissingDataSource(missingURL)
            }
            return try await projectLoader.exportAndLoadProject(
                projectURL: projectURL,
                staleCutoffDays: staleCutoffDays,
                hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
            )
        }
    }

    func closeSelected() {
        let ids = Array(selectedIDs)
        Task { @MainActor in
            await close(issueIDs: ids, reason: "Closed in Beadazzle")
        }
    }

    @discardableResult
    func close(issueIDs: [String], reason: String?) async -> Bool {
        guard let projectURL else { return false }
        let ids = issueIDs.sorted()
        guard !ids.isEmpty else { return false }
        guard guardHierarchyAllowsCompletion(issueIDs: ids, includedIssueIDs: ids) else { return false }

        let snapshot = currentMutationSnapshot()
        let idSet = Set(ids)
        let now = Date()
        let optimisticIssues = snapshot.issues.map { issue -> BeadIssue in
            guard idSet.contains(issue.id) else { return issue }
            var copy = issue
            copy.status = Self.closedStatusName
            copy.closedAt = copy.closedAt ?? now
            copy.updatedAt = now
            return copy
        }
        beginMutation()
        defer { endMutation() }
        applyOptimisticState(issues: optimisticIssues, dependencies: snapshot.dependencies)

        let idsForWrite = hierarchyCompletionWriteOrder(ids)
        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                try await commands.close(projectURL: projectURL, ids: idsForWrite, reason: reason)
            }
            guard self.projectURL == projectURL else { return false }
            reconcileState.request(.mutation)
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            if attemptedWrite {
                reconcileState.request(.mutation)
            }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func reopen(issueIDs: [String], reopeningAncestorIssueIDs ancestorIssueIDs: [String] = []) async -> Bool {
        guard let status = reopenStatusName else {
            lastError = "No active status is configured for reopened beads."
            return false
        }
        let ids = issueIDs
            .compactMap { index.issue(with: $0) }
            .filter(isDone)
            .map(\.id)
            .sorted()
        guard !ids.isEmpty else { return false }
        return await bulkSet(issueIDs: ids, status: status, reopeningAncestorIssueIDs: ancestorIssueIDs)
    }

    @discardableResult
    func reopenBlockedIssue(issueID: String) async -> Bool {
        guard let status = reopenStatusName else {
            lastError = "No active status is configured for reopened beads."
            return false
        }
        return await bulkSet(issueIDs: [issueID], status: status)
    }

    @discardableResult
    func delete(issueIDs: [String]) async -> Bool {
        guard let projectURL else { return false }
        let ids = issueIDs.sorted()
        guard !ids.isEmpty else { return false }

        let snapshot = currentMutationSnapshot()
        let idSet = Set(ids)
        let optimisticIssues = snapshot.issues.filter { !idSet.contains($0.id) }
        let optimisticDependencies = snapshot.dependencies.filter {
            !idSet.contains($0.issueID) && !idSet.contains($0.dependsOnID)
        }
        beginMutation()
        defer { endMutation() }
        _selectedIDs.subtract(idSet)
        syncFullPageDetailWithSelection()
        applyOptimisticState(issues: optimisticIssues, dependencies: optimisticDependencies)

        let commands = commands
        do {
            try await enqueueMutationWrite {
                try await commands.delete(projectURL: projectURL, ids: ids)
            }
            guard self.projectURL == projectURL else { return false }
            reconcileState.request(.mutation)
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func bulkSet(
        status: String? = nil,
        type: String? = nil,
        priority: Int? = nil,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) async -> Bool {
        await bulkSet(
            issueIDs: Array(selectedIDs),
            status: status,
            type: type,
            priority: priority,
            deferUntil: deferUntil
        )
    }

    @discardableResult
    func bulkSet(
        issueIDs: [String],
        status: String? = nil,
        type: String? = nil,
        priority: Int? = nil,
        deferUntil: IssueMetadataDateUpdate = .unchanged,
        reopeningAncestorIssueIDs ancestorIssueIDs: [String] = []
    ) async -> Bool {
        guard let projectURL else { return false }
        let ids = issueIDs.sorted()
        guard !ids.isEmpty else { return false }
        if let type {
            guard BeadIssueWorkflowPolicy.isNormalMutableIssueType(type),
                  ids.allSatisfy({ id in
                      guard let issue = index.issue(with: id) else { return false }
                      return !issue.isGate
                  }) else {
                lastError = BeadIssueWorkflowPolicy.reservedIssueTypeError
                return false
            }
        }

        let makesDone = status.map(statusClosesBeads) ?? false
        let ancestorIDs = Array(Set(ancestorIssueIDs).subtracting(ids)).sorted()
        let ancestorReopenStatus: String?
        if let status, statusClosesBeads(status) {
            guard guardHierarchyAllowsCompletion(issueIDs: ids, includedIssueIDs: ids) else { return false }
            ancestorReopenStatus = nil
        } else if status != nil {
            guard guardHierarchyAllowsUncompletion(
                issueIDs: ids,
                includedIssueIDs: ids + ancestorIDs
            ) else { return false }
            if ancestorIDs.isEmpty {
                ancestorReopenStatus = nil
            } else if let reopenStatusName {
                ancestorReopenStatus = reopenStatusName
            } else {
                lastError = "No active status is configured for reopened beads."
                return false
            }
        } else {
            ancestorReopenStatus = nil
        }

        let snapshot = currentMutationSnapshot()
        let idSet = Set(ids)
        let ancestorIDSet = Set(ancestorIDs)
        let now = Date()
        let optimisticIssues = snapshot.issues.map { issue -> BeadIssue in
            if ancestorIDSet.contains(issue.id), let ancestorReopenStatus {
                var copy = issue
                copy.status = ancestorReopenStatus
                copy.closedAt = nil
                copy.updatedAt = now
                return copy
            }
            guard idSet.contains(issue.id) else { return issue }
            var copy = issue
            if let status { copy.status = status }
            if let type { copy.issueType = type }
            if let priority { copy.priority = priority }
            switch deferUntil {
            case .unchanged:
                break
            case .set(let date):
                copy.deferUntil = date
            }
            if let status {
                copy.closedAt = statusClosesBeads(status) ? (copy.closedAt ?? now) : nil
            }
            copy.updatedAt = now
            return copy
        }
        beginMutation()
        defer { endMutation() }
        applyOptimisticState(issues: optimisticIssues, dependencies: snapshot.dependencies)

        let idsForWrite: [String]
        if makesDone {
            idsForWrite = hierarchyCompletionWriteOrder(ids)
        } else if status != nil {
            idsForWrite = hierarchyReopenWriteOrder(ids)
        } else {
            idsForWrite = ids
        }
        let ancestorIDsForWrite = hierarchyReopenWriteOrder(ancestorIDs)
        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                if !ancestorIDsForWrite.isEmpty, let ancestorReopenStatus {
                    try await commands.bulkUpdate(
                        projectURL: projectURL,
                        ids: ancestorIDsForWrite,
                        status: ancestorReopenStatus,
                        type: nil,
                        priority: nil,
                        deferUntil: .unchanged
                    )
                }
                try await commands.bulkUpdate(
                    projectURL: projectURL,
                    ids: idsForWrite,
                    status: status,
                    type: type,
                    priority: priority,
                    deferUntil: deferUntil
                )
            }
            guard self.projectURL == projectURL else { return false }
            reconcileState.request(.mutation)
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            if attemptedWrite {
                reconcileState.request(.mutation)
            }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateMetadata(
        issueID: String,
        labels: [String]? = nil,
        dueAt: IssueMetadataDateUpdate = .unchanged,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) async -> Bool {
        guard let projectURL, let originalIssue = index.issue(with: issueID) else { return false }

        var draft = IssueDraft(issue: originalIssue)
        if let labels {
            draft.labels = labels
        }
        switch dueAt {
        case .unchanged:
            break
        case .set(let date):
            draft.dueAt = date
        }
        switch deferUntil {
        case .unchanged:
            break
        case .set(let date):
            draft.deferUntil = date
        }

        guard draft != IssueDraft(issue: originalIssue) else { return true }

        let snapshot = currentMutationSnapshot()
        let optimisticIssues = snapshot.issues.map { issue -> BeadIssue in
            guard issue.id == issueID else { return issue }
            return optimisticallyUpdatedIssue(issue, from: draft)
        }
        beginMutation()
        defer { endMutation() }
        applyOptimisticState(issues: optimisticIssues, dependencies: snapshot.dependencies)

        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                try await commands.updateMetadata(
                    projectURL: projectURL,
                    issueID: issueID,
                    labels: labels,
                    originalLabels: originalIssue.labels,
                    dueAt: dueAt,
                    deferUntil: deferUntil
                )
            }
            guard self.projectURL == projectURL else { return false }
            reconcileState.request(.mutation)
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            if attemptedWrite {
                reconcileState.request(.mutation)
            }
            lastError = error.localizedDescription
            return false
        }
    }
}
