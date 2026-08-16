import CoreGraphics
import XCTest
@testable import Beadazzle

final class ContentLayoutTests: XCTestCase {
    func testDeleteRequestOffersChildDeletionWithoutDuplicatingSelectedChildren() {
        let request = DeleteBeadsRequest(
            projectURL: URL(fileURLWithPath: "/tmp/project"),
            selectedIssues: [
                makeIssue(id: "bd-parent", title: "Parent"),
                makeIssue(id: "bd-child", title: "Child")
            ],
            childIssues: [makeIssue(id: "bd-grandchild", title: "Grandchild")]
        )

        XCTAssertEqual(request.allIssueIDs, ["bd-child", "bd-grandchild", "bd-parent"])
        XCTAssertEqual(request.dialogTitle, "Delete selected beads?")
        XCTAssertEqual(request.deleteAllActionTitle, "Delete Selected and 1 Descendant Bead")
        XCTAssertEqual(request.deleteSelectedActionTitle, "Delete Selected Only")
        XCTAssertTrue(request.message.contains("Neither action can be undone"))
        XCTAssertTrue(request.message.contains("surviving direct children top-level"))

        let singleRequest = DeleteBeadsRequest(
            projectURL: request.projectURL,
            selectedIssues: [makeIssue(id: "bd-parent", title: "Parent")],
            childIssues: [makeIssue(id: "bd-child", title: "Child")]
        )
        XCTAssertEqual(singleRequest.dialogTitle, "Delete selected bead?")
        XCTAssertEqual(singleRequest.deleteSelectedActionTitle, "Delete Parent Only")
    }

    private func makeIssue(id: String, title: String) -> BeadIssue {
        BeadIssue(
            id: id,
            title: title,
            description: "",
            design: "",
            acceptanceCriteria: "",
            notes: "",
            status: "open",
            priority: 1,
            issueType: "task",
            assignee: nil,
            owner: nil,
            createdAt: nil,
            updatedAt: nil,
            closedAt: nil,
            dueAt: nil,
            deferUntil: nil,
            externalRef: nil,
            parentID: nil,
            labels: [],
            dependencyCount: 0,
            dependentCount: 0,
            commentCount: 0,
            pinned: false,
            ephemeral: false,
            isTemplate: false
        )
    }

    func testSidebarStaysVisibleAtListOnlyBreakpointAndCollapsesBelowIt() {
        XCTAssertTrue(
            ContentLayout.showsSidebar(
                for: ContentLayout.listOnlySidebarCollapseBreakpoint,
                presentation: .listOnly
            )
        )
        XCTAssertFalse(
            ContentLayout.showsSidebar(
                for: ContentLayout.listOnlySidebarCollapseBreakpoint - 1,
                presentation: .listOnly
            )
        )
    }

    func testSidebarStaysVisibleAtDetailBreakpointAndCollapsesBelowIt() {
        XCTAssertTrue(
            ContentLayout.showsSidebar(
                for: ContentLayout.detailSidebarCollapseBreakpoint,
                presentation: .splitDetail
            )
        )
        XCTAssertFalse(
            ContentLayout.showsSidebar(
                for: ContentLayout.detailSidebarCollapseBreakpoint - 1,
                presentation: .splitDetail
            )
        )
    }

    func testPresentationDrivesIssueListVisibility() {
        XCTAssertTrue(WorkspacePresentation.listOnly.showsIssueList)
        XCTAssertTrue(WorkspacePresentation.splitDetail.showsIssueList)
        XCTAssertFalse(WorkspacePresentation.fullPageDetail.showsIssueList)
        XCTAssertFalse(WorkspacePresentation.creation.showsIssueList)
        XCTAssertFalse(WorkspacePresentation.missingDataSource.showsIssueList)
        XCTAssertFalse(WorkspacePresentation.projectUnavailable.showsIssueList)
        XCTAssertFalse(WorkspacePresentation.unsupportedProject.showsIssueList)
    }

    func testIssueListToolbarControlsFollowListVisibilityAndHideForGates() {
        XCTAssertTrue(
            ContentLayout.showsIssueListToolbarControls(
                presentation: .listOnly,
                bookmark: .ready
            )
        )
        XCTAssertTrue(
            ContentLayout.showsIssueListToolbarControls(
                presentation: .splitDetail,
                bookmark: .all
            )
        )
        XCTAssertFalse(
            ContentLayout.showsIssueListToolbarControls(
                presentation: .fullPageDetail,
                bookmark: .ready
            )
        )
        XCTAssertFalse(
            ContentLayout.showsIssueListToolbarControls(
                presentation: .listOnly,
                bookmark: .gates
            )
        )
    }

    func testGatesHeaderAppearsOnlyWhileSearching() {
        XCTAssertFalse(
            IssueListSurfacePolicy.showsHeader(
                bookmark: .gates,
                hasSearchText: false
            )
        )
        XCTAssertTrue(
            IssueListSurfacePolicy.showsHeader(
                bookmark: .gates,
                hasSearchText: true
            )
        )
        XCTAssertTrue(
            IssueListSurfacePolicy.showsHeader(
                bookmark: .ready,
                hasSearchText: false
            )
        )
    }

    func testEmptyFolderPlaceholderYieldsToSearchResults() {
        XCTAssertTrue(
            IssueListSurfacePolicy.showsEmptyFolderPlaceholder(
                folderIsEmpty: true,
                hasSearchText: false
            )
        )
        XCTAssertFalse(
            IssueListSurfacePolicy.showsEmptyFolderPlaceholder(
                folderIsEmpty: true,
                hasSearchText: true
            )
        )
        XCTAssertFalse(
            IssueListSurfacePolicy.showsEmptyFolderPlaceholder(
                folderIsEmpty: false,
                hasSearchText: false
            )
        )
    }

    func testEmptyFolderRemainsADropTargetDuringCurrentViewSearch() {
        XCTAssertTrue(
            IssueListSurfacePolicy.showsEmptyFolderDropTarget(
                folderIsEmpty: true,
                isGlobalSearchActive: false
            )
        )
        XCTAssertFalse(
            IssueListSurfacePolicy.showsEmptyFolderDropTarget(
                folderIsEmpty: true,
                isGlobalSearchActive: true
            )
        )
        XCTAssertFalse(
            IssueListSurfacePolicy.showsEmptyFolderDropTarget(
                folderIsEmpty: false,
                isGlobalSearchActive: false
            )
        )
    }

    func testPresentationDerivesWorkspaceState() {
        XCTAssertEqual(
            ContentLayout.presentation(
                selectionCount: 0,
                isFullPageDetailPresented: false,
                hasCreationDraft: false
            ),
            .listOnly
        )
        XCTAssertEqual(
            ContentLayout.presentation(
                selectionCount: 1,
                isFullPageDetailPresented: false,
                hasCreationDraft: false
            ),
            .splitDetail
        )
        XCTAssertEqual(
            ContentLayout.presentation(
                selectionCount: 1,
                isFullPageDetailPresented: false,
                opensSplitViewForSelection: false,
                hasCreationDraft: false
            ),
            .listOnly
        )
        XCTAssertEqual(
            ContentLayout.presentation(
                selectionCount: 2,
                isFullPageDetailPresented: false,
                hasCreationDraft: false
            ),
            .listOnly
        )
        XCTAssertEqual(
            ContentLayout.presentation(
                selectionCount: 0,
                isFullPageDetailPresented: true,
                hasCreationDraft: false
            ),
            .fullPageDetail
        )
        XCTAssertEqual(
            ContentLayout.presentation(
                selectionCount: 1,
                isFullPageDetailPresented: true,
                opensSplitViewForSelection: false,
                hasCreationDraft: false
            ),
            .fullPageDetail
        )
        XCTAssertEqual(
            ContentLayout.presentation(
                selectionCount: 0,
                isFullPageDetailPresented: false,
                hasCreationDraft: true
            ),
            .creation
        )
    }

    @MainActor
    func testIssueListActivationStillOpensDetailWhenSingleClickSplitViewIsDisabled() {
        let defaults = makeIsolatedUserDefaults()
        let store = BeadStore(userDefaults: defaults)
        store.opensSplitViewOnSingleClick = false
        var openedIssueID: String?
        let table = IssueListTableView(
            rows: [
                IssueListRow(
                    issueID: "bd-1",
                    depth: 0,
                    hasChildren: false,
                    childProgress: nil,
                    isExpanded: false,
                    isContext: false
                )
            ],
            rowRevision: 1,
            selectedIDs: [],
            bookmark: .ready,
            mode: .outline,
            displayOptions: .compact,
            contentRevision: 0,
            gateClock: .distantPast,
            store: store,
            requestClose: { _ in },
            requestSetStatus: { _, _ in },
            requestBulkEdit: { _, _ in },
            requestDelete: { _ in },
            openDetail: { openedIssueID = $0 }
        )
        let coordinator = IssueListTableView.Coordinator(table)
        coordinator.update(force: true)

        coordinator.openRow(0)

        XCTAssertEqual(openedIssueID, "bd-1")
    }

    func testMissingDataSourceUsesDetailPaneWithoutHidingProjectSelector() {
        let presentation = ContentLayout.presentation(
            selectionCount: 0,
            isFullPageDetailPresented: false,
            hasCreationDraft: false,
            hasMissingDataSource: true
        )

        XCTAssertEqual(presentation, .missingDataSource)
        XCTAssertTrue(presentation.showsDetail)
        XCTAssertFalse(presentation.showsIssueList)
        XCTAssertTrue(
            ContentLayout.showsSidebar(
                for: ContentLayout.detailSidebarCollapseBreakpoint - 1,
                presentation: presentation
            )
        )
    }

    func testMissingDataSourcePresentationTakesPriorityOverTransientWorkspaceState() {
        XCTAssertEqual(
            ContentLayout.presentation(
                selectionCount: 0,
                isFullPageDetailPresented: true,
                hasCreationDraft: true,
                hasMissingDataSource: true
            ),
            .missingDataSource
        )
    }

    func testUnsupportedProjectUsesDetailPaneAndTakesPriority() {
        let presentation = ContentLayout.presentation(
            selectionCount: 1,
            isFullPageDetailPresented: true,
            hasCreationDraft: true,
            hasMissingDataSource: true,
            hasUnsupportedProject: true
        )

        XCTAssertEqual(presentation, .unsupportedProject)
        XCTAssertTrue(presentation.showsDetail)
        XCTAssertFalse(presentation.showsIssueList)
        XCTAssertTrue(
            ContentLayout.showsSidebar(
                for: ContentLayout.detailSidebarCollapseBreakpoint - 1,
                presentation: presentation
            )
        )
    }

    func testUnavailableProjectUsesDetailPaneWithoutHidingProjectSelector() {
        let presentation = ContentLayout.presentation(
            selectionCount: 1,
            isFullPageDetailPresented: true,
            hasCreationDraft: true,
            hasUnavailableProject: true
        )

        XCTAssertEqual(presentation, .projectUnavailable)
        XCTAssertTrue(presentation.showsDetail)
        XCTAssertFalse(presentation.showsIssueList)
        XCTAssertTrue(presentation.keepsProjectSelectorVisible)
    }

    func testSidebarCollapsesBeforeDetailInspectorRailIsLost() {
        let detailWidthWithSidebar = ContentLayout.detailSidebarCollapseBreakpoint
            - ContentLayout.sidebarIdealWidth
            - ContentLayout.detailListReservedWidth
            - ContentLayout.sidebarCollapseBuffer

        XCTAssertGreaterThanOrEqual(detailWidthWithSidebar, IssueDetailLayout.railBreakpoint)

        let detailWidthJustBelowBreakpoint = ContentLayout.detailSidebarCollapseBreakpoint
            - 1
            - ContentLayout.detailListReservedWidth
            - ContentLayout.sidebarCollapseBuffer

        XCTAssertGreaterThanOrEqual(detailWidthJustBelowBreakpoint, IssueDetailLayout.railBreakpoint)
    }

    func testResponsiveDetailWidthZones() {
        let wideWidth = ContentLayout.detailSidebarCollapseBreakpoint
        XCTAssertTrue(ContentLayout.showsSidebar(for: wideWidth, presentation: .splitDetail))
        XCTAssertTrue(WorkspacePresentation.splitDetail.showsIssueList)

        let detailOnlyRailWidth = ContentLayout.detailSidebarCollapseBreakpoint - 1
        XCTAssertFalse(ContentLayout.showsSidebar(for: detailOnlyRailWidth, presentation: .splitDetail))
        XCTAssertTrue(WorkspacePresentation.splitDetail.showsIssueList)
        XCTAssertTrue(IssueDetailLayout.usesInspectorRail(for: detailOnlyRailWidth))

        let ribbonWidth = IssueDetailLayout.railBreakpoint - 1
        XCTAssertFalse(ContentLayout.showsSidebar(for: ribbonWidth, presentation: .splitDetail))
        XCTAssertTrue(WorkspacePresentation.splitDetail.showsIssueList)
        XCTAssertFalse(IssueDetailLayout.usesInspectorRail(for: ribbonWidth))

        XCTAssertFalse(WorkspacePresentation.fullPageDetail.showsIssueList)
    }

    func testInspectorRailUsesThresholdOnly() {
        XCTAssertTrue(IssueDetailLayout.usesInspectorRail(for: IssueDetailLayout.railBreakpoint))
        XCTAssertFalse(IssueDetailLayout.usesInspectorRail(for: IssueDetailLayout.railBreakpoint - 1))
    }

    func testIssueBreadcrumbsYieldToEditActionsOnlyWhileDirty() {
        let clean = IssueBreadcrumbToolbarPresentation(isDirty: false)
        XCTAssertTrue(clean.showsBreadcrumbs)
        XCTAssertFalse(clean.showsEditActions)

        let dirty = IssueBreadcrumbToolbarPresentation(isDirty: true)
        XCTAssertFalse(dirty.showsBreadcrumbs)
        XCTAssertTrue(dirty.showsEditActions)
    }

    func testIssueDetailPaddingTracksInspectorRailMode() {
        XCTAssertEqual(
            IssueDetailLayout.horizontalPadding(usesInspectorRail: true),
            IssueDetailLayout.wideHorizontalPadding
        )
        XCTAssertEqual(
            IssueDetailLayout.horizontalPadding(usesInspectorRail: false),
            IssueDetailLayout.compactHorizontalPadding
        )
        XCTAssertEqual(
            IssueDetailLayout.verticalPadding(usesInspectorRail: true),
            IssueDetailLayout.wideVerticalPadding
        )
        XCTAssertEqual(
            IssueDetailLayout.verticalPadding(usesInspectorRail: false),
            IssueDetailLayout.compactVerticalPadding
        )
    }

    func testWindowMinimumAllowsBothCollapseStates() {
        XCTAssertLessThan(WindowLayout.minWidth, ContentLayout.listOnlySidebarCollapseBreakpoint)
        XCTAssertLessThan(WindowLayout.minWidth, ContentLayout.detailSidebarCollapseBreakpoint)
        XCTAssertLessThan(WindowLayout.minWidth, IssueDetailLayout.railBreakpoint)
    }
}
