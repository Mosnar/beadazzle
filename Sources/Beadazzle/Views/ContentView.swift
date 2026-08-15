import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(BeadStore.self) private var store: BeadStore
    @Environment(BeadWorkspaceWindowRegistry.self) private var registry
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
    @State private var folderEditorRequest: FolderBookmarkEditorRequest?
    @State private var bulkEditRequest: BulkEditRequest?
    @State private var beadsSetupRequest: BeadsSetupRequest?
    @State private var doltRemoteFreshnessSceneID = UUID()
    @State private var isConfirmingTrackerUpgrade = false

    var body: some View {
        @Bindable var store = store

        workspaceView(searchText: $store.searchText)
        .overlay(alignment: .bottom) {
            FolderAutomationStatusOverlay()
            .padding(.bottom, 12)
        }
        // Lives here rather than on the banner: a tracker that blocked the project from
        // opening offers the same upgrade from the unavailable view, which the banner
        // never reaches.
        .confirmationDialog(
            "Upgrade this tracker?",
            isPresented: $isConfirmingTrackerUpgrade,
            titleVisibility: .visible
        ) {
            Button("Upgrade Tracker") {
                store.startTrackerMigration(confirmedByUser: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(trackerUpgradeConfirmationMessage)
        }
        .toolbar {
            if store.showsBackNavigationButton || store.showsForwardNavigationButton {
                ToolbarItemGroup(placement: .navigation) {
                    if store.showsBackNavigationButton {
                        Button(action: store.goBack) {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .disabled(!workspace.canGoBack)
                        .help("Back")
                    }

                    if store.showsForwardNavigationButton {
                        Button(action: store.goForward) {
                            Label("Forward", systemImage: "chevron.forward")
                        }
                        .disabled(!workspace.canGoForward)
                        .help("Forward")
                    }
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if store.hasConfiguredProjectDoltRemote
                    || (store.projectEnvironment?.storageMode == .embedded
                        && store.isLoadingProjectDoltRemotes) {
                    ProjectDoltSyncMenu(
                        isExternallyDisabled: store.isLoadingProjectDoltRemotes
                    )
                } else {
                    Button {
                        store.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(!canRefresh)
                }

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

            if showsIssueListToolbarControls {
                ToolbarItemGroup(placement: .primaryAction) {
                    FilterMenu()
                        .disabled(store.isGlobalSearchActive)
                    IssueListSortMenu()
                    IssueListViewOptionsMenu()
                }
            }
        }
        .sheet(item: $pendingDeleteRequest) { request in
            DeleteBeadsConfirmationSheet(request: request) { issueIDs in
                await store.delete(issueIDs: issueIDs, expectedProjectURL: request.projectURL)
            }
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
                initialSymbolName: store.effectiveIssueListBookmark.systemImage
            )
        }
        .sheet(item: $folderEditorRequest) { request in
            FolderBookmarkSheet(
                initialIssueIDs: request.initialIssueIDs,
                suggestedName: store.suggestedFolderName,
                existing: request.folderID.flatMap { id in
                    workspace.savedViews.first { $0.id == id && $0.isFolder }
                }
            )
        }
        .sheet(item: $bulkEditRequest) { request in
            BulkEditSheet(request: request)
        }
        .sheet(item: $beadsSetupRequest) { request in
            BeadsSetupWizard(request: request)
        }
        .mutationErrorDialog(store: store)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.flushPendingWorkspaceState()
        }
        .focusedSceneValue(\.beadNavigationCommands, BeadNavigationCommandContext(store: store))
        .focusedSceneValue(\.workspaceCommands, WorkspaceCommandActions(
            newBead: store.canCreateBead ? { store.beginCreatingBead() } : nil,
            openProject: { openProject(destination: .preferred) },
            openProjectInNewWindow: { openProject(destination: .newWindow) },
            projectSettingsURL: project.projectURL?.standardizedFileURL,
            refresh: canRefresh ? { store.refresh() } : nil,
            find: store.hasReadableProject ? { searchPresented = true } : nil,
            searchCoverageTitle: searchCoverageCommandTitle,
            toggleSearchCoverage: searchCoverageCommand,
            saveCurrentViewAsBookmark: store.canSaveCurrentViewAsSmartBookmark ? presentSaveBookmark : nil
        ))
        .focusedSceneValue(\.projectSyncCommands, ProjectSyncCommandContext(
            store: store,
            canSynchronize: store.canSynchronizeProjectIssues
        ))
        .onChange(of: project.projectURL) {
            searchPresented = false
            pendingDeleteRequest = nil
            hierarchySheetRequest = nil
            deferredStatusRequest = nil
            savedViewEditorRequest = nil
            folderEditorRequest = nil
            bulkEditRequest = nil
            beadsSetupRequest = nil
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            let isActive = phase == .active
            store.setDoltRemoteFreshnessSceneActive(
                isActive,
                sceneID: doltRemoteFreshnessSceneID
            )
            guard isActive else { return }
            store.refreshServerProjectOnActivation()
        }
        .onDisappear {
            store.setDoltRemoteFreshnessSceneActive(
                false,
                sceneID: doltRemoteFreshnessSceneID
            )
        }
        .onChange(of: workspace.requestedSavedViewEditorID) { _, id in
            guard let id else { return }
            savedViewEditorRequest = SavedViewEditorRequest(mode: .edit(id))
            store.clearRequestedSavedViewEditor()
        }
        .onChange(of: workspace.requestedFolderIssueIDs) { _, issueIDs in
            guard let issueIDs else { return }
            folderEditorRequest = FolderBookmarkEditorRequest(initialIssueIDs: issueIDs)
            store.clearRequestedFolder()
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
                onNewFolder: { store.requestNewFolder() },
                onEditBookmark: { id in
                    if workspace.savedViews.first(where: { $0.id == id })?.isFolder == true {
                        folderEditorRequest = FolderBookmarkEditorRequest(folderID: id)
                    } else {
                        savedViewEditorRequest = SavedViewEditorRequest(mode: .edit(id))
                    }
                }
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
        .searchable(
            text: searchText,
            isPresented: $searchPresented,
            placement: .toolbar,
            prompt: Text(store.searchFieldPrompt)
        )
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
        guard store.canSaveCurrentViewAsSmartBookmark else { return }
        savedViewEditorRequest = SavedViewEditorRequest(mode: .create)
    }

    private func existingSavedView(for request: SavedViewEditorRequest) -> BeadSavedView? {
        guard case .edit(let id) = request.mode else { return nil }
        return workspace.savedViews.first { $0.id == id && !$0.isFolder }
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

        VStack(spacing: 0) {
            // A pending schema upgrade outranks setup advice: until it runs, `bd` cannot
            // read the database at all, so anything else the app reports about this
            // project is derived from the last export.
            if store.trackerMigration.isPending {
                TrackerMigrationBanner(
                    state: store.trackerMigration,
                    upgrade: { store.startTrackerMigration(confirmedByUser: false) },
                    confirmUpgrade: { isConfirmingTrackerUpgrade = true },
                    retry: store.retryTrackerMigrationAfterFailure
                )
            }

            if store.showsBeadsSetupAdvisory {
                BeadsSetupAdvisoryBanner(
                    findings: store.actionableBeadsSetupFindings,
                    openSetup: presentBeadsSetup,
                    dismiss: store.dismissBeadsSetupAdvisory
                )
            }

            HSplitView {
                if presentation.showsIssueList {
                    IssueListView(
                        openProject: openProject,
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
    }

    /// Spells out the consequence `bd` itself guards against, so confirming is an
    /// informed choice rather than a click-through.
    private var trackerUpgradeConfirmationMessage: String {
        guard case .awaitingConfirmation(_, let reason) = store.trackerMigration else {
            return "This applies the pending bd schema migration to this tracker."
        }
        return reason.explanation
    }

    @ViewBuilder
    private func workspaceDetailContent(for presentation: WorkspacePresentation) -> some View {
        switch presentation {
        case .missingDataSource:
            if let missingDataSourceURL = project.projectReadiness.missingDataSourceURL {
                MissingDatabaseView(
                    projectURL: missingDataSourceURL,
                    isBusy: project.isApplyingBeadsSetup || project.isLoading,
                    onSetUp: {
                        beadsSetupRequest = BeadsSetupRequest(projectURL: missingDataSourceURL)
                    },
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
                    onOpenProject: openProject,
                    trackerMigration: store.trackerMigration,
                    // The project never opened, so its remote list is unknown and the
                    // upgrade is always an explicit choice here.
                    onUpgradeTracker: { isConfirmingTrackerUpgrade = true }
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
            opensSplitViewForSelection: store.opensSplitViewOnSingleClick,
            hasCreationDraft: store.creationDraft != nil,
            hasMissingDataSource: project.projectReadiness.missingDataSourceURL != nil,
            hasUnavailableProject: project.projectReadiness.unavailableProject != nil,
            hasUnsupportedProject: project.projectReadiness.unsupportedProject != nil
        )
    }

    private var showsIssueListToolbarControls: Bool {
        ContentLayout.showsIssueListToolbarControls(
            presentation: workspacePresentation,
            bookmark: store.effectiveIssueListBookmark
        )
    }

    private var searchCoverageCommand: (() -> Void)? {
        if store.canExpandCurrentSearchToAllBeads {
            return store.searchAllBeadsUsingCurrentSearchText
        }
        if store.canReturnSearchToCurrentView {
            return store.searchCurrentViewUsingCurrentSearchText
        }
        return nil
    }

    private var searchCoverageCommandTitle: String? {
        if store.canExpandCurrentSearchToAllBeads {
            return "Search All Beads"
        }
        if store.canReturnSearchToCurrentView {
            return "Search Current View"
        }
        return nil
    }

    private func shouldShowSidebar(for width: CGFloat) -> Bool {
        ContentLayout.showsSidebar(
            for: width,
            presentation: workspacePresentation
        )
    }

    private var canRefresh: Bool {
        project.projectURL != nil && !project.isApplyingBeadsSetup && !project.isLoading
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
        let selectedIssues = issueIDs.sorted().compactMap { store.issue(with: $0) }
        guard !selectedIssues.isEmpty else { return }
        pendingDeleteRequest = DeleteBeadsRequest(
            projectURL: projectURL,
            selectedIssues: selectedIssues,
            childIssues: store.childIssues(forDeleting: selectedIssues.map(\.id))
        )
    }

    private func openProject() {
        openProject(destination: .preferred)
    }

    private func openProject(destination: BeadProjectOpenDestination) {
        guard let url = PanelService.chooseProjectFolder() else { return }
        // Only tear down this window's transient sheets when the project lands here;
        // routing it elsewhere leaves this window untouched.
        if registry.openProject(url, from: store, destination: destination) {
            hierarchySheetRequest = nil
        }
    }

    private func presentBeadsSetup() {
        guard let projectURL = project.projectURL else { return }
        beadsSetupRequest = BeadsSetupRequest(
            projectURL: projectURL,
            initialIntent: store.beadsSetupIntent
        )
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

private struct FolderAutomationStatusOverlay: View {
    @Environment(BeadStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let progress = store.folderAutomationProgress {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(progress.folderName) automation")
                            .font(.callout.weight(.medium))
                        Text(progress.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: progress.fractionCompleted)
                            .frame(width: 220)
                            .accessibilityLabel("\(progress.folderName) automation progress")
                            .accessibilityValue(
                                "\(progress.completedUnitCount) of \(progress.totalUnitCount) actions"
                            )
                    }

                    Button(
                        progress.isCancelling ? "Cancelling Automation" : "Cancel Automation",
                        systemImage: "xmark.circle"
                    ) {
                        store.cancelCurrentFolderAutomation()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .disabled(progress.isCancelling)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                .shadow(radius: 4, y: 2)
                .accessibilityElement(children: .contain)
                .transition(statusTransition)
            } else if let summary = store.folderAutomationSummary {
                Label(summary, systemImage: "bolt.fill")
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4, y: 2)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                    .transition(statusTransition)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: presentationID)
    }

    private var presentationID: String? {
        store.folderAutomationProgress == nil ? store.folderAutomationSummary : "progress"
    }

    private var statusTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
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

struct DeleteBeadsRequest: Identifiable, Equatable {
    let projectURL: URL
    let selectedIssues: [BeadIssue]
    let childIssues: [BeadIssue]

    var id: String {
        projectURL.standardizedFileURL.path + "|" + allIssueIDs.joined(separator: "|")
    }

    var issueIDs: [String] {
        selectedIssues.map(\.id)
    }

    var childIssueIDs: [String] {
        childIssues.map(\.id)
    }

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
        opensSplitViewForSelection: Bool = true,
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
        if opensSplitViewForSelection, selectionCount == 1 {
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

    static func showsIssueListToolbarControls(
        presentation: WorkspacePresentation,
        bookmark: BeadBookmark
    ) -> Bool {
        presentation.showsIssueList && bookmark != .gates
    }
}
