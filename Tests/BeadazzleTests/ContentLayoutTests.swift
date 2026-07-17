import CoreGraphics
import XCTest
@testable import Beadazzle

final class ContentLayoutTests: XCTestCase {
    func testDeleteRequestOffersChildDeletionWithoutDuplicatingSelectedChildren() {
        let request = DeleteBeadsRequest(
            projectURL: URL(fileURLWithPath: "/tmp/project"),
            issueIDs: ["bd-parent", "bd-child"],
            childIssueIDs: ["bd-grandchild"]
        )

        XCTAssertEqual(request.allIssueIDs, ["bd-child", "bd-grandchild", "bd-parent"])
        XCTAssertEqual(request.dialogTitle, "Delete selected beads?")
        XCTAssertEqual(request.deleteAllActionTitle, "Delete Selected and 1 Descendant Bead")
        XCTAssertEqual(request.deleteSelectedActionTitle, "Delete Selected Only")
        XCTAssertTrue(request.message.contains("Neither action can be undone"))
        XCTAssertTrue(request.message.contains("surviving direct children top-level"))

        let singleRequest = DeleteBeadsRequest(
            projectURL: request.projectURL,
            issueIDs: ["bd-parent"],
            childIssueIDs: ["bd-child"]
        )
        XCTAssertEqual(singleRequest.dialogTitle, "Delete selected bead?")
        XCTAssertEqual(singleRequest.deleteSelectedActionTitle, "Delete Parent Only")
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
                selectionCount: 0,
                isFullPageDetailPresented: false,
                hasCreationDraft: true
            ),
            .creation
        )
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
