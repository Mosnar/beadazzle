import Foundation

extension BeadStore {
    var hasRecoverableWorkspaceDrafts: Bool {
        creationDraft != nil || !issueEditDrafts.isEmpty || !commentDrafts.isEmpty
    }

    func issueEditDraftState(for issueID: String) -> IssueEditDraftState? {
        issueEditDrafts[issueID]
    }

    func issueEditDraft(for issue: BeadIssue) -> IssueDraft {
        issueEditDrafts[issue.id]?.draft ?? IssueDraft(issue: issue)
    }

    func updateIssueEditDraft(_ nextDraft: IssueDraft, for issue: BeadIssue) {
        let remoteDraft = IssueDraft(issue: issue)
        if nextDraft == remoteDraft {
            discardIssueEditDraft(issueID: issue.id)
            return
        }

        let existing = issueEditDrafts[issue.id]
        var nextDrafts = issueEditDrafts
        nextDrafts[issue.id] = IssueEditDraftState(
            draft: nextDraft,
            baseline: existing?.baseline ?? remoteDraft,
            conflictingFields: existing?.conflictingFields ?? []
        )
        guard nextDrafts != issueEditDrafts else { return }
        _issueEditDrafts = nextDrafts
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    func discardIssueEditDraft(issueID: String) {
        guard issueEditDrafts[issueID] != nil else { return }
        var nextDrafts = issueEditDrafts
        nextDrafts.removeValue(forKey: issueID)
        _issueEditDrafts = nextDrafts
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    func rebaseIssueEditDraft(onto issue: BeadIssue) {
        guard let state = issueEditDrafts[issue.id] else { return }
        let rebase = state.draft.rebased(from: state.baseline, onto: issue)
        let remoteDraft = IssueDraft(issue: issue)
        let conflicts = state.conflictingFields
            .union(rebase.conflictingFields)
            .filter { !rebase.draft.matches(remoteDraft, field: $0) }

        if rebase.draft == remoteDraft {
            discardIssueEditDraft(issueID: issue.id)
            return
        }

        var nextDrafts = issueEditDrafts
        nextDrafts[issue.id] = IssueEditDraftState(
            draft: rebase.draft,
            baseline: remoteDraft,
            conflictingFields: Set(conflicts)
        )
        guard nextDrafts != issueEditDrafts else { return }
        _issueEditDrafts = nextDrafts
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    func setIssueEditDraftConflicts(_ conflicts: Set<IssueDraftField>, issueID: String) {
        guard var state = issueEditDrafts[issueID], state.conflictingFields != conflicts else { return }
        state.conflictingFields = conflicts
        var nextDrafts = issueEditDrafts
        nextDrafts[issueID] = state
        _issueEditDrafts = nextDrafts
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    func commentDraft(for issueID: String) -> String {
        commentDrafts[issueID] ?? ""
    }

    func updateCommentDraft(_ text: String, issueID: String) {
        var nextDrafts = commentDrafts
        if text.isEmpty {
            nextDrafts.removeValue(forKey: issueID)
        } else {
            nextDrafts[issueID] = text
        }
        guard nextDrafts != commentDrafts else { return }
        _commentDrafts = nextDrafts
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    func clearCommentDraft(issueID: String) {
        updateCommentDraft("", issueID: issueID)
    }

    func resolveSubmittedIssueEditDraft(_ draft: IssueDraft, projectURL: URL) {
        workspaceStateRepository.clearIssueEditDraft(matching: draft, projectURL: projectURL)
        guard self.projectURL == projectURL,
              let issueID = draft.id,
              issueEditDrafts[issueID]?.draft == draft
        else { return }
        discardIssueEditDraft(issueID: issueID)
    }

    func resolveSubmittedCommentDraft(_ text: String, issueID: String, projectURL: URL) {
        workspaceStateRepository.clearCommentDraft(
            matching: text,
            issueID: issueID,
            projectURL: projectURL
        )
        guard self.projectURL == projectURL,
              commentDraft(for: issueID).trimmingCharacters(in: .whitespacesAndNewlines) == text
        else { return }
        clearCommentDraft(issueID: issueID)
    }

    func pruneWorkspaceDraftsToCurrentIssues() {
        let validIssueIDs = index.allIssueIDs
        let nextIssueDrafts = issueEditDrafts.filter { validIssueIDs.contains($0.key) }
        let nextCommentDrafts = commentDrafts.filter { validIssueIDs.contains($0.key) }
        guard nextIssueDrafts != issueEditDrafts || nextCommentDrafts != commentDrafts else { return }
        _issueEditDrafts = nextIssueDrafts
        _commentDrafts = nextCommentDrafts
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    func removeWorkspaceDrafts<S: Sequence>(issueIDs: S) where S.Element == String {
        let removedIDs = Set(issueIDs)
        guard !removedIDs.isEmpty else { return }
        let nextIssueDrafts = issueEditDrafts.filter { !removedIDs.contains($0.key) }
        let nextCommentDrafts = commentDrafts.filter { !removedIDs.contains($0.key) }
        guard nextIssueDrafts != issueEditDrafts || nextCommentDrafts != commentDrafts else { return }
        _issueEditDrafts = nextIssueDrafts
        _commentDrafts = nextCommentDrafts
        syncCurrentWorkspaceSnapshotIfNeeded()
    }
}
