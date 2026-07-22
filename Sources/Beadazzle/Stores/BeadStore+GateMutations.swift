import Foundation

extension BeadStore {
    @discardableResult
    func approveGate(id: String, reason: String?) async -> Bool {
        let affectedIDs = gateDecisionAffectedBeads(for: id).map(\.id)
        guard !affectedIDs.isEmpty else {
            return await resolveGate(id: id, reason: reason)
        }
        guard let approvalStatus = gateApprovalStatusName else {
            let didResolve = await resolveGate(id: id, reason: reason)
            if didResolve {
                lastError = "Gate approved, but no active status is configured for unblocked beads."
            }
            return false
        }
        guard await resolveGate(id: id, reason: reason) else { return false }
        return await bulkSet(issueIDs: affectedIDs, status: approvalStatus)
    }

    @discardableResult
    func rejectGate(
        id: String,
        reason: String,
        targetStatus: String,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) async -> Bool {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else {
            lastError = "A rejection reason is required."
            return false
        }
        let status = targetStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty else {
            lastError = "Choose a status for rejected beads."
            return false
        }

        let affectedIDs = gateDecisionAffectedBeads(for: id).map(\.id)
        let rejectionReason = "Rejected: \(trimmedReason)"
        if statusClosesBeads(status) {
            guard guardHierarchyAllowsCompletion(issueIDs: affectedIDs, includedIssueIDs: affectedIDs) else { return false }
        }
        guard await resolveGate(id: id, reason: rejectionReason) else { return false }
        guard !affectedIDs.isEmpty else { return true }

        if status.lowercased() == Self.closedStatusName {
            return await close(issueIDs: affectedIDs, reason: rejectionReason)
        }
        let deferredStatusUpdate: IssueMetadataDateUpdate
        if isDeferredStatus(status) {
            switch deferUntil {
            case .unchanged:
                deferredStatusUpdate = .set(nil)
            case .set:
                deferredStatusUpdate = deferUntil
            }
        } else {
            deferredStatusUpdate = .unchanged
        }
        return await bulkSet(
            issueIDs: affectedIDs,
            status: status,
            deferUntil: deferredStatusUpdate
        )
    }

    @discardableResult
    func resolveGate(id: String, reason: String?) async -> Bool {
        guard let projectURL else { return false }
        do {
            try await commands.resolveGate(projectURL: projectURL, id: id, reason: reason?.nilIfBlank)
            guard self.projectURL == projectURL else { return false }
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    /// Evaluate open gates (auto-closing resolved timers/GitHub gates). Returns the `bd`
    /// summary output, or nil on failure.
    @discardableResult
    func checkGates(type: String? = nil, escalate: Bool = false, dryRun: Bool = false) async -> String? {
        guard let projectURL else { return nil }
        do {
            let output = try await commands.checkGates(projectURL: projectURL, type: type, escalate: escalate, dryRun: dryRun)
            guard self.projectURL == projectURL else { return nil }
            if !dryRun {
                requestReconcile()
            }
            return output
        } catch {
            guard self.projectURL == projectURL else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createGate(blocks: String, type: GateAwaitType, reason: String?, timeout: String?, awaitID: String?) async -> Bool {
        guard let projectURL else { return false }
        guard let issue = issue(with: blocks) else {
            lastError = "Bead \(blocks) was not found."
            return false
        }
        if let unavailableMessage = BeadIssueWorkflowPolicy.gateCreationUnavailableMessage(
            blocking: issue,
            isDone: isDone(issue)
        ) {
            lastError = unavailableMessage
            return false
        }
        do {
            _ = try await commands.createGate(
                projectURL: projectURL,
                blocks: blocks,
                type: type,
                reason: reason?.nilIfBlank,
                timeout: timeout?.nilIfBlank,
                awaitID: awaitID?.nilIfBlank
            )
            guard self.projectURL == projectURL else { return false }
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addGateWaiter(id: String, waiter: String) async -> Bool {
        guard let projectURL else { return false }
        let trimmed = waiter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try await commands.addGateWaiter(projectURL: projectURL, id: id, waiter: trimmed)
            guard self.projectURL == projectURL else { return false }
            _gatesByID[id] = nil
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addDependency(issueID: String, dependsOnID: String, type: String) async -> Bool {
        guard let projectURL else { return false }
        let mutationGeneration = mutations.metadataMutationGeneration
        let optimisticMutationQueue = mutations.optimisticMutationQueue(for: mutationGeneration)
        await optimisticMutationQueue.acquire()
        defer { optimisticMutationQueue.release() }
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
            return false
        }
        guard guardHierarchyAllowsParentChildDependency(
            issueID: issueID,
            dependsOnID: dependsOnID,
            type: type
        ) else { return false }
        guard guardWorkflowAllowsBlockingDependency(
            issueID: issueID,
            dependsOnID: dependsOnID,
            type: type
        ) else { return false }

        let newDependency = BeadDependency(issueID: issueID, dependsOnID: dependsOnID, type: type, createdAt: Date())
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
        let existingDependencies = mutations.projection.dependencies(for: issueID, in: authoritativeIndex)
        let projectionID: UUID? = existingDependencies.contains(where: { $0.id == newDependency.id })
            ? nil
            : applyOptimisticProjection(
                BeadMutationProjectionEntry(addedDependencies: [newDependency])
            )

        let commands = commands
        do {
            try await enqueueMutationWrite {
                try await commands.addDependency(projectURL: projectURL, issueID: issueID, dependsOnID: dependsOnID, type: type)
            }
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                return rejectStaleMutation(targeting: projectURL)
            }
            if let projectionID {
                settleOptimisticProjection(id: projectionID, succeeded: true)
            }
            reconcileState.request(.mutation)
            announceCompletion("Added \(type) dependency for \(issueID)")
            return true
        } catch {
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                return rejectStaleMutation(targeting: projectURL)
            }
            if let projectionID {
                settleOptimisticProjection(id: projectionID, succeeded: false)
            }
            reconcileState.request(.mutation)
            // No retry baseline here: dependency edges live outside `BeadIssue`, so an issue
            // snapshot can't detect a superseding dependency change. Re-running a dependency
            // add is idempotent in bd, so a blind retry is acceptable.
            reportMutationFailure(
                error,
                title: "Couldn't add dependency for \(issueID)",
                retry: { [weak self] in
                    await self?.addDependency(issueID: issueID, dependsOnID: dependsOnID, type: type)
                }
            )
            return false
        }
    }

    func addComment(issueID: String, text: String) {
        guard let projectURL else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        _isAddingComment = true
        let commands = commands
        Task { @MainActor [weak self] in
            do {
                try await commands.addComment(projectURL: projectURL, issueID: issueID, text: trimmedText)
                guard let self else { return }
                guard self.projectURL == projectURL else {
                    self._isAddingComment = false
                    return
                }
                self.cacheOptimisticComment(issueID: issueID, text: trimmedText)
                if self.selectedIssue?.id == issueID {
                    self._isLoadingComments = false
                }
                self._isAddingComment = false
                self.requestReconcile()
            } catch {
                guard self?.projectURL == projectURL else { return }
                self?._isAddingComment = false
                self?.lastError = error.localizedDescription
            }
        }
    }

    @discardableResult
    func addCustomType(named rawName: String) async -> Bool {
        guard let projectURL else { return false }
        do {
            let name = try WorkflowValueValidator.normalizedIdentifier(rawName)
            guard BeadIssueWorkflowPolicy.isNormalMutableIssueType(name) else {
                lastError = BeadIssueWorkflowPolicy.normalMutationTypeError(for: name)
                return false
            }
            let allTypes = try await commands.loadTypeDefinitions(projectURL: projectURL)
            try ensureTypeNameIsAvailable(name, in: allTypes)
            var types = try await commands.loadCustomTypes(projectURL: projectURL)
            try ensureTypeNameIsAvailable(name, in: types)
            types.append(BeadTypeDefinition(name: name, description: nil, source: .custom))
            try await commands.saveCustomTypes(projectURL: projectURL, types: types.sorted { $0.name < $1.name })
            guard self.projectURL == projectURL else { return false }
            cachedDefinitions = nil // definitions changed — force the reconcile to re-read them
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteCustomType(named name: String) async -> Bool {
        guard let projectURL else { return false }
        do {
            let types = try await commands.loadCustomTypes(projectURL: projectURL)
            guard types.contains(where: { $0.name == name }) else { return false }
            let updatedTypes = types.filter { $0.name != name }
            try await commands.saveCustomTypes(projectURL: projectURL, types: updatedTypes.sorted { $0.name < $1.name })
            guard self.projectURL == projectURL else { return false }
            _hiddenTypeNames.remove(name)
            persistProjectVisibility()
            cachedDefinitions = nil // definitions changed — force the reconcile to re-read them
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addCustomStatus(named rawName: String, category: BeadStatusCategory) async -> Bool {
        guard let projectURL else { return false }
        do {
            let name = try WorkflowValueValidator.normalizedIdentifier(rawName)
            let allStatuses = try await commands.loadStatusDefinitions(projectURL: projectURL)
            try ensureStatusNameIsAvailable(name, in: allStatuses)
            var statuses = try await commands.loadCustomStatuses(projectURL: projectURL)
            try ensureStatusNameIsAvailable(name, in: statuses)
            statuses.append(
                BeadStatusDefinition(
                    name: name,
                    category: category,
                    icon: nil,
                    description: nil,
                    isBuiltIn: false,
                    source: .custom
                )
            )
            try await commands.saveCustomStatuses(projectURL: projectURL, statuses: statuses.sorted { $0.name < $1.name })
            guard self.projectURL == projectURL else { return false }
            cachedDefinitions = nil // definitions changed — force the reconcile to re-read them
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteCustomStatus(named name: String) async -> Bool {
        guard let projectURL else { return false }
        do {
            let statuses = try await commands.loadCustomStatuses(projectURL: projectURL)
            guard statuses.contains(where: { $0.name == name }) else { return false }
            let updatedStatuses = statuses.filter { $0.name != name }
            try await commands.saveCustomStatuses(projectURL: projectURL, statuses: updatedStatuses.sorted { $0.name < $1.name })
            guard self.projectURL == projectURL else { return false }
            _hiddenStatusNames.remove(name)
            persistProjectVisibility()
            cachedDefinitions = nil // definitions changed — force the reconcile to re-read them
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    private func ensureTypeNameIsAvailable(_ name: String, in types: [BeadTypeDefinition]) throws {
        guard types.allSatisfy({ $0.name != name }) else {
            throw BeadError.commandFailed(command: "bd config", output: "\(name) already exists.")
        }
    }

    private func ensureStatusNameIsAvailable(_ name: String, in statuses: [BeadStatusDefinition]) throws {
        guard statuses.allSatisfy({ $0.name != name }) else {
            throw BeadError.commandFailed(command: "bd config", output: "\(name) already exists.")
        }
    }

    @discardableResult
    func removeDependency(_ dependency: BeadDependency) async -> Bool {
        guard let projectURL else { return false }
        let mutationGeneration = mutations.metadataMutationGeneration
        let optimisticMutationQueue = mutations.optimisticMutationQueue(for: mutationGeneration)
        await optimisticMutationQueue.acquire()
        defer { optimisticMutationQueue.release() }
        guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
            return false
        }

        let removedDependencies = mutations.projection
            .dependencies(for: dependency.issueID, in: authoritativeIndex)
            .filter {
                $0.issueID == dependency.issueID && $0.dependsOnID == dependency.dependsOnID
            }
        let mutationLifetimeGeneration = beginMutation()
        defer { endMutation(generation: mutationLifetimeGeneration) }
        let projectionID = applyOptimisticProjection(
            BeadMutationProjectionEntry(removedDependencies: removedDependencies)
        )

        let commands = commands
        do {
            try await enqueueMutationWrite {
                try await commands.removeDependency(
                    projectURL: projectURL,
                    issueID: dependency.issueID,
                    dependsOnID: dependency.dependsOnID
                )
            }
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                return rejectStaleMutation(targeting: projectURL)
            }
            settleOptimisticProjection(id: projectionID, succeeded: true)
            reconcileState.request(.mutation)
            announceCompletion("Removed \(dependency.type) dependency for \(dependency.issueID)")
            return true
        } catch {
            guard ownsMutation(projectURL: projectURL, generation: mutationGeneration) else {
                return rejectStaleMutation(targeting: projectURL)
            }
            settleOptimisticProjection(id: projectionID, succeeded: false)
            reconcileState.request(.mutation)
            reportMutationFailure(
                error,
                title: "Couldn't remove dependency for \(dependency.issueID)",
                retry: { [weak self] in
                    await self?.removeDependency(dependency)
                }
            )
            return false
        }
    }

}
