import XCTest
@testable import Beadazzle

final class IssueActivityTimelineTests: XCTestCase {
    private let semantics = BeadProjectSemantics(
        statuses: [
            BeadStatusDefinition(name: "open", category: .active),
            BeadStatusDefinition(name: "in_progress", category: .wip),
            BeadStatusDefinition(name: "closed", category: .done)
        ],
        types: []
    )

    private func makeIssue(
        id: String = "bd-a",
        title: String = "Title",
        issueType: String = "task",
        status: String = "open",
        createdAt: Date? = Date(timeIntervalSince1970: 1_000),
        createdBy: String? = "ransom",
        updatedAt: Date? = nil,
        closedAt: Date? = nil,
        closeReason: String? = nil
    ) -> BeadIssue {
        BeadIssue(
            id: id,
            title: title,
            description: "",
            design: "",
            acceptanceCriteria: "",
            notes: "",
            status: status,
            priority: 2,
            issueType: issueType,
            assignee: nil,
            owner: "owner@example.com",
            createdAt: createdAt,
            createdBy: createdBy,
            updatedAt: updatedAt,
            closedAt: closedAt,
            closeReason: closeReason,
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

    private func event(
        id: String,
        at seconds: TimeInterval,
        field: String = "status",
        old: String? = nil,
        new: String? = nil,
        reason: String? = nil
    ) -> BeadIssueEvent {
        BeadIssueEvent(
            id: id,
            issueID: "bd-a",
            kind: "field_change",
            actor: "Beadazzle",
            createdAt: Date(timeIntervalSince1970: seconds),
            field: field,
            oldValue: old,
            newValue: new,
            reason: reason
        )
    }

    private func comment(id: String, at seconds: TimeInterval) -> BeadComment {
        BeadComment(
            id: id,
            issueID: "bd-a",
            author: "ransom",
            text: "A comment",
            createdAt: Date(timeIntervalSince1970: seconds),
            updatedAt: nil
        )
    }

    func testMergesEventsAndCommentsOldestFirstWithSynthesizedCreation() {
        let items = IssueActivityTimeline.items(
            issue: makeIssue(),
            events: [event(id: "int-1", at: 3_000, old: "open", new: "in_progress")],
            comments: [comment(id: "c-1", at: 2_000)],
            semantics: semantics
        )

        XCTAssertEqual(items.count, 3)
        guard case .event(let created) = items[0] else { return XCTFail("Expected created event first") }
        XCTAssertEqual(created.message, "created this bead")
        XCTAssertEqual(created.actor, "ransom")
        guard case .comment(let mergedComment) = items[1] else { return XCTFail("Expected comment second") }
        XCTAssertEqual(mergedComment.id, "c-1")
        guard case .event(let statusChange) = items[2] else { return XCTFail("Expected status event last") }
        XCTAssertEqual(statusChange.message, "changed status from open to in_progress")
    }

    func testCloseAndReopenTransitionsUseDedicatedPhrasing() {
        let items = IssueActivityTimeline.items(
            issue: makeIssue(status: "closed", closedAt: Date(timeIntervalSince1970: 4_000)),
            events: [
                event(id: "int-1", at: 2_000, old: "open", new: "closed", reason: "Shipped it."),
                event(id: "int-2", at: 3_000, old: "closed", new: "open"),
                event(id: "int-3", at: 4_000, old: "open", new: "closed")
            ],
            comments: [],
            semantics: semantics
        )

        let messages = items.compactMap { item -> String? in
            guard case .event(let event) = item else { return nil }
            return event.message
        }
        XCTAssertEqual(messages, [
            "created this bead",
            "closed this bead",
            "reopened this bead",
            "closed this bead"
        ])
        guard case .event(let close) = items[1] else { return XCTFail("Expected close event") }
        XCTAssertEqual(close.reason, "Shipped it.")
        // A logged close means no synthesized close entry is appended.
        XCTAssertEqual(items.count, 4)
    }

    func testSynthesizesCloseEntryWhenLogPredatesTheClose() {
        let items = IssueActivityTimeline.items(
            issue: makeIssue(
                status: "closed",
                closedAt: Date(timeIntervalSince1970: 5_000),
                closeReason: "Fixed upstream."
            ),
            events: [],
            comments: [],
            semantics: semantics
        )

        XCTAssertEqual(items.count, 2)
        guard case .event(let close) = items[1] else { return XCTFail("Expected synthesized close") }
        XCTAssertEqual(close.message, "closed this bead")
        XCTAssertEqual(close.reason, "Fixed upstream.")
        XCTAssertEqual(close.date, Date(timeIntervalSince1970: 5_000))
    }

    func testDoesNotSynthesizeCloseForOpenIssues() {
        let items = IssueActivityTimeline.items(
            issue: makeIssue(),
            events: [],
            comments: [],
            semantics: semantics
        )
        XCTAssertEqual(items.count, 1)
    }

    func testSynthesizesMissingReopenWhenSnapshotIsActive() {
        let items = IssueActivityTimeline.items(
            issue: makeIssue(status: "open", updatedAt: Date(timeIntervalSince1970: 4_000)),
            events: [event(id: "int-close", at: 2_000, old: "open", new: "closed")],
            comments: [],
            semantics: semantics
        )

        let presentations = items.compactMap { item -> IssueActivityEventPresentation? in
            guard case .event(let presentation) = item else { return nil }
            return presentation
        }
        XCTAssertEqual(presentations.map(\.message), [
            "created this bead", "closed this bead", "reopened this bead"
        ])
        XCTAssertEqual(presentations.last?.id, "synthesized-reopened-bd-a")
        XCTAssertEqual(presentations.last?.date, Date(timeIntervalSince1970: 4_000))
    }

    func testSynthesizesMissingRecloseAfterLatestLoggedReopen() {
        let items = IssueActivityTimeline.items(
            issue: makeIssue(
                status: "closed",
                // A later metadata edit must not move the reconstructed close.
                updatedAt: Date(timeIntervalSince1970: 6_000),
                closedAt: Date(timeIntervalSince1970: 5_000),
                closeReason: "Finally done."
            ),
            events: [
                event(id: "int-close", at: 2_000, old: "open", new: "closed"),
                event(id: "int-reopen", at: 3_000, old: "closed", new: "open")
            ],
            comments: [],
            semantics: semantics
        )

        let presentations = items.compactMap { item -> IssueActivityEventPresentation? in
            guard case .event(let presentation) = item else { return nil }
            return presentation
        }
        XCTAssertEqual(presentations.map(\.message), [
            "created this bead", "closed this bead", "reopened this bead", "closed this bead"
        ])
        XCTAssertEqual(presentations.last?.id, "synthesized-closed-bd-a")
        XCTAssertEqual(presentations.last?.reason, "Finally done.")
        XCTAssertEqual(presentations.last?.date, Date(timeIntervalSince1970: 5_000))
    }

    func testUnknownCreatorIsNotMisattributedToOwner() {
        let items = IssueActivityTimeline.items(
            issue: makeIssue(createdBy: nil),
            events: [],
            comments: [],
            semantics: semantics
        )

        guard case .event(let creation) = items[0] else { return XCTFail("Expected creation") }
        XCTAssertNil(creation.actor)
    }

    func testEqualTimestampsPreserveInputOrder() {
        let items = IssueActivityTimeline.items(
            issue: makeIssue(),
            events: [
                event(id: "z-first", at: 2_000, field: "priority", old: "2", new: "1"),
                event(id: "a-second", at: 2_000, field: "assignee", new: "ransom")
            ],
            comments: [],
            semantics: semantics
        )

        let ids = items.compactMap { item -> String? in
            guard case .event(let presentation) = item else { return nil }
            return presentation.id
        }
        XCTAssertEqual(ids, ["synthesized-created-bd-a", "z-first", "a-second"])
    }

    func testUncategorizedClosedStatusStillReadsAsClose() {
        let bareSemantics = BeadProjectSemantics.empty
        let items = IssueActivityTimeline.items(
            issue: makeIssue(status: "closed"),
            events: [event(id: "int-1", at: 2_000, old: "open", new: "closed")],
            comments: [],
            semantics: bareSemantics
        )

        guard case .event(let close) = items[1] else { return XCTFail("Expected close event") }
        XCTAssertEqual(close.message, "closed this bead")
    }

    func testDependencyEdgesBecomeEventsOnBothEndpoints() {
        let issue = makeIssue()
        let child = makeIssue(id: "bd-child", title: "The child")
        let blocker = makeIssue(id: "bd-blocker", title: "The blocker")
        let others = [child.id: child, blocker.id: blocker]
        let dependencies = [
            BeadDependency(
                issueID: "bd-child",
                dependsOnID: "bd-a",
                type: "parent-child",
                createdAt: Date(timeIntervalSince1970: 2_000),
                createdBy: "ransom"
            ),
            BeadDependency(
                issueID: "bd-a",
                dependsOnID: "bd-blocker",
                type: "blocks",
                createdAt: Date(timeIntervalSince1970: 3_000),
                createdBy: "ransom"
            ),
            BeadDependency(
                issueID: "bd-related",
                dependsOnID: "bd-a",
                type: "related",
                createdAt: Date(timeIntervalSince1970: 4_000)
            )
        ]

        let items = IssueActivityTimeline.items(
            issue: issue,
            events: [],
            comments: [],
            dependencies: dependencies,
            semantics: semantics,
            resolveIssue: { others[$0] }
        )

        let phrases = items.compactMap { item -> String? in
            guard case .event(let event) = item else { return nil }
            return [event.message, event.reference?.displayText].compactMap { $0 }.joined(separator: " | ")
        }
        // "related" edges are skipped; only hierarchy, blocking, and discovery read as
        // activity. The blocker is open, so no unblocked entry appears.
        XCTAssertEqual(phrases, [
            "created this bead",
            "added child bead | bd-child The child",
            "marked this bead as blocked by | bd-blocker The blocker"
        ])
        guard case .event(let childEvent) = items[1] else { return XCTFail("Expected child event") }
        XCTAssertEqual(childEvent.actor, "ransom")
        XCTAssertEqual(childEvent.reference?.issueID, "bd-child")
    }

    func testDependencyDateCannotPrecedeEitherEndpointCreation() {
        let issue = makeIssue(createdAt: Date(timeIntervalSince1970: 2_000))
        let child = makeIssue(
            id: "bd-child",
            title: "The child",
            createdAt: Date(timeIntervalSince1970: 3_000)
        )
        let dependency = BeadDependency(
            issueID: child.id,
            dependsOnID: issue.id,
            type: "parent-child",
            createdAt: Date(timeIntervalSince1970: 1_000),
            createdBy: "ransom"
        )

        let items = IssueActivityTimeline.items(
            issue: issue,
            events: [],
            comments: [],
            dependencies: [dependency],
            semantics: semantics,
            resolveIssue: { $0 == child.id ? child : nil }
        )

        guard case .event(let relationship) = items[1] else {
            return XCTFail("Expected relationship after creation")
        }
        XCTAssertEqual(relationship.date, Date(timeIntervalSince1970: 3_000))
    }

    func testChildAndBlockerPerspectivesReadFromTheOtherSide() {
        let child = makeIssue(id: "bd-child")
        let parent = makeIssue(id: "bd-a", title: "The parent")
        let gate = makeIssue(id: "bd-gate", title: "Deploy gate", issueType: BeadProjectIndex.gateIssueType)
        let others = [parent.id: parent, gate.id: gate]
        let dependencies = [
            BeadDependency(
                issueID: "bd-child",
                dependsOnID: "bd-a",
                type: "parent-child",
                createdAt: Date(timeIntervalSince1970: 2_000)
            ),
            BeadDependency(
                issueID: "bd-child",
                dependsOnID: "bd-gate",
                type: "blocks",
                createdAt: Date(timeIntervalSince1970: 3_000)
            ),
            BeadDependency(
                issueID: "bd-blocked",
                dependsOnID: "bd-child",
                type: "blocks",
                createdAt: Date(timeIntervalSince1970: 4_000)
            )
        ]

        let items = IssueActivityTimeline.items(
            issue: child,
            events: [],
            comments: [],
            dependencies: dependencies,
            semantics: semantics,
            resolveIssue: { others[$0] }
        )

        let phrases = items.compactMap { item -> String? in
            guard case .event(let event) = item else { return nil }
            return [event.message, event.reference?.displayText].compactMap { $0 }.joined(separator: " | ")
        }
        // "bd-blocked" is unresolved, so its reference degrades to the bare id.
        XCTAssertEqual(phrases, [
            "created this bead",
            "set the parent to | bd-a The parent",
            "gated this bead behind | bd-gate Deploy gate",
            "marked this bead as blocking | bd-blocked"
        ])
    }

    func testBlockerCloseSynthesizesUnblockedEntry() {
        let issue = makeIssue()
        let blocker = makeIssue(
            id: "bd-blocker",
            title: "The blocker",
            status: "closed",
            closedAt: Date(timeIntervalSince1970: 6_000)
        )
        let dependencies = [
            BeadDependency(
                issueID: "bd-a",
                dependsOnID: "bd-blocker",
                type: "blocks",
                createdAt: Date(timeIntervalSince1970: 2_000),
                createdBy: "ransom"
            )
        ]

        let items = IssueActivityTimeline.items(
            issue: issue,
            events: [],
            comments: [],
            dependencies: dependencies,
            semantics: semantics,
            resolveIssue: { $0 == blocker.id ? blocker : nil }
        )

        XCTAssertEqual(items.count, 3)
        guard case .event(let unblocked) = items[2] else { return XCTFail("Expected unblocked event last") }
        XCTAssertEqual(unblocked.message, "no longer blocked by")
        XCTAssertEqual(unblocked.standaloneMessage, "No longer blocked by")
        XCTAssertEqual(unblocked.reference?.displayText, "bd-blocker The blocker")
        XCTAssertEqual(unblocked.date, Date(timeIntervalSince1970: 6_000))
        XCTAssertNil(unblocked.actor)
    }

    func testDiscoveredFromEdgesReadFromBothSides() {
        let source = makeIssue(id: "bd-src", title: "The source")
        let discovered = makeIssue(id: "bd-a")
        let dependency = BeadDependency(
            issueID: "bd-a",
            dependsOnID: "bd-src",
            type: "discovered-from",
            createdAt: Date(timeIntervalSince1970: 2_000),
            createdBy: "ransom"
        )

        let discoveredItems = IssueActivityTimeline.items(
            issue: discovered,
            events: [],
            comments: [],
            dependencies: [dependency],
            semantics: semantics,
            resolveIssue: { $0 == source.id ? source : nil }
        )
        guard case .event(let forward) = discoveredItems[1] else { return XCTFail("Expected discovery event") }
        XCTAssertEqual(forward.message, "discovered while working on")
        XCTAssertEqual(forward.reference?.displayText, "bd-src The source")

        let sourceItems = IssueActivityTimeline.items(
            issue: source,
            events: [],
            comments: [],
            dependencies: [dependency],
            semantics: semantics,
            resolveIssue: { $0 == discovered.id ? discovered : nil }
        )
        guard case .event(let reverse) = sourceItems[1] else { return XCTFail("Expected discovery event") }
        XCTAssertEqual(reverse.message, "led to discovering")
        XCTAssertEqual(reverse.reference?.issueID, "bd-a")
    }

    func testStandaloneMessageCapitalizesActorlessEvents() {
        let items = IssueActivityTimeline.items(
            issue: makeIssue(
                status: "closed",
                closedAt: Date(timeIntervalSince1970: 5_000),
                closeReason: "Done."
            ),
            events: [],
            comments: [],
            semantics: semantics
        )
        guard case .event(let close) = items[1] else { return XCTFail("Expected synthesized close") }
        XCTAssertNil(close.actor)
        XCTAssertEqual(close.standaloneMessage, "Closed this bead")
    }

    func testTitleAndProseFieldChangesUseFriendlyPhrasing() {
        let items = IssueActivityTimeline.items(
            issue: makeIssue(),
            events: [
                event(id: "int-1", at: 2_000, field: "title", old: "Old name", new: "New name"),
                event(id: "int-2", at: 3_000, field: "description", old: "Long old body", new: "Long new body")
            ],
            comments: [],
            semantics: semantics
        )

        let messages = items.compactMap { item -> String? in
            guard case .event(let event) = item, !event.message.hasPrefix("created") else { return nil }
            return event.message
        }
        XCTAssertEqual(messages, [
            "renamed this bead from “Old name” to “New name”",
            "updated the description"
        ])
    }

    func testNonStatusFieldChangesUseGenericPhrasing() {
        let items = IssueActivityTimeline.items(
            issue: makeIssue(),
            events: [
                event(id: "int-1", at: 2_000, field: "priority", old: "2", new: "1"),
                event(id: "int-2", at: 3_000, field: "assignee", new: "ransom"),
                event(id: "int-3", at: 4_000, field: "due_at", old: "2026-07-01")
            ],
            comments: [],
            semantics: semantics
        )

        let messages = items.compactMap { item -> String? in
            guard case .event(let event) = item, !event.message.hasPrefix("created") else { return nil }
            return event.message
        }
        XCTAssertEqual(messages, [
            "changed priority from 2 to 1",
            "set assignee to ransom",
            "removed due at (was 2026-07-01)"
        ])
    }
}
