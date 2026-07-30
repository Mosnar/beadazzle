import CoreGraphics
import Foundation

/// A find request the host posts to the markdown engine's find bus.
struct BeadFindRequest: Equatable {
    var text: String
    /// Identifies this round of gathering. Echoed back by the engine so a reply
    /// belonging to an earlier round can be dropped — the query text alone can't
    /// distinguish them, and neither can the document IDs, which are identical
    /// for the same issue ID in a different project.
    var token: Int
    /// Document that owns the focused match. Every other field highlights its
    /// matches without a focused one and does not scroll.
    var focusDocumentID: String?
    /// Index of the focused match *within* `focusDocumentID`.
    var focusIndex: Int
}

/// What find is currently searching.
///
/// The project is part of the identity even though it never appears in a
/// document ID: two projects can contain the same issue ID, and keying only on
/// the ID let a switch between them keep the previous project's results.
struct BeadFindScope: Equatable {
    /// Distinguishes projects. Not used to build document IDs.
    var projectKey: String
    /// Prefix the markdown engine's document IDs are built from, which must
    /// match what `IssueBodySections` hands each field.
    var documentIDPrefix: String
}

/// Sends find requests to the markdown engine. A protocol so `BeadFindSession`
/// can be tested without NotificationCenter in the loop.
@MainActor
protocol BeadFindDispatching: AnyObject {
    func send(_ request: BeadFindRequest)
    func clearHighlights()
}

/// Per-window state for "find in current bead".
///
/// The four body fields are separate markdown-engine text views, and each one
/// counts its own matches in *display* coordinates. The engine is the only
/// thing that knows how many matches a field really has: concealed Markdown
/// markers make the displayed text differ from the source, so counting the
/// draft strings here would disagree with what the user can see. This type
/// therefore owns no matching logic. It posts a query, collects the per-field
/// counts that come back, and maps one global "3 of 17" position onto
/// (field, local index) pairs.
@Observable
@MainActor
final class BeadFindSession {
    /// The order find walks the fields, matching how `IssueBodySections`
    /// renders them so Find Next moves down the page.
    static let sectionOrder: [IssueTextSection] = [
        .description,
        .acceptanceCriteria,
        .design,
        .notes
    ]

    /// Text the user typed. Debounced before it reaches the engine so typing in
    /// a large bead doesn't re-scan four documents on every keystroke.
    var query = "" {
        didSet {
            guard query != oldValue, !suppressesQueryObserver else { return }
            queryDidChange()
        }
    }

    private(set) var isPresented = false
    private(set) var totalMatchCount = 0
    /// Zero-based position of the focused match across every field, or `nil`
    /// when the current query matches nothing.
    private(set) var focusedMatchIndex: Int?
    /// Bumped whenever the focused match moves, so a view can drive `scrollTo`
    /// even when the reported rect happens to be unchanged.
    private(set) var focusToken = 0
    /// Bumped whenever the bar should take keyboard focus, so pressing the find
    /// shortcut again while it is already open returns the caret to the field.
    private(set) var focusRequestToken = 0

    /// Whether every field has reported for the current query. Counts arrive one
    /// field at a time, so before this is true the total is partial and must not
    /// be shown — otherwise the bar reads "No results" during the debounce and
    /// then flickers through partial totals as replies land.
    private(set) var isSettled = false

    /// Notification names this window's fields and this session talk over.
    /// A `let`, so reading it from a view body registers no observation
    /// dependency.
    let bus: BeadFindBus

    private let debounce: Duration
    private let settleGrace: Duration
    private var dispatcher: BeadFindDispatching?
    private var scope: BeadFindScope?
    private var counts: [IssueTextSection: Int] = [:]
    private var receivedSections: Set<IssueTextSection> = []
    private var matchRects: [String: CGRect] = [:]
    private var postedRequest: BeadFindRequest?
    private var suppressesQueryObserver = false
    /// Bumped whenever results start being re-gathered, so a settlement deadline
    /// armed for an earlier request can't declare newer work complete.
    private var requestGeneration = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    init(
        bus: BeadFindBus = BeadFindBus(),
        debounce: Duration = .milliseconds(120),
        settleGrace: Duration = .milliseconds(250),
        dispatcher: BeadFindDispatching? = nil
    ) {
        self.bus = bus
        self.debounce = debounce
        self.settleGrace = settleGrace
        self.dispatcher = dispatcher
    }

    /// A session wired to post on its own bus. Each window makes one, so no two
    /// windows share a find channel.
    static func forWindow() -> BeadFindSession {
        let bus = BeadFindBus()
        return BeadFindSession(bus: bus, dispatcher: BeadFindNotificationDispatcher(bus: bus))
    }

    // MARK: - Presentation

    /// Show the bar for the bead described by `scope`.
    func open(scope: BeadFindScope) {
        if self.scope != scope {
            self.scope = scope
            clearResults()
        }
        isPresented = true
        focusRequestToken += 1
        if !query.isEmpty {
            scheduleSend()
        }
    }

    func close() {
        debounceTask?.cancel()
        debounceTask = nil
        isPresented = false
        withQueryObserverSuppressed { query = "" }
        clearResults()
        dispatcher?.clearHighlights()
    }

    /// Point the session at a different bead without closing the bar, then
    /// re-run the current query against it.
    func rebind(scope: BeadFindScope) {
        guard self.scope != scope else { return }
        self.scope = scope
        clearResults()
        guard isPresented, !query.isEmpty else { return }
        scheduleSend()
    }

    /// Re-run the current query against the same bead.
    ///
    /// Editing a field makes the engine restyle it, which rebuilds its text
    /// attributes and drops the highlight background, so the query has to be
    /// re-posted for the highlights and counts to stay truthful while typing.
    func refreshMatches() {
        guard isPresented, !query.isEmpty else { return }
        // Counts are kept so the bar doesn't blank out mid-edit; they're simply
        // no longer trusted as complete until every field answers again.
        receivedSections.removeAll(keepingCapacity: true)
        invalidateSettlement()
        // The request itself is unchanged, so clear the de-dupe record that
        // would otherwise swallow it.
        postedRequest = nil
        scheduleSend()
    }

    // MARK: - Navigation

    func moveToNextMatch() {
        advanceFocus(by: 1)
    }

    func moveToPreviousMatch() {
        advanceFocus(by: -1)
    }

    // MARK: - Engine replies

    /// Record one field's reply. Replies arrive a main-queue hop later, so one
    /// belonging to an earlier round can still land: `token` places it, and
    /// `matchedQuery` is a second guard for engines that echo no token.
    func ingest(
        documentID: String,
        matchedQuery: String,
        count: Int,
        matchRect: CGRect?,
        token: Int?
    ) {
        guard !query.isEmpty, matchedQuery == query else { return }
        // A reply from before the last rebind or refresh describes text that is
        // no longer on screen, even though its query and document ID still match.
        guard token == requestGeneration else { return }
        guard let section = section(forDocumentID: documentID) else { return }

        counts[section] = count
        receivedSections.insert(section)
        if let matchRect, matchRects[documentID] != matchRect {
            matchRects[documentID] = matchRect
            // The anchor for this rect is about to appear. If it belongs to the
            // focused document the scroll has to be re-driven, because the
            // focused index itself may not have changed.
            if documentID == focusedDocumentID {
                focusToken += 1
            }
        }
        if receivedSections.count == Self.sectionOrder.count {
            settleTask?.cancel()
            settleTask = nil
            isSettled = true
        }
        recomputeTotals()
    }

    // MARK: - Display

    /// The focused field and the match's index within it, or `nil` when
    /// nothing is focused.
    var focusTarget: (section: IssueTextSection, localIndex: Int)? {
        guard let focusedMatchIndex, totalMatchCount > 0 else { return nil }
        var remaining = focusedMatchIndex
        for section in Self.sectionOrder {
            let count = counts[section] ?? 0
            if remaining < count {
                return (section, remaining)
            }
            remaining -= count
        }
        return nil
    }

    /// "3 of 17" for the bar, or "No results" once every field has reported.
    /// `nil` while a query is still being answered, so the bar shows nothing
    /// rather than a wrong count.
    var matchSummary: String? {
        guard !query.isEmpty, isSettled else { return nil }
        guard totalMatchCount > 0 else { return "No results" }
        return "\((focusedMatchIndex ?? 0) + 1) of \(totalMatchCount)"
    }

    /// Only true once the count is known to be complete, so Find Next/Previous
    /// can't act on a partial total.
    var hasMatches: Bool {
        isSettled && totalMatchCount > 0
    }

    /// Whether the focused match's rect has arrived, meaning a field is carrying
    /// the scroll anchor right now.
    var hasFocusedAnchor: Bool {
        guard let focusedDocumentID else { return false }
        return matchRects[focusedDocumentID] != nil
    }

    /// Document ID of the field that owns the focused match.
    private var focusedDocumentID: String? {
        guard let prefix = scope?.documentIDPrefix, let focusTarget else { return nil }
        return focusTarget.section.documentID(prefix: prefix)
    }

    /// The focused match's rect within `documentID`'s own field, for the
    /// invisible scroll anchor. Non-nil only for the field that owns the
    /// focused match, so exactly one field carries the anchor at a time.
    func scrollAnchorRect(forDocumentID documentID: String) -> CGRect? {
        guard let prefix = scope?.documentIDPrefix, let focusTarget else { return nil }
        guard focusTarget.section.documentID(prefix: prefix) == documentID else { return nil }
        return matchRects[documentID]
    }

    // MARK: - Query plumbing

    private func queryDidChange() {
        clearResults()

        guard !query.isEmpty else {
            debounceTask?.cancel()
            debounceTask = nil
            dispatcher?.clearHighlights()
            return
        }

        scheduleSend()
    }

    private func scheduleSend() {
        debounceTask?.cancel()

        guard debounce > .zero else {
            debounceTask = nil
            sendCurrentQuery()
            return
        }

        let delay = debounce
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.sendCurrentQuery()
        }
    }

    private func sendCurrentQuery() {
        guard !query.isEmpty, let prefix = scope?.documentIDPrefix else { return }

        // No counts have come back yet, so focus the first field optimistically.
        // `recomputeTotals` re-posts if the real counts put the first match
        // somewhere else — usually they don't, so this costs nothing.
        let target = focusTarget ?? (section: Self.sectionOrder[0], localIndex: 0)
        send(BeadFindRequest(
            text: query,
            token: requestGeneration,
            focusDocumentID: target.section.documentID(prefix: prefix),
            focusIndex: target.localIndex
        ))
    }

    private func advanceFocus(by offset: Int) {
        // `hasMatches`, not a raw total: `refreshMatches` deliberately retains
        // the previous counts while unsettled, so a raw check would let the find
        // field's Return key walk a stale map while every visible stepping
        // control is disabled.
        guard hasMatches else { return }
        let current = focusedMatchIndex ?? 0
        let wrapped = ((current + offset) % totalMatchCount + totalMatchCount) % totalMatchCount
        guard wrapped != current || totalMatchCount == 1 else { return }
        focusedMatchIndex = wrapped
        focusToken += 1
        sendFocusedRequest()
    }

    private func sendFocusedRequest() {
        guard !query.isEmpty, let prefix = scope?.documentIDPrefix, let target = focusTarget else { return }
        send(BeadFindRequest(
            text: query,
            token: requestGeneration,
            focusDocumentID: target.section.documentID(prefix: prefix),
            focusIndex: target.localIndex
        ))
    }

    private func send(_ request: BeadFindRequest) {
        guard request != postedRequest else { return }
        postedRequest = request
        // Armed before dispatching, not after: a synchronous reply run would
        // otherwise settle the results and then find a fresh deadline armed
        // behind it, left pending to fire against some later request.
        scheduleSettleDeadline()
        dispatcher?.send(request)
    }

    /// Settle regardless after a grace period. Every field is normally mounted
    /// and replies, but a silent one would otherwise hide the count for good.
    private func scheduleSettleDeadline() {
        settleTask?.cancel()
        guard settleGrace > .zero else {
            settleTask = nil
            return
        }
        let grace = settleGrace
        // Cancellation alone isn't enough — a task already past its sleep can't
        // be called back — so the generation is checked before settling.
        let generation = requestGeneration
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            self?.settleIfStillCurrent(generation: generation)
        }
    }

    private func settleIfStillCurrent(generation: Int) {
        guard generation == requestGeneration else { return }
        isSettled = true
        // Settling on incomplete counts still has to be self-consistent: if the
        // field we optimistically focused is the one that never answered, the
        // focus belongs on a field that did, or the bar would report a match
        // with nothing highlighted and nothing to scroll to.
        recomputeTotals()
    }

    /// Invalidate any in-flight settlement: results are about to be re-gathered,
    /// so no older deadline may declare them complete.
    private func invalidateSettlement() {
        settleTask?.cancel()
        settleTask = nil
        requestGeneration += 1
        isSettled = false
    }

    private func recomputeTotals() {
        totalMatchCount = Self.sectionOrder.reduce(0) { $0 + (counts[$1] ?? 0) }

        let previousIndex = focusedMatchIndex
        if totalMatchCount == 0 {
            focusedMatchIndex = nil
        } else if let previousIndex {
            focusedMatchIndex = min(previousIndex, totalMatchCount - 1)
        } else {
            focusedMatchIndex = 0
        }

        if focusedMatchIndex != previousIndex {
            focusToken += 1
        }

        refocusIfNeeded()
    }

    /// Correct the optimistic focus once the real counts disagree with it.
    ///
    /// Waits until every field has reported, so a single early reply can't make
    /// the focus hop from field to field as the rest trickle in. The exception
    /// is a definite signal: the field we asked to focus reported zero matches,
    /// so it cannot be right regardless of what else is outstanding.
    private func refocusIfNeeded() {
        guard let prefix = scope?.documentIDPrefix, let target = focusTarget else { return }

        let settled = isSettled
        let postedFieldIsEmpty = postedRequest?.focusDocumentID
            .flatMap(section(forDocumentID:))
            .map { receivedSections.contains($0) && (counts[$0] ?? 0) == 0 }
            ?? false
        guard settled || postedFieldIsEmpty else { return }

        send(BeadFindRequest(
            text: query,
            token: requestGeneration,
            focusDocumentID: target.section.documentID(prefix: prefix),
            focusIndex: target.localIndex
        ))
    }

    private func clearResults() {
        invalidateSettlement()
        counts.removeAll(keepingCapacity: true)
        receivedSections.removeAll(keepingCapacity: true)
        matchRects.removeAll(keepingCapacity: true)
        postedRequest = nil
        totalMatchCount = 0
        focusedMatchIndex = nil
        focusToken += 1
    }

    private func section(forDocumentID documentID: String) -> IssueTextSection? {
        guard let prefix = scope?.documentIDPrefix else { return nil }
        return Self.sectionOrder.first { $0.documentID(prefix: prefix) == documentID }
    }

    private func withQueryObserverSuppressed(_ body: () -> Void) {
        suppressesQueryObserver = true
        body()
        suppressesQueryObserver = false
    }
}
