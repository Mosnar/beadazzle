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
        let statuses = Array(Set(issues.map(\.status).filter { !$0.isEmpty })).sorted().map { status in
            BeadStatusDefinition(name: status, category: .uncategorized, icon: nil, description: nil)
        }
        let types = Array(Set(issues.map(\.issueType).filter { !$0.isEmpty })).sorted().map { type in
            BeadTypeDefinition(name: type, description: nil)
        }
        return BeadProjectSemantics(statuses: statuses, types: types)
    }
}
