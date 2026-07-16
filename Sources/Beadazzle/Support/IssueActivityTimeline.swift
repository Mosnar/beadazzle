import Foundation

/// One row in an issue's Activity feed: either a compact history event or a comment.
enum IssueActivityItem: Identifiable, Hashable, Sendable {
    case event(IssueActivityEventPresentation)
    case comment(BeadComment)

    var id: String {
        switch self {
        case .event(let event):
            "event-\(event.id)"
        case .comment(let comment):
            "comment-\(comment.id)"
        }
    }

    var date: Date? {
        switch self {
        case .event(let event):
            event.date
        case .comment(let comment):
            comment.createdAt
        }
    }
}

/// Another bead an event points at ("added child bead <bd-x Title>"), rendered as a
/// clickable reference with the shared bead hover preview.
struct IssueActivityReference: Hashable, Sendable {
    var issueID: String
    var displayText: String
}

/// A history event already phrased for display ("changed status from open to closed").
struct IssueActivityEventPresentation: Identifiable, Hashable, Sendable {
    var id: String
    var date: Date?
    var actor: String?
    var systemImage: String
    /// Lowercase verb phrase completing "<actor> …" ("closed this bead"). When
    /// `reference` is set, the phrase ends where the reference begins ("set the
    /// parent to").
    var message: String
    /// Supplementary context shown under the message — the close/state-change reason.
    var reason: String?
    /// The bead the message trails into, shown as a clickable link after `message`.
    var reference: IssueActivityReference?

    /// The message standing alone for events with no recorded actor ("Closed this bead").
    var standaloneMessage: String {
        guard let first = message.first else { return message }
        return first.uppercased() + message.dropFirst()
    }
}

/// Merges an issue's logged history events with its comments into one oldest-first
/// feed, synthesizing entries the event log cannot provide: issue creation, child and
/// blocker/gate links (from dependency edges, which carry their creator and date), and
/// a close (with `close_reason`) that happened before the log existed.
enum IssueActivityTimeline {
    static func items(
        issue: BeadIssue,
        events: [BeadIssueEvent],
        comments: [BeadComment],
        dependencies: [BeadDependency] = [],
        semantics: BeadProjectSemantics,
        resolveIssue: (String) -> BeadIssue? = { _ in nil }
    ) -> [IssueActivityItem] {
        var items: [IssueActivityItem] = []

        items.append(.event(IssueActivityEventPresentation(
            id: "synthesized-created-\(issue.id)",
            date: issue.createdAt,
            actor: issue.createdBy,
            systemImage: "plus.circle",
            message: "created this bead"
        )))

        items.append(contentsOf: events.map {
            .event(presentation(for: $0, semantics: semantics, notBefore: issue.createdAt))
        })

        items.append(contentsOf: dependencies.compactMap { dependency in
            presentation(for: dependency, on: issue, resolveIssue: resolveIssue).map(IssueActivityItem.event)
        })

        // When a blocker (or gate) closes, the blocked bead becomes workable — that's
        // activity worth seeing. Derived from the blocker's `closed_at`, so a reopened
        // blocker withdraws its entry along with the unblock itself.
        items.append(contentsOf: dependencies.compactMap { dependency -> IssueActivityItem? in
            guard dependency.isBlocking,
                  dependency.issueID == issue.id,
                  let blocker = resolveIssue(dependency.dependsOnID),
                  let blockerClosedAt = blocker.closedAt,
                  semantics.isDone(blocker) else {
                return nil
            }
            return .event(IssueActivityEventPresentation(
                id: "unblocked-\(dependency.id)",
                date: latestDate(
                    blockerClosedAt,
                    relationshipDate(for: dependency, on: issue, resolveIssue: resolveIssue)
                ),
                actor: nil,
                systemImage: "hand.raised.slash",
                message: "no longer blocked by",
                reference: reference(for: blocker.id, resolveIssue: resolveIssue)
            ))
        })

        // The snapshot is authoritative. Some valid `bd` commands (notably `bd reopen`)
        // do not append an interaction, so reconcile the latest logged transition with
        // the current issue state instead of merely asking whether any close ever existed.
        let latestStatusEvent = latestStatusEvent(in: events)
        let latestLoggedDone = latestStatusEvent?.newValue.map {
            isDoneStatus($0, semantics: semantics)
        }
        let currentDone = isDoneStatus(issue.status, semantics: semantics)
        if currentDone, latestLoggedDone != true {
            items.append(.event(IssueActivityEventPresentation(
                id: "synthesized-closed-\(issue.id)",
                date: latestDate(
                    issue.closedAt ?? issue.updatedAt,
                    latestStatusEvent?.createdAt,
                    issue.createdAt
                ),
                actor: nil,
                systemImage: Self.closeSystemImage,
                message: "closed this bead",
                reason: issue.closeReason
            )))
        } else if !currentDone, latestLoggedDone == true {
            items.append(.event(IssueActivityEventPresentation(
                id: "synthesized-reopened-\(issue.id)",
                date: latestDate(
                    issue.updatedAt,
                    latestStatusEvent?.createdAt,
                    issue.createdAt
                ),
                actor: nil,
                systemImage: "arrow.uturn.backward.circle",
                message: "reopened this bead"
            )))
        }

        items.append(contentsOf: comments.map(IssueActivityItem.comment))

        // Swift's sort is not stable. Preserve insertion/source order for identical
        // timestamps rather than falling back to ids that may not encode chronology.
        return items.enumerated().sorted { lhs, rhs in
            let left = latestDate(lhs.element.date, issue.createdAt) ?? .distantPast
            let right = latestDate(rhs.element.date, issue.createdAt) ?? .distantPast
            if left != right {
                return left < right
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    private static let closeSystemImage = "checkmark.circle"

    /// Body fields whose logged old/new values are prose; showing a diff inline is
    /// noise, so these phrase as "updated the <field>".
    private static let proseFields: Set<String> = ["description", "design", "notes", "acceptance_criteria"]

    /// Dependency edges become feed entries on both endpoints: the blocked side shows
    /// the blocker (or gate) arriving, the blocker side shows what it blocks,
    /// parent-child edges read as "added child bead" / "set the parent", and
    /// discovered-from edges record provenance. Removed edges leave no trace in the
    /// snapshot, so only current links appear. Messages end where the clickable
    /// reference begins.
    private static func presentation(
        for dependency: BeadDependency,
        on issue: BeadIssue,
        resolveIssue: (String) -> BeadIssue?
    ) -> IssueActivityEventPresentation? {
        let normalizedType = dependency.type
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isParentChild = normalizedType == "parent-child"
        let isDiscoveredFrom = normalizedType == "discovered-from"
        guard dependency.isBlocking || isParentChild || isDiscoveredFrom else { return nil }

        let otherID = dependency.issueID == issue.id ? dependency.dependsOnID : dependency.issueID
        let isForward = dependency.issueID == issue.id

        let systemImage: String
        let message: String
        if isParentChild {
            systemImage = BeadIconography.children
            message = isForward ? "set the parent to" : "added child bead"
        } else if isDiscoveredFrom {
            systemImage = "sparkles"
            message = isForward ? "discovered while working on" : "led to discovering"
        } else if isForward {
            // This issue is blocked until `otherID` closes.
            systemImage = BeadIconography.blockedBy
            message = resolveIssue(otherID)?.isGate == true
                ? "gated this bead behind"
                : "marked this bead as blocked by"
        } else {
            systemImage = BeadIconography.blocking
            message = "marked this bead as blocking"
        }

        return IssueActivityEventPresentation(
            id: "dependency-\(dependency.id)",
            date: relationshipDate(for: dependency, on: issue, resolveIssue: resolveIssue),
            actor: dependency.createdBy,
            systemImage: systemImage,
            message: message,
            reference: reference(for: otherID, resolveIssue: resolveIssue)
        )
    }

    private static func reference(
        for issueID: String,
        resolveIssue: (String) -> BeadIssue?
    ) -> IssueActivityReference {
        let displayText = resolveIssue(issueID).map { "\(issueID) \(clamped($0.title))" } ?? issueID
        return IssueActivityReference(issueID: issueID, displayText: displayText)
    }

    private static func presentation(
        for event: BeadIssueEvent,
        semantics: BeadProjectSemantics,
        notBefore lowerBound: Date?
    ) -> IssueActivityEventPresentation {
        var systemImage = "pencil.circle"
        var message: String

        if event.kind == "field_change", let field = event.field {
            if field == "status" {
                let oldDone = event.oldValue.map { isDoneStatus($0, semantics: semantics) } ?? false
                let newDone = event.newValue.map { isDoneStatus($0, semantics: semantics) } ?? false
                if newDone, !oldDone {
                    systemImage = closeSystemImage
                    message = "closed this bead"
                } else if oldDone, !newDone {
                    systemImage = "arrow.uturn.backward.circle"
                    message = "reopened this bead"
                } else {
                    systemImage = "circle.lefthalf.filled"
                    message = changeMessage(field: field, old: event.oldValue, new: event.newValue)
                }
            } else {
                message = changeMessage(field: field, old: event.oldValue, new: event.newValue)
            }
        } else {
            message = "updated this bead"
        }

        return IssueActivityEventPresentation(
            id: event.id,
            date: latestDate(event.createdAt, lowerBound),
            actor: event.actor,
            systemImage: systemImage,
            message: message,
            reason: event.reason
        )
    }

    private static func changeMessage(field: String, old: String?, new: String?) -> String {
        let fieldName = field.replacingOccurrences(of: "_", with: " ")
        if field == "title" {
            if let old = old.map(clamped), let new = new.map(clamped) {
                return "renamed this bead from “\(old)” to “\(new)”"
            }
        } else if proseFields.contains(field) {
            return "updated the \(fieldName)"
        }
        switch (old.map(clamped), new.map(clamped)) {
        case (let old?, let new?):
            return "changed \(fieldName) from \(old) to \(new)"
        case (nil, let new?):
            return "set \(fieldName) to \(new)"
        case (let old?, nil):
            return "removed \(fieldName) (was \(old))"
        case (nil, nil):
            return "changed \(fieldName)"
        }
    }

    /// Logged values can be entire body fields (a description edit records the full
    /// old and new text); keep event rows to a one-line summary.
    private static func clamped(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > 80 else { return flattened }
        return flattened.prefix(79) + "…"
    }

    /// A status counts as "done" via its category; statuses the project hasn't
    /// categorized fall back to the built-in `closed` name so default Beads
    /// projects still read close/reopen transitions correctly.
    private static func isDoneStatus(_ status: String, semantics: BeadProjectSemantics) -> Bool {
        switch semantics.category(forStatus: status) {
        case .done:
            true
        case .uncategorized:
            status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "closed"
        default:
            false
        }
    }

    private static func latestStatusEvent(in events: [BeadIssueEvent]) -> BeadIssueEvent? {
        events.enumerated()
            .filter { _, event in
                event.kind == "field_change" && event.field == "status" && event.newValue != nil
            }
            .max { lhs, rhs in
                let leftDate = lhs.element.createdAt ?? .distantPast
                let rightDate = rhs.element.createdAt ?? .distantPast
                if leftDate != rightDate {
                    return leftDate < rightDate
                }
                if lhs.element.sourceOrder != rhs.element.sourceOrder {
                    return lhs.element.sourceOrder < rhs.element.sourceOrder
                }
                return lhs.offset < rhs.offset
            }?
            .element
    }

    private static func relationshipDate(
        for dependency: BeadDependency,
        on issue: BeadIssue,
        resolveIssue: (String) -> BeadIssue?
    ) -> Date? {
        let otherID = dependency.issueID == issue.id ? dependency.dependsOnID : dependency.issueID
        return latestDate(
            dependency.createdAt,
            issue.createdAt,
            resolveIssue(otherID)?.createdAt
        )
    }

    private static func latestDate(_ dates: Date?...) -> Date? {
        dates.compactMap { $0 }.max()
    }
}
