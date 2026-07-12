import Foundation

extension BeadStore {
    @discardableResult
    func setParent(issueID: String, parentID: String?) async -> Bool {
        guard let projectURL, let originalIssue = index.issue(with: issueID) else { return false }
        let normalizedParentID = parentID?.nilIfBlank
        guard normalizedParentID != issueID else {
            lastError = "A bead cannot be its own parent."
            return false
        }
        if let normalizedParentID {
            guard index.issue(with: normalizedParentID) != nil else {
                lastError = "Bead \(normalizedParentID) was not found."
                return false
            }
            guard !index.descendantIDs(for: issueID).contains(normalizedParentID) else {
                lastError = "A bead cannot be moved under one of its child beads."
                return false
            }
            guard guardHierarchyAllowsParentChildDependency(
                issueID: issueID,
                dependsOnID: normalizedParentID,
                type: "parent-child"
            ) else { return false }
        }
        guard originalIssue.parentID != normalizedParentID else { return true }

        let snapshot = currentMutationSnapshot()
        let now = Date()
        let optimisticIssues = snapshot.issues.map { issue -> BeadIssue in
            guard issue.id == issueID else { return issue }
            var copy = issue
            copy.parentID = normalizedParentID
            copy.updatedAt = now
            return copy
        }
        var optimisticDependencies = snapshot.dependencies.filter {
            !($0.issueID == issueID && $0.type == "parent-child")
        }
        if let normalizedParentID {
            optimisticDependencies.append(
                BeadDependency(
                    issueID: issueID,
                    dependsOnID: normalizedParentID,
                    type: "parent-child",
                    createdAt: now
                )
            )
        }

        beginMutation()
        defer { endMutation() }
        applyOptimisticState(issues: optimisticIssues, dependencies: optimisticDependencies)

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
