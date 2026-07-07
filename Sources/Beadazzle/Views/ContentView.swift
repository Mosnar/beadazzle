import SwiftUI

struct ContentView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsSidebar = true
    @State private var workspaceWidth: CGFloat = 0
    @State private var showingDeleteConfirmation = false
    @State private var closeBeadRequest: CloseBeadRequest?
    @State private var closeChildStatusRequest: CloseChildBeadsStatusRequest?
    @State private var searchPresented = false

    var body: some View {
        @Bindable var store = store

        Group {
            if let missingDataSourceURL = store.missingDataSourceURL {
                MissingDatabaseView(
                    projectURL: missingDataSourceURL,
                    isInitializing: store.isInitializingBeads,
                    isRecovering: store.isLoading && !store.isInitializingBeads,
                    onInitialize: store.initializeBeads,
                    onOpenProject: openProject
                )
            } else {
                workspaceView(searchText: $store.searchText)
            }
        }
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
                    showingDeleteConfirmation: $showingDeleteConfirmation,
                    requestCloseSelected: requestCloseSelected,
                    requestSetStatus: requestSetSelectedStatus
                )
                .disabled(!store.hasReadableProject)
            }
        }
        .confirmationDialog(
            "Delete selected beads?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(store.selectedIDs.count) Bead\(store.selectedIDs.count == 1 ? "" : "s")", role: .destructive) {
                Task {
                    await store.deleteSelected()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Beads deletes are destructive. Dependencies involving the selected beads will be cleaned up by bd.")
        }
        .sheet(item: $closeBeadRequest) { request in
            CloseBeadReasonSheet(request: request)
        }
        .sheet(item: $closeChildStatusRequest) { request in
            CloseChildBeadsConfirmationSheet(
                title: "Close child beads too?",
                message: "Setting \(request.targetDescription) to \(request.status) will close it while child beads are still open. Close the child beads as well?",
                confirmTitle: "Set Status and Close Children",
                childIssues: request.childIssues,
                secondaryTitle: "Set Status Only",
                secondaryAction: {
                    await store.bulkSet(issueIDs: request.issueIDs, status: request.status)
                }
            ) {
                await store.bulkSet(issueIDs: request.allIssueIDs, status: request.status)
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
            closeBeadRequest = nil
            closeChildStatusRequest = nil
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
                showsSidebar: ContentLayout.showsSidebar(for: width, showsDetail: showsWorkspaceDetail)
            )
        }
        .onChange(of: showsWorkspaceDetail) {
            updateColumnVisibility(
                showsSidebar: ContentLayout.showsSidebar(for: workspaceWidth, showsDetail: showsWorkspaceDetail)
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
        HSplitView {
            if showsIssueListPane {
                IssueListView(
                    requestClose: requestClose,
                    requestSetStatus: requestSetStatus,
                    openDetail: openDetail
                )
                    .frame(
                        minWidth: showsWorkspaceDetail ? ContentLayout.listMinWidth : 0,
                        idealWidth: showsWorkspaceDetail ? ContentLayout.listIdealWidth : nil,
                        maxWidth: showsWorkspaceDetail ? ContentLayout.listMaxWidth : .infinity,
                        maxHeight: .infinity
                    )
            }

            if showsWorkspaceDetail {
                DetailView(requestClose: requestClose)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var showsWorkspaceDetail: Bool {
        ContentLayout.showsWorkspaceDetail(
            selectionCount: store.selectedIDs.count,
            isFullPageDetailPresented: store.fullPageDetailIssueID != nil,
            hasCreationDraft: store.creationDraft != nil
        )
    }

    private var showsIssueListPane: Bool {
        ContentLayout.showsIssueList(
            isFullPageDetailPresented: store.fullPageDetailIssueID != nil,
            hasCreationDraft: store.creationDraft != nil
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }

    private func openProject() {
        guard let url = PanelService.chooseProjectFolder() else { return }
        closeBeadRequest = nil
        store.openProject(url)
    }

    private func requestClose(_ issue: BeadIssue) {
        closeBeadRequest = CloseBeadRequest(issue: issue)
    }

    private func openDetail(issueID: String) {
        store.openFullPageDetail(issueID: issueID)
    }

    private func requestCloseSelected() {
        let selectedIssues = store.selectedIDs
            .sorted()
            .compactMap { store.issue(with: $0) }
        guard !selectedIssues.isEmpty else { return }
        closeBeadRequest = CloseBeadRequest(issues: selectedIssues)
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
                closeChildStatusRequest = CloseChildBeadsStatusRequest(
                    issues: issues,
                    status: status,
                    childIssues: childIssues
                )
                return
            }
        }

        Task {
            await store.bulkSet(issueIDs: issues.map(\.id), status: status)
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

    static func showsWorkspaceDetail(
        selectionCount: Int,
        isFullPageDetailPresented: Bool,
        hasCreationDraft: Bool
    ) -> Bool {
        hasCreationDraft || isFullPageDetailPresented || selectionCount == 1
    }

    static func showsSidebar(for width: CGFloat, showsDetail: Bool) -> Bool {
        let breakpoint = showsDetail ? detailSidebarCollapseBreakpoint : listOnlySidebarCollapseBreakpoint
        return width >= breakpoint
    }

    static func showsIssueList(isFullPageDetailPresented: Bool, hasCreationDraft: Bool) -> Bool {
        !isFullPageDetailPresented && !hasCreationDraft
    }
}
