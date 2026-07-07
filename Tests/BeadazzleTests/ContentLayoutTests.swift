import CoreGraphics
import XCTest
@testable import Beadazzle

final class ContentLayoutTests: XCTestCase {
    func testSidebarStaysVisibleAtListOnlyBreakpointAndCollapsesBelowIt() {
        XCTAssertTrue(ContentLayout.showsSidebar(for: ContentLayout.listOnlySidebarCollapseBreakpoint, showsDetail: false))
        XCTAssertFalse(ContentLayout.showsSidebar(for: ContentLayout.listOnlySidebarCollapseBreakpoint - 1, showsDetail: false))
    }

    func testSidebarStaysVisibleAtDetailBreakpointAndCollapsesBelowIt() {
        XCTAssertTrue(ContentLayout.showsSidebar(for: ContentLayout.detailSidebarCollapseBreakpoint, showsDetail: true))
        XCTAssertFalse(ContentLayout.showsSidebar(for: ContentLayout.detailSidebarCollapseBreakpoint - 1, showsDetail: true))
    }

    func testIssueListVisibilityOnlyDependsOnFullPageStates() {
        XCTAssertTrue(ContentLayout.showsIssueList(isFullPageDetailPresented: false, hasCreationDraft: false))
        XCTAssertFalse(ContentLayout.showsIssueList(isFullPageDetailPresented: true, hasCreationDraft: false))
        XCTAssertFalse(ContentLayout.showsIssueList(isFullPageDetailPresented: false, hasCreationDraft: true))
    }

    func testWorkspaceDetailIsShownForSingleSelectionExplicitDetailOrCreation() {
        XCTAssertFalse(ContentLayout.showsWorkspaceDetail(selectionCount: 0, isFullPageDetailPresented: false, hasCreationDraft: false))
        XCTAssertTrue(ContentLayout.showsWorkspaceDetail(selectionCount: 1, isFullPageDetailPresented: false, hasCreationDraft: false))
        XCTAssertFalse(ContentLayout.showsWorkspaceDetail(selectionCount: 2, isFullPageDetailPresented: false, hasCreationDraft: false))
        XCTAssertTrue(ContentLayout.showsWorkspaceDetail(selectionCount: 0, isFullPageDetailPresented: true, hasCreationDraft: false))
        XCTAssertTrue(ContentLayout.showsWorkspaceDetail(selectionCount: 0, isFullPageDetailPresented: false, hasCreationDraft: true))
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
        XCTAssertTrue(ContentLayout.showsSidebar(for: wideWidth, showsDetail: true))
        XCTAssertTrue(ContentLayout.showsIssueList(isFullPageDetailPresented: false, hasCreationDraft: false))

        let detailOnlyRailWidth = ContentLayout.detailSidebarCollapseBreakpoint - 1
        XCTAssertFalse(ContentLayout.showsSidebar(for: detailOnlyRailWidth, showsDetail: true))
        XCTAssertTrue(ContentLayout.showsIssueList(isFullPageDetailPresented: false, hasCreationDraft: false))
        XCTAssertTrue(IssueDetailLayout.usesInspectorRail(for: detailOnlyRailWidth))

        let ribbonWidth = IssueDetailLayout.railBreakpoint - 1
        XCTAssertFalse(ContentLayout.showsSidebar(for: ribbonWidth, showsDetail: true))
        XCTAssertTrue(ContentLayout.showsIssueList(isFullPageDetailPresented: false, hasCreationDraft: false))
        XCTAssertFalse(IssueDetailLayout.usesInspectorRail(for: ribbonWidth))

        XCTAssertFalse(ContentLayout.showsIssueList(isFullPageDetailPresented: true, hasCreationDraft: false))
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
