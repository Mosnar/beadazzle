import Foundation

/// One entry from a project's `interactions.jsonl` event log: a recorded change to an
/// issue with the actor, timestamp, and any field values supplied by `bd`. Read-only
/// history; never written by the app.
struct BeadIssueEvent: Identifiable, Hashable, Sendable {
    var id: String
    var issueID: String
    var kind: String
    var actor: String?
    var createdAt: Date?
    var field: String?
    var oldValue: String?
    var newValue: String?
    var reason: String?
    /// The event's zero-based line position in the append-only log. This is the
    /// authoritative, stable tie-breaker when timestamps are equal.
    var sourceOrder: Int = 0
}
