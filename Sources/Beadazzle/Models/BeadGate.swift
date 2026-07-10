import Foundation

/// The condition a gate is waiting on before it resolves. Mirrors `bd`'s `await_type`
/// values (`human`, `timer`, `gh:run`, `gh:pr`, `bead`), preserving unknown values so a
/// newer `bd` never renders as blank.
enum GateAwaitType: Hashable, Sendable {
    case human
    case timer
    case githubRun
    case githubPR
    case bead
    case other(String)

    init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "human":
            self = .human
        case "timer":
            self = .timer
        case "gh:run":
            self = .githubRun
        case "gh:pr":
            self = .githubPR
        case "bead":
            self = .bead
        case let other:
            self = .other(other)
        }
    }

    /// The value `bd gate create --type` expects.
    var commandValue: String {
        switch self {
        case .human: "human"
        case .timer: "timer"
        case .githubRun: "gh:run"
        case .githubPR: "gh:pr"
        case .bead: "bead"
        case let .other(raw): raw
        }
    }

    var title: String {
        switch self {
        case .human: "Human approval"
        case .timer: "Timer"
        case .githubRun: "GitHub run"
        case .githubPR: "GitHub PR"
        case .bead: "Cross-rig bead"
        case let .other(raw): raw.isEmpty ? "Gate" : raw
        }
    }

    var systemImage: String {
        switch self {
        case .human: "person.badge.clock"
        case .timer: "timer"
        case .githubRun: "gearshape.2"
        case .githubPR: "arrow.triangle.pull"
        case .bead: "link"
        case .other: "flag"
        }
    }

    /// Gate types this app can create. Excludes `.bead` (needs a cross-rig id) and `.other`.
    static let creatable: [GateAwaitType] = [.timer, .human, .githubPR, .githubRun]
}

enum GateActionState: Int, Hashable, Sendable {
    case needsInput
    case elapsed
    case pending

    var isReady: Bool {
        switch self {
        case .needsInput, .elapsed:
            true
        case .pending:
            false
        }
    }
}

/// A Beads gate: a bead (`issue_type == "gate"`) that blocks another bead until it is
/// resolved (closed). Snapshot reads provide the display fields; `bd gate show --json`
/// enriches the selected gate with waiters.
struct BeadGate: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var awaitType: GateAwaitType
    var status: String
    var reason: String?
    var awaitID: String?
    /// Raw `bd` timeout in nanoseconds (timer gates only).
    var timeoutNanoseconds: Int64?
    var createdAt: Date?
    var updatedAt: Date?
    /// Populated only by `bd gate show`.
    var waiters: [String]
    /// Best-effort blocked-bead id parsed from the description; the dependency graph is the
    /// authoritative source (`index.dependentsByIssueID`).
    var blocksIssueID: String?

    /// A gate is actionable while it is not closed.
    var isOpen: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "closed"
    }

    var timeout: TimeInterval? {
        guard let timeoutNanoseconds else { return nil }
        return TimeInterval(timeoutNanoseconds) / 1_000_000_000
    }

    /// When a timer gate is expected to expire (`created_at + timeout`).
    var expiresAt: Date? {
        guard awaitType == .timer, let createdAt, let timeout else { return nil }
        return createdAt.addingTimeInterval(timeout)
    }

    func actionState(now: Date = Date()) -> GateActionState {
        guard isOpen else { return .pending }
        switch awaitType {
        case .human:
            return .needsInput
        case .timer:
            guard let expiresAt else { return .pending }
            return expiresAt <= now ? .elapsed : .pending
        case .githubRun, .githubPR, .bead, .other:
            return .pending
        }
    }
}

extension BeadGate {
    init?(issue: BeadIssue, waiters: [String] = []) {
        guard issue.isGate else { return nil }
        self.init(
            id: issue.id,
            title: issue.title,
            awaitType: issue.gateAwaitType ?? .other(""),
            status: issue.status,
            reason: Self.parseReason(from: issue.description),
            awaitID: issue.gateAwaitID,
            timeoutNanoseconds: issue.gateTimeoutNanoseconds,
            createdAt: issue.createdAt,
            updatedAt: issue.updatedAt,
            waiters: waiters,
            blocksIssueID: Self.parseBlockedID(from: issue.description)
        )
    }

    /// Decode the array shape returned by `bd gate list --json`. `bd` emits the literal
    /// `null` when there are no gates, so fragments are allowed and non-array input yields [].
    static func decodeList(from data: Data) throws -> [BeadGate] {
        guard let array = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { decode(from: $0) }
    }

    /// Decode the single-object shape returned by `bd gate show --json` (tolerates an array).
    static func decodeOne(from data: Data) throws -> BeadGate? {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let record = object as? [String: Any] {
            return decode(from: record)
        }
        if let array = object as? [[String: Any]] {
            return array.first.flatMap(decode(from:))
        }
        return nil
    }

    static func decode(from record: [String: Any]) -> BeadGate? {
        guard let id = record["id"] as? String, !id.isEmpty else { return nil }
        let description = record["description"] as? String
        let awaitTypeRaw = stringValue(record["await_type"]) ?? stringValue(record["gate_type"]) ?? ""
        return BeadGate(
            id: id,
            title: (record["title"] as? String) ?? id,
            awaitType: GateAwaitType(rawValue: awaitTypeRaw),
            status: (record["status"] as? String) ?? "open",
            reason: parseReason(from: description),
            awaitID: stringValue(record["await_id"]),
            timeoutNanoseconds: int64Value(record["timeout"]),
            createdAt: date(from: record["created_at"]),
            updatedAt: date(from: record["updated_at"]),
            waiters: stringArray(record["waiters"]),
            blocksIssueID: parseBlockedID(from: description)
        )
    }

    // MARK: Description parsing

    /// Descriptions look like: "Ad-hoc gate blocking <id>\n\nReason: <text>".
    static func parseReason(from description: String?) -> String? {
        guard let description else { return nil }
        guard let range = description.range(of: "Reason:") else { return nil }
        let value = description[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func parseBlockedID(from description: String?) -> String? {
        // Anchored to the first line ("Ad-hoc gate blocking <id>") so a reason mentioning
        // "blocking" can't be mistaken for the blocked id.
        guard let firstLine = description?.split(separator: "\n", maxSplits: 1).first else { return nil }
        guard let range = firstLine.range(of: "blocking ") else { return nil }
        let token = firstLine[range.upperBound...].prefix { !$0.isWhitespace }
        return token.isEmpty ? nil : String(token)
    }

    // MARK: Value coercion

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string.isEmpty ? nil : string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [String]) ?? (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            return Int64(string)
        }
        return nil
    }

    static func date(from value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return BeadFormatters.parseDate(string)
    }
}
