import Foundation

enum BeadStatusCategory: String, CaseIterable, Identifiable, Sendable {
    case active
    case wip
    case done
    case frozen
    case uncategorized

    var id: Self { self }

    var title: String {
        switch self {
        case .active:
            "Active"
        case .wip:
            "In Progress"
        case .done:
            "Done"
        case .frozen:
            "Frozen"
        case .uncategorized:
            "Uncategorized"
        }
    }

    var systemImage: String {
        switch self {
        case .active:
            "circle"
        case .wip:
            "circle.lefthalf.filled"
        case .done:
            "checkmark.circle"
        case .frozen:
            "snowflake"
        case .uncategorized:
            "questionmark.circle"
        }
    }
}

enum BeadDefinitionSource: String, Hashable, Sendable {
    case builtIn
    case core
    case custom
    case observed

    var title: String {
        switch self {
        case .builtIn:
            "Built In"
        case .core:
            "Core"
        case .custom:
            "Custom"
        case .observed:
            "Observed"
        }
    }
}

struct BeadStatusDefinition: Hashable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var category: BeadStatusCategory
    var icon: String?
    var description: String?
    var isBuiltIn: Bool = false
    var source: BeadDefinitionSource = .observed

    var isCustom: Bool {
        source == .custom
    }
}

struct BeadTypeDefinition: Hashable, Identifiable, Sendable {
    var id: String { name }
    var name: String
    var description: String?
    var source: BeadDefinitionSource = .observed

    var isCustom: Bool {
        source == .custom
    }
}

struct BeadProjectSemantics: Equatable, Sendable {
    var statuses: [BeadStatusDefinition]
    var types: [BeadTypeDefinition]

    static let empty = BeadProjectSemantics(statuses: [], types: [])

    var statusNames: [String] {
        statuses.map(\.name)
    }

    var typeNames: [String] {
        types.map(\.name)
    }

    var excludingSystemRecordTypes: BeadProjectSemantics {
        BeadProjectSemantics(
            statuses: statuses,
            types: types.filter { !BeadIssueWorkflowPolicy.isSystemRecordIssueType($0.name) }
        )
    }

    func category(forStatus status: String) -> BeadStatusCategory {
        statuses.first { $0.name == status }?.category ?? .uncategorized
    }

    func isDone(_ issue: BeadIssue) -> Bool {
        let category = category(forStatus: issue.status)
        if category != .uncategorized {
            return category == .done
        }
        return issue.closedAt != nil
    }

    func isWorkedOn(_ issue: BeadIssue) -> Bool {
        isDone(issue) || category(forStatus: issue.status) == .wip
    }

    static func fallback(issues: [BeadIssue]) -> BeadProjectSemantics {
        let observedStatuses = Set(issues.lazy.compactMap { issue in
            !issue.isSystemRecord && !issue.status.isEmpty ? issue.status : nil
        })
        let statuses = observedStatuses.sorted().map { status in
            BeadStatusDefinition(name: status, category: .uncategorized, icon: nil, description: nil)
        }
        let observedTypes = Set(issues.lazy.compactMap { issue in
            let type = issue.issueType
            return !type.isEmpty && !BeadIssueWorkflowPolicy.isSystemRecordIssueType(type) ? type : nil
        })
        let types = observedTypes.sorted().map { type in
            BeadTypeDefinition(name: type, description: nil)
        }
        return BeadProjectSemantics(statuses: statuses, types: types)
    }
}
