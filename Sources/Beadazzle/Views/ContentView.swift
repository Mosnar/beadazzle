import SwiftUI

struct ContentView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsSidebar = true
    @State private var workspaceWidth: CGFloat = 0
    @State private var creationDraft: IssueDraft?
    @State private var showingDeleteConfirmation = false
    @State private var closeBeadRequest: CloseBeadRequest?
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
                    beginCreatingBead()
                } label: {
                    Label("New Bead", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .disabled(!store.hasReadableProject)

                BulkActionsMenu(
                    showingDeleteConfirmation: $showingDeleteConfirmation,
                    requestCloseSelected: requestCloseSelected
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
                beginCreatingBead()
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
        .onChange(of: store.selectedIDs) {
            if creationDraft != nil, !store.selectedIDs.isEmpty {
                creationDraft = nil
            }
        }
        .onChange(of: store.projectURL) {
            creationDraft = nil
            closeBeadRequest = nil
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
                IssueListView(requestClose: requestClose)
                    .frame(
                        minWidth: showsWorkspaceDetail ? ContentLayout.listMinWidth : 0,
                        idealWidth: showsWorkspaceDetail ? ContentLayout.listIdealWidth : nil,
                        maxWidth: showsWorkspaceDetail ? ContentLayout.listMaxWidth : .infinity,
                        maxHeight: .infinity
                    )
            }

            if showsWorkspaceDetail {
                DetailView(creationDraft: $creationDraft, requestClose: requestClose)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var showsWorkspaceDetail: Bool {
        !store.selectedIDs.isEmpty || creationDraft != nil
    }

    private var showsIssueListPane: Bool {
        ContentLayout.showsIssueList(for: workspaceWidth, showsDetail: showsWorkspaceDetail)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }

    private func openProject() {
        guard let url = PanelService.chooseProjectFolder() else { return }
        creationDraft = nil
        closeBeadRequest = nil
        store.openProject(url)
    }

    private func beginCreatingBead() {
        guard store.hasReadableProject else { return }
        guard creationDraft == nil else { return }
        store.clearSelection()
        creationDraft = store.blankDraft()
    }

    private func requestClose(_ issue: BeadIssue) {
        closeBeadRequest = CloseBeadRequest(issue: issue)
    }

    private func requestCloseSelected() {
        let selectedIssues = store.selectedIDs
            .sorted()
            .compactMap { store.issue(with: $0) }
        guard !selectedIssues.isEmpty else { return }
        closeBeadRequest = CloseBeadRequest(issues: selectedIssues)
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
    static let issueListCollapseBreakpoint = detailListReservedWidth + IssueDetailLayout.railBreakpoint + sidebarCollapseBuffer
    static let detailSidebarCollapseBreakpoint = IssueDetailLayout.railBreakpoint + sidebarIdealWidth + detailListReservedWidth + sidebarCollapseBuffer

    static func showsSidebar(for width: CGFloat, showsDetail: Bool) -> Bool {
        let breakpoint = showsDetail ? detailSidebarCollapseBreakpoint : listOnlySidebarCollapseBreakpoint
        return width >= breakpoint
    }

    static func showsIssueList(for width: CGFloat, showsDetail: Bool) -> Bool {
        !showsDetail || width >= issueListCollapseBreakpoint
    }
}
