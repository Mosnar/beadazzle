import SwiftUI

struct ContentView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsSidebar = true
    @State private var workspaceWidth: CGFloat = 0
    @State private var pendingDeleteRequest: DeleteBeadsRequest?
    @State private var hierarchySheetRequest: ContentHierarchySheetRequest?
    @State private var deferredStatusRequest: DeferredStatusRequest?
    @State private var searchPresented = false

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
                .keyboardShortcut("r")
                .disabled(store.projectURL == nil || store.isInitializingBeads || store.isLoading)

                Button {
                    store.beginCreatingBead()
                } label: {
                    Label("New Bead", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .disabled(!store.canCreateBead)
                .help(store.selectedBookmark == .gates ? "Gates are created from a bead's ⋯ menu, not here" : "New Bead")

                BulkActionsMenu(
                    requestDeleteSelected: requestDeleteSelected,
                    requestCloseSelected: requestCloseSelected,
                    requestSetStatus: requestSetSelectedStatus
                )
                .disabled(!store.hasReadableProject)
            }
        }
        .confirmationDialog(
            "Delete selected beads?",
            isPresented: deleteConfirmationBinding,
            titleVisibility: .visible,
            presenting: pendingDeleteRequest
        ) { request in
            Button(request.actionTitle, role: .destructive) {
                Task {
                    await store.delete(issueIDs: request.issueIDs)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Beads deletes are destructive. Dependencies involving the selected beads will be cleaned up by bd.")
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
        .alert("Beadazzle", isPresented: errorBinding) {
            Button("OK") {
                store.lastError = nil
            }
        } message: {
            Text(store.lastError ?? "")
        }
        .onAppear {
            store.openDefaultProjectIfAvailable()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBeadRequested)) { _ in
            if store.hasReadableProject {
                store.beginCreatingBead()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjectRequested)) { _ in
            openProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshRequested)) { _ in
            store.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchRequested)) { _ in
            if store.hasReadableProject {
                searchPresented = true
            }
        }
        .onChange(of: store.projectURL) {
            hierarchySheetRequest = nil
            deferredStatusRequest = nil
        }
    }

    private func workspaceView(searchText: Binding<String>) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
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
                canGoBack: store.canGoBack,
                canGoForward: store.canGoForward,
                goBack: store.goBack,
                goForward: store.goForward
            )
            .frame(width: 0, height: 0)
        }
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
            if let missingDataSourceURL = store.missingDataSourceURL {
                MissingDatabaseView(
                    projectURL: missingDataSourceURL,
                    isInitializing: store.isInitializingBeads,
                    isRecovering: store.isLoading && !store.isInitializingBeads,
                    onInitialize: store.initializeBeads,
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
            selectionCount: store.selectedIDs.count,
            isFullPageDetailPresented: store.fullPageDetailIssueID != nil,
            hasCreationDraft: store.creationDraft != nil,
            hasMissingDataSource: store.missingDataSourceURL != nil
        )
    }

    private func shouldShowSidebar(for width: CGFloat) -> Bool {
        ContentLayout.showsSidebar(
            for: width,
            presentation: workspacePresentation
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
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
        requestDelete(store.selectedIDs)
    }

    private func requestDelete(_ issueIDs: Set<String>) {
        guard !issueIDs.isEmpty else { return }
        pendingDeleteRequest = DeleteBeadsRequest(issueIDs: issueIDs.sorted())
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
        let selectedIssues = store.selectedIDs
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
        requestSetStatus(store.selectedIDs, status)
    }

    private func requestSetStatus(_ issueIDs: Set<String>, _ status: String) {
        let issues = issueIDs
            .sorted()
            .compactMap { store.issue(with: $0) }
        guard !issues.isEmpty else { return }

        if store.statusClosesBeads(status) {
            let childIssues = store.openChildIssues(forClosing: issues.map(\.id))
            if !childIssues.isEmpty {
                hierarchySheetRequest = .closeChildrenForStatus(
                    CloseChildBeadsStatusRequest(
                        issues: issues,
                        status: status,
                        childIssues: childIssues
                    )
                )
                return
            }
        } else {
            let ancestorIssues = store.doneAncestorIssues(forReopening: issues.map(\.id))
            if !ancestorIssues.isEmpty {
                hierarchySheetRequest = .reopenAncestorsForStatus(
                    ReopenAncestorBeadsStatusRequest(
                        issues: issues,
                        status: status,
                        ancestorIssues: ancestorIssues
                    )
                )
                return
            }
        }

        if store.isDeferredStatus(status) {
            deferredStatusRequest = DeferredStatusRequest(issues: issues, status: status)
            return
        }

        Task {
            await store.bulkSet(issueIDs: issues.map(\.id), status: status)
        }
    }

    private func requestReopen(issues: [BeadIssue]) {
        let issueIDs = issues.map(\.id)
        let ancestorIssues = store.doneAncestorIssues(forReopening: issueIDs)
        if !ancestorIssues.isEmpty {
            guard let reopenStatus = store.reopenStatusName else {
                store.lastError = "No active status is configured for reopened beads."
                return
            }
            hierarchySheetRequest = .reopenAncestorsForStatus(
                ReopenAncestorBeadsStatusRequest(
                    issues: issues,
                    status: reopenStatus,
                    ancestorIssues: ancestorIssues
                )
            )
        } else {
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

private struct DeleteBeadsRequest: Equatable {
    let issueIDs: [String]

    var actionTitle: String {
        "Delete \(issueIDs.count) Bead\(issueIDs.count == 1 ? "" : "s")"
    }
}

enum WorkspacePresentation: Equatable {
    case listOnly
    case splitDetail
    case fullPageDetail
    case creation
    case missingDataSource

    var showsDetail: Bool {
        self != .listOnly
    }

    var showsIssueList: Bool {
        switch self {
        case .listOnly, .splitDetail:
            true
        case .fullPageDetail, .creation, .missingDataSource:
            false
        }
    }

    var keepsProjectSelectorVisible: Bool {
        self == .missingDataSource
    }
}

enum ContentLayout {
    static let sidebarMinWidth: CGFloat = 190
    static let sidebarIdealWidth: CGFloat = 240
    static let sidebarMaxWidth: CGFloat = 320
    static let listMinWidth: CGFloat = 320
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
        hasMissingDataSource: Bool = false
    ) -> WorkspacePresentation {
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
