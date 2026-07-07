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
    case reopenAncestorsForSave(ReopenAncestorBeadsSaveRequest)

    var id: String {
        switch self {
        case .closeChildrenForSave(let request):
            "close-children-save|\(request.id)"
        case .reopenAncestorsForSave(let request):
            "reopen-ancestors-save|\(request.id)"
        }
    }
}
