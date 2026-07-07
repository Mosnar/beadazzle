import SwiftUI

struct DetailView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    let requestClose: (BeadIssue) -> Void
    @State private var draft: IssueDraft?
    @State private var draftIssueID: String?
    @State private var suppressesCreationDraftUpdates = false
    @State private var isCreatingDraft = false
    @State private var hierarchySheetRequest: DetailHierarchySheetRequest?

    var body: some View {
        @Bindable var store = store

        Group {
            if store.creationDraft != nil {
                IssueCreationPage(
                    draft: creationDraftBinding,
                    isCreating: isCreatingDraft,
                    createAction: createDraft,
                    cancelAction: cancelCreation
                )
            } else if let issue = store.selectedIssue, let gate = store.gate(for: issue.id) {
                GateDetailPage(issue: issue, gate: gate)
            } else if let issue = store.selectedIssue {
                IssueDetailPage(
                    issue: issue,
                    draft: draftBinding(for: issue),
                    isDirty: activeDraft(for: issue) != IssueDraft(issue: issue),
                    saveAction: { save(issue) },
                    revertAction: resetDraft,
                    requestClose: requestClose
                )
                .onChange(of: issue.id) {
                    resetDraft()
                }
                .onChange(of: activeDraft(for: issue).status) { _, newStatus in
                    commitStatusChangeIfNeeded(issue: issue, status: newStatus)
                }
                .onChange(of: activeDraft(for: issue).issueType) { _, newType in
                    commitTypeChangeIfNeeded(issueID: issue.id, type: newType)
                }
                .onChange(of: activeDraft(for: issue).priority) { _, newPriority in
                    commitPriorityChangeIfNeeded(issueID: issue.id, priority: newPriority)
                }
                .onChange(of: activeDraft(for: issue).labels) { _, newLabels in
                    commitLabelsChangeIfNeeded(issueID: issue.id, labels: newLabels)
                }
                .onChange(of: activeDraft(for: issue).dueAt) { _, newDate in
                    commitDueDateChangeIfNeeded(issueID: issue.id, dueAt: newDate)
                }
                .onChange(of: activeDraft(for: issue).deferUntil) { _, newDate in
                    commitDeferredDateChangeIfNeeded(issueID: issue.id, deferUntil: newDate)
                }
            } else {
                ContentUnavailableView("Select a Bead", systemImage: "circle.hexagongrid")
            }
        }
        .focusedValue(\.beadSaveAction, activeSaveAction)
        .sheet(item: $hierarchySheetRequest) { request in
            hierarchySheet(for: request)
        }
    }

    @ViewBuilder
    private func hierarchySheet(for request: DetailHierarchySheetRequest) -> some View {
        switch request {
        case .closeChildrenForSave(let request):
            HierarchyRelatedBeadsSheet(
                title: "Close child beads too?",
                message: "Saving \(request.targetDescription) as \(request.draft.status) will close it while child beads are still open. Close the child beads as well?",
                confirmTitle: "Save and Close Children",
                relatedIssues: request.childIssues
            ) {
                let didSave = await store.save(request.draft, closingChildIssueIDs: request.childIssueIDs)
                if didSave {
                    resetDraft()
                }
                return didSave
            }
        case .closeChildrenForLiveStatus(let request):
            HierarchyRelatedBeadsSheet(
                title: "Close child beads too?",
                message: "Setting \(request.targetDescription) to \(request.status) will close it while child beads are still open. Close the child beads as well?",
                confirmTitle: "Set Status and Close Children",
                relatedIssues: request.childIssues,
                cancelAction: {
                    rollbackLiveStatusChangeIfNeeded(request)
                }
            ) {
                let didSet = await store.bulkSet(issueIDs: request.allIssueIDs, status: request.status)
                if !didSet {
                    rollbackLiveStatusChangeIfNeeded(request)
                }
                return didSet
            }
        case .reopenAncestorsForSave(let request):
            HierarchyRelatedBeadsSheet(
                title: "Reopen parent beads too?",
                message: "Saving \(request.targetDescription) as \(request.draft.status) will reopen it while parent beads are still closed. Reopen the parent beads as well?",
                confirmTitle: "Save and Reopen Parents",
                relatedIssues: request.ancestorIssues
            ) {
                let didSave = await store.save(
                    request.draft,
                    reopeningAncestorIssueIDs: request.ancestorIssueIDs
                )
                if didSave {
                    resetDraft()
                }
                return didSave
            }
        case .reopenAncestorsForLiveStatus(let request):
            HierarchyRelatedBeadsSheet(
                title: "Reopen parent beads too?",
                message: "Setting \(request.targetDescription) to \(request.status) will reopen it while parent beads are still closed. Reopen the parent beads as well?",
                confirmTitle: "Set Status and Reopen Parents",
                relatedIssues: request.ancestorIssues,
                cancelAction: {
                    rollbackLiveStatusChangeIfNeeded(request)
                }
            ) {
                let didSet = await store.bulkSet(
                    issueIDs: request.issueIDs,
                    status: request.status,
                    reopeningAncestorIssueIDs: request.ancestorIssueIDs
                )
                if !didSet {
                    rollbackLiveStatusChangeIfNeeded(request)
                }
                return didSet
            }
        }
    }

    private var creationDraftBinding: Binding<IssueDraft> {
        Binding(
            get: { store.creationDraft ?? store.blankDraft() },
            set: { nextDraft in
                guard !suppressesCreationDraftUpdates, store.selectedIDs.isEmpty else { return }
                store.creationDraft = nextDraft
            }
        )
    }

    private var activeSaveAction: BeadSaveAction? {
        if let creationDraft = store.creationDraft {
            guard !isCreatingDraft, canSave(creationDraft) else { return nil }
            return BeadSaveAction(title: "Create Bead", perform: createDraft)
        }

        guard let issue = store.selectedIssue else { return nil }
        let draft = activeDraft(for: issue)
        guard draft != IssueDraft(issue: issue), canSave(draft) else { return nil }
        return BeadSaveAction(title: "Save Bead", perform: { save(issue) })
    }

    private func draftBinding(for issue: BeadIssue) -> Binding<IssueDraft> {
        Binding(
            get: { activeDraft(for: issue) },
            set: { nextDraft in
                draftIssueID = issue.id
                draft = nextDraft
            }
        )
    }

    private func activeDraft(for issue: BeadIssue) -> IssueDraft {
        if draftIssueID == issue.id, let draft {
            return draft
        }
        return IssueDraft(issue: issue)
    }

    private func createDraft() {
        guard !isCreatingDraft, let creationDraft = store.creationDraft else { return }
        isCreatingDraft = true
        Task {
            defer {
                isCreatingDraft = false
            }
            if await store.save(creationDraft) {
                store.creationDraft = nil
            }
        }
    }

    private func cancelCreation() {
        suppressesCreationDraftUpdates = true
        if store.canGoBack {
            store.goBack()
        } else {
            store.cancelCreation()
        }
        Task { @MainActor in
            await Task.yield()
            suppressesCreationDraftUpdates = false
        }
    }

    private func save(_ issue: BeadIssue) {
        let draft = activeDraft(for: issue)
        if !store.isDone(issue), store.statusClosesBeads(draft.status) {
            let childIssues = store.openChildIssues(forClosing: [issue.id])
            if !childIssues.isEmpty {
                hierarchySheetRequest = .closeChildrenForSave(
                    CloseChildBeadsSaveRequest(
                        issueID: issue.id,
                        title: draft.title,
                        draft: draft,
                        childIssues: childIssues
                    )
                )
                return
            }
        } else if store.isDone(issue), !store.statusClosesBeads(draft.status) {
            let ancestorIssues = store.doneAncestorIssues(forReopening: [issue.id])
            if !ancestorIssues.isEmpty {
                hierarchySheetRequest = .reopenAncestorsForSave(
                    ReopenAncestorBeadsSaveRequest(
                        issueID: issue.id,
                        title: draft.title,
                        draft: draft,
                        ancestorIssues: ancestorIssues
                    )
                )
                return
            }
        }

        Task {
            if await store.save(draft) {
                resetDraft()
            }
        }
    }

    private func commitStatusChangeIfNeeded(issue: BeadIssue, status: String) {
        guard draftIssueID == issue.id, draft != nil else { return }
        guard store.issue(with: issue.id)?.status != status else { return }

        if !store.isDone(issue), store.statusClosesBeads(status) {
            let childIssues = store.openChildIssues(forClosing: [issue.id])
            if !childIssues.isEmpty {
                hierarchySheetRequest = .closeChildrenForLiveStatus(
                    CloseChildBeadsStatusRequest(
                        issues: [issue],
                        status: status,
                        childIssues: childIssues
                    )
                )
                return
            }
        } else if store.isDone(issue), !store.statusClosesBeads(status) {
            let ancestorIssues = store.doneAncestorIssues(forReopening: [issue.id])
            if !ancestorIssues.isEmpty {
                hierarchySheetRequest = .reopenAncestorsForLiveStatus(
                    ReopenAncestorBeadsStatusRequest(
                        issues: [issue],
                        status: status,
                        ancestorIssues: ancestorIssues
                    )
                )
                return
            }
        }

        Task { @MainActor in
            let didSet = await store.bulkSet(issueIDs: [issue.id], status: status)
            if !didSet {
                rollbackStatusIfStillAttempted(issueID: issue.id, attemptedStatus: status)
            }
        }
    }

    private func commitTypeChangeIfNeeded(issueID: String, type: String) {
        guard draftIssueID == issueID, draft != nil else { return }
        guard store.issue(with: issueID)?.issueType != type else { return }

        Task { @MainActor in
            let didSet = await store.bulkSet(issueIDs: [issueID], type: type)
            if !didSet {
                rollbackTypeIfStillAttempted(issueID: issueID, attemptedType: type)
            }
        }
    }

    private func commitPriorityChangeIfNeeded(issueID: String, priority: Int) {
        guard draftIssueID == issueID, draft != nil else { return }
        guard store.issue(with: issueID)?.priority != priority else { return }

        Task { @MainActor in
            let didSet = await store.bulkSet(issueIDs: [issueID], priority: priority)
            if !didSet {
                rollbackPriorityIfStillAttempted(issueID: issueID, attemptedPriority: priority)
            }
        }
    }

    private func commitLabelsChangeIfNeeded(issueID: String, labels: [String]) {
        guard draftIssueID == issueID, draft != nil else { return }
        guard store.issue(with: issueID)?.labels != labels else { return }

        Task { @MainActor in
            let didSet = await store.updateMetadata(issueID: issueID, labels: labels)
            if !didSet {
                rollbackLabelsIfStillAttempted(issueID: issueID, attemptedLabels: labels)
            }
        }
    }

    private func commitDueDateChangeIfNeeded(issueID: String, dueAt: Date?) {
        guard draftIssueID == issueID, draft != nil else { return }
        guard store.issue(with: issueID)?.dueAt != dueAt else { return }

        Task { @MainActor in
            let didSet = await store.updateMetadata(issueID: issueID, dueAt: .set(dueAt))
            if !didSet {
                rollbackDueDateIfStillAttempted(issueID: issueID, attemptedDate: dueAt)
            }
        }
    }

    private func commitDeferredDateChangeIfNeeded(issueID: String, deferUntil: Date?) {
        guard draftIssueID == issueID, draft != nil else { return }
        guard store.issue(with: issueID)?.deferUntil != deferUntil else { return }

        Task { @MainActor in
            let didSet = await store.updateMetadata(issueID: issueID, deferUntil: .set(deferUntil))
            if !didSet {
                rollbackDeferredDateIfStillAttempted(issueID: issueID, attemptedDate: deferUntil)
            }
        }
    }

    private func rollbackLiveStatusChangeIfNeeded(_ request: CloseChildBeadsStatusRequest) {
        guard let issueID = request.issueIDs.first else { return }
        rollbackStatusIfStillAttempted(issueID: issueID, attemptedStatus: request.status)
    }

    private func rollbackLiveStatusChangeIfNeeded(_ request: ReopenAncestorBeadsStatusRequest) {
        guard let issueID = request.issueIDs.first else { return }
        rollbackStatusIfStillAttempted(issueID: issueID, attemptedStatus: request.status)
    }

    private func rollbackStatusIfStillAttempted(issueID: String, attemptedStatus: String) {
        rollbackMetadataIfStillAttempted(issueID: issueID) { draft in
            draft.status == attemptedStatus
        } apply: { draft, issue in
            draft.status = issue.status
        }
    }

    private func rollbackTypeIfStillAttempted(issueID: String, attemptedType: String) {
        rollbackMetadataIfStillAttempted(issueID: issueID) { draft in
            draft.issueType == attemptedType
        } apply: { draft, issue in
            draft.issueType = issue.issueType
        }
    }

    private func rollbackPriorityIfStillAttempted(issueID: String, attemptedPriority: Int) {
        rollbackMetadataIfStillAttempted(issueID: issueID) { draft in
            draft.priority == attemptedPriority
        } apply: { draft, issue in
            draft.priority = issue.priority
        }
    }

    private func rollbackLabelsIfStillAttempted(issueID: String, attemptedLabels: [String]) {
        rollbackMetadataIfStillAttempted(issueID: issueID) { draft in
            draft.labels == attemptedLabels
        } apply: { draft, issue in
            draft.labels = issue.labels
        }
    }

    private func rollbackDueDateIfStillAttempted(issueID: String, attemptedDate: Date?) {
        rollbackMetadataIfStillAttempted(issueID: issueID) { draft in
            draft.dueAt == attemptedDate
        } apply: { draft, issue in
            draft.dueAt = issue.dueAt
        }
    }

    private func rollbackDeferredDateIfStillAttempted(issueID: String, attemptedDate: Date?) {
        rollbackMetadataIfStillAttempted(issueID: issueID) { draft in
            draft.deferUntil == attemptedDate
        } apply: { draft, issue in
            draft.deferUntil = issue.deferUntil
        }
    }

    private func rollbackMetadataIfStillAttempted(
        issueID: String,
        matchesAttempt: (IssueDraft) -> Bool,
        apply rollback: (inout IssueDraft, BeadIssue) -> Void
    ) {
        guard draftIssueID == issueID,
              var currentDraft = draft,
              matchesAttempt(currentDraft),
              let currentIssue = store.issue(with: issueID)
        else { return }
        rollback(&currentDraft, currentIssue)
        draft = currentDraft
    }

    private func resetDraft() {
        draft = nil
        draftIssueID = nil
    }

    private func canSave(_ draft: IssueDraft) -> Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum DetailHierarchySheetRequest: Identifiable, Equatable {
    case closeChildrenForSave(CloseChildBeadsSaveRequest)
    case closeChildrenForLiveStatus(CloseChildBeadsStatusRequest)
    case reopenAncestorsForSave(ReopenAncestorBeadsSaveRequest)
    case reopenAncestorsForLiveStatus(ReopenAncestorBeadsStatusRequest)

    var id: String {
        switch self {
        case .closeChildrenForSave(let request):
            "close-children-save|\(request.id)"
        case .closeChildrenForLiveStatus(let request):
            "close-children-live-status|\(request.id)"
        case .reopenAncestorsForSave(let request):
            "reopen-ancestors-save|\(request.id)"
        case .reopenAncestorsForLiveStatus(let request):
            "reopen-ancestors-live-status|\(request.id)"
        }
    }
}
