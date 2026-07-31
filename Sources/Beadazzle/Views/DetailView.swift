import SwiftUI

private struct ActiveIssueTextSectionContext {
    let id: String
    let projectKey: String
    let documentIDPrefix: String
    let draft: IssueDraft
}

struct DetailView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    private var workspace: BeadWorkspaceStore { store.workspace }
    let requestClose: (BeadIssue) -> Void
    @State private var draft: IssueDraft?
    @State private var draftIssueID: String?
    @State private var draftBaseline: IssueDraft?
    @State private var draftConflictFields: Set<IssueDraftField> = []
    @State private var pendingDraftConflict: PendingDraftConflict?
    @State private var suppressesCreationDraftUpdates = false
    @State private var hierarchySheetRequest: DetailHierarchySheetRequest?
    @State private var deferredStatusRequest: DeferredStatusRequest?
    @State private var suppressedDeferredDateWrite: DeferredDateWriteSuppression?
    @State private var textSectionVisibilityOverrides = IssueTextSectionVisibilityOverrides()
    @State private var textSectionContextID: String?
    /// In-bead find is per-window state, so it lives here rather than on the
    /// app-wide `BeadStore` that every window shares.
    @State private var findSession = BeadFindSession.forWindow()

    var body: some View {
        @Bindable var store = store
        let textSectionContext = activeTextSectionContext
        let textSectionLayout = effectiveTextSectionLayout(for: textSectionContext)
        let activeFindScope = makeFindScope(
            context: textSectionContext,
            visibleTextSections: textSectionLayout.visible
        )

        Group {
            if store.creationDraft != nil {
                IssueCreationPage(
                    draft: creationDraftBinding,
                    textSectionLayout: textSectionLayout,
                    revealTextSection: revealTextSection,
                    hideTextSection: hideTextSection,
                    isCreating: store.isSubmittingCreationDraft,
                    createAction: createDraft,
                    cancelAction: cancelCreation
                )
            } else if let issue = store.selectedIssue, let gate = store.gate(for: issue.id) {
                GateDetailPage(issue: issue, gate: gate)
            } else if let issue = store.selectedIssue {
                IssueDetailPage(
                    issue: issue,
                    draft: draftBinding(for: issue),
                    textSectionLayout: textSectionLayout,
                    revealTextSection: revealTextSection,
                    hideTextSection: hideTextSection,
                    isDirty: activeDraft(for: issue) != IssueDraft(issue: issue),
                    saveAction: { save(issue) },
                    revertAction: resetDraft,
                    requestClose: requestClose
                )
                .onChange(of: issue.id) {
                    resetDraft()
                    deferredStatusRequest = nil
                }
                .onChange(of: issue) { _, updatedIssue in
                    rebaseActiveDraft(onto: updatedIssue)
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
                .onChange(of: activeDraft(for: issue).assignee) { _, newAssignee in
                    commitAssigneeChangeIfNeeded(issueID: issue.id, assignee: newAssignee)
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
        .beadFindSessionEnvironment(findSession)
        .focusedValue(\.beadSaveAction, activeSaveAction)
        .focusedSceneValue(\.beadFindActions, findActions(scope: activeFindScope))
        .onReceive(NotificationCenter.default.publisher(for: findSession.bus.results)) { notification in
            BeadFindBus.ingest(notification, into: findSession)
        }
        // Keeps find pointed at whatever is actually on screen. `task(id:)`
        // rather than `onChange` because it must also run for the initial value:
        // navigating can remount this view rather than update it. Closing when
        // the scope goes away means find state can't survive into a gate bead,
        // an empty selection, or another project.
        .task(id: activeFindScope) {
            guard let activeFindScope else {
                findSession.close()
                return
            }
            findSession.rebind(scope: activeFindScope)
        }
        .task(id: textSectionContext?.id) {
            synchronizeVisibleTextSections(contextID: textSectionContext?.id)
        }
        .sheet(item: $hierarchySheetRequest) { request in
            hierarchySheet(for: request)
        }
        .sheet(item: $deferredStatusRequest) { request in
            DeferredStatusDateSheet(
                request: request,
                cancelAction: {
                    rollbackDeferredStatusChangeIfNeeded(request)
                }
            ) { deferUntil in
                await confirmDeferredStatusChange(request, deferUntil: deferUntil)
            }
        }
        .alert(
            "Pulled Changes Also Edited This Bead",
            isPresented: Binding(
                get: { pendingDraftConflict != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDraftConflict = nil
                    }
                }
            )
        ) {
            Button("Review Changes", role: .cancel) {
                pendingDraftConflict = nil
            }
            Button("Keep My Changes", role: .destructive) {
                guard let conflict = pendingDraftConflict,
                      let issue = store.issue(with: conflict.issueID) else {
                    pendingDraftConflict = nil
                    return
                }
                pendingDraftConflict = nil
                save(issue, allowsConflictingChanges: true)
            }
        } message: {
            Text(pendingDraftConflict?.message ?? "Review the pulled changes before saving.")
        }
    }

    /// Availability is resolved here, where the session's observable state is
    /// tracked, and gated on there being a searchable body right now — so stale
    /// session state can't leave Find Next enabled over a gate bead or an empty
    /// selection.
    private func findActions(scope: BeadFindScope?) -> BeadFindActions {
        BeadFindActions(
            session: findSession,
            scope: scope,
            canStepBetweenMatches: scope != nil && findSession.isPresented && findSession.hasMatches
        )
    }

    /// What find should search, or `nil` when there is no searchable body — gate
    /// beads render plain text rather than the markdown engine fields find
    /// relies on, and nothing is searchable with no selection.
    private var activeTextSectionContext: ActiveIssueTextSectionContext? {
        guard let projectKey = store.project.projectURL?.path else { return nil }
        if let creationDraft = store.creationDraft {
            return ActiveIssueTextSectionContext(
                id: "\(projectKey)::creation",
                projectKey: projectKey,
                documentIDPrefix: IssueTextSection.creationDocumentIDPrefix,
                draft: creationDraft
            )
        }
        guard let issue = store.selectedIssue, store.gate(for: issue.id) == nil else {
            return nil
        }
        return ActiveIssueTextSectionContext(
            id: "\(projectKey)::\(issue.id)",
            projectKey: projectKey,
            documentIDPrefix: issue.id,
            draft: activeDraft(for: issue)
        )
    }

    private func effectiveTextSectionLayout(
        for context: ActiveIssueTextSectionContext?
    ) -> IssueTextSectionLayout {
        guard let context else {
            return IssueTextSectionLayout(visible: [], hidden: [])
        }
        let explicitlyRevealed = textSectionContextID == context.id
            ? textSectionVisibilityOverrides.revealed
            : []
        let explicitlyHidden = textSectionContextID == context.id
            ? textSectionVisibilityOverrides.hidden
            : []
        return IssueTextSectionPresentationPolicy.editorLayout(
            draft: context.draft,
            preferences: store.effectiveIssueTextSectionPreferences,
            explicitlyRevealed: explicitlyRevealed,
            explicitlyHidden: explicitlyHidden
        )
    }

    private func makeFindScope(
        context: ActiveIssueTextSectionContext?,
        visibleTextSections: [IssueTextSection]
    ) -> BeadFindScope? {
        guard let context, !visibleTextSections.isEmpty else { return nil }
        return BeadFindScope(
            projectKey: context.projectKey,
            documentIDPrefix: context.documentIDPrefix,
            sectionOrder: visibleTextSections
        )
    }

    private func synchronizeVisibleTextSections(contextID: String?) {
        guard let contextID else {
            textSectionContextID = nil
            textSectionVisibilityOverrides = IssueTextSectionVisibilityOverrides()
            return
        }
        if textSectionContextID != contextID {
            textSectionContextID = contextID
            textSectionVisibilityOverrides = IssueTextSectionVisibilityOverrides()
        }
    }

    private func revealTextSection(_ section: IssueTextSection) {
        guard let context = activeTextSectionContext else { return }
        if textSectionContextID != context.id {
            textSectionContextID = context.id
            textSectionVisibilityOverrides = IssueTextSectionVisibilityOverrides()
        }
        textSectionVisibilityOverrides.reveal(section)
    }

    private func hideTextSection(_ section: IssueTextSection) {
        guard let context = activeTextSectionContext,
              IssueTextSectionPresentationPolicy.canHide(section, in: context.draft)
        else { return }
        if textSectionContextID != context.id {
            textSectionContextID = context.id
            textSectionVisibilityOverrides = IssueTextSectionVisibilityOverrides()
        }
        textSectionVisibilityOverrides.hide(section)
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
                let didSave = await store.save(
                    request.draft,
                    closingChildIssueIDs: request.childIssueIDs,
                    context: request.saveContext
                )
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
                    reopeningAncestorIssueIDs: request.ancestorIssueIDs,
                    context: request.saveContext
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
                if store.isDeferredStatus(request.status) {
                    presentDeferredStatusAfterCurrentSheet(
                        DeferredStatusRequest(
                            issueIDs: request.issueIDs,
                            title: request.title,
                            status: request.status,
                            reopeningAncestorIssueIDs: request.ancestorIssueIDs
                        )
                    )
                    return true
                }
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
                guard !suppressesCreationDraftUpdates,
                      !store.isSubmittingCreationDraft,
                      workspace.selectedIDs.isEmpty else { return }
                store.creationDraft = nextDraft
            }
        )
    }

    private var activeSaveAction: BeadSaveAction? {
        if let creationDraft = store.creationDraft {
            guard !store.isSubmittingCreationDraft, canSave(creationDraft) else { return nil }
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
                if draftIssueID != issue.id || draftBaseline == nil {
                    draftBaseline = IssueDraft(issue: issue)
                    draftConflictFields = []
                    pendingDraftConflict = nil
                }
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
        guard !store.isSubmittingCreationDraft, store.creationDraft != nil else { return }
        Task { @MainActor in
            _ = await store.submitCreationDraft()
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

    private func save(_ issue: BeadIssue, allowsConflictingChanges: Bool = false) {
        let draft = activeDraft(for: issue)
        let unresolvedConflicts = unresolvedDraftConflicts(draft: draft, issue: issue)
        draftConflictFields = unresolvedConflicts
        if !allowsConflictingChanges, !unresolvedConflicts.isEmpty {
            pendingDraftConflict = PendingDraftConflict(
                issueID: issue.id,
                fields: unresolvedConflicts
            )
            return
        }
        let saveContext = IssueDraftSaveContext(
            baseline: draftBaseline ?? IssueDraft(issue: issue),
            allowsConflictingChanges: allowsConflictingChanges
        )
        if !store.isDone(issue), store.statusClosesBeads(draft.status) {
            let childIssues = store.openChildIssues(forClosing: [issue.id])
            if !childIssues.isEmpty {
                hierarchySheetRequest = .closeChildrenForSave(
                    CloseChildBeadsSaveRequest(
                        issueID: issue.id,
                        title: draft.title,
                        draft: draft,
                        saveContext: saveContext,
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
                        saveContext: saveContext,
                        ancestorIssues: ancestorIssues
                    )
                )
                return
            }
        }

        Task {
            if await store.save(draft, context: saveContext) {
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

        if store.isDeferredStatus(status) {
            deferredStatusRequest = DeferredStatusRequest(issues: [issue], status: status)
            return
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

    private func commitAssigneeChangeIfNeeded(issueID: String, assignee: String) {
        guard draftIssueID == issueID, draft != nil else { return }
        guard store.issue(with: issueID)?.assignee?.nilIfBlank != assignee.nilIfBlank else { return }

        Task { @MainActor in
            let didSet = await store.updateMetadata(issueID: issueID, assignee: assignee)
            if !didSet {
                rollbackAssigneeIfStillAttempted(issueID: issueID, attemptedAssignee: assignee)
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
        if suppressedDeferredDateWrite == DeferredDateWriteSuppression(issueID: issueID, date: deferUntil) {
            return
        }
        guard store.issue(with: issueID)?.deferUntil != deferUntil else { return }

        Task { @MainActor in
            let didSet = await store.updateMetadata(issueID: issueID, deferUntil: .set(deferUntil))
            if !didSet {
                rollbackDeferredDateIfStillAttempted(issueID: issueID, attemptedDate: deferUntil)
            }
        }
    }

    private func confirmDeferredStatusChange(_ request: DeferredStatusRequest, deferUntil: Date?) async -> Bool {
        let didSet = await store.bulkSet(
            issueIDs: request.issueIDs,
            status: request.status,
            deferUntil: .set(deferUntil),
            reopeningAncestorIssueIDs: request.reopeningAncestorIssueIDs
        )
        if didSet {
            syncDraftAfterDeferredStatusChange(request, deferUntil: deferUntil)
        } else {
            rollbackDeferredStatusChangeIfNeeded(request)
        }
        return didSet
    }

    private func presentDeferredStatusAfterCurrentSheet(_ request: DeferredStatusRequest) {
        Task { @MainActor in
            await Task.yield()
            deferredStatusRequest = request
        }
    }

    private func syncDraftAfterDeferredStatusChange(_ request: DeferredStatusRequest, deferUntil: Date?) {
        guard let issueID = request.issueIDs.first,
              draftIssueID == issueID,
              var currentDraft = draft
        else { return }
        let suppression = DeferredDateWriteSuppression(issueID: issueID, date: deferUntil)
        suppressedDeferredDateWrite = suppression
        currentDraft.status = request.status
        currentDraft.deferUntil = deferUntil
        draft = currentDraft
        Task { @MainActor in
            await Task.yield()
            if suppressedDeferredDateWrite == suppression {
                suppressedDeferredDateWrite = nil
            }
        }
    }

    private func rollbackDeferredStatusChangeIfNeeded(_ request: DeferredStatusRequest) {
        guard let issueID = request.issueIDs.first else { return }
        rollbackStatusIfStillAttempted(issueID: issueID, attemptedStatus: request.status)
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

    private func rollbackAssigneeIfStillAttempted(issueID: String, attemptedAssignee: String) {
        rollbackMetadataIfStillAttempted(issueID: issueID) { draft in
            draft.assignee == attemptedAssignee
        } apply: { draft, issue in
            draft.assignee = issue.assignee ?? ""
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
        draftBaseline = nil
        draftConflictFields = []
        pendingDraftConflict = nil
    }

    private func rebaseActiveDraft(onto issue: BeadIssue) {
        guard draftIssueID == issue.id,
              let draft,
              let draftBaseline else { return }
        let rebase = draft.rebased(from: draftBaseline, onto: issue)
        let remoteDraft = IssueDraft(issue: issue)
        var conflicts = draftConflictFields.union(rebase.conflictingFields)
        conflicts = Set(conflicts.filter { !rebase.draft.matches(remoteDraft, field: $0) })
        self.draft = rebase.draft
        self.draftBaseline = remoteDraft
        draftConflictFields = conflicts
        pendingDraftConflict = nil
        hierarchySheetRequest = nil
    }

    private func unresolvedDraftConflicts(
        draft: IssueDraft,
        issue: BeadIssue
    ) -> Set<IssueDraftField> {
        let current = IssueDraft(issue: issue)
        return Set(draftConflictFields.filter { !draft.matches(current, field: $0) })
    }

    private func canSave(_ draft: IssueDraft) -> Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct PendingDraftConflict: Equatable {
    let issueID: String
    let fields: Set<IssueDraftField>

    var message: String {
        let names = IssueDraftField.allCases
            .filter(fields.contains)
            .map(\.displayName)
            .formatted(.list(type: .and))
        return "Both you and a pulled update changed \(names). Keeping your changes will overwrite only those fields; all other pulled changes will be preserved."
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

private struct DeferredDateWriteSuppression: Equatable {
    let issueID: String
    let date: Date?
}
