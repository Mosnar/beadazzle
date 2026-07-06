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

    func testIssueListStaysVisibleAtDetailBreakpointAndCollapsesBelowIt() {
        XCTAssertTrue(ContentLayout.showsIssueList(for: ContentLayout.issueListCollapseBreakpoint, showsDetail: true))
        XCTAssertFalse(ContentLayout.showsIssueList(for: ContentLayout.issueListCollapseBreakpoint - 1, showsDetail: true))
    }

    func testIssueListStaysVisibleWhenNoDetailIsShown() {
        XCTAssertTrue(ContentLayout.showsIssueList(for: 0, showsDetail: false))
        XCTAssertTrue(ContentLayout.showsIssueList(for: WindowLayout.minWidth, showsDetail: false))
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

    func testIssueListCollapsesBeforeDetailInspectorRailIsLost() {
        let detailWidthWithList = ContentLayout.issueListCollapseBreakpoint
            - ContentLayout.detailListReservedWidth
            - ContentLayout.sidebarCollapseBuffer

        XCTAssertGreaterThanOrEqual(detailWidthWithList, IssueDetailLayout.railBreakpoint)

        let detailOnlyWidthJustBelowBreakpoint = ContentLayout.issueListCollapseBreakpoint - 1
        XCTAssertTrue(IssueDetailLayout.usesInspectorRail(for: detailOnlyWidthJustBelowBreakpoint))
    }

    func testResponsiveDetailWidthZones() {
        let wideWidth = ContentLayout.detailSidebarCollapseBreakpoint
        XCTAssertTrue(ContentLayout.showsSidebar(for: wideWidth, showsDetail: true))
        XCTAssertTrue(ContentLayout.showsIssueList(for: wideWidth, showsDetail: true))

        let mediumWidth = ContentLayout.issueListCollapseBreakpoint
        XCTAssertFalse(ContentLayout.showsSidebar(for: mediumWidth, showsDetail: true))
        XCTAssertTrue(ContentLayout.showsIssueList(for: mediumWidth, showsDetail: true))

        let detailOnlyRailWidth = ContentLayout.issueListCollapseBreakpoint - 1
        XCTAssertFalse(ContentLayout.showsSidebar(for: detailOnlyRailWidth, showsDetail: true))
        XCTAssertFalse(ContentLayout.showsIssueList(for: detailOnlyRailWidth, showsDetail: true))
        XCTAssertTrue(IssueDetailLayout.usesInspectorRail(for: detailOnlyRailWidth))

        let ribbonWidth = IssueDetailLayout.railBreakpoint - 1
        XCTAssertFalse(ContentLayout.showsSidebar(for: ribbonWidth, showsDetail: true))
        XCTAssertFalse(ContentLayout.showsIssueList(for: ribbonWidth, showsDetail: true))
        XCTAssertFalse(IssueDetailLayout.usesInspectorRail(for: ribbonWidth))
    }

    func testInspectorRailUsesThresholdOnly() {
        XCTAssertTrue(IssueDetailLayout.usesInspectorRail(for: IssueDetailLayout.railBreakpoint))
        XCTAssertFalse(IssueDetailLayout.usesInspectorRail(for: IssueDetailLayout.railBreakpoint - 1))
    }

    func testWindowMinimumAllowsBothCollapseStates() {
        XCTAssertLessThan(WindowLayout.minWidth, ContentLayout.listOnlySidebarCollapseBreakpoint)
        XCTAssertLessThan(WindowLayout.minWidth, ContentLayout.issueListCollapseBreakpoint)
        XCTAssertLessThan(WindowLayout.minWidth, ContentLayout.detailSidebarCollapseBreakpoint)
        XCTAssertLessThan(WindowLayout.minWidth, IssueDetailLayout.railBreakpoint)
    }
}
