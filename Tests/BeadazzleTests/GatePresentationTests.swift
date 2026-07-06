import XCTest
@testable import Beadazzle

final class GatePresentationTests: XCTestCase {
    func testConditionHeadlineForHumanAndGitHubGates() {
        XCTAssertEqual(GatePresentation.conditionHeadline(for: gate(.human)), "Awaiting approval")
        XCTAssertEqual(GatePresentation.conditionHeadline(for: gate(.githubPR, awaitID: "42")), "Awaiting PR #42")
        XCTAssertEqual(GatePresentation.conditionHeadline(for: gate(.githubPR)), "Awaiting PR merge")
        XCTAssertEqual(GatePresentation.conditionHeadline(for: gate(.githubRun, awaitID: "7")), "Awaiting run #7")
        XCTAssertEqual(GatePresentation.conditionHeadline(for: gate(.githubRun)), "Awaiting CI run")
        XCTAssertEqual(GatePresentation.conditionHeadline(for: gate(.other("quantum"))), "quantum")
    }

    func testConditionHeadlineForTimerReflectsExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let oneHour: Int64 = 3_600_000_000_000

        let pending = gate(.timer, createdAt: now, timeoutNanoseconds: oneHour)
        XCTAssertTrue(
            GatePresentation.conditionHeadline(for: pending, now: now).hasPrefix("Expires"),
            "a not-yet-expired timer should read as pending"
        )

        let elapsed = gate(.timer, createdAt: now.addingTimeInterval(-7200), timeoutNanoseconds: oneHour)
        XCTAssertEqual(GatePresentation.conditionHeadline(for: elapsed, now: now), "Timer elapsed")

        let noTimeout = gate(.timer)
        XCTAssertEqual(GatePresentation.conditionHeadline(for: noTimeout, now: now), "Timer gate")
    }

    func testBlockingDependencyPredicateIsCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(dependency(type: "blocks").isBlocking)
        XCTAssertTrue(dependency(type: " Blocks ").isBlocking)
        XCTAssertFalse(dependency(type: "parent-child").isBlocking)
        XCTAssertFalse(dependency(type: "related").isBlocking)
    }

    // MARK: - Fixtures

    private func gate(
        _ awaitType: GateAwaitType,
        awaitID: String? = nil,
        createdAt: Date? = nil,
        timeoutNanoseconds: Int64? = nil
    ) -> BeadGate {
        BeadGate(
            id: "g-1",
            title: "Gate",
            awaitType: awaitType,
            status: "open",
            reason: nil,
            awaitID: awaitID,
            timeoutNanoseconds: timeoutNanoseconds,
            createdAt: createdAt,
            updatedAt: nil,
            waiters: [],
            blocksIssueID: nil
        )
    }

    private func dependency(type: String) -> BeadDependency {
        BeadDependency(issueID: "a", dependsOnID: "b", type: type, createdAt: nil)
    }
}
