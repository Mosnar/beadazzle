import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(\.scenePhase) private var scenePhase
    private var project: BeadProjectStore { store.project }
    private var workspace: BeadWorkspaceStore { store.workspace }
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsSidebar = true
    @State private var workspaceWidth: CGFloat = 0
    @State private var pendingDeleteRequest: DeleteBeadsRequest?
    @State private var hierarchySheetRequest: ContentHierarchySheetRequest?
    @State private var deferredStatusRequest: DeferredStatusRequest?
    @State private var searchPresented = false
    @State private var savedViewEditorRequest: SavedViewEditorRequest?
    @State private var bulkEditRequest: BulkEditRequest?

    var body: some View {
        @Bindable var store = store

        workspaceView(searchText: $store.searchText)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!canRefresh)

                Button {
                    store.beginCreatingBead()
                } label: {
                    Label("New Bead", systemImage: "plus")
                }
                .disabled(!store.canCreateBead)
                .help(newBeadHelp)

                BulkActionsMenu(
                    requestDeleteSelected: requestDeleteSelected,
                    requestCloseSelected: requestCloseSelected,
                    requestSetStatus: requestSetSelectedStatus,
                    requestBulkEdit: requestBulkEditSelected
                )
                .disabled(!store.hasReadableProject)
            }
        }
        .confirmationDialog(
            pendingDeleteRequest?.dialogTitle ?? "Delete selected beads?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingDeleteRequest
        ) { request in
            if request.childIssueIDs.isEmpty {
                deleteButton(request.actionTitle, request: request, issueIDs: request.issueIDs)
            } else {
                deleteButton(request.deleteAllActionTitle, request: request, issueIDs: request.allIssueIDs)
                deleteButton(request.deleteSelectedActionTitle, request: request, issueIDs: request.issueIDs)
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .sheet(item: $hierarchySheetRequest) { request in
            hierarchySheet(for: request)
        }
        .sheet(item: $deferredStatusRequest) { request in
            DeferredStatusDateSheet(request: request) { deferUntil in
                await store.bulkSet(
                    issueIDs: request.issueIDs,
                    status: request.status,
                    deferUntil: .set(deferUntil),
                    reopeningAncestorIssueIDs: request.reopeningAncestorIssueIDs
                )
            }
        }
        .sheet(item: $savedViewEditorRequest) { request in
            SaveBookmarkSheet(
                existing: existingSavedView(for: request),
                initialQuery: store.currentSavedViewQuery,
                initialOrdering: store.currentSavedViewOrdering,
                suggestedName: store.suggestedSavedViewName,
                initialSymbolName: workspace.selectedBookmark.systemImage
            )
        }
        .sheet(item: $bulkEditRequest) { request in
            BulkEditSheet(request: request)
        }
        .mutationErrorDialog(store: store)
        .onAppear {
            store.openDefaultProjectIfAvailable()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.flushPendingWorkspaceState()
        }
        .focusedSceneValue(\.workspaceCommands, WorkspaceCommandActions(
            newBead: store.canCreateBead ? { store.beginCreatingBead() } : nil,
            openProject: openProject,
            refresh: canRefresh ? { store.refresh() } : nil,
            find: store.hasReadableProject ? { searchPresented = true } : nil,
            saveCurrentViewAsBookmark: store.canCreateSavedView ? presentSaveBookmark : nil
        ))
        .onChange(of: project.projectURL) {
            pendingDeleteRequest = nil
            hierarchySheetRequest = nil
            deferredStatusRequest = nil
            savedViewEditorRequest = nil
            bulkEditRequest = nil
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            store.refreshServerProjectOnActivation()
        }
        .onChange(of: workspace.requestedSavedViewEditorID) { _, id in
            guard let id else { return }
            savedViewEditorRequest = SavedViewEditorRequest(mode: .edit(id))
            store.clearRequestedSavedViewEditor()
        }
    }

    private var newBeadHelp: String {
        if workspace.selectedBookmark == .gates {
            return "Gates are created from a bead's ⋯ menu, not here"
        }
        return "New Bead"
    }

    private func workspaceView(searchText: Binding<String>) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                onSaveBookmark: presentSaveBookmark,
                onEditBookmark: { id in savedViewEditorRequest = SavedViewEditorRequest(mode: .edit(id)) }
            )
                .navigationSplitViewColumnWidth(
                    min: ContentLayout.sidebarMinWidth,
                    ideal: ContentLayout.sidebarIdealWidth,
                    max: ContentLayout.sidebarMaxWidth
                )
        } detail: {
            workspaceContent
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            workspaceWidth = width
            updateColumnVisibility(
                showsSidebar: shouldShowSidebar(for: width)
            )
        }
        .onChange(of: workspacePresentation) {
            updateColumnVisibility(
                showsSidebar: shouldShowSidebar(for: workspaceWidth)
            )
        }
        .searchable(text: searchText, isPresented: $searchPresented, placement: .toolbar, prompt: "Search beads")
        .background {
            WorkspaceMouseNavigationBridge(
                canGoBack: workspace.canGoBack,
                canGoForward: workspace.canGoForward,
                goBack: store.goBack,
                goForward: store.goForward
            )
            .frame(width: 0, height: 0)
        }
    }

    private func presentSaveBookmark() {
        guard store.canCreateSavedView else { return }
        savedViewEditorRequest = SavedViewEditorRequest(mode: .create)
    }

    private func existingSavedView(for request: SavedViewEditorRequest) -> BeadSavedView? {
        guard case .edit(let id) = request.mode else { return nil }
        return workspace.savedViews.first { $0.id == id }
    }

    // Keep `IssueListView` in a single, stable structural slot (HSplitView[0]) across
    // every layout state. Previously the list moved between an HSplitView child and a
    // top-level view depending on selection, changing its identity — so switching
    // bookmarks (which can flip whether a selection survives) tore down and rebuilt the
    // whole NSTableView-backed list on the main thread. A stable slot turns that into a
    // cheap incremental data diff on the already-realized list.
    @ViewBuilder
    private var workspaceContent: some View {
        let presentation = workspacePresentation

        HSplitView {
            if presentation.showsIssueList {
                IssueListView(
                    requestClose: requestClose,
                    requestSetStatus: requestSetStatus,
                    requestBulkEdit: requestBulkEdit,
                    requestDelete: requestDelete,
                    openDetail: openDetail
                )
                    .frame(
                        minWidth: presentation.showsDetail ? ContentLayout.listMinWidth : 0,
                        idealWidth: presentation.showsDetail ? ContentLayout.listIdealWidth : nil,
                        maxWidth: presentation.showsDetail ? ContentLayout.listMaxWidth : .infinity,
                        maxHeight: .infinity
                    )
            }

            if presentation.showsDetail {
                workspaceDetailContent(for: presentation)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    @ViewBuilder
    private func workspaceDetailContent(for presentation: WorkspacePresentation) -> some View {
        switch presentation {
        case .missingDataSource:
            if let missingDataSourceURL = project.projectReadiness.missingDataSourceURL {
                MissingDatabaseView(
                    projectURL: missingDataSourceURL,
                    isInitializing: project.isInitializingBeads,
                    isRecovering: project.isLoading && !project.isInitializingBeads,
                    onInitialize: store.initializeBeads,
                    onOpenProject: openProject
                )
            }
        case .unsupportedProject:
            if let unsupportedProject = project.projectReadiness.unsupportedProject {
                UnsupportedProjectView(
                    projectURL: unsupportedProject.url,
                    detail: unsupportedProject.detail,
                    isRetrying: project.isLoading,
                    onRetry: store.refresh,
                    onOpenProject: openProject
                )
            }
        case .projectUnavailable:
            if let unavailableProject = project.projectReadiness.unavailableProject {
                ProjectUnavailableView(
                    projectURL: unavailableProject.url,
                    detail: unavailableProject.detail,
                    isRetrying: project.isLoading,
                    onRetry: store.refresh,
                    onOpenProject: openProject
                )
            }
        case .splitDetail, .fullPageDetail, .creation:
            DetailView(requestClose: requestClose)
        case .listOnly:
            EmptyView()
        }
    }

    private var workspacePresentation: WorkspacePresentation {
        ContentLayout.presentation(
            selectionCount: workspace.selectedIDs.count,
            isFullPageDetailPresented: workspace.fullPageDetailIssueID != nil,
            hasCreationDraft: store.creationDraft != nil,
            hasMissingDataSource: project.projectReadiness.missingDataSourceURL != nil,
            hasUnavailableProject: project.projectReadiness.unavailableProject != nil,
            hasUnsupportedProject: project.projectReadiness.unsupportedProject != nil
        )
    }

    private func shouldShowSidebar(for width: CGFloat) -> Bool {
        ContentLayout.showsSidebar(
            for: width,
            presentation: workspacePresentation
        )
    }

    private var canRefresh: Bool {
        project.projectURL != nil && !project.isInitializingBeads && !project.isLoading
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteRequest != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteRequest = nil
                }
            }
        )
    }

    private func requestDeleteSelected() {
        requestDelete(workspace.selectedIDs)
    }

    private func requestBulkEditSelected(_ target: BulkEditTarget) {
        requestBulkEdit(workspace.selectedIDs, target)
    }

    private func requestBulkEdit(_ issueIDs: Set<String>, _ target: BulkEditTarget) {
        guard !issueIDs.isEmpty else { return }
        bulkEditRequest = store.makeBulkEditRequest(issueIDs: issueIDs, target: target)
    }

    private func requestDelete(_ issueIDs: Set<String>) {
        guard !issueIDs.isEmpty, let projectURL = project.projectURL else { return }
        let sortedIssueIDs = issueIDs.sorted()
        pendingDeleteRequest = DeleteBeadsRequest(
            projectURL: projectURL,
            issueIDs: sortedIssueIDs,
            childIssueIDs: store.childIssues(forDeleting: sortedIssueIDs).map(\.id)
        )
    }

    @ViewBuilder
    private func deleteButton(_ title: String, request: DeleteBeadsRequest, issueIDs: [String]) -> some View {
        Button(title, role: .destructive) {
            Task {
                await store.delete(issueIDs: issueIDs, expectedProjectURL: request.projectURL)
            }
        }
    }

    private func openProject() {
        guard let url = PanelService.chooseProjectFolder() else { return }
        hierarchySheetRequest = nil
        store.openProject(url)
    }

    private func requestClose(_ issue: BeadIssue) {
        guard store.completionAction(for: [issue.id]) == .close else {
            requestReopen(issues: [issue])
            return
        }
        hierarchySheetRequest = .close(CloseBeadRequest(issue: issue))
    }

    private func openDetail(issueID: String) {
        store.openFullPageDetail(issueID: issueID)
    }

    private func requestCloseSelected() {
        let selectedIssues = workspace.selectedIDs
            .sorted()
            .compactMap { store.issue(with: $0) }
        guard !selectedIssues.isEmpty else { return }
        let issueIDs = selectedIssues.map(\.id)
        guard store.completionAction(for: issueIDs) == .close else {
            requestReopen(issues: selectedIssues)
            return
        }
        let closeableIssues = selectedIssues.filter { !store.isDone($0) }
        guard !closeableIssues.isEmpty else { return }
        hierarchySheetRequest = .close(CloseBeadRequest(issues: closeableIssues))
    }

    private func requestSetSelectedStatus(_ status: String) {
        requestSetStatus(workspace.selectedIDs, status)
    }

    private func requestSetStatus(_ issueIDs: Set<String>, _ status: String) {
        let issues = issueIDs
            .sorted()
            .compactMap { store.issue(with: $0) }
        guard !issues.isEmpty else { return }

        switch store.statusChangeConfirmation(forSetting: status, on: issues.map(\.id)) {
        case .closeChildren(let childIssues):
            hierarchySheetRequest = .closeChildrenForStatus(
                CloseChildBeadsStatusRequest(
                    issues: issues,
                    status: status,
                    childIssues: childIssues
                )
            )
        case .reopenAncestors(let ancestorIssues):
            hierarchySheetRequest = .reopenAncestorsForStatus(
                ReopenAncestorBeadsStatusRequest(
                    issues: issues,
                    status: status,
                    ancestorIssues: ancestorIssues
                )
            )
        case .deferDate:
            deferredStatusRequest = DeferredStatusRequest(issues: issues, status: status)
        case .proceed:
            Task {
                await store.bulkSet(issueIDs: issues.map(\.id), status: status)
            }
        }
    }

    private func requestReopen(issues: [BeadIssue]) {
        let issueIDs = issues.map(\.id)
        switch store.reopenConfirmation(for: issueIDs) {
        case .missingReopenStatus:
            store.lastError = "No active status is configured for reopened beads."
        case .reopenAncestors(let ancestorIssues, let reopenStatus):
            hierarchySheetRequest = .reopenAncestorsForStatus(
                ReopenAncestorBeadsStatusRequest(
                    issues: issues,
                    status: reopenStatus,
                    ancestorIssues: ancestorIssues
                )
            )
        case .proceed:
            Task {
                await store.reopen(issueIDs: issueIDs)
            }
        }
    }

    @ViewBuilder
    private func hierarchySheet(for request: ContentHierarchySheetRequest) -> some View {
        switch request {
        case .close(let request):
            CloseBeadReasonSheet(request: request)
        case .closeChildrenForStatus(let request):
            HierarchyRelatedBeadsSheet(
                title: "Close child beads too?",
                message: "Setting \(request.targetDescription) to \(request.status) will close it while child beads are still open. Close the child beads as well?",
                confirmTitle: "Set Status and Close Children",
                relatedIssues: request.childIssues
            ) {
                await store.bulkSet(issueIDs: request.allIssueIDs, status: request.status)
            }
        case .reopenAncestorsForStatus(let request):
            HierarchyRelatedBeadsSheet(
                title: "Reopen parent beads too?",
                message: "Setting \(request.targetDescription) to \(request.status) will reopen it while parent beads are still closed. Reopen the parent beads as well?",
                confirmTitle: "Set Status and Reopen Parents",
                relatedIssues: request.ancestorIssues
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
                return await store.bulkSet(
                    issueIDs: request.issueIDs,
                    status: request.status,
                    reopeningAncestorIssueIDs: request.ancestorIssueIDs
                )
            }
        }
    }

    private func presentDeferredStatusAfterCurrentSheet(_ request: DeferredStatusRequest) {
        Task { @MainActor in
            await Task.yield()
            deferredStatusRequest = request
        }
    }

    private func updateColumnVisibility(showsSidebar nextShowsSidebar: Bool) {
        guard showsSidebar != nextShowsSidebar else { return }
        showsSidebar = nextShowsSidebar

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            columnVisibility = nextShowsSidebar ? .all : .detailOnly
        }
    }

}

private enum ContentHierarchySheetRequest: Identifiable, Equatable {
    case close(CloseBeadRequest)
    case closeChildrenForStatus(CloseChildBeadsStatusRequest)
    case reopenAncestorsForStatus(ReopenAncestorBeadsStatusRequest)

    var id: String {
        switch self {
        case .close(let request):
            "close|\(request.id)"
        case .closeChildrenForStatus(let request):
            "close-children-status|\(request.id)"
        case .reopenAncestorsForStatus(let request):
            "reopen-ancestors-status|\(request.id)"
        }
    }
}

struct DeleteBeadsRequest: Equatable {
    let projectURL: URL
    let issueIDs: [String]
    let childIssueIDs: [String]

    var allIssueIDs: [String] {
        uniqueSortedIssueIDs(issueIDs + childIssueIDs)
    }

    var actionTitle: String {
        "Delete \(issueIDs.count) Bead\(issueIDs.count == 1 ? "" : "s")"
    }

    var dialogTitle: String {
        issueIDs.count == 1 ? "Delete selected bead?" : "Delete selected beads?"
    }

    var deleteAllActionTitle: String {
        "Delete Selected and \(childIssueIDs.count.formatted()) Descendant Bead\(childIssueIDs.count == 1 ? "" : "s")"
    }

    var deleteSelectedActionTitle: String {
        issueIDs.count == 1 ? "Delete Parent Only" : "Delete Selected Only"
    }

    var message: String {
        guard !childIssueIDs.isEmpty else {
            return "Beads deletes are destructive. Dependencies involving the selected beads will be cleaned up by bd."
        }
        let descendantText = childIssueIDs.count == 1 ? "descendant bead" : "descendant beads"
        return "The selection has \(childIssueIDs.count.formatted()) \(descendantText). Neither action can be undone. Deleting only the selected beads will make any surviving direct children top-level."
    }
}

enum WorkspacePresentation: Equatable {
    case listOnly
    case splitDetail
    case fullPageDetail
    case creation
    case missingDataSource
    case projectUnavailable
    case unsupportedProject

    var showsDetail: Bool {
        self != .listOnly
    }

    var showsIssueList: Bool {
        switch self {
        case .listOnly, .splitDetail:
            true
        case .fullPageDetail, .creation, .missingDataSource, .projectUnavailable, .unsupportedProject:
            false
        }
    }

    var keepsProjectSelectorVisible: Bool {
        self == .missingDataSource || self == .projectUnavailable || self == .unsupportedProject
    }
}

enum ContentLayout {
    static let workspaceToolbarHeight: CGFloat = 40
    static let sidebarMinWidth: CGFloat = 190
    static let sidebarIdealWidth: CGFloat = 240
    static let sidebarMaxWidth: CGFloat = 320
    static let listMinWidth: CGFloat = 420
    static let listIdealWidth: CGFloat = 420
    static let listMaxWidth: CGFloat = 560
    static let sidebarCollapseBuffer: CGFloat = 24
    static let detailListReservedWidth = listMaxWidth
    static let listOnlySidebarCollapseBreakpoint = sidebarIdealWidth + listMinWidth + sidebarCollapseBuffer
    static let detailSidebarCollapseBreakpoint = IssueDetailLayout.railBreakpoint + sidebarIdealWidth + detailListReservedWidth + sidebarCollapseBuffer

    static func presentation(
        selectionCount: Int,
        isFullPageDetailPresented: Bool,
        hasCreationDraft: Bool,
        hasMissingDataSource: Bool = false,
        hasUnavailableProject: Bool = false,
        hasUnsupportedProject: Bool = false
    ) -> WorkspacePresentation {
        if hasUnsupportedProject {
            return .unsupportedProject
        }
        if hasUnavailableProject {
            return .projectUnavailable
        }
        if hasMissingDataSource {
            return .missingDataSource
        }
        if hasCreationDraft {
            return .creation
        }
        if isFullPageDetailPresented {
            return .fullPageDetail
        }
        if selectionCount == 1 {
            return .splitDetail
        }
        return .listOnly
    }

    static func showsSidebar(
        for width: CGFloat,
        presentation: WorkspacePresentation
    ) -> Bool {
        if presentation.keepsProjectSelectorVisible {
            return true
        }

        let breakpoint = presentation.showsDetail ? detailSidebarCollapseBreakpoint : listOnlySidebarCollapseBreakpoint
        return width >= breakpoint
    }
}
