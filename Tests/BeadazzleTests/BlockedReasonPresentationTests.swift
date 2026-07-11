import XCTest
@testable import Beadazzle

final class BlockedReasonPresentationTests: XCTestCase {
    func testActiveIssueBlockerPresentation() throws {
        let blocker = BlockedReasonPresentation.Blocker.issue(issue("bd-blocker", title: "Fix crawler"))

        let presentation = try XCTUnwrap(BlockedReasonPresentation.active(blockers: [blocker]))

        XCTAssertEqual(presentation.kind, .issue)
        XCTAssertEqual(presentation.title, "Blocked by bd-blocker: Fix crawler")
        XCTAssertEqual(presentation.systemImage, BeadIconography.blockedBy)
        XCTAssertEqual(presentation.tint, .secondary)
        XCTAssertEqual(presentation.help, "bd-blocker: Fix crawler")
    }

    func testActiveGateBlockerPresentation() throws {
        let gate = gate(.human, reason: "Need design sign-off")
        let blocker = BlockedReasonPresentation.Blocker.gate(gate, now: Date(timeIntervalSince1970: 1_000))

        let presentation = try XCTUnwrap(BlockedReasonPresentation.active(blockers: [blocker]))

        XCTAssertEqual(presentation.kind, .gate)
        XCTAssertEqual(presentation.title, "Waiting on Awaiting approval")
        XCTAssertEqual(presentation.systemImage, BeadIconography.humanGate)
        XCTAssertEqual(presentation.tint, .action)
        XCTAssertTrue(presentation.help.contains("Gate g-1: Awaiting approval"))
        XCTAssertTrue(presentation.help.contains("Reason: Need design sign-off"))
    }

    func testMultipleBlockerPresentation() throws {
        let blockers = [
            BlockedReasonPresentation.Blocker.issue(issue("bd-a", title: "Alpha")),
            BlockedReasonPresentation.Blocker.issue(issue("bd-b", title: "Beta"))
        ]

        let presentation = try XCTUnwrap(BlockedReasonPresentation.active(blockers: blockers))

        XCTAssertEqual(presentation.kind, .multiple)
        XCTAssertEqual(presentation.title, "Blocked by 2 blockers: bd-a: Alpha")
        XCTAssertEqual(presentation.systemImage, BeadIconography.blockedBy)
        XCTAssertTrue(presentation.help.contains("- bd-a: Alpha"))
        XCTAssertTrue(presentation.help.contains("- bd-b: Beta"))
    }

    func testExternalBlockerPresentation() throws {
        let blocker = BlockedReasonPresentation.Blocker.external(reference: "external:project:capability")

        let presentation = try XCTUnwrap(BlockedReasonPresentation.active(blockers: [blocker]))

        XCTAssertEqual(presentation.kind, .external)
        XCTAssertEqual(presentation.title, "Blocked by external reference")
        XCTAssertEqual(presentation.systemImage, BeadIconography.externalReference)
        XCTAssertEqual(presentation.tint, .warning)
        XCTAssertTrue(presentation.help.contains("external:project:capability"))
    }

    func testResolvedGatePresentation() throws {
        let gate = gate(.githubPR, status: "closed", reason: "PR merged", awaitID: "42")

        let presentation = try XCTUnwrap(BlockedReasonPresentation.resolvedGate(
            gates: [gate],
            now: Date(timeIntervalSince1970: 1_000)
        ))

        XCTAssertEqual(presentation.kind, .resolvedGate)
        XCTAssertEqual(presentation.title, "Resolved gate; status still blocked")
        XCTAssertEqual(presentation.systemImage, "checkmark.seal")
        XCTAssertEqual(presentation.tint, .resolved)
        XCTAssertTrue(presentation.help.contains("Gate g-1: Awaiting PR #42"))
        XCTAssertTrue(presentation.help.contains("Reason: PR merged"))
    }

    func testUnexplainedPresentation() {
        let presentation = BlockedReasonPresentation.unexplained

        XCTAssertEqual(presentation.kind, .unexplained)
        XCTAssertEqual(presentation.title, "Marked blocked; no active blocker found")
        XCTAssertEqual(presentation.systemImage, "questionmark.circle")
        XCTAssertEqual(presentation.tint, .unexplained)
    }

    func testSubissueBlockerPresentation() {
        let child = issue("bd-child", title: "Child task")
        let blocker = BlockedReasonPresentation.Blocker.issue(issue("bd-blocker", title: "Fix crawler"))

        let presentation = BlockedReasonPresentation.subissue(child, blockers: [blocker])

        XCTAssertEqual(presentation.kind, .subissue)
        XCTAssertEqual(presentation.title, "Sub-issue blocked by bd-blocker: Fix crawler")
        XCTAssertEqual(presentation.systemImage, BeadIconography.children)
        XCTAssertEqual(presentation.tint, .secondary)
        XCTAssertTrue(presentation.help.contains("Sub-issue bd-child: Child task"))
        XCTAssertTrue(presentation.help.contains("bd-blocker: Fix crawler"))
    }

    func testResolvedGateAttentionPresentationOffersReopen() throws {
        let gate = gate(.githubPR, status: "closed", reason: "PR merged", awaitID: "42")
        let reason = try XCTUnwrap(BlockedReasonPresentation.resolvedGate(
            gates: [gate],
            now: Date(timeIntervalSince1970: 1_000)
        ))

        let presentation = try XCTUnwrap(BlockedActionPresentation.make(issueID: "bd-stale", reason: reason))

        XCTAssertEqual(presentation.kind, .resolvedGate)
        XCTAssertEqual(presentation.message, "Gate resolved; status still blocked.")
        XCTAssertEqual(presentation.actions, [.reopen])
    }

    func testNoActiveGateAttentionPresentationOffersGateCreationAndReopen() throws {
        let presentation = try XCTUnwrap(BlockedActionPresentation.make(
            issueID: "bd-manual",
            reason: .unexplained
        ))

        XCTAssertEqual(presentation.kind, .noActiveGate)
        XCTAssertEqual(presentation.message, "Marked blocked with no active gate.")
        XCTAssertEqual(presentation.actions, [.createTimer, .createDecision, .reopen])
    }

    func testNoActiveGateAttentionPresentationOmitsGateActionsWhenUnsupported() throws {
        let presentation = try XCTUnwrap(BlockedActionPresentation.make(
            issueID: "bd-epic",
            reason: .unexplained,
            canCreateGate: false
        ))

        XCTAssertEqual(presentation.kind, .noActiveGate)
        XCTAssertEqual(presentation.message, "Marked blocked with no active gate.")
        XCTAssertEqual(presentation.actions, [.reopen])
    }

    func testActiveDecisionGateAttentionPresentationOffersApproveAndReject() throws {
        let gate = gate(.human, reason: "Need design sign-off")
        let blocker = BlockedReasonPresentation.Blocker.gate(gate, now: Date(timeIntervalSince1970: 1_000))
        let reason = try XCTUnwrap(BlockedReasonPresentation.active(blockers: [blocker]))

        let presentation = try XCTUnwrap(BlockedActionPresentation.make(
            issueID: "bd-gated",
            reason: reason,
            readyDecisionGate: gate
        ))

        XCTAssertEqual(presentation.kind, .awaitingApproval)
        XCTAssertEqual(presentation.gateID, "g-1")
        XCTAssertEqual(presentation.message, "Waiting on Gate — needs your decision.")
        XCTAssertEqual(presentation.actions, [.approve, .reject])
    }

    func testActiveGateWithoutReadyDecisionGateDoesNotCreateAttentionPresentation() throws {
        let gate = gate(.timer)
        let blocker = BlockedReasonPresentation.Blocker.gate(gate, now: Date(timeIntervalSince1970: 1_000))
        let reason = try XCTUnwrap(BlockedReasonPresentation.active(blockers: [blocker]))

        XCTAssertNil(BlockedActionPresentation.make(issueID: "bd-gated", reason: reason))
    }

    func testActiveBlockerPresentationDoesNotCreateAttentionPresentation() throws {
        let blocker = BlockedReasonPresentation.Blocker.issue(issue("bd-blocker", title: "Fix crawler"))
        let reason = try XCTUnwrap(BlockedReasonPresentation.active(blockers: [blocker]))

        XCTAssertNil(BlockedActionPresentation.make(issueID: "bd-blocked", reason: reason))
    }

    func testSubissueBlockerPresentationDoesNotCreateAttentionPresentation() {
        let reason = BlockedReasonPresentation.subissue(issue("bd-child", title: "Child task"), blockers: [])

        XCTAssertNil(BlockedActionPresentation.make(issueID: "bd-parent", reason: reason))
    }

    private func issue(_ id: String, title: String) -> BeadIssue {
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

    private func gate(
        _ awaitType: GateAwaitType,
        status: String = "open",
        reason: String? = nil,
        awaitID: String? = nil
    ) -> BeadGate {
        BeadGate(
            id: "g-1",
            title: "Gate",
            awaitType: awaitType,
            status: status,
            reason: reason,
            awaitID: awaitID,
            timeoutNanoseconds: nil,
            createdAt: nil,
            updatedAt: nil,
            waiters: [],
            blocksIssueID: "bd-target"
        )
    }
}
