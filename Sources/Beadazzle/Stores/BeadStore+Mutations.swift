import Foundation

struct MetadataMutationHandle {
    let id: UUID
    let generation: Int
    let possiblePersistedLabels: [String]
}

extension BeadStore {
    // MARK: Optimistic mutations

    /// Built-in status `bd close` moves an issue to; used for optimistic close patches.
    internal static let closedStatusName = "closed"
    internal static let deferredStatusName = "deferred"

    /// Installs a complete in-memory snapshot for focused store tests and diagnostic
    /// callers. User mutations use sparse projection entries instead.
    internal func applyOptimisticState(issues: [BeadIssue], dependencies: [BeadDependency]) {
        let replacement = BeadProjectIndex(
            issues: issues,
            dependencies: dependencies,
            semantics: index.semantics,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
            reusingSearchTextFrom: index
        )
        authoritativeIndex = replacement
        index = replacement
        _contentRevision &+= 1
        scheduleSavedViewCountRebuild()
        _selectedIDs = selectedIDs.filter(replacement.isUserFacingIssueID)
        syncFullPageDetailWithSelection()
        pruneExpandedIssueIDs()
        expandAncestorsForSelection(rebuildRows: false)
        applyFilters()
        loadDependenciesForSelection()
        syncCommentsForSelectionFromCache()
        pruneGateDetailsForCurrentSnapshot()
    }

    @discardableResult
    internal func applyOptimisticProjection(_ entry: BeadMutationProjectionEntry) -> UUID {
        mutations.projection.append(entry)
        _contentRevision &+= 1
        _selectedIDs = selectedIDs.filter { issueID in
            issue(with: issueID)?.isSystemRecord == false
        }
        syncFullPageDetailWithSelection()
        syncCommentsForSelectionFromCache()
        scheduleProjectionMaterialization()
        return entry.id
    }

    internal func settleOptimisticProjection(id: UUID, succeeded: Bool) {
        if succeeded {
            _ = mutations.projection.markSucceeded(id)
            return
        }
        guard mutations.projection.remove(id) else { return }
        _contentRevision &+= 1
        _selectedIDs = selectedIDs.filter { issueID in
            issue(with: issueID)?.isSystemRecord == false
        }
        syncFullPageDetailWithSelection()
        syncCommentsForSelectionFromCache()
        scheduleProjectionMaterialization()
    }

    internal func scheduleProjectionMaterialization() {
        projectionGeneration &+= 1
        let generation = projectionGeneration
        projectionMaterializationTask?.cancel()

        let base = authoritativeIndex
        let projection = mutations.projection
        let previousIndex = index
        let projectionMaterializer = projectionMaterializer
        let expectedProjectURL = projectURL
        let staleCutoffDays = staleCutoffDays
        let hidesParentsWithOnlyBlockedChildrenInReady = hidesParentsWithOnlyBlockedChildrenInReady

        projectionMaterializationTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.projectionGeneration == generation {
                    self.projectionMaterializationTask = nil
                }
            }
            // Let same-run-loop mutation bursts collapse to their final sparse projection.
            // The materializer actor serializes any rebuild that has already begun.
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            let materializedIndex = await projectionMaterializer.materialize(
                projection: projection,
                over: base,
                previousIndex: previousIndex,
                staleCutoffDays: staleCutoffDays,
                hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
            )
            guard !Task.isCancelled,
                  let self,
                  let materializedIndex,
                  self.projectionGeneration == generation,
                  self.projectURL == expectedProjectURL
            else { return }

            self.index = materializedIndex
            self._contentRevision &+= 1
            self.scheduleSavedViewCountRebuild()
            self._selectedIDs = self.selectedIDs.filter(materializedIndex.isUserFacingIssueID)
            self.syncFullPageDetailWithSelection()
            self.pruneExpandedIssueIDs()
            self.expandAncestorsForSelection(rebuildRows: false)
            self.applyFilters()
            self.loadDependenciesForSelection()
            self.syncCommentsForSelectionFromCache()
            self.pruneGateDetailsForCurrentSnapshot()
        }
    }

    func waitForPendingProjectionMaterialization() async {
        while let task = projectionMaterializationTask {
            await task.value
            if projectionMaterializationTask == task { return }
        }
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

    private func optimisticSavePatch(from draft: IssueDraft, originalIssue: BeadIssue) -> BeadIssueMutationPatch {
        let now = Date()
        return BeadIssueMutationPatch(
            title: .set(draft.title),
            description: .set(draft.description),
            design: .set(draft.design),
            acceptanceCriteria: .set(draft.acceptanceCriteria),
            notes: .set(draft.notes),
            status: .set(draft.status),
            priority: .set(draft.priority),
            issueType: .set(draft.issueType),
            updatedAt: .set(now),
            closedAt: .set(statusClosesBeads(draft.status) ? (originalIssue.closedAt ?? now) : nil),
            dueAt: .set(draft.dueAt),
            deferUntil: .set(draft.deferUntil),
            labels: .set(draft.labels)
        )
    }

    private func projectedCreatedIssue(id: String, draft: IssueDraft) -> BeadIssue {
        let now = Date()
        return BeadIssue(
            id: id,
            title: draft.title,
            description: draft.description,
            design: draft.design,
            acceptanceCriteria: draft.acceptanceCriteria,
            notes: draft.notes,
            status: draft.status,
            priority: draft.priority,
            issueType: draft.issueType,
            assignee: draft.assignee.nilIfBlank,
            owner: nil,
            createdAt: now,
            updatedAt: now,
            closedAt: statusClosesBeads(draft.status) ? now : nil,
            dueAt: draft.dueAt,
            deferUntil: draft.deferUntil,
            externalRef: nil,
            parentID: draft.parentID,
            labels: draft.labels,
            dependencyCount: 0,
            dependentCount: 0,
            commentCount: 0,
            pinned: false,
            ephemeral: false,
            isTemplate: false
        )
    }

    private func generatedIssueID() -> String {
        var prefixCounts: [String: Int] = [:]
        for issue in authoritativeIndex.issues {
            guard let prefix = Self.issuePrefix(from: issue.id) else { continue }
            prefixCounts[prefix, default: 0] += 1
        }
        let inferredPrefix = prefixCounts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
        let fallbackPrefix = projectEnvironment?.context.database ?? projectURL?.lastPathComponent
        let prefix = Self.normalizedIssuePrefix(
            projectEnvironment?.context.issuePrefix ?? inferredPrefix ?? fallbackPrefix
        ) ?? "bd"

        while true {
            let suffix = UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .prefix(12)
                .lowercased()
            let candidate = "\(prefix)-\(suffix)"
            if issue(with: candidate) == nil {
                return candidate
            }
        }
    }

    private static func issuePrefix(from issueID: String) -> String? {
        guard let root = issueID.split(separator: ".", maxSplits: 1).first,
              let separator = root.lastIndex(of: "-"),
              separator != root.startIndex else {
            return nil
        }
        return normalizedIssuePrefix(String(root[..<separator]))
    }

    private static func normalizedIssuePrefix(_ value: String?) -> String? {
        guard let value = value?.nilIfBlank else { return nil }
        let components = value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return components.filter { !$0.isEmpty }.joined(separator: "-").nilIfBlank
    }

    internal func beginMetadataMutation(
        issueID: String,
        originalIssue: BeadIssue,
        patch: BeadMetadataMutationPatch,
        writeWasAttempted: Bool = true
    ) -> MetadataMutationHandle {
        let mutationID = UUID()
        var state = mutations.metadataMutations[issueID] ?? BeadMetadataMutationState(
            confirmedIssue: originalIssue,
            pendingMutations: []
        )
        let proposedLabels = patch.proposedLabels(for: state.resolvedIssue)
        let possiblePersistedLabels: [String]
        if let proposedLabels, writeWasAttempted {
            mutations.recordPossiblyPersistedLabels(state.confirmedIssue.labels, for: issueID)
            possiblePersistedLabels = mutations.possiblyPersistedLabels(for: issueID)
            mutations.recordPossiblyPersistedLabels(proposedLabels, for: issueID)
        } else {
            possiblePersistedLabels = mutations.possiblyPersistedLabels(for: issueID)
        }
        let fieldWriteVersions = mutations.recordMetadataWrite(patch.fields, for: issueID)
        state.pendingMutations.append(BeadPendingMetadataMutation(
            id: mutationID,
            patch: patch,
            possiblePersistedLabels: possiblePersistedLabels,
            proposedLabels: proposedLabels,
            fieldWriteVersions: fieldWriteVersions,
            writeWasAttempted: writeWasAttempted
        ))
        mutations.metadataMutations[issueID] = state
        return MetadataMutationHandle(
            id: mutationID,
            generation: mutations.metadataMutationGeneration,
            possiblePersistedLabels: possiblePersistedLabels
        )
    }

    /// Marks the point immediately before a bulk command is enqueued. Bulk editors
    /// register all optimistic patches up front, but cancelled, never-started work
    /// must not be treated as possibly persisted on disk.
    @discardableResult
    internal func markMetadataMutationWriteAttempted(
        issueID: String,
        mutationID: UUID
    ) -> Bool {
        guard var state = mutations.metadataMutations[issueID],
              let index = state.pendingMutations.firstIndex(where: { $0.id == mutationID })
        else { return false }
        guard !state.pendingMutations[index].writeWasAttempted else { return true }

        if let proposedLabels = state.pendingMutations[index].proposedLabels {
            mutations.recordPossiblyPersistedLabels(state.confirmedIssue.labels, for: issueID)
            state.pendingMutations[index].possiblePersistedLabels = mutations.possiblyPersistedLabels(
                for: issueID
            )
            mutations.recordPossiblyPersistedLabels(proposedLabels, for: issueID)
        }
        state.pendingMutations[index].writeWasAttempted = true
        mutations.metadataMutations[issueID] = state
        return true
    }

    private func settleMetadataMutations(
        _ handlesByIssueID: [String: MetadataMutationHandle],
        succeeded: Bool
    ) -> Bool {
        for issueID in handlesByIssueID.keys.sorted() {
            guard let handle = handlesByIssueID[issueID],
                  resolveMetadataMutationSettlement(
                      issueID: issueID,
                      mutationID: handle.id,
                      succeeded: succeeded
                  )
            else { return false }
        }
        return true
    }

    private func resolveMetadataMutationSettlement(
        issueID: String,
        mutationID: UUID,
        succeeded: Bool
    ) -> Bool {
        guard var state = mutations.metadataMutations[issueID] else { return false }
        guard state.pendingMutations.contains(where: { $0.id == mutationID }) else {
            return false
        }
        guard let completedMutations = state.recordCompletion(id: mutationID, succeeded: succeeded) else {
            return false
        }
        for mutation in completedMutations
        where mutation.patch.updatesLabels && mutation.writeWasAttempted {
            if mutation.succeeded == true,
               mutation.patch.confirmsCompleteLabelSetOnSuccess {
                mutations.confirmPersistedLabels(for: issueID)
            } else if mutation.succeeded == false {
                mutations.recordPossiblyPersistedLabels(
                    mutation.possiblePersistedLabels + (mutation.proposedLabels ?? []),
                    for: issueID
                )
            }
        }
        for mutation in state.pendingMutations
        where mutation.patch.updatesLabels && mutation.writeWasAttempted {
            mutations.recordPossiblyPersistedLabels(
                mutation.possiblePersistedLabels + (mutation.proposedLabels ?? []),
                for: issueID
            )
        }
        let completedFields = completedMutations.reduce(into: BeadMetadataMutationFields()) {
            $0.formUnion($1.patch.fields)
        }
        let completedFieldWriteVersions = completedMutations.reduce(into: BeadMetadataFieldVersions()) {
            $0.replace($1.patch.fields, with: $1.fieldWriteVersions)
        }
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
        return true
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
    internal func settleMetadataMutation(
        issueID: String,
        mutationID: UUID,
        succeeded: Bool
    ) -> Bool {
        resolveMetadataMutationSettlement(
            issueID: issueID,
            mutationID: mutationID,
            succeeded: succeeded
        )
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

        // The id is minted by `bd`, so create awaits that single write. Once the id arrives,
        // a projected issue is revealed immediately; snapshot export/reload happens later.
        guard let draftID = draft.id else {
            return await createBead(draft, revealCreated: true) != nil
        }

        let mutationGeneration = mutations.metadataMutationGeneration
        let optimisticMutationQueue = mutations.optimisticMutationQueue(for: mutationGeneration)
        await optimisticMutationQueue.acquire()
        defer { optimisticMutationQueue.release() }
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration),
              let originalIssue = issue(with: draftID)
        else {
            return false
        }

        guard BeadIssueWorkflowPolicy.canChangeIssueTypeThroughNormalMutation(
            originalIssue,
            to: draft.issueType
        ) else {
            lastError = originalIssue.isSystemRecord
                ? BeadIssueWorkflowPolicy.systemRecordIssueTypeError
                : BeadIssueWorkflowPolicy.normalMutationTypeError(for: draft.issueType)
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
        let managedStateDimensions = stateDimensionsManagedForLabelEditing(issueID: draftID)
        let ordinaryDraftLabels = BeadStateLabel.excluding(
            dimensions: managedStateDimensions,
            from: draft.labels
        )
        let ordinaryOriginalLabels = BeadStateLabel.excluding(
            dimensions: managedStateDimensions,
            from: originalIssue.labels
        )
        guard !blockUnsafeLabelClear(
            issueID: draftID,
            labels: ordinaryDraftLabels,
            knownPossibleLabels: ordinaryOriginalLabels
        ) else { return false }
        let metadataPatch = BeadMetadataMutationPatch(
            assignee: nil,
            labels: draft.labels,
            preservingStateDimensions: managedStateDimensions,
            dueAt: .set(draft.dueAt),
            deferUntil: .set(draft.deferUntil)
        )
        let metadataMutation = beginMetadataMutation(
            issueID: draftID,
            originalIssue: originalIssue,
            patch: metadataPatch
        )
        var optimisticDraft = draft
        optimisticDraft.labels = metadataPatch.proposedLabels(for: originalIssue) ?? draft.labels
        var preparedCommandDraft = optimisticDraft
        preparedCommandDraft.labels = BeadStateLabel.excluding(
            dimensions: managedStateDimensions,
            from: optimisticDraft.labels
        )
        let commandDraft = preparedCommandDraft
        let commandOriginalIssue: BeadIssue = {
            var copy = originalIssue
            copy.labels = BeadStateLabel.excluding(
                dimensions: managedStateDimensions,
                from: metadataMutation.possiblePersistedLabels
            )
            return copy
        }()
        let childIDSet = Set(childIDs)
        let ancestorIDSet = Set(ancestorIDs)
        let now = Date()
        var issueChanges: [String: BeadProjectedIssueChange] = [
            draftID: .update(optimisticSavePatch(from: optimisticDraft, originalIssue: originalIssue))
        ]
        for ancestorID in ancestorIDSet {
            guard let ancestorReopenStatus else { continue }
            issueChanges[ancestorID] = .update(BeadIssueMutationPatch(
                status: .set(ancestorReopenStatus),
                updatedAt: .set(now),
                closedAt: .set(nil)
            ))
        }
        for childID in childIDSet {
            let closedAt = issue(with: childID)?.closedAt ?? now
            issueChanges[childID] = .update(BeadIssueMutationPatch(
                status: .set(draft.status),
                updatedAt: .set(now),
                closedAt: .set(closedAt)
            ))
        }
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
        let projectionID = applyOptimisticProjection(
            BeadMutationProjectionEntry(issueChanges: issueChanges)
        )

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
                try await commands.update(
                    projectURL: projectURL,
                    draft: commandDraft,
                    originalIssue: commandOriginalIssue
                )
            }
            guard self.projectURL == projectURL,
                  mutations.metadataMutationGeneration == metadataMutation.generation
            else { return rejectStaleMutation(targeting: projectURL) }
            guard settleMetadataMutation(
                issueID: draftID,
                mutationID: metadataMutation.id,
                succeeded: true
            ) else { return false }
            settleOptimisticProjection(id: projectionID, succeeded: true)
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
            settleOptimisticProjection(id: projectionID, succeeded: false)
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
        guard let submission = submitCreateBead(draft, revealCreated: revealCreated) else {
            return nil
        }
        return await submission.value ? submission.issueID : nil
    }

    @discardableResult
    func submitCreateBead(_ draft: IssueDraft, revealCreated: Bool) -> BeadCreateSubmission? {
        guard let projectURL else { return nil }
        guard draft.id == nil else { return nil }
        guard BeadIssueWorkflowPolicy.isNormalMutableIssueType(draft.issueType) else {
            lastError = BeadIssueWorkflowPolicy.normalMutationTypeError(for: draft.issueType)
            return nil
        }

        let mutationGeneration = mutations.metadataMutationGeneration
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
            return nil
        }
        if let parentID = draft.parentID?.nilIfBlank,
           let unavailableMessage = addSubIssueUnavailableMessage(parentID: parentID) {
            lastError = unavailableMessage
            return nil
        }
        let mutationLifetimeGeneration = beginMutation()
        let createdIssueID = generatedIssueID()
        var preparedCommandDraft = draft
        preparedCommandDraft.id = createdIssueID
        let commandDraft = preparedCommandDraft
        let projectedIssue = projectedCreatedIssue(id: createdIssueID, draft: draft)
        let projectionID = applyOptimisticProjection(
            BeadMutationProjectionEntry(
                issueChanges: [createdIssueID: .insert(projectedIssue)]
            )
        )
        if revealCreated {
            revealIssue(id: createdIssueID)
        }

        let commands = commands
        let completion = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.endMutation(generation: mutationLifetimeGeneration) }
            do {
                let persistedIssueID = try await self.enqueueMutationWrite {
                    try await commands.create(projectURL: projectURL, draft: commandDraft)
                }
                guard persistedIssueID == createdIssueID else {
                    throw BeadError.commandFailed(
                        command: "bd create --id \(createdIssueID)",
                        output: "bd reported the unexpected issue id \(persistedIssueID)."
                    )
                }
                guard self.ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                    return self.rejectStaleMutation(targeting: projectURL)
                }
                self.settleOptimisticProjection(id: projectionID, succeeded: true)
                self.reconcileState.request(.mutation)
                self.announceCompletion("Created bead \(createdIssueID)")
                return true
            } catch {
                guard self.ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                    return self.rejectStaleMutation(targeting: projectURL)
                }
                self.settleOptimisticProjection(id: projectionID, succeeded: false)
                self.reconcileState.request(.mutation)
                self.reportMutationFailure(
                    error,
                    title: "Couldn't create bead",
                    retry: { [weak self] in
                        guard let retry = self?.submitCreateBead(draft, revealCreated: revealCreated) else {
                            return
                        }
                        _ = await retry.value
                    }
                )
                return false
            }
        }
        return BeadCreateSubmission(issueID: createdIssueID, completion: completion)
    }

    func closeSelected() {
        let ids = Array(selectedIDs)
        _ = submitClose(issueIDs: ids, reason: "Closed in Beadazzle")
    }

    @discardableResult
    func close(issueIDs: [String], reason: String?) async -> Bool {
        guard let submission = submitClose(issueIDs: issueIDs, reason: reason) else {
            return false
        }
        return await submission.value
    }

    @discardableResult
    func submitClose(issueIDs: [String], reason: String?) -> BeadMutationSubmission? {
        guard let projectURL else { return nil }
        let mutationGeneration = mutations.metadataMutationGeneration
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
            return nil
        }
        let ids = Array(Set(issueIDs)).sorted()
        guard !ids.isEmpty else { return nil }
        guard ids.allSatisfy({ issue(with: $0)?.isSystemRecord != true }) else {
            lastError = BeadIssueWorkflowPolicy.systemRecordIssueTypeError
            return nil
        }
        guard guardHierarchyAllowsCompletion(issueIDs: ids, includedIssueIDs: ids) else { return nil }

        let now = Date()
        var issueChanges: [String: BeadProjectedIssueChange] = [:]
        for issueID in ids {
            issueChanges[issueID] = .update(BeadIssueMutationPatch(
                status: .set(Self.closedStatusName),
                updatedAt: .set(now),
                closedAt: .set(issue(with: issueID)?.closedAt ?? now)
            ))
        }
        let mutationLifetimeGeneration = beginMutation()
        let projectionID = applyOptimisticProjection(
            BeadMutationProjectionEntry(issueChanges: issueChanges)
        )

        let idsForWrite = hierarchyCompletionWriteOrder(ids)
        let commands = commands
        let completion = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.endMutation(generation: mutationLifetimeGeneration) }
            do {
                try await self.enqueueMutationWrite {
                    try await commands.close(projectURL: projectURL, ids: idsForWrite, reason: reason)
                }
                guard self.ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                    return self.rejectStaleMutation(targeting: projectURL)
                }
                self.settleOptimisticProjection(id: projectionID, succeeded: true)
                self.reconcileState.request(.mutation)
                self.announceCompletion(ids.count == 1 ? "Closed bead \(ids[0])" : "Closed \(ids.count) beads")
                return true
            } catch {
                guard self.ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                    return self.rejectStaleMutation(targeting: projectURL)
                }
                self.settleOptimisticProjection(id: projectionID, succeeded: false)
                self.reconcileState.request(.mutation)
                let retryBaseline = self.retryBaseline(for: ids)
                self.reportMutationFailure(
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
        return BeadMutationSubmission(completion: completion)
    }

    @discardableResult
    func reopen(issueIDs: [String], reopeningAncestorIssueIDs ancestorIssueIDs: [String] = []) async -> Bool {
        guard let status = reopenStatusName else {
            lastError = "No active status is configured for reopened beads."
            return false
        }
        let ids = issueIDs
            .compactMap { issue(with: $0) }
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
        let requestedIDs = Array(Set(issueIDs)).sorted()
        guard !requestedIDs.isEmpty else { return false }
        guard requestedIDs.allSatisfy({ issue(with: $0)?.isSystemRecord != true }) else {
            lastError = BeadIssueWorkflowPolicy.systemRecordIssueTypeError
            return false
        }
        let ownedSystemRecordIDs = index.systemRecordIssueIDs(ownedBy: requestedIDs)
        let ids = Array(Set(requestedIDs).union(ownedSystemRecordIDs)).sorted()

        let idSet = Set(ids)
        let removedDependencies = mutations.projection.dependencies(
            touching: idSet,
            in: authoritativeIndex
        )
        let issueChanges = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, BeadProjectedIssueChange.delete)
        })
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
        _selectedIDs.subtract(idSet)
        syncFullPageDetailWithSelection()
        let projectionID = applyOptimisticProjection(
            BeadMutationProjectionEntry(
                issueChanges: issueChanges,
                removedDependencies: removedDependencies
            )
        )

        let commands = commands
        do {
            try await enqueueMutationWrite {
                try await commands.delete(projectURL: projectURL, ids: ids)
            }
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                return rejectStaleMutation(targeting: projectURL)
            }
            mutations.discardMetadataMutations(for: ids)
            settleOptimisticProjection(id: projectionID, succeeded: true)
            reconcileState.request(.mutation)
            announceCompletion(
                requestedIDs.count == 1
                    ? "Deleted bead \(requestedIDs[0])"
                    : "Deleted \(requestedIDs.count) beads"
            )
            return true
        } catch {
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                return rejectStaleMutation(targeting: projectURL)
            }
            settleOptimisticProjection(id: projectionID, succeeded: false)
            reconcileState.request(.mutation)
            let retryBaseline = retryBaseline(for: ids)
            reportMutationFailure(
                error,
                title: requestedIDs.count == 1
                    ? "Couldn't delete \(requestedIDs[0])"
                    : "Couldn't delete \(requestedIDs.count) beads",
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

    /// Adds ordinary labels without replacing existing labels. The command plan is
    /// explicit here (rather than hidden in the command service) so large selections
    /// report granular progress, retain successful chunks, and can stop between writes.
    @discardableResult
    func addLabels(
        issueIDs: [String],
        labels rawLabels: [String],
        expectedProjectURL: URL? = nil,
        maximumCommandArgumentBytes: Int = BeadsCommandArguments.safeBulkArgumentByteLimit,
        progress reportProgress: ((BulkMutationProgress) -> Void)? = nil
    ) async -> BulkMutationResult {
        guard let projectURL else {
            return BulkMutationResult(
                progress: BulkMutationProgress(totalCount: 0),
                outcome: .rejected,
                failures: []
            )
        }
        guard expectedProjectURL == nil || expectedProjectURL == projectURL else {
            return BulkMutationResult(
                progress: BulkMutationProgress(totalCount: 0),
                outcome: .superseded,
                failures: []
            )
        }

        let labels = IssueDraft.normalizedLabels(IssueDraft.normalizedLabelText(rawLabels))
        guard !labels.isEmpty else {
            return BulkMutationResult(
                progress: BulkMutationProgress(totalCount: 0),
                outcome: .completed,
                failures: []
            )
        }

        let mutationGeneration = mutations.metadataMutationGeneration
        let optimisticMutationQueue = mutations.optimisticMutationQueue(for: mutationGeneration)
        await optimisticMutationQueue.acquire()
        defer { optimisticMutationQueue.release() }
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
            return BulkMutationResult(
                progress: BulkMutationProgress(totalCount: 0),
                outcome: .superseded,
                failures: []
            )
        }

        let requestedIssues = Array(Set(issueIDs)).sorted().compactMap { issue(with: $0) }
        guard !requestedIssues.isEmpty else {
            return BulkMutationResult(
                progress: BulkMutationProgress(totalCount: 0),
                outcome: .completed,
                failures: []
            )
        }
        guard !requestedIssues.contains(where: \.isSystemRecord) else {
            lastError = BeadIssueWorkflowPolicy.systemRecordIssueTypeError
            return BulkMutationResult(
                progress: BulkMutationProgress(totalCount: 0),
                outcome: .rejected,
                failures: []
            )
        }
        let requestedIDs = requestedIssues.map(\.id)
        let managedDimensions = stateDimensionsManagedForLabelEditing(issueIDs: requestedIDs)
        if let propertyDimension = labels.lazy.compactMap(BeadStateLabel.dimension(of:)).first(
            where: managedDimensions.contains
        ) {
            lastError = "\(stateDimensionDisplayName(for: propertyDimension)) is managed as a property. Use Set Property so the change is recorded in Activity."
            return BulkMutationResult(
                progress: BulkMutationProgress(totalCount: 0),
                outcome: .rejected,
                failures: []
            )
        }
        let labelSet = Set(labels)
        let targetIssues = requestedIssues.filter { issue in
            !labelSet.isSubset(of: Set(issue.labels))
        }
        guard !targetIssues.isEmpty else {
            return BulkMutationResult(
                progress: BulkMutationProgress(totalCount: 0),
                outcome: .completed,
                failures: []
            )
        }

        let targetIDs = targetIssues.map(\.id)
        let targetIDSet = Set(targetIDs)
        let plans = BeadsCommandArguments.addLabelBatchPlans(
            ids: targetIDs,
            labels: labels,
            maximumArgumentBytes: maximumCommandArgumentBytes
        )
        var mutationHandlesByPlan: [[String: MetadataMutationHandle]] = []
        mutationHandlesByPlan.reserveCapacity(plans.count)
        for plan in plans {
            let patch = BeadMetadataMutationPatch(addingLabels: plan.labels)
            var handles: [String: MetadataMutationHandle] = [:]
            for issueID in plan.issueIDs {
                guard let issue = issue(with: issueID) else { continue }
                handles[issueID] = beginMetadataMutation(
                    issueID: issueID,
                    originalIssue: issue,
                    patch: patch,
                    writeWasAttempted: false
                )
            }
            mutationHandlesByPlan.append(handles)
        }

        var mutationProgress = BulkMutationProgress(totalCount: targetIDs.count)
        reportProgress?(mutationProgress)
        if Task.isCancelled {
            for handles in mutationHandlesByPlan {
                for (issueID, handle) in handles {
                    _ = settleMetadataMutation(
                        issueID: issueID,
                        mutationID: handle.id,
                        succeeded: false
                    )
                }
            }
            return BulkMutationResult(
                progress: mutationProgress,
                outcome: .cancelled,
                failures: []
            )
        }

        var optimisticIssueChanges: [String: BeadProjectedIssueChange] = [:]
        optimisticIssueChanges.reserveCapacity(targetIDSet.count)
        for issueID in targetIDSet {
            guard let resolved = mutations.metadataMutations[issueID]?.resolvedIssue else { continue }
            optimisticIssueChanges[issueID] = .update(
                BeadIssueMutationPatch(labels: .set(resolved.labels))
            )
        }
        let lifetimeGeneration = beginMutation()
        defer { endMutation(generation: lifetimeGeneration) }
        let busyToken = beginPerceptibleBusy(issueIDs: targetIDSet)
        defer { endPerceptibleBusy(busyToken) }
        let projectionID = applyOptimisticProjection(
            BeadMutationProjectionEntry(issueChanges: optimisticIssueChanges)
        )

        var remainingPlanCountByID: [String: Int] = [:]
        for plan in plans {
            for issueID in plan.issueIDs {
                remainingPlanCountByID[issueID, default: 0] += 1
            }
        }

        let commands = commands
        var failures = BulkMutationFailureCollection()
        var nextPlanIndex = 0
        var outcome = BulkMutationOutcome.completed
        var settlementIsValid = true

        while nextPlanIndex < plans.count {
            if Task.isCancelled {
                outcome = .cancelled
                break
            }
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                outcome = .superseded
                break
            }

            let plan = plans[nextPlanIndex]
            let handles = mutationHandlesByPlan[nextPlanIndex]
            for issueID in plan.issueIDs {
                guard let handle = handles[issueID] else {
                    settlementIsValid = false
                    continue
                }
                settlementIsValid = markMetadataMutationWriteAttempted(
                    issueID: issueID,
                    mutationID: handle.id
                ) && settlementIsValid
            }

            var succeeded = false
            do {
                try await enqueueMutationWrite {
                    try await commands.addLabelsBatch(
                        projectURL: projectURL,
                        ids: plan.issueIDs,
                        labels: plan.labels
                    )
                }
                succeeded = true
            } catch {
                failures.record(issueIDs: plan.issueIDs, error: error)
            }

            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                outcome = .superseded
                break
            }
            for issueID in plan.issueIDs {
                guard let handle = handles[issueID] else {
                    settlementIsValid = false
                    continue
                }
                settlementIsValid = settleMetadataMutation(
                    issueID: issueID,
                    mutationID: handle.id,
                    succeeded: succeeded
                ) && settlementIsValid
                remainingPlanCountByID[issueID, default: 1] -= 1
                if remainingPlanCountByID[issueID] == 0 {
                    mutationProgress.recordCompletion(succeeded: !failures.issueIDs.contains(issueID))
                }
            }
            reportProgress?(mutationProgress)
            nextPlanIndex += 1
        }

        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
            return BulkMutationResult(
                progress: mutationProgress,
                outcome: .superseded,
                failures: failures.details,
                failedIssueIDs: failures.failedIssueIDs,
                failureCount: failures.commandCount
            )
        }

        if nextPlanIndex < plans.count {
            for index in nextPlanIndex..<plans.count {
                for (issueID, handle) in mutationHandlesByPlan[index] {
                    settlementIsValid = settleMetadataMutation(
                        issueID: issueID,
                        mutationID: handle.id,
                        succeeded: false
                    ) && settlementIsValid
                }
            }
        }
        guard settlementIsValid else {
            settleOptimisticProjection(id: projectionID, succeeded: false)
            requestReconcile()
            return BulkMutationResult(
                progress: mutationProgress,
                outcome: .rejected,
                failures: failures.details,
                failedIssueIDs: failures.failedIssueIDs,
                failureCount: failures.commandCount
            )
        }

        settleOptimisticProjection(id: projectionID, succeeded: false)
        var finalIssueChanges: [String: BeadProjectedIssueChange] = [:]
        finalIssueChanges.reserveCapacity(targetIDSet.count)
        for issueID in targetIDSet {
            guard let currentIssue = issue(with: issueID) else { continue }
            let resolved = mutations.metadataMutations[issueID]?.resolvedIssue
                ?? mutations.metadataSettlement(for: issueID)?.issue
                ?? currentIssue
            guard currentIssue.labels != resolved.labels else { continue }
            finalIssueChanges[issueID] = .update(
                BeadIssueMutationPatch(labels: .set(resolved.labels))
            )
        }
        if !finalIssueChanges.isEmpty {
            _ = applyOptimisticProjection(
                BeadMutationProjectionEntry(
                    issueChanges: finalIssueChanges,
                    settlement: .succeeded
                )
            )
        }
        if nextPlanIndex > 0 {
            reconcileState.request(.mutation)
        }

        if mutationProgress.succeededCount > 0 {
            announceCompletion(
                mutationProgress.succeededCount == 1
                    ? "Added labels to 1 bead"
                    : "Added labels to \(mutationProgress.succeededCount) beads"
            )
        }
        let failedIssueIDs = failures.failedIssueIDs
        if !failures.isEmpty {
            let baseline = retryBaseline(for: failedIssueIDs)
            reportBulkMutationFailure(
                failures,
                title: failedIssueIDs.count == 1
                    ? "Couldn't add labels to 1 bead"
                    : "Couldn't add labels to \(failedIssueIDs.count) beads",
                retry: { [weak self] in
                    guard let self, self.retryBaselineHolds(baseline) else { return }
                    _ = await self.addLabels(
                        issueIDs: failedIssueIDs,
                        labels: labels,
                        expectedProjectURL: projectURL,
                        maximumCommandArgumentBytes: maximumCommandArgumentBytes
                    )
                }
            )
        }
        return BulkMutationResult(
            progress: mutationProgress,
            outcome: outcome,
            failures: failures.details,
            failedIssueIDs: failedIssueIDs,
            failureCount: failures.commandCount
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
        guard ids.allSatisfy({ issue(with: $0)?.isSystemRecord != true }) else {
            lastError = BeadIssueWorkflowPolicy.systemRecordIssueTypeError
            return false
        }
        if let type {
            guard BeadIssueWorkflowPolicy.isNormalMutableIssueType(type),
                  ids.allSatisfy({ id in
                      guard let issue = issue(with: id) else { return false }
                      return !issue.isGate
                  }) else {
                lastError = BeadIssueWorkflowPolicy.normalMutationTypeError(for: type)
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
                guard let issue = issue(with: issueID) else { continue }
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
        let idSet = Set(ids)
        let ancestorIDSet = Set(ancestorIDs)
        let now = Date()
        var issueChanges: [String: BeadProjectedIssueChange] = [:]
        issueChanges.reserveCapacity(idSet.count + ancestorIDSet.count)
        if let ancestorReopenStatus {
            for issueID in ancestorIDSet {
                issueChanges[issueID] = .update(
                    BeadIssueMutationPatch(
                        status: .set(ancestorReopenStatus),
                        updatedAt: .set(now),
                        closedAt: .set(nil)
                    )
                )
            }
        }
        for issueID in idSet {
            guard let originalIssue = issue(with: issueID) else { continue }
            var patch = BeadIssueMutationPatch(updatedAt: .set(now))
            if let status {
                patch.status = .set(status)
                patch.closedAt = .set(statusClosesBeads(status) ? (originalIssue.closedAt ?? now) : nil)
            }
            if let type { patch.issueType = .set(type) }
            if let priority { patch.priority = .set(priority) }
            if case .set(let date) = deferUntil { patch.deferUntil = .set(date) }
            issueChanges[issueID] = .update(patch)
        }
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
        let projectionID = applyOptimisticProjection(
            BeadMutationProjectionEntry(issueChanges: issueChanges)
        )

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
                  settleMetadataMutations(
                      metadataMutationsByIssueID,
                      succeeded: true
                  )
            else { return rejectStaleMutation(targeting: projectURL) }
            settleOptimisticProjection(id: projectionID, succeeded: true)
            reconcileState.request(.mutation)
            return true
        } catch {
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration),
                  settleMetadataMutations(
                    metadataMutationsByIssueID,
                    succeeded: false
                  )
            else { return rejectStaleMutation(targeting: projectURL) }
            settleOptimisticProjection(id: projectionID, succeeded: false)
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
        guard let projectURL, let originalIssue = issue(with: issueID) else { return false }
        let managedStateDimensions = stateDimensionsManagedForLabelEditing(issueID: issueID)
        let commandLabels = labels.map {
            BeadStateLabel.excluding(dimensions: managedStateDimensions, from: $0)
        }
        let retainedPossibleLabels = mutations.possiblyPersistedLabels(for: issueID)
        let clearsLabels = commandLabels?.isEmpty == true
        if let commandLabels, blockUnsafeLabelClear(
            issueID: issueID,
            labels: commandLabels,
            knownPossibleLabels: BeadStateLabel.excluding(
                dimensions: managedStateDimensions,
                from: originalIssue.labels
            )
        ) { return false }
        let requiresAuthoritativeLabelReplacement = labels?.isEmpty == false
            && (!retainedPossibleLabels.isEmpty || mutations.labelUncertaintyOverflowed(for: issueID))

        let patch = BeadMetadataMutationPatch(
            assignee: assignee,
            labels: labels,
            preservingStateDimensions: managedStateDimensions,
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
        let projectedIssue = patch.applying(to: originalIssue)
        var issuePatch = BeadIssueMutationPatch()
        if patch.updatesAssignee {
            issuePatch.assignee = .set(projectedIssue.assignee)
        }
        if patch.updatesLabels {
            issuePatch.labels = .set(projectedIssue.labels)
        }
        if case .set = dueAt {
            issuePatch.dueAt = .set(projectedIssue.dueAt)
        }
        if case .set = deferUntil {
            issuePatch.deferUntil = .set(projectedIssue.deferUntil)
        }
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
        let perceptibleBusyToken = beginPerceptibleBusy(issueIDs: [issueID])
        defer { endPerceptibleBusy(perceptibleBusyToken) }
        let projectionID = applyOptimisticProjection(
            BeadMutationProjectionEntry(issueChanges: [issueID: .update(issuePatch)])
        )

        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                try await commands.updateMetadata(
                    projectURL: projectURL,
                    issueID: issueID,
                    assignee: assignee,
                    labels: commandLabels,
                    originalLabels: commandLabels == nil
                        ? nil
                        : BeadStateLabel.excluding(
                            dimensions: managedStateDimensions,
                            from: metadataMutation.possiblePersistedLabels
                        ),
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
            settleOptimisticProjection(id: projectionID, succeeded: true)
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
            settleOptimisticProjection(id: projectionID, succeeded: false)
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
