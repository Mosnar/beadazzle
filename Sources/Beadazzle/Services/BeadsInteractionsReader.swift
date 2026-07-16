import Foundation

/// Decodes individual entries from `.beads/interactions.jsonl`.
/// Production reads are coordinated by `BeadActivityHistoryRepository`, which keeps
/// only compact file offsets for the project and decodes events for one issue at a time.
struct BeadsInteractionsReader {
    static let fileName = "interactions.jsonl"

    private let decoder = JSONDecoder()

    func issueID(fromJSONLLine rawLineData: Data) -> String? {
        guard let lineData = normalized(rawLineData),
              let record = try? decoder.decode(InteractionHeader.self, from: lineData) else {
            return nil
        }
        return record.issueID.nilIfBlank
    }

    func event(fromJSONLLine rawLineData: Data, lineNumber: Int) -> BeadIssueEvent? {
        guard let lineData = normalized(rawLineData),
              let record = try? decoder.decode(InteractionRecord.self, from: lineData),
              let issueID = record.issueID.nilIfBlank else {
            return nil
        }

        return BeadIssueEvent(
            // The line-number fallback keeps identity stable across reloads because
            // the interaction log is append-only.
            id: record.id?.nilIfBlank ?? "interaction-line-\(lineNumber)",
            issueID: issueID,
            kind: record.kind?.nilIfBlank ?? "unknown",
            actor: record.actor?.nilIfBlank,
            createdAt: BeadFormatters.parseDate(record.createdAt),
            field: record.extra?.field?.nilIfBlank,
            oldValue: compactValue(record.extra?.oldValue, field: record.extra?.field),
            newValue: compactValue(record.extra?.newValue, field: record.extra?.field),
            reason: record.extra?.reason?.nilIfBlank,
            sourceOrder: max(0, lineNumber - 1)
        )
    }

    /// Test and fixture helper. Production code never materializes a project-wide
    /// event dictionary.
    func events(fromJSONLData data: Data) -> [String: [BeadIssueEvent]] {
        var eventsByIssueID: [String: [BeadIssueEvent]] = [:]
        for (lineNumber, line) in data.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
            guard let event = event(fromJSONLLine: Data(line), lineNumber: lineNumber + 1) else {
                continue
            }
            eventsByIssueID[event.issueID, default: []].append(event)
        }
        return eventsByIssueID.mapValues(Self.sorted)
    }

    static func sorted(_ events: [BeadIssueEvent]) -> [BeadIssueEvent] {
        events.sorted { lhs, rhs in
            let left = lhs.createdAt ?? .distantPast
            let right = rhs.createdAt ?? .distantPast
            if left != right {
                return left < right
            }
            return lhs.sourceOrder < rhs.sourceOrder
        }
    }

    private func normalized(_ rawLineData: Data) -> Data? {
        guard !rawLineData.isEmpty else { return nil }
        guard rawLineData.last == 13 else { return rawLineData }
        return rawLineData.dropLast()
    }

    /// Body fields are never rendered inline. Avoid retaining arbitrarily large old
    /// and new values even for the selected issue if a future `bd` version logs them.
    private func compactValue(_ value: String?, field: String?) -> String? {
        guard let value = value?.nilIfBlank else { return nil }
        let normalizedField = field?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.proseFields.contains(normalizedField ?? "") {
            return nil
        }
        guard value.count > Self.maximumInlineValueLength else { return value }
        return String(value.prefix(Self.maximumInlineValueLength - 1)) + "…"
    }

    private static let maximumInlineValueLength = 160
    private static let proseFields: Set<String> = [
        "description", "design", "notes", "acceptance_criteria"
    ]
}

private struct InteractionHeader: Decodable {
    var issueID: String

    enum CodingKeys: String, CodingKey {
        case issueID = "issue_id"
    }
}

private struct InteractionRecord: Decodable {
    var id: String?
    var kind: String?
    var createdAt: String?
    var actor: String?
    var issueID: String
    var extra: InteractionExtra?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case createdAt = "created_at"
        case actor
        case issueID = "issue_id"
        case extra
    }
}

private struct InteractionExtra: Decodable {
    var field: String?
    var oldValue: String?
    var newValue: String?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case field
        case oldValue = "old_value"
        case newValue = "new_value"
        case reason
    }
}
