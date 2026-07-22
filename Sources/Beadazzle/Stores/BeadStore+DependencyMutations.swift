import Foundation

extension BeadStore {
    @discardableResult
    func setParent(issueID: String, parentID: String?) async -> Bool {
        guard let projectURL else { return false }
        let mutationGeneration = mutations.metadataMutationGeneration
        let optimisticMutationQueue = mutations.optimisticMutationQueue(for: mutationGeneration)
        await optimisticMutationQueue.acquire()
        defer { optimisticMutationQueue.release() }
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
            return false
        }
        guard let originalIssue = issue(with: issueID) else { return false }
        let normalizedParentID = parentID?.nilIfBlank
        guard normalizedParentID != issueID else {
            lastError = "A bead cannot be its own parent."
            return false
        }
        if let normalizedParentID {
            guard issue(with: normalizedParentID) != nil else {
                lastError = "Bead \(normalizedParentID) was not found."
                return false
            }
            var ancestorID: String? = normalizedParentID
            var visited: Set<String> = []
            while let currentID = ancestorID, visited.insert(currentID).inserted {
                if currentID == issueID {
                    lastError = "A bead cannot be moved under one of its child beads."
                    return false
                }
                ancestorID = parentIssue(for: currentID)?.id
            }
            guard ancestorID == nil else {
                lastError = "A bead cannot be moved under one of its child beads."
                return false
            }
        }
        let currentParentID = originalIssue.parentID?.nilIfBlank
            ?? mutations.projection
                .dependencies(for: issueID, in: authoritativeIndex)
                .first { $0.type == "parent-child" }?
                .dependsOnID
        guard currentParentID != normalizedParentID else { return true }
        if let normalizedParentID {
            guard guardHierarchyAllowsParentChildDependency(
                issueID: issueID,
                dependsOnID: normalizedParentID,
                type: "parent-child"
            ) else { return false }
        }

        let now = Date()
        let existingParentDependencies = mutations.projection
            .dependencies(for: issueID, in: authoritativeIndex)
            .filter { $0.type == "parent-child" }
        var addedDependencies: [BeadDependency] = []
        if let normalizedParentID {
            addedDependencies.append(
                BeadDependency(
                    issueID: issueID,
                    dependsOnID: normalizedParentID,
                    type: "parent-child",
                    createdAt: now
                )
            )
        }

        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
        let perceptibleBusyToken = beginPerceptibleBusy(issueIDs: [issueID])
        defer { endPerceptibleBusy(perceptibleBusyToken) }
        let projectionID = applyOptimisticProjection(
            BeadMutationProjectionEntry(
                issueChanges: [
                    issueID: .update(
                        BeadIssueMutationPatch(
                            updatedAt: .set(now),
                            parentID: .set(normalizedParentID)
                        )
                    )
                ],
                addedDependencies: addedDependencies,
                removedDependencies: existingParentDependencies
            )
        )

        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                try await commands.setParent(
                    projectURL: projectURL,
                    issueID: issueID,
                    parentID: normalizedParentID
                )
            }
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                return rejectStaleMutation(targeting: projectURL)
            }
            settleOptimisticProjection(id: projectionID, succeeded: true)
            reconcileState.request(.mutation)
            announceCompletion(
                normalizedParentID == nil
                    ? "Removed parent of \(issueID)"
                    : "Moved \(issueID) under \(normalizedParentID!)"
            )
            return true
        } catch {
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                return rejectStaleMutation(targeting: projectURL)
            }
            settleOptimisticProjection(id: projectionID, succeeded: false)
            if attemptedWrite {
                reconcileState.request(.mutation)
            }
            let retryBaseline = retryBaseline(for: [issueID])
            reportMutationFailure(
                error,
                title: "Couldn't change parent of \(issueID)",
                retry: { [weak self] in
                    guard let self, self.retryBaselineHolds(retryBaseline) else { return }
                    await self.setParent(issueID: issueID, parentID: parentID)
                }
            )
            return false
        }
    }

    @discardableResult
    func applyBeadPickerSelection(_ selectedIssueID: String, action: BeadPickerAction) async -> Bool {
        switch action {
        case .setParent(let issueID):
            return await setParent(issueID: issueID, parentID: selectedIssueID)
        case .addBlockedBy(let issueID):
            return await addDependency(issueID: issueID, dependsOnID: selectedIssueID, type: "blocks")
        case .addBlocks(let issueID):
            return await addDependency(issueID: selectedIssueID, dependsOnID: issueID, type: "blocks")
        case .addChild(let parentID):
            return await setParent(issueID: selectedIssueID, parentID: parentID)
        }
    }

    @discardableResult
    func applyBeadPickerQuickCreate(_ createdIssueID: String, action: BeadPickerAction) async -> Bool {
        guard action.needsPostCreateRelationship else { return true }
        return await applyBeadPickerSelection(createdIssueID, action: action)
    }

}
