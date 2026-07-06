import Foundation

struct BeadIssue: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var description: String
    var design: String
    var acceptanceCriteria: String
    var notes: String
    var status: String
    var priority: Int
    var issueType: String
    var assignee: String?
    var owner: String?
    var createdAt: Date?
    var updatedAt: Date?
    var closedAt: Date?
    var dueAt: Date?
    var deferUntil: Date?
    var externalRef: String?
    var parentID: String?
    var labels: [String]
    var dependencyCount: Int
    var dependentCount: Int
    var commentCount: Int
    var pinned: Bool
    var ephemeral: Bool
    var isTemplate: Bool

    var summaryText: String {
        [
            title,
            description,
            design,
            acceptanceCriteria,
            notes,
            labels.joined(separator: " "),
            assignee ?? "",
            owner ?? "",
            externalRef ?? ""
        ]
            .joined(separator: " ")
    }
}

enum IssueListMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case outline = "Outline"
    case flat = "Flat"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .outline:
            return "list.bullet.indent"
        case .flat:
            return "list.bullet"
        }
    }
}

struct IssueListRow: Identifiable, Hashable, Sendable {
    var id: String { issueID }
    var issueID: String
    var depth: Int
    var hasChildren: Bool
    var childProgress: IssueChildProgress?
    var isExpanded: Bool
    var isContext: Bool
}

struct IssueChildProgress: Hashable, Sendable {
    var completedCount: Int
    var workedCount: Int
    var totalCount: Int
}

struct BeadDependency: Identifiable, Hashable, Sendable {
    var id: String { "\(issueID)->\(dependsOnID):\(type)" }
    var issueID: String
    var dependsOnID: String
    var type: String
    var createdAt: Date?
}

struct BeadComment: Identifiable, Hashable, Sendable {
    var id: String
    var issueID: String
    var author: String?
    var text: String
    var createdAt: Date?
    var updatedAt: Date?
}

struct IssueDraft: Equatable, Identifiable, Sendable {
    var id: String?
    var title: String
    var description: String
    var design: String
    var acceptanceCriteria: String
    var notes: String
    var status: String
    var priority: Int
    var issueType: String
    var assignee: String
    var labelsText: String
    var dueAt: Date?
    var deferUntil: Date?

    var stableID: String {
        id ?? "new"
    }

    var labels: [String] {
        get {
            Self.normalizedLabels(labelsText)
        }
        set {
            labelsText = Self.normalizedLabelText(newValue)
        }
    }

    static func blank(defaultType: String, defaultStatus: String) -> IssueDraft {
        IssueDraft(
            id: nil,
            title: "",
            description: "",
            design: "",
            acceptanceCriteria: "",
            notes: "",
            status: defaultStatus,
            priority: 2,
            issueType: defaultType,
            assignee: "",
            labelsText: ""
        )
    }

    init(issue: BeadIssue) {
        id = issue.id
        title = issue.title
        description = issue.description
        design = issue.design
        acceptanceCriteria = issue.acceptanceCriteria
        notes = issue.notes
        status = issue.status
        priority = issue.priority
        issueType = issue.issueType
        assignee = issue.assignee ?? ""
        labelsText = issue.labels.joined(separator: ", ")
        dueAt = issue.dueAt
        deferUntil = issue.deferUntil
    }

    init(
        id: String?,
        title: String,
        description: String,
        design: String,
        acceptanceCriteria: String,
        notes: String,
        status: String,
        priority: Int,
        issueType: String,
        assignee: String,
        labelsText: String,
        dueAt: Date? = nil,
        deferUntil: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.design = design
        self.acceptanceCriteria = acceptanceCriteria
        self.notes = notes
        self.status = status
        self.priority = priority
        self.issueType = issueType
        self.assignee = assignee
        self.labelsText = labelsText
        self.dueAt = dueAt
        self.deferUntil = deferUntil
    }

    static func normalizedLabels(_ labelsText: String) -> [String] {
        labelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func normalizedLabelText(_ labels: [String]) -> String {
        labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

enum IssueSort: String, CaseIterable, Identifiable, Sendable {
    case priority = "Priority"
    case updated = "Updated"
    case created = "Created"
    case title = "Title"
    case status = "Status"
    case type = "Type"

    var id: String { rawValue }
}

enum SortDirection: String, CaseIterable, Identifiable, Sendable {
    case ascending = "Ascending"
    case descending = "Descending"

    var id: String { rawValue }
}

struct BeadIssueSortOrder: Sendable {
    var sort: IssueSort
    var direction: SortDirection

    func areInIncreasingOrder(_ lhs: BeadIssue, _ rhs: BeadIssue) -> Bool {
        let comparison = compare(lhs, rhs)
        switch comparison {
        case .orderedAscending:
            return direction == .ascending
        case .orderedDescending:
            return direction == .descending
        case .orderedSame:
            return false
        }
    }

    private func compare(_ lhs: BeadIssue, _ rhs: BeadIssue) -> ComparisonResult {
        let primary: ComparisonResult
        switch sort {
        case .priority:
            primary = compareInts(lhs.priority, rhs.priority)
                .then(compareDates(rhs.updatedAt, lhs.updatedAt))
        case .updated:
            primary = compareDates(lhs.updatedAt, rhs.updatedAt)
        case .created:
            primary = compareDates(lhs.createdAt, rhs.createdAt)
        case .title:
            primary = compareStrings(lhs.title, rhs.title)
        case .status:
            primary = compareStrings(lhs.status, rhs.status)
        case .type:
            primary = compareStrings(lhs.issueType, rhs.issueType)
        }
        return primary.then(compareStrings(lhs.id, rhs.id))
    }

    private func compareInts(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let left = lhs ?? .distantPast
        let right = rhs ?? .distantPast
        if left < right { return .orderedAscending }
        if left > right { return .orderedDescending }
        return .orderedSame
    }

    private func compareStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedStandardCompare(rhs)
    }
}

private extension ComparisonResult {
    func then(_ next: ComparisonResult) -> ComparisonResult {
        self == .orderedSame ? next : self
    }
}
