import CoreGraphics
import XCTest
@testable import Beadazzle

@MainActor
final class BeadFindSessionTests: XCTestCase {
    private static let prefix = "bd-42"
    private static let projectKey = "/tmp/project-a"

    private final class FindTrafficCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var queriesOnA = 0
        private var queriesOnB = 0
        private var clearsOnB = 0

        func recordQueryOnA() {
            lock.withLock { queriesOnA += 1 }
        }

        func recordQueryOnB() {
            lock.withLock { queriesOnB += 1 }
        }

        func recordClearOnB() {
            lock.withLock { clearsOnB += 1 }
        }

        func snapshot() -> (queriesOnA: Int, queriesOnB: Int, clearsOnB: Int) {
            lock.withLock { (queriesOnA, queriesOnB, clearsOnB) }
        }
    }

    private static func scope(
        prefix: String = "bd-42",
        projectKey: String = "/tmp/project-a"
    ) -> BeadFindScope {
        BeadFindScope(projectKey: projectKey, documentIDPrefix: prefix)
    }

    /// Records what the session would post to the markdown engine.
    @MainActor
    private final class RecordingDispatcher: BeadFindDispatching {
        var requests: [BeadFindRequest] = []
        var clearCount = 0

        func send(_ request: BeadFindRequest) {
            requests.append(request)
        }

        func clearHighlights() {
            clearCount += 1
        }
    }

    /// Answers for every field synchronously from inside `send`, the way the
    /// engine's main-queue observers can when the post happens on the main
    /// thread. This is the ordering that used to leave a settle deadline armed
    /// behind already-completed work.
    @MainActor
    private final class SynchronousReplyDispatcher: BeadFindDispatching {
        weak var session: BeadFindSession?
        var repliesEnabled = true

        func send(_ request: BeadFindRequest) {
            guard repliesEnabled, let session else { return }
            for section in BeadFindSession.sectionOrder {
                session.ingest(
                    documentID: section.documentID(prefix: BeadFindSessionTests.prefix),
                    matchedQuery: request.text,
                    count: section == .description ? 2 : 0,
                    matchRect: nil,
                    token: request.token
                )
            }
        }

        func clearHighlights() {}
    }

    private func makeSession() -> (BeadFindSession, RecordingDispatcher) {
        let dispatcher = RecordingDispatcher()
        // Zero debounce so a query reaches the dispatcher synchronously, and no
        // settle deadline so results settle only when every field replies.
        let session = BeadFindSession(
            debounce: .zero,
            settleGrace: .zero,
            dispatcher: dispatcher
        )
        session.open(scope: Self.scope())
        trackedDispatcher = dispatcher
        return (session, dispatcher)
    }

    private func documentID(_ section: IssueTextSection) -> String {
        section.documentID(prefix: Self.prefix)
    }

    /// Reply on behalf of every field, in the order given, echoing the token
    /// from the request the session actually posted — as the engine does.
    private func reply(
        to session: BeadFindSession,
        query: String,
        counts: [(IssueTextSection, Int)],
        rects: [IssueTextSection: CGRect] = [:],
        token: Int? = nil,
        dispatcher: RecordingDispatcher? = nil
    ) {
        let echoed = token ?? dispatcher?.requests.last?.token ?? lastToken
        for (section, count) in counts {
            session.ingest(
                documentID: documentID(section),
                matchedQuery: query,
                count: count,
                matchRect: rects[section],
                token: echoed
            )
        }
    }

    /// Token of the most recent request any dispatcher in this test recorded.
    private var lastToken: Int? { trackedDispatcher?.requests.last?.token }
    private weak var trackedDispatcher: RecordingDispatcher?

    func testQueryIsPostedWithTheFirstFieldFocusedBeforeAnyCountsArrive() {
        let (session, dispatcher) = makeSession()

        session.query = "widget"

        XCTAssertEqual(dispatcher.requests.count, 1)
        XCTAssertEqual(dispatcher.requests.first?.text, "widget")
        XCTAssertEqual(dispatcher.requests.first?.focusDocumentID, documentID(.description))
        XCTAssertEqual(dispatcher.requests.first?.focusIndex, 0)
    }

    func testFindUsesVisibleSectionsInTheirDisplayOrder() {
        let dispatcher = RecordingDispatcher()
        let session = BeadFindSession(
            debounce: .zero,
            settleGrace: .zero,
            dispatcher: dispatcher
        )
        session.open(scope: BeadFindScope(
            projectKey: Self.projectKey,
            documentIDPrefix: Self.prefix,
            sectionOrder: [.notes, .description]
        ))

        session.query = "widget"
        XCTAssertEqual(dispatcher.requests.last?.focusDocumentID, documentID(.notes))

        reply(to: session, query: "widget", counts: [
            (.notes, 0),
            (.description, 2)
        ], dispatcher: dispatcher)

        XCTAssertTrue(session.isSettled)
        XCTAssertEqual(session.totalMatchCount, 2)
        XCTAssertEqual(session.focusTarget?.section, .description)
    }

    func testTotalIsTheSumOfEveryFieldsCount() {
        let (session, _) = makeSession()
        session.query = "widget"

        reply(to: session, query: "widget", counts: [
            (.description, 2),
            (.acceptanceCriteria, 1),
            (.design, 0),
            (.notes, 4)
        ])

        XCTAssertEqual(session.totalMatchCount, 7)
        XCTAssertEqual(session.focusedMatchIndex, 0)
        XCTAssertEqual(session.matchSummary, "1 of 7")
    }

    func testGlobalIndexMapsOntoTheOwningFieldAndSkipsEmptyOnes() {
        let (session, _) = makeSession()
        session.query = "widget"
        reply(to: session, query: "widget", counts: [
            (.description, 2),
            (.acceptanceCriteria, 0),
            (.design, 3),
            (.notes, 1)
        ])

        // 0,1 → description; 2,3,4 → design (acceptanceCriteria contributes
        // nothing and must not consume a position); 5 → notes.
        let expected: [(Int, IssueTextSection, Int)] = [
            (0, .description, 0),
            (1, .description, 1),
            (2, .design, 0),
            (3, .design, 1),
            (4, .design, 2),
            (5, .notes, 0)
        ]

        for (globalIndex, section, localIndex) in expected {
            while (session.focusedMatchIndex ?? 0) < globalIndex {
                session.moveToNextMatch()
            }
            XCTAssertEqual(session.focusedMatchIndex, globalIndex)
            XCTAssertEqual(session.focusTarget?.section, section, "global index \(globalIndex)")
            XCTAssertEqual(session.focusTarget?.localIndex, localIndex, "global index \(globalIndex)")
        }
    }

    func testNextWrapsFromTheLastMatchToTheFirst() {
        let (session, _) = makeSession()
        session.query = "widget"
        reply(to: session, query: "widget", counts: [
            (.description, 1),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 1)
        ])

        session.moveToNextMatch()
        XCTAssertEqual(session.focusedMatchIndex, 1)
        XCTAssertEqual(session.focusTarget?.section, .notes)

        session.moveToNextMatch()
        XCTAssertEqual(session.focusedMatchIndex, 0)
        XCTAssertEqual(session.focusTarget?.section, .description)
    }

    func testPreviousWrapsFromTheFirstMatchToTheLast() {
        let (session, _) = makeSession()
        session.query = "widget"
        reply(to: session, query: "widget", counts: [
            (.description, 2),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 1)
        ])

        session.moveToPreviousMatch()

        XCTAssertEqual(session.focusedMatchIndex, 2)
        XCTAssertEqual(session.focusTarget?.section, .notes)
        XCTAssertEqual(session.matchSummary, "3 of 3")
    }

    func testRepliesArrivingOutOfOrderStillProduceTheCorrectTotal() {
        let (session, _) = makeSession()
        session.query = "widget"

        reply(to: session, query: "widget", counts: [
            (.notes, 4),
            (.design, 0),
            (.description, 2),
            (.acceptanceCriteria, 1)
        ])

        XCTAssertEqual(session.totalMatchCount, 7)
        // Document order still decides where global index 0 lives, not the
        // order the replies happened to arrive in.
        XCTAssertEqual(session.focusTarget?.section, .description)
        XCTAssertEqual(session.focusTarget?.localIndex, 0)
    }

    func testRepliesForASupersededQueryAreDiscarded() {
        let (session, _) = makeSession()
        session.query = "widget"
        session.query = "gadget"

        reply(to: session, query: "widget", counts: [
            (.description, 9),
            (.acceptanceCriteria, 9),
            (.design, 9),
            (.notes, 9)
        ])

        XCTAssertEqual(session.totalMatchCount, 0)
        XCTAssertNil(session.focusedMatchIndex)
    }

    func testSummaryIsWithheldUntilEveryFieldHasReplied() {
        let (session, _) = makeSession()

        session.query = "widget"

        // Nothing has answered yet — the bar must not claim there are no results.
        XCTAssertFalse(session.isSettled)
        XCTAssertNil(session.matchSummary)
        XCTAssertFalse(session.hasMatches)

        // Nor may a partial total surface as if it were the answer.
        reply(to: session, query: "widget", counts: [(.description, 2)])
        XCTAssertNil(session.matchSummary)

        reply(to: session, query: "widget", counts: [(.acceptanceCriteria, 1), (.design, 0)])
        XCTAssertNil(session.matchSummary)

        reply(to: session, query: "widget", counts: [(.notes, 4)])
        XCTAssertTrue(session.isSettled)
        XCTAssertEqual(session.matchSummary, "1 of 7")
    }

    func testEditingAFieldWithholdsTheSummaryUntilFieldsAnswerAgain() {
        let (session, _) = makeSession()
        session.query = "widget"
        reply(to: session, query: "widget", counts: [
            (.description, 2),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 0)
        ])
        XCTAssertEqual(session.matchSummary, "1 of 2")

        session.refreshMatches()

        // The count is stale until every field reports on the edited text, but
        // the previous total is kept so the anchor doesn't vanish mid-edit.
        XCTAssertFalse(session.isSettled)
        XCTAssertNil(session.matchSummary)
        XCTAssertEqual(session.totalMatchCount, 2)

        reply(to: session, query: "widget", counts: [
            (.description, 3),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 0)
        ])
        XCTAssertEqual(session.matchSummary, "1 of 3")
    }

    func testSummaryResolvesOnTheGraceDeadlineWhenAFieldNeverReplies() async throws {
        let dispatcher = RecordingDispatcher()
        let session = BeadFindSession(
            debounce: .zero,
            settleGrace: .milliseconds(30),
            dispatcher: dispatcher
        )
        session.open(scope: Self.scope())

        session.query = "widget"
        // Only one field ever answers; the rest are silent.
        reply(to: session, query: "widget", counts: [(.description, 2)], dispatcher: dispatcher)
        XCTAssertNil(session.matchSummary)

        try await Task.sleep(for: .milliseconds(200))

        // A silent field must not hide the count forever.
        XCTAssertTrue(session.isSettled)
        XCTAssertEqual(session.matchSummary, "1 of 2")
        // And the count it settles on must be one it can actually act on: the
        // field that answered owns the focus.
        XCTAssertEqual(session.focusTarget?.section, .description)
    }

    /// The grace path settles on incomplete counts by design. It must still land
    /// the focus on a field that reported matches, or the bar would claim a match
    /// with nothing highlighted and nothing to scroll to.
    func testGraceSettlementFocusesAFieldThatActuallyReplied() async throws {
        let dispatcher = RecordingDispatcher()
        let session = BeadFindSession(
            debounce: .zero,
            settleGrace: .milliseconds(30),
            dispatcher: dispatcher
        )
        session.open(scope: Self.scope())

        session.query = "widget"
        // Description was focused optimistically, but it is the silent one.
        XCTAssertEqual(dispatcher.requests.last?.focusDocumentID, documentID(.description))
        reply(to: session, query: "widget", counts: [(.acceptanceCriteria, 2)], dispatcher: dispatcher)

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(session.isSettled)
        XCTAssertEqual(session.focusTarget?.section, .acceptanceCriteria)
        XCTAssertEqual(
            dispatcher.requests.last?.focusDocumentID,
            documentID(.acceptanceCriteria),
            "settling on partial counts must re-post the focus to a field that has matches"
        )
    }

    func testStaleRepliesFromBeforeARefreshAreRejected() {
        let (session, dispatcher) = makeSession()
        session.query = "widget"
        reply(to: session, query: "widget", counts: [
            (.description, 9),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 0)
        ])
        XCTAssertEqual(session.totalMatchCount, 9)
        let staleToken = dispatcher.requests.last?.token

        // An edit re-gathers. The query text and document IDs are unchanged, so
        // the token is the only thing that can place a late reply.
        session.refreshMatches()
        reply(
            to: session,
            query: "widget",
            counts: [
                (.description, 9),
                (.acceptanceCriteria, 0),
                (.design, 0),
                (.notes, 0)
            ],
            token: staleToken
        )

        XCTAssertFalse(session.isSettled, "a reply from before the refresh must not settle it")
        XCTAssertNil(session.matchSummary)
    }

    func testReturnCannotNavigateARetainedCountWhileUnsettled() {
        let (session, _) = makeSession()
        session.query = "widget"
        reply(to: session, query: "widget", counts: [
            (.description, 10),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 0)
        ])
        session.moveToNextMatch()
        XCTAssertEqual(session.focusedMatchIndex, 1)

        // Editing retains the old counts so the bar doesn't blank out, but they
        // are no longer trustworthy — and the find field's Return key reaches
        // the session directly, bypassing the disabled chevrons.
        session.refreshMatches()
        session.moveToNextMatch()

        XCTAssertEqual(
            session.focusedMatchIndex,
            1,
            "Return must not walk a stale count map while stepping controls are disabled"
        )
    }

    func testADeadlineFromAnEarlierRequestCannotSettleRefreshedResults() async throws {
        let dispatcher = SynchronousReplyDispatcher()
        // The grace has to outlast the gap to the refresh, so the earlier
        // request's deadline is still pending when the refresh happens — that's
        // the only arrangement in which it can wrongly settle newer work.
        let session = BeadFindSession(
            debounce: .milliseconds(400),
            settleGrace: .milliseconds(300),
            dispatcher: dispatcher
        )
        dispatcher.session = session
        session.open(scope: Self.scope())

        // Replies land synchronously inside the dispatch, completing the first
        // request before its own deadline comes due. Wait out the debounce so
        // that dispatch has actually happened.
        session.query = "widget"
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(session.isSettled)
        XCTAssertEqual(session.matchSummary, "1 of 2")

        // An edit re-gathers, and this time nothing answers.
        dispatcher.repliesEnabled = false
        session.refreshMatches()
        XCTAssertFalse(session.isSettled)

        // Past when the first request's deadline would have fired, but well
        // before the refreshed request is even dispatched — so nothing
        // legitimate can settle it yet.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(
            session.isSettled,
            "a deadline armed for an earlier request must not declare refreshed results complete"
        )
        XCTAssertNil(session.matchSummary)
    }

    func testEachWindowGetsItsOwnFindChannel() {
        let windowA = BeadFindSession.forWindow()
        let windowB = BeadFindSession.forWindow()

        // The engine observes with `object: nil`, so the name is the only scope
        // there is — shared names would let two windows overwrite each other's
        // highlights and cross-file each other's counts.
        XCTAssertNotEqual(windowA.bus.query, windowB.bus.query)
        XCTAssertNotEqual(windowA.bus.results, windowB.bus.results)
        XCTAssertNotEqual(windowA.bus.clearHighlights, windowB.bus.clearHighlights)
    }

    func testOneWindowsFindTrafficIsNotDeliveredToAnother() {
        let busA = BeadFindBus()
        let busB = BeadFindBus()
        let counts = FindTrafficCounts()

        let observers = [
            NotificationCenter.default.addObserver(forName: busA.query, object: nil, queue: nil) { _ in
                counts.recordQueryOnA()
            },
            NotificationCenter.default.addObserver(forName: busB.query, object: nil, queue: nil) { _ in
                counts.recordQueryOnB()
            },
            NotificationCenter.default.addObserver(forName: busB.clearHighlights, object: nil, queue: nil) { _ in
                counts.recordClearOnB()
            }
        ]
        addTeardownBlock { @MainActor in
            observers.forEach(NotificationCenter.default.removeObserver(_:))
        }

        let dispatcherA = BeadFindNotificationDispatcher(bus: busA)
        dispatcherA.send(BeadFindRequest(
            text: "widget",
            token: 1,
            focusDocumentID: "bd-1-description",
            focusIndex: 0
        ))
        dispatcherA.clearHighlights()

        let snapshot = counts.snapshot()
        XCTAssertEqual(snapshot.queriesOnA, 1)
        XCTAssertEqual(snapshot.queriesOnB, 0)
        XCTAssertEqual(snapshot.clearsOnB, 0)
    }

    func testRebindingToAnotherProjectWithTheSameIssueIDResetsResults() {
        let (session, _) = makeSession()
        session.query = "widget"
        reply(to: session, query: "widget", counts: [
            (.description, 3),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 0)
        ])
        XCTAssertEqual(session.totalMatchCount, 3)

        // Same issue ID, different project: the document IDs are identical, so
        // only the project key distinguishes them.
        session.rebind(scope: Self.scope(projectKey: "/tmp/project-b"))

        XCTAssertEqual(session.totalMatchCount, 0)
        XCTAssertFalse(session.isSettled)
        XCTAssertNil(session.matchSummary)
    }

    func testFocusIsCorrectedWhenTheOptimisticallyFocusedFieldHasNoMatches() {
        let (session, dispatcher) = makeSession()
        session.query = "widget"
        XCTAssertEqual(dispatcher.requests.last?.focusDocumentID, documentID(.description))

        reply(to: session, query: "widget", counts: [
            (.description, 0),
            (.acceptanceCriteria, 0),
            (.design, 2),
            (.notes, 0)
        ])

        XCTAssertEqual(session.focusTarget?.section, .design)
        XCTAssertEqual(dispatcher.requests.last?.focusDocumentID, documentID(.design))
        XCTAssertEqual(dispatcher.requests.last?.focusIndex, 0)
    }

    func testNoMatchesReportsNoResults() {
        let (session, _) = makeSession()
        session.query = "widget"

        reply(to: session, query: "widget", counts: [
            (.description, 0),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 0)
        ])

        XCTAssertEqual(session.totalMatchCount, 0)
        XCTAssertNil(session.focusedMatchIndex)
        XCTAssertNil(session.focusTarget)
        XCTAssertEqual(session.matchSummary, "No results")
        XCTAssertFalse(session.hasMatches)
    }

    func testNextAndPreviousDoNothingWithoutMatches() {
        let (session, _) = makeSession()
        session.query = "widget"
        reply(to: session, query: "widget", counts: [
            (.description, 0),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 0)
        ])

        session.moveToNextMatch()
        session.moveToPreviousMatch()

        XCTAssertNil(session.focusedMatchIndex)
    }

    func testClearingTheQueryResetsResultsAndClearsHighlights() {
        let (session, dispatcher) = makeSession()
        session.query = "widget"
        reply(to: session, query: "widget", counts: [
            (.description, 3),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 0)
        ])

        session.query = ""

        XCTAssertEqual(session.totalMatchCount, 0)
        XCTAssertNil(session.focusedMatchIndex)
        XCTAssertNil(session.matchSummary)
        XCTAssertEqual(dispatcher.clearCount, 1)
    }

    func testClosingClearsHighlightsAndTheQuery() {
        let (session, dispatcher) = makeSession()
        session.query = "widget"

        session.close()

        XCTAssertFalse(session.isPresented)
        XCTAssertEqual(session.query, "")
        XCTAssertEqual(session.totalMatchCount, 0)
        // Exactly one clear: emptying the query while closing must not post a
        // second one through the query observer.
        XCTAssertEqual(dispatcher.clearCount, 1)
    }

    func testFocusedIndexIsClampedWhenAFieldReportsFewerMatches() {
        let (session, _) = makeSession()
        session.query = "widget"
        reply(to: session, query: "widget", counts: [
            (.description, 5),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 0)
        ])
        session.moveToNextMatch()
        session.moveToNextMatch()
        session.moveToNextMatch()
        XCTAssertEqual(session.focusedMatchIndex, 3)

        // The user edits the field and it now holds only two matches.
        session.ingest(
            documentID: documentID(.description),
            matchedQuery: "widget",
            count: 2,
            matchRect: nil,
            token: lastToken
        )

        XCTAssertEqual(session.totalMatchCount, 2)
        XCTAssertEqual(session.focusedMatchIndex, 1)
        XCTAssertEqual(session.matchSummary, "2 of 2")
    }

    func testScrollAnchorIsExposedOnlyForTheFocusedField() {
        let (session, _) = makeSession()
        session.query = "widget"
        let descriptionRect = CGRect(x: 0, y: 120, width: 80, height: 18)
        let notesRect = CGRect(x: 0, y: 40, width: 60, height: 18)

        reply(
            to: session,
            query: "widget",
            counts: [
                (.description, 1),
                (.acceptanceCriteria, 0),
                (.design, 0),
                (.notes, 1)
            ],
            rects: [.description: descriptionRect, .notes: notesRect]
        )

        XCTAssertEqual(session.scrollAnchorRect(forDocumentID: documentID(.description)), descriptionRect)
        XCTAssertNil(session.scrollAnchorRect(forDocumentID: documentID(.notes)))

        session.moveToNextMatch()

        XCTAssertNil(session.scrollAnchorRect(forDocumentID: documentID(.description)))
        XCTAssertEqual(session.scrollAnchorRect(forDocumentID: documentID(.notes)), notesRect)
    }

    func testFocusTokenAdvancesWhenTheFocusedMatchMoves() {
        let (session, _) = makeSession()
        session.query = "widget"
        reply(to: session, query: "widget", counts: [
            (.description, 2),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 0)
        ])
        let before = session.focusToken

        session.moveToNextMatch()

        XCTAssertGreaterThan(session.focusToken, before)
    }

    func testRebindingToAnotherBeadReRunsTheQueryAgainstIt() {
        let (session, dispatcher) = makeSession()
        session.query = "widget"
        reply(to: session, query: "widget", counts: [
            (.description, 3),
            (.acceptanceCriteria, 0),
            (.design, 0),
            (.notes, 0)
        ])

        session.rebind(scope: Self.scope(prefix: "bd-99"))

        XCTAssertEqual(session.totalMatchCount, 0)
        XCTAssertEqual(session.query, "widget")
        XCTAssertEqual(
            dispatcher.requests.last?.focusDocumentID,
            IssueTextSection.description.documentID(prefix: "bd-99")
        )
        // Replies keyed to the previous bead must no longer count.
        session.ingest(
            documentID: documentID(.description),
            matchedQuery: "widget",
            count: 3,
            matchRect: nil,
            token: dispatcher.requests.last?.token
        )
        XCTAssertEqual(session.totalMatchCount, 0)
    }
}
