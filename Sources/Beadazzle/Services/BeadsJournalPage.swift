import Foundation
import OSLog

enum BeadsJournalError: String, Error {
    case unavailable
    case invalidRecord
    case requiresSnapshot
    case pageFull
    case anchorChanged
    case sequenceGap
    case emptyFeed
    case duplicateIssueID
    case unsupportedOperation
    case configurationChanged
    case busyBaseline

    private static let logger = Logger(subsystem: "com.beadazzle.Beadazzle", category: "JournalRefresh")

    static func logFallback(_ error: Error) {
        // Never log issue contents, paths, or command output.
        let reason = (error as? Self)?.rawValue ?? "commandOrDecodeFailure"
        logger.debug("Using full snapshot: \(reason, privacy: .public)")
    }
}

/// The CLI has no head-only read. Both discovery and catch-up have hard limits;
/// reaching either limit uses a full export instead of draining an unbounded history.
enum BeadsJournalPage: Sendable {
    static let recordLimit = 2_048
    static let outputLimit = 8 * 1_024 * 1_024
    static let commandTimeout: Duration = .seconds(3)

    case records([BeadsJournalRecord])
    case truncated(head: Int64)

    static func decode(_ output: String, exitStatus: Int32) throws -> Self {
        if exitStatus != 0 {
            struct Truncation: Decodable {
                let code: String
                let head: Int64
            }
            let data = Data(BeadsJSONCommandOutput.payload(from: output).utf8)
            guard let error = try? JSONDecoder().decode(Truncation.self, from: data),
                  error.code == "events_journal_truncated", error.head >= 0 else {
                throw BeadsJournalError.unavailable
            }
            return .truncated(head: error.head)
        }
        // Warnings on stderr share this runner's output pipe. Refuse them, including
        // the disabled-journal notice; an empty disabled feed is not a current feed.
        return .records(try output.split(whereSeparator: \.isNewline).map { line in
            try BeadsJournalRecord(data: Data(line.utf8))
        })
    }
}

struct BeadsJournalRecord: Equatable, Sendable {
    let sequence: Int64
    let operation: String
    let issueID: String
    let data: Data

    init(data: Data) throws {
        struct Header: Decodable {
            let seq: Int64
            let op: String
            let issue_id: String
        }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.seq > 0, !header.op.isEmpty,
              !header.issue_id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BeadsJournalError.invalidRecord
        }
        sequence = header.seq
        operation = header.op
        issueID = header.issue_id
        self.data = data
    }

    /// Only non-structural edits to existing exported beads are accelerated. Other
    /// operations require an export so filters, relationships and counts stay exact.
    func replacingFields(in original: BeadIssue) throws -> BeadIssue {
        guard operation == "update" || operation == "close" else {
            throw BeadsJournalError.unsupportedOperation
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = envelope["issue"] as? [String: Any],
              record["id"] as? String == original.id,
              record["title"] is String,
              record["status"] is String,
              record["issue_type"] is String,
              let priority = record["priority"] as? NSNumber,
              CFGetTypeID(priority) != CFBooleanGetTypeID(),
              (0...4).contains(priority.intValue),
              priority.doubleValue == Double(priority.intValue),
              let updatedAt = record["updated_at"] as? String,
              BeadFormatters.parseDate(updatedAt) != nil,
              let createdAt = record["created_at"] as? String,
              BeadFormatters.parseDate(createdAt) != nil else {
            throw BeadsJournalError.requiresSnapshot
        }
        let textFields = [
            "description", "design", "acceptance_criteria", "notes",
            "await_type", "await_id", "assignee", "owner", "created_by", "close_reason",
            "external_ref", "parent", "parent_id", "closed_at", "due_at", "defer_until"
        ]
        for key in textFields {
            if let value = record[key], !(value is NSNull), !(value is String) {
                throw BeadsJournalError.invalidRecord
            }
        }
        for key in ["pinned", "ephemeral", "is_template", "no_history"] {
            if let value = record[key], !(value is NSNull) {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw BeadsJournalError.invalidRecord
                }
                if key == "no_history", number.boolValue { throw BeadsJournalError.requiresSnapshot }
            }
        }
        if let labels = record["labels"], !(labels is NSNull), !(labels is [String]) {
            throw BeadsJournalError.invalidRecord
        }
        for key in ["closed_at", "due_at", "defer_until"] {
            if let value = record[key] as? String, !value.isEmpty, BeadFormatters.parseDate(value) == nil {
                throw BeadsJournalError.invalidRecord
            }
        }
        if let value = record["timeout"], !(value is NSNull) {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  Int64(number.stringValue) != nil else { throw BeadsJournalError.invalidRecord }
        }
        var issue = BeadsJSONLSnapshotReader().loadIssue(
            record: record, id: original.id, dependencyRecords: []
        )
        guard !issue.status.isEmpty, issue.status != "tombstone",
              issue.issueType == original.issueType,
              issue.owner == original.owner,
              issue.ephemeral == original.ephemeral,
              issue.isTemplate == original.isTemplate,
              issue.parentID == nil || issue.parentID == original.parentID else {
            throw BeadsJournalError.requiresSnapshot
        }
        // Journal issue payloads omit these export-derived fields. No structural or
        // comment operation is accepted in this batch, so their baseline stays valid.
        issue.parentID = original.parentID
        issue.dependencyCount = original.dependencyCount
        issue.dependentCount = original.dependentCount
        issue.commentCount = original.commentCount
        return issue
    }
}
