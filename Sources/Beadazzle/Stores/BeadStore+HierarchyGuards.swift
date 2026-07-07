import Foundation

extension BeadStore {
    func openChildIssues(forClosing issueIDs: [String]) -> [BeadIssue] {
        unresolvedChildIssues(forCompleting: issueIDs, includedIssueIDs: issueIDs)
    }

    func doneAncestorIssues(forReopening issueIDs: [String]) -> [BeadIssue] {
        let reopeningIDs = issueIDs.filter { id in
            guard let issue = issue(with: id) else { return false }
            return isDone(issue)
        }
        return hierarchyMutationPolicy.doneAncestorsPreventingUncompletion(
            of: reopeningIDs,
            includedIssueIDs: issueIDs
        )
    }

    func unresolvedChildIssues(
        forCompleting issueIDs: [String],
        includedIssueIDs: [String]
    ) -> [BeadIssue] {
        hierarchyMutationPolicy.unresolvedDescendantsPreventingCompletion(
            of: issueIDs,
            includedIssueIDs: includedIssueIDs
        )
    }

    func guardHierarchyAllowsCompletion(issueIDs: [String], includedIssueIDs: [String]) -> Bool {
        let completingIDs = issueIDs.filter { id in
            guard let issue = issue(with: id) else { return false }
            return !isDone(issue)
        }
        let unresolvedChildren = unresolvedChildIssues(
            forCompleting: completingIDs,
            includedIssueIDs: includedIssueIDs
        )
        guard !unresolvedChildren.isEmpty else { return true }

        lastError = hierarchyError(
            prefix: "Close child beads first or include them",
            issues: unresolvedChildren
        )
        return false
    }

    func guardHierarchyAllowsUncompletion(issueIDs: [String], includedIssueIDs: [String]) -> Bool {
        let reopeningIDs = issueIDs.filter { id in
            guard let issue = issue(with: id) else { return false }
            return isDone(issue)
        }
        let doneAncestors = hierarchyMutationPolicy.doneAncestorsPreventingUncompletion(
            of: reopeningIDs,
            includedIssueIDs: includedIssueIDs
        )
        guard !doneAncestors.isEmpty else { return true }

        lastError = hierarchyError(
            prefix: "Reopen parent beads first or include them",
            issues: doneAncestors
        )
        return false
    }

    func guardHierarchyAllowsParentChildDependency(
        issueID: String,
        dependsOnID: String,
        type: String
    ) -> Bool {
        let unresolvedIssues = hierarchyMutationPolicy.unresolvedIssuesCreatedByParentChildDependency(
            issueID: issueID,
            dependsOnID: dependsOnID,
            type: type
        )
        guard !unresolvedIssues.isEmpty else { return true }

        lastError = hierarchyError(
            prefix: "Reopen \(dependsOnID) or resolve child beads before adding \(issueID) as a child",
            issues: unresolvedIssues
        )
        return false
    }

    func hierarchyCompletionWriteOrder(_ issueIDs: [String]) -> [String] {
        hierarchyMutationPolicy.completionWriteOrder(issueIDs)
    }

    func hierarchyReopenWriteOrder(_ issueIDs: [String]) -> [String] {
        hierarchyMutationPolicy.reopenWriteOrder(issueIDs)
    }

    private func hierarchyError(prefix: String, issues: [BeadIssue]) -> String {
        let ids = issues.map(\.id).joined(separator: ", ")
        return "\(prefix): \(ids)."
    }
}
