import Foundation

enum IssueTextSection: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case description
    case acceptanceCriteria
    case design
    case notes

    static let canonicalOrder: [IssueTextSection] = [
        .description,
        .acceptanceCriteria,
        .design,
        .notes
    ]

    /// Document-ID prefix the unsaved creation draft uses, since it has no
    /// issue ID to key its fields by yet.
    static let creationDocumentIDPrefix = "new-bead"

    var id: Self { self }

    var title: String {
        switch self {
        case .description:
            "Description"
        case .acceptanceCriteria:
            "Acceptance Criteria"
        case .design:
            "Design"
        case .notes:
            "Notes"
        }
    }

    var placeholder: String {
        switch self {
        case .description:
            "Add description..."
        case .acceptanceCriteria:
            "Add acceptance criteria..."
        case .design:
            "Add design notes..."
        case .notes:
            "Add notes..."
        }
    }

    var storageKey: String {
        switch self {
        case .description:
            "description"
        case .acceptanceCriteria:
            "acceptance-criteria"
        case .design:
            "design"
        case .notes:
            "notes"
        }
    }

    /// Identifier the markdown engine uses for this field's document.
    func documentID(prefix: String) -> String {
        "\(prefix)-\(storageKey)"
    }

    var minimumLineCount: Int {
        switch self {
        case .description, .acceptanceCriteria, .design:
            3
        case .notes:
            2
        }
    }

    func text(in draft: IssueDraft) -> String {
        switch self {
        case .description:
            draft.description
        case .acceptanceCriteria:
            draft.acceptanceCriteria
        case .design:
            draft.design
        case .notes:
            draft.notes
        }
    }

    /// Checks for meaningful content without allocating a trimmed copy and
    /// stops at the first non-whitespace character.
    func hasContent(in draft: IssueDraft) -> Bool {
        Self.hasContent(text(in: draft))
    }

    static func hasContent(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }
}
