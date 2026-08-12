import Foundation

enum IssueDraftField: String, CaseIterable, Codable, Hashable, Sendable {
    case title
    case description
    case design
    case acceptanceCriteria
    case notes
    case status
    case priority
    case issueType
    case assignee
    case labels
    case dueAt
    case deferUntil

    var displayName: String {
        switch self {
        case .title: "title"
        case .description: "description"
        case .design: "design"
        case .acceptanceCriteria: "acceptance criteria"
        case .notes: "notes"
        case .status: "status"
        case .priority: "priority"
        case .issueType: "type"
        case .assignee: "assignee"
        case .labels: "labels"
        case .dueAt: "due date"
        case .deferUntil: "deferred date"
        }
    }
}

/// A recoverable, unsaved edit to an existing bead. The baseline travels with the
/// draft so a later project reload can still distinguish local and remote changes.
struct IssueEditDraftState: Codable, Equatable, Sendable {
    var draft: IssueDraft
    var baseline: IssueDraft
    var conflictingFields: Set<IssueDraftField> = []
}

struct IssueDraftRebaseResult: Equatable, Sendable {
    var draft: IssueDraft
    var conflictingFields: Set<IssueDraftField>
}

struct IssueDraftSaveContext: Equatable, Sendable {
    var baseline: IssueDraft
    var allowsConflictingChanges: Bool
}

struct IssueDraftConflictError: LocalizedError, Sendable {
    var fields: Set<IssueDraftField>

    var errorDescription: String? {
        let names = IssueDraftField.allCases
            .filter(fields.contains)
            .map(\.displayName)
        let joined = names.formatted(.list(type: .and))
        return "This bead changed after editing began. Review the pulled changes to \(joined), then save again."
    }
}

extension IssueDraft {
    func fieldsChanged(comparedTo baseline: IssueDraft) -> Set<IssueDraftField> {
        Set(IssueDraftField.allCases.filter { !matches(baseline, field: $0) })
    }

    func rebased(from baseline: IssueDraft, onto issue: BeadIssue) -> IssueDraftRebaseResult {
        let remote = IssueDraft(issue: issue)
        let localChanges = fieldsChanged(comparedTo: baseline)
        let remoteChanges = remote.fieldsChanged(comparedTo: baseline)
        let conflicts = localChanges.intersection(remoteChanges).filter {
            !matches(remote, field: $0)
        }
        var rebased = remote
        for field in localChanges {
            rebased.apply(field, from: self)
        }
        return IssueDraftRebaseResult(
            draft: rebased,
            conflictingFields: Set(conflicts)
        )
    }

    func matches(_ other: IssueDraft, field: IssueDraftField) -> Bool {
        switch field {
        case .title: title == other.title
        case .description: description == other.description
        case .design: design == other.design
        case .acceptanceCriteria: acceptanceCriteria == other.acceptanceCriteria
        case .notes: notes == other.notes
        case .status: status == other.status
        case .priority: priority == other.priority
        case .issueType: issueType == other.issueType
        case .assignee: assignee == other.assignee
        // Beads labels are a set even though the draft stores them in a stable array for
        // presentation. Reordering the same labels must not create a pulled-change conflict.
        case .labels: Set(labels) == Set(other.labels)
        case .dueAt: dueAt == other.dueAt
        case .deferUntil: deferUntil == other.deferUntil
        }
    }

    private mutating func apply(_ field: IssueDraftField, from source: IssueDraft) {
        switch field {
        case .title: title = source.title
        case .description: description = source.description
        case .design: design = source.design
        case .acceptanceCriteria: acceptanceCriteria = source.acceptanceCriteria
        case .notes: notes = source.notes
        case .status: status = source.status
        case .priority: priority = source.priority
        case .issueType: issueType = source.issueType
        case .assignee: assignee = source.assignee
        case .labels: labels = source.labels
        case .dueAt: dueAt = source.dueAt
        case .deferUntil: deferUntil = source.deferUntil
        }
    }
}
