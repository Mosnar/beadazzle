import XCTest
@testable import Beadazzle

final class ProjectHealthPresentationTests: XCTestCase {
    func testHealthyPresentationCollapsesEveryCheckAndHidesSummaryBadge() {
        let preflight = makePreflight(
            status: .ready,
            checks: [
                makeCheck(id: .bdCLI, status: .ready),
                makeCheck(id: .backup, status: .info)
            ]
        )

        let presentation = ProjectHealthPresentation(preflight: preflight)

        XCTAssertTrue(presentation.attentionChecks.isEmpty)
        XCTAssertEqual(presentation.otherChecks.map(\.id), [.bdCLI, .backup])
        XCTAssertNil(presentation.summaryBadgeStatus)
        XCTAssertEqual(presentation.checksDisclosureTitle, "View All Checks")
    }

    func testMixedPresentationKeepsWarningBlockedAndCheckingRowsVisible() {
        let preflight = makePreflight(
            status: .blocked,
            checks: [
                makeCheck(id: .bdCLI, status: .blocked),
                makeCheck(id: .readableData, status: .ready),
                makeCheck(id: .snapshotFreshness, status: .warning),
                makeCheck(id: .exportConfiguration, status: .checking),
                makeCheck(id: .gitHooks, status: .info)
            ]
        )

        let presentation = ProjectHealthPresentation(preflight: preflight)

        XCTAssertEqual(
            presentation.attentionChecks.map(\.id),
            [.bdCLI, .snapshotFreshness, .exportConfiguration]
        )
        XCTAssertEqual(presentation.otherChecks.map(\.id), [.readableData, .gitHooks])
        XCTAssertEqual(presentation.summaryBadgeStatus, .blocked)
        XCTAssertEqual(presentation.checksDisclosureTitle, "Other Checks")
    }

    func testBadgePolicyOnlyHighlightsStatesThatNeedAttention() {
        XCTAssertFalse(ProjectPreflightHealth.Status.ready.requiresAttention)
        XCTAssertFalse(ProjectPreflightHealth.Status.info.requiresAttention)
        XCTAssertTrue(ProjectPreflightHealth.Status.warning.requiresAttention)
        XCTAssertTrue(ProjectPreflightHealth.Status.blocked.requiresAttention)
        XCTAssertTrue(ProjectPreflightHealth.Status.checking.requiresAttention)
    }

    private func makePreflight(
        status: ProjectPreflightHealth.Status,
        checks: [ProjectPreflightHealth.Check]
    ) -> ProjectPreflightHealth {
        ProjectPreflightHealth(
            status: status,
            title: "Status",
            summary: "Summary",
            checks: checks
        )
    }

    private func makeCheck(
        id: ProjectPreflightHealth.CheckID,
        status: ProjectPreflightHealth.Status
    ) -> ProjectPreflightHealth.Check {
        ProjectPreflightHealth.Check(
            id: id,
            title: id.rawValue,
            status: status,
            summary: "Summary",
            detail: nil,
            actionHint: nil
        )
    }
}
