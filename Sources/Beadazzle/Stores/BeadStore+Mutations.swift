import Foundation

private struct MetadataMutationHandle {
    let id: UUID
    let generation: Int
    let possiblePersistedLabels: [String]
}

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
        internal let metadataFieldWriteVersions: [String: BeadMetadataFieldVersions]
        internal let metadataSettlementRevisions: [String: BeadMetadataFieldVersions]
    }

    internal func currentMutationSnapshot() -> MutationSnapshot {
        MutationSnapshot(
            issues: index.issues,
            dependencies: index.dependencies,
            metadataFieldWriteVersions: mutations.metadataFieldWriteVersionsSnapshot(),
            metadataSettlementRevisions: mutations.metadataSettlementRevisionsSnapshot()
        )
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

    /// Debounce window after the last mutation settles before a single reconcile runs.
    private static let reconcileDebounce: Duration = .milliseconds(600)

    /// Marks the start of an optimistic mutation. Increments the in-flight count and
    /// supersedes any queued or running reconcile: a fresh edit must not be clobbered by
    /// a reload of pre-edit state (that was the rapid-edit flicker). The mutation's own
    /// completion reschedules a reconcile.
    @discardableResult
    internal func beginMutation() -> Int {
        let generation = mutations.metadataMutationGeneration
        activeMutationCount += 1
        mutations.optimisticMutationRevision &+= 1
        reconcileDebounceTask?.cancel()
        reconcileDebounceTask = nil
        if reconcileState.cancelInFlightForMutation() {
            refreshTask?.cancel()
        }
        return generation
    }

    internal func endMutation(generation: Int) {
        guard mutations.metadataMutationGeneration == generation else { return }
        activeMutationCount = max(0, activeMutationCount - 1)
        scheduleReconcileIfIdle()
    }

    /// Serializes `bd` subprocesses in submission order. Focused metadata callers apply
    /// their optimistic patch before enqueueing; generic callers also serialize rollback.
    internal func enqueueMutationWrite<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await mutations.writeQueue.enqueue(operation)
    }

    internal func ownsMutation(projectURL: URL, generation: Int) -> Bool {
        self.projectURL == projectURL && mutations.metadataMutationGeneration == generation
    }

    internal func rejectStaleMutation(targeting projectURL: URL) -> Bool {
        if self.projectURL == projectURL {
            requestReconcile()
        }
        return false
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

    private func beginMetadataMutation(
        issueID: String,
        originalIssue: BeadIssue,
        patch: BeadMetadataMutationPatch
    ) -> MetadataMutationHandle {
        let mutationID = UUID()
        var state = mutations.metadataMutations[issueID] ?? BeadMetadataMutationState(
            confirmedIssue: originalIssue,
            pendingMutations: []
        )
        let possiblePersistedLabels: [String]
        if let labels = patch.labels {
            mutations.recordPossiblyPersistedLabels(state.confirmedIssue.labels, for: issueID)
            possiblePersistedLabels = mutations.possiblyPersistedLabels(for: issueID)
            mutations.recordPossiblyPersistedLabels(labels, for: issueID)
        } else {
            possiblePersistedLabels = mutations.possiblyPersistedLabels(for: issueID)
        }
        let fieldWriteVersions = mutations.recordMetadataWrite(patch.fields, for: issueID)
        state.pendingMutations.append(BeadPendingMetadataMutation(
            id: mutationID,
            patch: patch,
            possiblePersistedLabels: possiblePersistedLabels,
            fieldWriteVersions: fieldWriteVersions
        ))
        mutations.metadataMutations[issueID] = state
        return MetadataMutationHandle(
            id: mutationID,
            generation: mutations.metadataMutationGeneration,
            possiblePersistedLabels: possiblePersistedLabels
        )
    }

    private func settleMetadataMutations(
        _ handlesByIssueID: [String: MetadataMutationHandle],
        succeeded: Bool,
        applyResolvedState: Bool = true
    ) -> Bool {
        let snapshot = currentMutationSnapshot()
        let currentIssuesByID = Dictionary(uniqueKeysWithValues: snapshot.issues.map { ($0.id, $0) })
        var updatedIssuesByID: [String: BeadIssue] = [:]
        for issueID in handlesByIssueID.keys.sorted() {
            guard let handle = handlesByIssueID[issueID] else { return false }
            let settlement = resolveMetadataMutationSettlement(
                issueID: issueID,
                mutationID: handle.id,
                succeeded: succeeded,
                currentIssue: currentIssuesByID[issueID]
            )
            guard settlement.isValid else { return false }
            if let updatedIssue = settlement.updatedIssue {
                updatedIssuesByID[issueID] = updatedIssue
            }
        }
        guard applyResolvedState, !updatedIssuesByID.isEmpty else { return true }
        let optimisticIssues = snapshot.issues.map { updatedIssuesByID[$0.id] ?? $0 }
        applyOptimisticState(issues: optimisticIssues, dependencies: snapshot.dependencies)
        return true
    }

    private func resolveMetadataMutationSettlement(
        issueID: String,
        mutationID: UUID,
        succeeded: Bool,
        currentIssue: BeadIssue?
    ) -> (isValid: Bool, updatedIssue: BeadIssue?) {
        guard var state = mutations.metadataMutations[issueID] else { return (false, nil) }
        let fieldsToSettle = state.pendingFields
        let latestFieldWriteVersions = state.latestFieldWriteVersions
        guard state.pendingMutations.contains(where: { $0.id == mutationID }) else {
            return (false, nil)
        }
        guard let completedMutations = state.recordCompletion(id: mutationID, succeeded: succeeded) else {
            return (false, nil)
        }
        for mutation in completedMutations where mutation.patch.labels != nil {
            if mutation.succeeded == true {
                mutations.confirmPersistedLabels(for: issueID)
            } else {
                mutations.recordPossiblyPersistedLabels(
                    mutation.possiblePersistedLabels + (mutation.patch.labels ?? []),
                    for: issueID
                )
            }
        }
        for mutation in state.pendingMutations where mutation.patch.labels != nil {
            mutations.recordPossiblyPersistedLabels(
                mutation.possiblePersistedLabels + (mutation.patch.labels ?? []),
                for: issueID
            )
        }
        let completedFields = completedMutations.reduce(into: BeadMetadataMutationFields()) {
            $0.formUnion($1.patch.fields)
        }
        let completedFieldWriteVersions = completedMutations.reduce(into: BeadMetadataFieldVersions()) {
            $0.replace($1.patch.fields, with: $1.fieldWriteVersions)
        }
        let resolvedMetadataIssue = state.resolvedIssue
        mutations.recordMetadataSettlement(
            completedFields,
            issue: state.confirmedIssue,
            sourceWriteVersions: completedFieldWriteVersions
        )

        if state.pendingMutations.isEmpty {
            mutations.metadataMutations.removeValue(forKey: issueID)
        } else {
            mutations.metadataMutations[issueID] = state
        }
        guard let currentIssue else { return (true, nil) }
        let ownedFields = mutations.metadataFieldWriteVersions(for: issueID).matchingFields(
            latestFieldWriteVersions,
            among: fieldsToSettle
        )
        let updatedIssue = replacingMetadata(ownedFields, in: currentIssue, with: resolvedMetadataIssue)
        return (true, updatedIssue == currentIssue ? nil : updatedIssue)
    }

    internal func replacingMetadata(
        _ fields: BeadMetadataMutationFields,
        in issue: BeadIssue,
        with metadataIssue: BeadIssue
    ) -> BeadIssue {
        var copy = issue
        if fields.contains(.assignee) {
            copy.assignee = metadataIssue.assignee
        }
        if fields.contains(.labels) {
            copy.labels = metadataIssue.labels
        }
        if fields.contains(.dueAt) {
            copy.dueAt = metadataIssue.dueAt
        }
        if fields.contains(.deferUntil) {
            copy.deferUntil = metadataIssue.deferUntil
        }
        return copy
    }

    @discardableResult
    private func settleMetadataMutation(issueID: String, mutationID: UUID, succeeded: Bool) -> Bool {
        let snapshot = currentMutationSnapshot()
        let settlement = resolveMetadataMutationSettlement(
            issueID: issueID,
            mutationID: mutationID,
            succeeded: succeeded,
            currentIssue: snapshot.issues.first(where: { $0.id == issueID })
        )
        guard settlement.isValid else { return false }
        guard let updatedIssue = settlement.updatedIssue else { return true }
        let optimisticIssues = snapshot.issues.map { $0.id == issueID ? updatedIssue : $0 }
        applyOptimisticState(issues: optimisticIssues, dependencies: snapshot.dependencies)
        return true
    }

    private func rollbackIssuesPreservingConcurrentMetadata(
        snapshot: MutationSnapshot,
        optimisticIssues: [BeadIssue],
        currentIssues: [BeadIssue]
    ) -> [BeadIssue] {
        let optimisticByID = Dictionary(uniqueKeysWithValues: optimisticIssues.map { ($0.id, $0) })
        let currentByID = Dictionary(uniqueKeysWithValues: currentIssues.map { ($0.id, $0) })

        return snapshot.issues.map { originalIssue in
            let optimisticIssue = optimisticByID[originalIssue.id]
            let currentIssue = currentByID[originalIssue.id]
            let snapshotWrites = snapshot.metadataFieldWriteVersions[originalIssue.id] ?? .init()
            let currentWrites = mutations.metadataFieldWriteVersions(for: originalIssue.id)
            let snapshotSettlements = snapshot.metadataSettlementRevisions[originalIssue.id] ?? .init()
            let settlement = mutations.metadataSettlement(for: originalIssue.id)
            var rollbackIssue = originalIssue

            if let settlement,
               settlement.revisions.assignee != snapshotSettlements.assignee,
               settlement.sourceWriteVersions.assignee == currentWrites.assignee
                || currentWrites.assignee == snapshotWrites.assignee {
                rollbackIssue.assignee = settlement.issue.assignee
            } else if let currentIssue, let optimisticIssue,
                      currentWrites.assignee != snapshotWrites.assignee
                        || currentIssue.assignee != optimisticIssue.assignee {
                rollbackIssue.assignee = currentIssue.assignee
            }
            if let settlement,
               settlement.revisions.labels != snapshotSettlements.labels,
               settlement.sourceWriteVersions.labels == currentWrites.labels
                || currentWrites.labels == snapshotWrites.labels {
                rollbackIssue.labels = settlement.issue.labels
            } else if let currentIssue, let optimisticIssue,
                      currentWrites.labels != snapshotWrites.labels
                        || currentIssue.labels != optimisticIssue.labels {
                rollbackIssue.labels = currentIssue.labels
            }
            if let settlement,
               settlement.revisions.dueAt != snapshotSettlements.dueAt,
               settlement.sourceWriteVersions.dueAt == currentWrites.dueAt
                || currentWrites.dueAt == snapshotWrites.dueAt {
                rollbackIssue.dueAt = settlement.issue.dueAt
            } else if let currentIssue, let optimisticIssue,
                      currentWrites.dueAt != snapshotWrites.dueAt
                        || currentIssue.dueAt != optimisticIssue.dueAt {
                rollbackIssue.dueAt = currentIssue.dueAt
            }
            if let settlement,
               settlement.revisions.deferUntil != snapshotSettlements.deferUntil,
               settlement.sourceWriteVersions.deferUntil == currentWrites.deferUntil
                || currentWrites.deferUntil == snapshotWrites.deferUntil {
                rollbackIssue.deferUntil = settlement.issue.deferUntil
            } else if let currentIssue, let optimisticIssue,
                      currentWrites.deferUntil != snapshotWrites.deferUntil
                        || currentIssue.deferUntil != optimisticIssue.deferUntil {
                rollbackIssue.deferUntil = currentIssue.deferUntil
            }
            if let currentIssue, let optimisticIssue,
               currentIssue.updatedAt != optimisticIssue.updatedAt {
                rollbackIssue.updatedAt = currentIssue.updatedAt
            }
            return rollbackIssue
        }
    }

    internal func rollbackOptimisticState(
        to snapshot: MutationSnapshot,
        preservingConcurrentMetadataFrom optimisticIssues: [BeadIssue]
    ) {
        let rollbackIssues = rollbackIssuesPreservingConcurrentMetadata(
            snapshot: snapshot,
            optimisticIssues: optimisticIssues,
            currentIssues: index.issues
        )
        applyOptimisticState(issues: rollbackIssues, dependencies: snapshot.dependencies)
        for issue in rollbackIssues {
            if mutations.metadataMutations[issue.id]?.pendingMutations.isEmpty == true {
                mutations.metadataMutations.removeValue(forKey: issue.id)
            }
        }
    }

    private func blockUnsafeLabelClear(
        issueID: String,
        labels: [String],
        knownPossibleLabels: [String]
    ) -> Bool {
        if labels.isEmpty {
            mutations.recordPossiblyPersistedLabels(knownPossibleLabels, for: issueID)
        }
        guard labels.isEmpty, mutations.labelUncertaintyOverflowed(for: issueID) else {
            return false
        }
        lastError = "Labels could not be cleared safely after repeated failed updates. Refresh the project and try again."
        requestReconcile()
        return true
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
        guard let draftID = draft.id else {
            return await createBead(draft, revealCreated: true) != nil
        }

        let mutationGeneration = mutations.metadataMutationGeneration
        let optimisticMutationQueue = mutations.optimisticMutationQueue(for: mutationGeneration)
        await optimisticMutationQueue.acquire()
        defer { optimisticMutationQueue.release() }
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration),
              let originalIssue = index.issue(with: draftID)
        else {
            return false
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
        guard !blockUnsafeLabelClear(
            issueID: draftID,
            labels: draft.labels,
            knownPossibleLabels: originalIssue.labels
        ) else { return false }
        let metadataMutation = beginMetadataMutation(
            issueID: draftID,
            originalIssue: originalIssue,
            patch: BeadMetadataMutationPatch(
                assignee: nil,
                labels: draft.labels,
                dueAt: .set(draft.dueAt),
                deferUntil: .set(draft.deferUntil)
            )
        )
        let commandOriginalIssue: BeadIssue = {
            var copy = originalIssue
            copy.labels = metadataMutation.possiblePersistedLabels
            return copy
        }()
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
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
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
                try await commands.update(projectURL: projectURL, draft: draft, originalIssue: commandOriginalIssue)
            }
            guard self.projectURL == projectURL,
                  mutations.metadataMutationGeneration == metadataMutation.generation
            else { return rejectStaleMutation(targeting: projectURL) }
            guard settleMetadataMutation(
                issueID: draftID,
                mutationID: metadataMutation.id,
                succeeded: true
            ) else { return false }
            reconcileState.request(.mutation)
            return true
        } catch {
            guard self.projectURL == projectURL,
                  mutations.metadataMutationGeneration == metadataMutation.generation
            else { return rejectStaleMutation(targeting: projectURL) }
            guard settleMetadataMutation(
                issueID: draftID,
                mutationID: metadataMutation.id,
                succeeded: false
            ) else { return false }
            rollbackOptimisticState(
                to: snapshot,
                preservingConcurrentMetadataFrom: optimisticIssues
            )
            if attemptedWrite {
                reconcileState.request(.mutation)
            }
            let retryBaseline = retryBaseline(for: [draftID] + childIDs + ancestorIDs)
            reportMutationFailure(
                error,
                title: "Couldn't save \(draftID)",
                retry: { [weak self] in
                    guard let self, self.retryBaselineHolds(retryBaseline) else { return }
                    await self.save(
                        draft,
                        closingChildIssueIDs: childIssueIDs,
                        reopeningAncestorIssueIDs: ancestorIssueIDs
                    )
                }
            )
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

        let mutationGeneration = mutations.metadataMutationGeneration
        let optimisticMutationQueue = mutations.optimisticMutationQueue(for: mutationGeneration)
        await optimisticMutationQueue.acquire()
        defer { optimisticMutationQueue.release() }
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
            return nil
        }
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }

        let createdIssueID: String
        do {
            let commands = commands
            createdIssueID = try await enqueueMutationWrite {
                try await commands.create(projectURL: projectURL, draft: draft)
            }
        } catch {
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                _ = rejectStaleMutation(targeting: projectURL)
                return nil
            }
            requestReconcile()
            reportMutationFailure(
                error,
                title: "Couldn't create bead",
                retry: { [weak self] in
                    _ = await self?.createBead(draft, revealCreated: revealCreated)
                }
            )
            return nil
        }

        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
            _ = rejectStaleMutation(targeting: projectURL)
            return nil
        }

        do {
            let reloaded = try await reloadProjectAfterMutation(
                projectURL: projectURL,
                revealIssueID: createdIssueID,
                revealCreated: revealCreated,
                mutationGeneration: mutationGeneration
            )
            guard reloaded else {
                _ = rejectStaleMutation(targeting: projectURL)
                return nil
            }
            announceCompletion("Created bead \(createdIssueID)")
            return createdIssueID
        } catch {
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                _ = rejectStaleMutation(targeting: projectURL)
                return nil
            }
            requestReconcile()
            // The bead was created; only the reveal/refresh failed. Retrying create would
            // duplicate it, so this failure is not retryable.
            reportMutationFailure(
                error,
                title: "Created \(createdIssueID), but couldn't refresh"
            )
            if revealCreated, index.issue(with: createdIssueID) != nil {
                revealIssue(id: createdIssueID)
            }
            return createdIssueID
        }
    }

    private func reloadProjectAfterMutation(
        projectURL: URL,
        revealIssueID: String,
        revealCreated: Bool,
        mutationGeneration: Int
    ) async throws -> Bool {
        let metadataBaseline = mutations.reloadBaseline()
        let refreshGeneration = project.beginRefresh()
        defer { project.finishRefresh(generation: refreshGeneration) }
        lastError = nil

        let loadedProject = try await loadProjectRecoveringMissingDataSource(projectURL: projectURL)
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration),
              project.ownsRefresh(projectURL: projectURL, generation: refreshGeneration)
        else { return false }

        applyLoadedProject(
            loadedProject,
            projectURL: projectURL,
            metadataBaseline: metadataBaseline
        )
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
        let mutationGeneration = mutations.metadataMutationGeneration
        let optimisticMutationQueue = mutations.optimisticMutationQueue(for: mutationGeneration)
        await optimisticMutationQueue.acquire()
        defer { optimisticMutationQueue.release() }
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
            return false
        }
        let ids = Array(Set(issueIDs)).sorted()
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
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
        applyOptimisticState(issues: optimisticIssues, dependencies: snapshot.dependencies)

        let idsForWrite = hierarchyCompletionWriteOrder(ids)
        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                try await commands.close(projectURL: projectURL, ids: idsForWrite, reason: reason)
            }
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                return rejectStaleMutation(targeting: projectURL)
            }
            reconcileState.request(.mutation)
            announceCompletion(ids.count == 1 ? "Closed bead \(ids[0])" : "Closed \(ids.count) beads")
            return true
        } catch {
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                return rejectStaleMutation(targeting: projectURL)
            }
            rollbackOptimisticState(to: snapshot, preservingConcurrentMetadataFrom: optimisticIssues)
            if attemptedWrite {
                reconcileState.request(.mutation)
            }
            let retryBaseline = retryBaseline(for: ids)
            reportMutationFailure(
                error,
                title: ids.count == 1 ? "Couldn't close \(ids[0])" : "Couldn't close \(ids.count) beads",
                retry: { [weak self] in
                    guard let self, self.retryBaselineHolds(retryBaseline) else { return }
                    await self.close(issueIDs: issueIDs, reason: reason)
                }
            )
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
    func delete(issueIDs: [String], expectedProjectURL: URL? = nil) async -> Bool {
        guard let projectURL else { return false }
        guard expectedProjectURL == nil || expectedProjectURL == projectURL else { return false }
        let mutationGeneration = mutations.metadataMutationGeneration
        let optimisticMutationQueue = mutations.optimisticMutationQueue(for: mutationGeneration)
        await optimisticMutationQueue.acquire()
        defer { optimisticMutationQueue.release() }
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
            return false
        }
        let ids = Array(Set(issueIDs)).sorted()
        guard !ids.isEmpty else { return false }

        let snapshot = currentMutationSnapshot()
        let idSet = Set(ids)
        let optimisticIssues = snapshot.issues.filter { !idSet.contains($0.id) }
        let optimisticDependencies = snapshot.dependencies.filter {
            !idSet.contains($0.issueID) && !idSet.contains($0.dependsOnID)
        }
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
        _selectedIDs.subtract(idSet)
        syncFullPageDetailWithSelection()
        applyOptimisticState(issues: optimisticIssues, dependencies: optimisticDependencies)

        let commands = commands
        do {
            try await enqueueMutationWrite {
                try await commands.delete(projectURL: projectURL, ids: ids)
            }
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                return rejectStaleMutation(targeting: projectURL)
            }
            mutations.discardMetadataMutations(for: ids)
            reconcileState.request(.mutation)
            announceCompletion(ids.count == 1 ? "Deleted bead \(ids[0])" : "Deleted \(ids.count) beads")
            return true
        } catch {
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                return rejectStaleMutation(targeting: projectURL)
            }
            rollbackOptimisticState(to: snapshot, preservingConcurrentMetadataFrom: optimisticIssues)
            reconcileState.request(.mutation)
            let retryBaseline = retryBaseline(for: ids)
            reportMutationFailure(
                error,
                title: ids.count == 1 ? "Couldn't delete \(ids[0])" : "Couldn't delete \(ids.count) beads",
                retry: { [weak self] in
                    guard let self, self.retryBaselineHolds(retryBaseline) else { return }
                    await self.delete(issueIDs: issueIDs, expectedProjectURL: expectedProjectURL)
                }
            )
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
        let mutationGeneration = mutations.metadataMutationGeneration
        let optimisticMutationQueue = mutations.optimisticMutationQueue(for: mutationGeneration)
        await optimisticMutationQueue.acquire()
        defer { optimisticMutationQueue.release() }
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
            return false
        }
        let ids = Array(Set(issueIDs)).sorted()
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

        var metadataMutationsByIssueID: [String: MetadataMutationHandle] = [:]
        if case .set = deferUntil {
            for issueID in ids {
                guard let issue = index.issue(with: issueID) else { continue }
                metadataMutationsByIssueID[issueID] = beginMetadataMutation(
                    issueID: issueID,
                    originalIssue: issue,
                    patch: BeadMetadataMutationPatch(
                        assignee: nil,
                        labels: nil,
                        dueAt: .unchanged,
                        deferUntil: deferUntil
                    )
                )
            }
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
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
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
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration),
                  settleMetadataMutations(metadataMutationsByIssueID, succeeded: true)
            else { return rejectStaleMutation(targeting: projectURL) }
            reconcileState.request(.mutation)
            return true
        } catch {
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration),
                  settleMetadataMutations(
                    metadataMutationsByIssueID,
                    succeeded: false,
                    applyResolvedState: false
                  )
            else { return rejectStaleMutation(targeting: projectURL) }
            rollbackOptimisticState(to: snapshot, preservingConcurrentMetadataFrom: optimisticIssues)
            if attemptedWrite {
                reconcileState.request(.mutation)
            }
            reportMutationFailure(error, title: "Couldn't update beads")
            return false
        }
    }

    @discardableResult
    func updateMetadata(
        issueID: String,
        assignee: String? = nil,
        labels: [String]? = nil,
        dueAt: IssueMetadataDateUpdate = .unchanged,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) async -> Bool {
        guard let projectURL, let originalIssue = index.issue(with: issueID) else { return false }
        let retainedPossibleLabels = mutations.possiblyPersistedLabels(for: issueID)
        let clearsLabels = labels?.isEmpty == true
        if let labels, blockUnsafeLabelClear(
            issueID: issueID,
            labels: labels,
            knownPossibleLabels: originalIssue.labels
        ) { return false }
        let requiresAuthoritativeLabelReplacement = labels?.isEmpty == false
            && (!retainedPossibleLabels.isEmpty || mutations.labelUncertaintyOverflowed(for: issueID))

        let patch = BeadMetadataMutationPatch(
            assignee: assignee,
            labels: labels,
            dueAt: dueAt,
            deferUntil: deferUntil
        )
        guard patch.changes(originalIssue)
                || (clearsLabels && !retainedPossibleLabels.isEmpty)
                || requiresAuthoritativeLabelReplacement
        else {
            return true
        }

        let metadataMutation = beginMetadataMutation(
            issueID: issueID,
            originalIssue: originalIssue,
            patch: patch
        )
        let snapshot = currentMutationSnapshot()
        let optimisticIssues = snapshot.issues.map { issue -> BeadIssue in
            guard issue.id == issueID else { return issue }
            return patch.applying(to: issue)
        }
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
        let perceptibleBusyToken = beginPerceptibleBusy(issueIDs: [issueID])
        defer { endPerceptibleBusy(perceptibleBusyToken) }
        if optimisticIssues != snapshot.issues {
            applyOptimisticState(issues: optimisticIssues, dependencies: snapshot.dependencies)
        }

        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                try await commands.updateMetadata(
                    projectURL: projectURL,
                    issueID: issueID,
                    assignee: assignee,
                    labels: labels,
                    originalLabels: metadataMutation.possiblePersistedLabels,
                    dueAt: dueAt,
                    deferUntil: deferUntil
                )
            }
            guard self.projectURL == projectURL,
                  mutations.metadataMutationGeneration == metadataMutation.generation
            else { return rejectStaleMutation(targeting: projectURL) }
            guard settleMetadataMutation(
                issueID: issueID,
                mutationID: metadataMutation.id,
                succeeded: true
            ) else { return false }
            reconcileState.request(.mutation)
            return true
        } catch {
            guard self.projectURL == projectURL,
                  mutations.metadataMutationGeneration == metadataMutation.generation
            else { return rejectStaleMutation(targeting: projectURL) }
            guard settleMetadataMutation(
                issueID: issueID,
                mutationID: metadataMutation.id,
                succeeded: false
            ) else { return false }
            if attemptedWrite {
                reconcileState.request(.mutation)
            }
            let retryBaseline = retryBaseline(for: [issueID])
            reportMutationFailure(
                error,
                title: "Couldn't update \(issueID)",
                retry: { [weak self] in
                    guard let self, self.retryBaselineHolds(retryBaseline) else { return }
                    await self.updateMetadata(
                        issueID: issueID,
                        assignee: assignee,
                        labels: labels,
                        dueAt: dueAt,
                        deferUntil: deferUntil
                    )
                }
            )
            return false
        }
    }
}
