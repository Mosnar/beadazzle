import Foundation

extension BeadStore {
    // MARK: State dimension catalog

    /// Dimensions proven by the event beads that `bd set-state` creates. A
    /// colon-shaped label alone is not sufficient provenance: ordinary project
    /// taxonomies such as `area:ui` must remain ordinary labels.
    var discoveredStateDimensions: [String] {
        index.stateDimensionNames
    }

    func unpinnedStateDimensionOptions() -> [String] {
        let pinnedDimensions = Set(pinnedStateDimensions)
        return discoveredStateDimensions.filter { !pinnedDimensions.contains($0) }
    }

    /// Values backed by recorded state events are indexed once during project
    /// load. A manually pinned dimension falls back to one scan of the already
    /// compact project-wide label catalog when its picker opens.
    func stateValueOptions(for dimension: String) -> [String] {
        if let values = index.stateValuesByDimension[dimension] {
            return values
        }

        var seen: Set<String> = []
        var values: [String] = []
        for label in index.labelNames {
            guard let parsed = BeadStateLabel.parse(label),
                  parsed.dimension == dimension,
                  seen.insert(parsed.value).inserted else { continue }
            values.append(parsed.value)
        }
        return values.sorted(by: BeadStateLabel.isOrderedBefore)
    }

    /// Builds presentation rows only for the selected dimension. The index owns
    /// the raw catalog; these short-lived arrays add sparse local presentation
    /// metadata without duplicating project-wide label memberships in memory.
    func stateValueCatalog(for dimension: String) -> BeadStateValueCatalog {
        let displayNames = stateValueDisplayNames[dimension] ?? [:]
        let archivedValues = archivedStateValuesByDimension[dimension] ?? []
        let values = stateValueOptions(for: dimension)
        var active: [BeadStateValuePresentation] = []
        var archived: [BeadStateValuePresentation] = []
        active.reserveCapacity(max(values.count - archivedValues.count, 0))
        archived.reserveCapacity(min(values.count, archivedValues.count))

        for value in values {
            let isArchived = archivedValues.contains(value)
            let presentation = BeadStateValuePresentation(
                value: value,
                displayName: displayNames[value] ?? value,
                isArchived: isArchived
            )
            if isArchived {
                archived.append(presentation)
            } else {
                active.append(presentation)
            }
        }
        return BeadStateValueCatalog(active: active, archived: archived)
    }

    func stateValuePresentation(for value: String, in dimension: String) -> BeadStateValuePresentation {
        BeadStateValuePresentation(
            value: value,
            displayName: stateValueDisplayName(for: value, in: dimension),
            isArchived: isStateValueArchived(value, in: dimension)
        )
    }

    func stateValueDisplayName(for value: String, in dimension: String) -> String {
        stateValueDisplayNames[dimension]?[value] ?? value
    }

    @discardableResult
    func setStateValueDisplayName(_ rawDisplayName: String, for value: String, in dimension: String) -> Bool {
        guard BeadStateLabel.normalizedDimensionInput(dimension) == dimension else {
            lastError = BeadStateLabel.dimensionInputRequirement
            return false
        }
        guard BeadStateLabel.normalizedValueInput(value) == value else {
            lastError = BeadStateLabel.valueInputRequirement
            return false
        }

        let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, !displayName.contains(where: \Character.isNewline) else {
            lastError = "Display names must contain text on a single line."
            return false
        }

        var names = stateValueDisplayNames
        var dimensionNames = names[dimension] ?? [:]
        if displayName == value {
            dimensionNames.removeValue(forKey: value)
        } else {
            dimensionNames[value] = displayName
        }
        if dimensionNames.isEmpty {
            names.removeValue(forKey: dimension)
        } else {
            names[dimension] = dimensionNames
        }
        guard names != stateValueDisplayNames else { return true }
        stateValueDisplayNames = names
        return true
    }

    func isStateValueArchived(_ value: String, in dimension: String) -> Bool {
        archivedStateValuesByDimension[dimension]?.contains(value) == true
    }

    @discardableResult
    func setStateValue(_ value: String, in dimension: String, isArchived: Bool) -> Bool {
        guard BeadStateLabel.normalizedDimensionInput(dimension) == dimension else {
            lastError = BeadStateLabel.dimensionInputRequirement
            return false
        }
        guard BeadStateLabel.normalizedValueInput(value) == value else {
            lastError = BeadStateLabel.valueInputRequirement
            return false
        }

        var archivedValues = archivedStateValuesByDimension
        var dimensionValues = archivedValues[dimension] ?? []
        if isArchived {
            dimensionValues.insert(value)
        } else {
            dimensionValues.remove(value)
        }
        if dimensionValues.isEmpty {
            archivedValues.removeValue(forKey: dimension)
        } else {
            archivedValues[dimension] = dimensionValues
        }
        guard archivedValues != archivedStateValuesByDimension else { return true }
        archivedStateValuesByDimension = archivedValues
        return true
    }

    func stateValueUsageCount(for value: String, in dimension: String) -> Int {
        index.count(forLabel: BeadStateLabel.label(dimension: dimension, value: value))
    }

    func isStateDimensionPinned(_ dimension: String) -> Bool {
        pinnedStateDimensions.contains(dimension)
    }

    func stateDimensionDisplayName(for dimension: String) -> String {
        stateDimensionDisplayNames[dimension] ?? BeadStateLabel.displayName(for: dimension)
    }

    /// Changes only Beadazzle's project-local presentation name. Renaming the
    /// dimension itself would orphan `bd set-state` event history because Beads
    /// does not provide a state-dimension rename operation.
    @discardableResult
    func setStateDimensionDisplayName(_ rawDisplayName: String, for dimension: String) -> Bool {
        guard BeadStateLabel.normalizedDimensionInput(dimension) == dimension else {
            lastError = BeadStateLabel.dimensionInputRequirement
            return false
        }

        let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, !displayName.contains(where: \Character.isNewline) else {
            lastError = "Display names must contain text on a single line."
            return false
        }

        var names = stateDimensionDisplayNames
        if displayName == BeadStateLabel.displayName(for: dimension) {
            names.removeValue(forKey: dimension)
        } else {
            names[dimension] = displayName
        }
        guard names != stateDimensionDisplayNames else { return true }
        stateDimensionDisplayNames = names
        return true
    }

    /// Pinned dimensions are managed until the user unpins them. An active
    /// overlay remains managed for that issue until its command is reconciled,
    /// preventing an edit made during the short unpin/write race from replacing
    /// the in-flight state through the generic label path.
    internal func stateDimensionsManagedForLabelEditing(issueID: String) -> [String] {
        var seen = Set(pinnedStateDimensions)
        var dimensions = pinnedStateDimensions
        guard let overrides = stateLabelOverridesByIssueID[issueID] else {
            return dimensions
        }
        for dimension in overrides.keys.sorted() where seen.insert(dimension).inserted {
            dimensions.append(dimension)
        }
        return dimensions
    }

    internal func stateDimensionsManagedForLabelEditing(issueIDs: [String]) -> Set<String> {
        var dimensions = Set(pinnedStateDimensions)
        for issueID in issueIDs {
            if let overrides = stateLabelOverridesByIssueID[issueID] {
                dimensions.formUnion(overrides.keys)
            }
        }
        return dimensions
    }

    @discardableResult
    func pinStateDimension(_ rawDimension: String) -> Bool {
        pinStateDimension(rawDimension, at: pinnedStateDimensions.endIndex)
    }

    @discardableResult
    func pinStateDimension(_ rawDimension: String, at index: Int) -> Bool {
        guard let dimension = BeadStateLabel.normalizedDimensionInput(rawDimension) else {
            lastError = BeadStateLabel.dimensionInputRequirement
            return false
        }
        guard !pinnedStateDimensions.contains(dimension) else { return true }
        let insertionIndex = min(max(index, pinnedStateDimensions.startIndex), pinnedStateDimensions.endIndex)
        pinnedStateDimensions.insert(dimension, at: insertionIndex)
        return true
    }

    func unpinStateDimension(_ dimension: String) {
        pinnedStateDimensions.removeAll { $0 == dimension }
    }

    func movePinnedStateDimensions(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let validOffsets = offsets.filter { pinnedStateDimensions.indices.contains($0) }
        guard !validOffsets.isEmpty else { return }

        var reorderedDimensions = pinnedStateDimensions
        let movingDimensions = validOffsets.map { reorderedDimensions[$0] }
        for offset in validOffsets.reversed() {
            reorderedDimensions.remove(at: offset)
        }
        let removedBeforeDestination = validOffsets.lazy.filter { $0 < destination }.count
        let insertionIndex = min(
            max(destination - removedBeforeDestination, 0),
            reorderedDimensions.count
        )
        reorderedDimensions.insert(contentsOf: movingDimensions, at: insertionIndex)

        guard reorderedDimensions != pinnedStateDimensions else { return }
        pinnedStateDimensions = reorderedDimensions
    }

    func canMovePinnedStateDimensionUp(_ dimension: String) -> Bool {
        guard let index = pinnedStateDimensions.firstIndex(of: dimension) else { return false }
        return index > pinnedStateDimensions.startIndex
    }

    func canMovePinnedStateDimensionDown(_ dimension: String) -> Bool {
        guard let index = pinnedStateDimensions.firstIndex(of: dimension) else { return false }
        return index < pinnedStateDimensions.index(before: pinnedStateDimensions.endIndex)
    }

    func movePinnedStateDimensionUp(_ dimension: String) {
        guard let index = pinnedStateDimensions.firstIndex(of: dimension),
              index > pinnedStateDimensions.startIndex else { return }
        var reorderedDimensions = pinnedStateDimensions
        reorderedDimensions.swapAt(index, reorderedDimensions.index(before: index))
        pinnedStateDimensions = reorderedDimensions
    }

    func movePinnedStateDimensionDown(_ dimension: String) {
        guard let index = pinnedStateDimensions.firstIndex(of: dimension),
              index < pinnedStateDimensions.index(before: pinnedStateDimensions.endIndex) else { return }
        var reorderedDimensions = pinnedStateDimensions
        reorderedDimensions.swapAt(index, reorderedDimensions.index(after: index))
        pinnedStateDimensions = reorderedDimensions
    }

    // MARK: State overlays

    internal func applyingStateLabelOverrides(to issue: BeadIssue) -> BeadIssue {
        guard let overrides = stateLabelOverridesByIssueID[issue.id], !overrides.isEmpty else {
            return issue
        }
        var copy = issue
        copy.labels = BeadStateLabel.applying(overrides: overrides, to: copy.labels)
        return copy
    }

    private func setStateLabelOverride(issueID: String, dimension: String, value: String?) {
        var overrides = stateLabelOverridesByIssueID
        guard Self.setStateLabelOverride(
            issueID: issueID,
            dimension: dimension,
            value: value,
            in: &overrides
        ) else { return }
        stateLabelOverridesByIssueID = overrides
        _contentRevision &+= 1
    }

    private static func setStateLabelOverride(
        issueID: String,
        dimension: String,
        value: String?,
        in overrides: inout [String: [String: String]]
    ) -> Bool {
        guard overrides[issueID]?[dimension] != value else { return false }
        var issueOverrides = overrides[issueID, default: [:]]
        if let value {
            issueOverrides[dimension] = value
        } else {
            issueOverrides.removeValue(forKey: dimension)
        }
        if issueOverrides.isEmpty {
            overrides.removeValue(forKey: issueID)
        } else {
            overrides[issueID] = issueOverrides
        }
        return true
    }

    private func setStateLabelOverrides(issueIDs: [String], dimension: String, value: String) {
        var overrides = stateLabelOverridesByIssueID
        var changed = false
        for issueID in issueIDs {
            changed = Self.setStateLabelOverride(
                issueID: issueID,
                dimension: dimension,
                value: value,
                in: &overrides
            ) || changed
        }
        guard changed else { return }
        stateLabelOverridesByIssueID = overrides
        _contentRevision &+= 1
    }

    /// Re-derives the visible override after a write settles. The metadata
    /// coordinator knows which overlapping label writes succeeded, so a failed
    /// newer state write can fall back to an earlier successful value rather
    /// than flashing all the way back to the pre-mutation snapshot.
    private func synchronizeStateLabelOverride(issueID: String, dimension: String) {
        let resolvedIssue = mutations.metadataMutations[issueID]?.resolvedIssue
            ?? mutations.metadataSettlement(for: issueID)?.issue
            ?? index.issue(with: issueID)
        let resolvedValue = resolvedIssue.flatMap {
            BeadStateLabel.value(of: dimension, in: $0.labels)
        }
        let indexedValue = index.issue(with: issueID).flatMap {
            BeadStateLabel.value(of: dimension, in: $0.labels)
        }
        setStateLabelOverride(
            issueID: issueID,
            dimension: dimension,
            value: resolvedValue == indexedValue ? nil : resolvedValue
        )
    }

    private func synchronizeStateLabelOverrides(issueIDs: [String], dimension: String) {
        var overrides = stateLabelOverridesByIssueID
        var changed = false
        for issueID in issueIDs {
            let resolvedIssue = mutations.metadataMutations[issueID]?.resolvedIssue
                ?? mutations.metadataSettlement(for: issueID)?.issue
                ?? index.issue(with: issueID)
            let resolvedValue = resolvedIssue.flatMap {
                BeadStateLabel.value(of: dimension, in: $0.labels)
            }
            let indexedValue = index.issue(with: issueID).flatMap {
                BeadStateLabel.value(of: dimension, in: $0.labels)
            }
            changed = Self.setStateLabelOverride(
                issueID: issueID,
                dimension: dimension,
                value: resolvedValue == indexedValue ? nil : resolvedValue,
                in: &overrides
            ) || changed
        }
        guard changed else { return }
        stateLabelOverridesByIssueID = overrides
        _contentRevision &+= 1
    }

    /// A successful refresh is authoritative and retires every overlay, even if
    /// another writer changed the value after our command. A refresh that fell
    /// back to a stale export only retires matching values; mismatches remain
    /// visible until a later authoritative load can resolve ownership.
    internal func reconcileStateLabelOverrides(authoritative: Bool) {
        guard !stateLabelOverridesByIssueID.isEmpty else { return }
        if authoritative {
            stateLabelOverridesByIssueID = [:]
            return
        }

        var reconciled = stateLabelOverridesByIssueID
        for (issueID, overrides) in stateLabelOverridesByIssueID {
            guard let issue = index.issue(with: issueID) else { continue }
            var remaining = overrides
            for (dimension, value) in overrides
            where BeadStateLabel.value(of: dimension, in: issue.labels) == value {
                remaining.removeValue(forKey: dimension)
            }
            if remaining.isEmpty {
                reconciled.removeValue(forKey: issueID)
            } else {
                reconciled[issueID] = remaining
            }
        }
        if reconciled != stateLabelOverridesByIssueID {
            stateLabelOverridesByIssueID = reconciled
        }
    }

    // MARK: State mutation

    /// Sets one state dimension through `bd set-state`, which records an event
    /// bead (with the optional reason) and swaps the `dimension:value` label.
    /// A tiny label overlay updates the selected detail and visible list row in
    /// O(1); the normal off-main project reload updates filters and the index.
    @discardableResult
    func setState(
        issueID: String,
        dimension rawDimension: String,
        value rawValue: String,
        reason: String? = nil
    ) async -> Bool {
        guard let projectURL else { return false }
        guard let dimension = BeadStateLabel.normalizedDimensionInput(rawDimension) else {
            lastError = BeadStateLabel.dimensionInputRequirement
            return false
        }
        guard let value = BeadStateLabel.normalizedValueInput(rawValue) else {
            lastError = BeadStateLabel.valueInputRequirement
            return false
        }
        guard let originalIssue = issue(with: issueID) else { return false }
        guard BeadStateLabel.value(of: dimension, in: originalIssue.labels) != value else {
            return true
        }

        let patch = BeadMetadataMutationPatch(stateDimension: dimension, value: value)
        let metadataMutation = beginMetadataMutation(
            issueID: issueID,
            originalIssue: originalIssue,
            patch: patch
        )
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
        let perceptibleBusyToken = beginPerceptibleBusy(issueIDs: [issueID])
        defer { endPerceptibleBusy(perceptibleBusyToken) }
        setStateLabelOverride(issueID: issueID, dimension: dimension, value: value)

        let commands = commands
        let reason = reason?.nilIfBlank
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                try await commands.setState(
                    projectURL: projectURL,
                    issueID: issueID,
                    dimension: dimension,
                    value: value,
                    reason: reason
                )
            }
            guard self.projectURL == projectURL,
                  mutations.metadataMutationGeneration == metadataMutation.generation
            else { return rejectStaleMutation(targeting: projectURL) }
            guard settleMetadataMutation(
                issueID: issueID,
                mutationID: metadataMutation.id,
                succeeded: true,
                applyResolvedState: false
            ) else { return false }
            synchronizeStateLabelOverride(issueID: issueID, dimension: dimension)
            reconcileState.request(.mutation)
            announceCompletion("Set \(dimension) of \(issueID) to \(value)")
            return true
        } catch {
            guard self.projectURL == projectURL,
                  mutations.metadataMutationGeneration == metadataMutation.generation
            else { return rejectStaleMutation(targeting: projectURL) }
            guard settleMetadataMutation(
                issueID: issueID,
                mutationID: metadataMutation.id,
                succeeded: false,
                applyResolvedState: false
            ) else { return false }
            synchronizeStateLabelOverride(issueID: issueID, dimension: dimension)
            if attemptedWrite {
                reconcileState.request(.mutation)
            }
            let retryBaseline = retryBaseline(for: [issueID])
            reportMutationFailure(
                error,
                title: "Couldn't set \(dimension) of \(issueID)",
                retry: { [weak self] in
                    guard let self, self.retryBaselineHolds(retryBaseline) else { return }
                    await self.setState(
                        issueID: issueID,
                        dimension: dimension,
                        value: value,
                        reason: reason
                    )
                }
            )
            return false
        }
    }

    /// Applies one state property to several beads while preserving an Activity event
    /// per bead. Commands run serially but yield between beads so a project switch can
    /// stop a very large batch. Individual failures do not stop later beads, and the
    /// standard mutation dialog offers a retry for failures only.
    @discardableResult
    func bulkSetState(
        issueIDs: [String],
        dimension rawDimension: String,
        value rawValue: String,
        reason: String? = nil,
        expectedProjectURL: URL? = nil,
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
        guard let dimension = BeadStateLabel.normalizedDimensionInput(rawDimension) else {
            lastError = BeadStateLabel.dimensionInputRequirement
            return BulkMutationResult(
                progress: BulkMutationProgress(totalCount: 0),
                outcome: .rejected,
                failures: []
            )
        }
        guard let value = BeadStateLabel.normalizedValueInput(rawValue) else {
            lastError = BeadStateLabel.valueInputRequirement
            return BulkMutationResult(
                progress: BulkMutationProgress(totalCount: 0),
                outcome: .rejected,
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

        let targetIssues = Array(Set(issueIDs)).sorted().compactMap { issue(with: $0) }.filter {
            BeadStateLabel.value(of: dimension, in: $0.labels) != value
        }
        guard !targetIssues.isEmpty else {
            return BulkMutationResult(
                progress: BulkMutationProgress(totalCount: 0),
                outcome: .completed,
                failures: []
            )
        }

        let patch = BeadMetadataMutationPatch(stateDimension: dimension, value: value)
        var handles: [String: MetadataMutationHandle] = [:]
        for issue in targetIssues {
            handles[issue.id] = beginMetadataMutation(
                issueID: issue.id,
                originalIssue: issue,
                patch: patch,
                writeWasAttempted: false
            )
        }
        let targetIDs = targetIssues.map(\.id)
        var mutationProgress = BulkMutationProgress(totalCount: targetIDs.count)
        reportProgress?(mutationProgress)
        let lifetimeGeneration = beginMutation()
        defer { endMutation(generation: lifetimeGeneration) }
        let busyToken = beginPerceptibleBusy(issueIDs: Set(targetIDs))
        defer { endPerceptibleBusy(busyToken) }
        setStateLabelOverrides(issueIDs: targetIDs, dimension: dimension, value: value)

        let commands = commands
        let normalizedReason = reason?.nilIfBlank
        var failures = BulkMutationFailureCollection()
        var nextIssueIndex = 0
        var outcome = BulkMutationOutcome.completed
        var settlementIsValid = true
        while nextIssueIndex < targetIDs.count {
            if Task.isCancelled {
                outcome = .cancelled
                break
            }
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                outcome = .superseded
                break
            }

            let issueID = targetIDs[nextIssueIndex]
            guard let handle = handles[issueID] else {
                settlementIsValid = false
                break
            }
            settlementIsValid = markMetadataMutationWriteAttempted(
                issueID: issueID,
                mutationID: handle.id
            ) && settlementIsValid

            var succeeded = false
            do {
                try await enqueueMutationWrite {
                    try await commands.setState(
                        projectURL: projectURL,
                        issueID: issueID,
                        dimension: dimension,
                        value: value,
                        reason: normalizedReason
                    )
                }
                succeeded = true
            } catch {
                failures.record(issueIDs: [issueID], error: error)
            }
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                outcome = .superseded
                break
            }
            settlementIsValid = settleMetadataMutation(
                issueID: issueID,
                mutationID: handle.id,
                succeeded: succeeded,
                applyResolvedState: false
            ) && settlementIsValid
            mutationProgress.recordCompletion(succeeded: succeeded)
            reportProgress?(mutationProgress)
            nextIssueIndex += 1
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
        if nextIssueIndex < targetIDs.count {
            for issueID in targetIDs[nextIssueIndex...] {
                guard let handle = handles[issueID] else {
                    settlementIsValid = false
                    continue
                }
                settlementIsValid = settleMetadataMutation(
                    issueID: issueID,
                    mutationID: handle.id,
                    succeeded: false,
                    applyResolvedState: false
                ) && settlementIsValid
            }
        }
        guard settlementIsValid else {
            requestReconcile()
            return BulkMutationResult(
                progress: mutationProgress,
                outcome: .rejected,
                failures: failures.details,
                failedIssueIDs: failures.failedIssueIDs,
                failureCount: failures.commandCount
            )
        }

        synchronizeStateLabelOverrides(issueIDs: targetIDs, dimension: dimension)
        if nextIssueIndex > 0 {
            reconcileState.request(.mutation)
        }

        if mutationProgress.succeededCount > 0 {
            announceCompletion(
                mutationProgress.succeededCount == 1
                    ? "Set \(dimension) on 1 bead"
                    : "Set \(dimension) on \(mutationProgress.succeededCount) beads"
            )
        }
        let failedIDs = failures.failedIssueIDs
        if !failures.isEmpty {
            let baseline = retryBaseline(for: failedIDs)
            reportBulkMutationFailure(
                failures,
                title: failedIDs.count == 1
                    ? "Couldn't set \(dimension) on 1 bead"
                    : "Couldn't set \(dimension) on \(failedIDs.count) beads",
                retry: { [weak self] in
                    guard let self, self.retryBaselineHolds(baseline) else { return }
                    _ = await self.bulkSetState(
                        issueIDs: failedIDs,
                        dimension: dimension,
                        value: value,
                        reason: normalizedReason,
                        expectedProjectURL: projectURL
                    )
                }
            )
        }
        return BulkMutationResult(
            progress: mutationProgress,
            outcome: outcome,
            failures: failures.details,
            failedIssueIDs: failedIDs,
            failureCount: failures.commandCount
        )
    }
}
