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
    var gateAwaitType: GateAwaitType? = nil
    var gateAwaitID: String? = nil
    var gateTimeoutNanoseconds: Int64? = nil
    var assignee: String?
    var owner: String?
    var createdAt: Date?
    var createdBy: String? = nil
    var updatedAt: Date?
    var closedAt: Date?
    var closeReason: String? = nil
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

    var isGate: Bool {
        BeadIssueWorkflowPolicy.isReservedIssueType(issueType)
    }

    /// True when every field contributing to `summaryText` is unchanged. Used to carry
    /// pre-folded search bytes across index rebuilds; each comparison is cheap for an
    /// untouched issue because copy-on-write leaves both sides sharing storage.
    func hasSameSearchText(as other: BeadIssue) -> Bool {
        id == other.id
            && title == other.title
            && description == other.description
            && design == other.design
            && acceptanceCriteria == other.acceptanceCriteria
            && notes == other.notes
            && labels == other.labels
            && assignee == other.assignee
            && owner == other.owner
            && externalRef == other.externalRef
    }
}

enum BeadCompletionAction: Equatable, Sendable {
    case close
    case reopen
}

enum BeadIssueWorkflowPolicy {
    static let reservedIssueTypeError = "The gate type is reserved for gate actions."
    static let unsupportedEpicGateError = "Gate creation for epics is not supported by this Beads CLI yet."

    static func isReservedIssueType(_ type: String) -> Bool {
        normalizedIssueType(type) == BeadProjectIndex.gateIssueType
    }

    static func isNormalMutableIssueType(_ type: String) -> Bool {
        !isReservedIssueType(type)
    }

    static func normalMutableIssueTypes(_ types: [String]) -> [String] {
        types.filter(isNormalMutableIssueType)
    }

    static func canChangeIssueTypeThroughNormalMutation(_ issue: BeadIssue, to type: String) -> Bool {
        issue.issueType == type || (!issue.isGate && isNormalMutableIssueType(type))
    }

    static func canCreateGate(blocking issue: BeadIssue, isDone: Bool) -> Bool {
        gateCreationUnavailableMessage(blocking: issue, isDone: isDone) == nil
    }

    static func canAddBlockingDependency(blockedIssue: BeadIssue, blockerIssue: BeadIssue) -> Bool {
        isEpicIssueType(blockedIssue.issueType) == isEpicIssueType(blockerIssue.issueType)
    }

    static func blockingDependencyUnavailableMessage(blockedIssue: BeadIssue, blockerIssue: BeadIssue) -> String? {
        guard !canAddBlockingDependency(blockedIssue: blockedIssue, blockerIssue: blockerIssue) else {
            return nil
        }
        if isEpicIssueType(blockedIssue.issueType) {
            return "\(blockedIssue.id) is an epic, so it can only be blocked by another epic."
        }
        return "\(blockerIssue.id) is an epic, so it can only block other epics."
    }

    static func blockingCompatibleIssueTypes(with issueType: String, candidates: [String]) -> [String] {
        let needsEpicPeer = isEpicIssueType(issueType)
        return normalMutableIssueTypes(candidates).filter { candidate in
            isEpicIssueType(candidate) == needsEpicPeer
        }
    }

    static func gateCreationUnavailableMessage(blocking issue: BeadIssue, isDone: Bool) -> String? {
        if isDone {
            return "Reopen \(issue.id) before creating a gate."
        }
        if issue.isGate {
            return reservedIssueTypeError
        }
        if normalizedIssueType(issue.issueType) == "epic" {
            return unsupportedEpicGateError
        }
        return nil
    }

    private static func isEpicIssueType(_ type: String) -> Bool {
        normalizedIssueType(type) == "epic"
    }

    private static func normalizedIssueType(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func completionAction(for issues: [BeadIssue], isDone: (BeadIssue) -> Bool) -> BeadCompletionAction {
        guard !issues.isEmpty, issues.allSatisfy(isDone) else {
            return .close
        }
        return .reopen
    }

    static func completionTitle(
        issueCount: Int,
        issues: [BeadIssue],
        isDone: (BeadIssue) -> Bool
    ) -> String {
        let action = completionAction(for: issues, isDone: isDone)
        let hasDoneIssue = issues.contains(where: isDone)
        let hasOpenIssue = issues.contains { !isDone($0) }
        return completionTitle(
            for: action,
            issueCount: issueCount,
            hasMixedCompletionState: hasDoneIssue && hasOpenIssue
        )
    }

    static func completionSystemImage(for action: BeadCompletionAction) -> String {
        switch action {
        case .close:
            "checkmark.circle"
        case .reopen:
            "arrow.uturn.backward.circle"
        }
    }

    private static func completionTitle(
        for action: BeadCompletionAction,
        issueCount: Int,
        hasMixedCompletionState: Bool
    ) -> String {
        switch action {
        case .close:
            if issueCount > 1, hasMixedCompletionState {
                return "Close Open Selected..."
            }
            return issueCount == 1 ? "Close Bead..." : "Close Selected..."
        case .reopen:
            return issueCount == 1 ? "Reopen Bead" : "Reopen Selected"
        }
    }
}

enum IssueListMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case outline = "Outline"
    case flat = "Flat"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .outline:
            return BeadIconography.children
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
    var createdBy: String? = nil

    /// A "blocks" edge (`issueID` is blocked until `dependsOnID` closes). Matched
    /// case- and whitespace-insensitively, the single definition of the relationship.
    var isBlocking: Bool {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "blocks"
    }
}

struct BeadComment: Identifiable, Hashable, Sendable {
    var id: String
    var issueID: String
    var author: String?
    var text: String
    var createdAt: Date?
    var updatedAt: Date?
}

struct IssueDraft: Codable, Equatable, Identifiable, Sendable {
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
    var parentID: String?
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

    static func blank(defaultType: String, defaultStatus: String, parentID: String? = nil) -> IssueDraft {
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
            labelsText: "",
            parentID: parentID
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
        parentID = issue.parentID
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
        parentID: String? = nil,
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
        self.parentID = parentID
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

enum IssueMetadataDateUpdate: Equatable, Sendable {
    case unchanged
    case set(Date?)
}

enum IssueSort: String, CaseIterable, Codable, Identifiable, Sendable {
    case priority = "Priority"
    case updated = "Updated"
    case created = "Created"
    case title = "Title"
    case status = "Status"
    case type = "Type"

    var id: String { rawValue }
}

enum SortDirection: String, CaseIterable, Codable, Identifiable, Sendable {
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
        lhs.naturalCompare(rhs)
    }
}

private extension ComparisonResult {
    func then(_ next: ComparisonResult) -> ComparisonResult {
        self == .orderedSame ? next : self
    }
}
