import Foundation

enum NewBeadAssigneePreference: Equatable, Sendable {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case unassigned
        case owner
        case specific

        var id: Self { self }

        var title: String {
            switch self {
            case .unassigned:
                "Unassigned"
            case .owner:
                "Owner"
            case .specific:
                "Specific Assignee"
            }
        }
    }

    case unassigned
    case owner
    case specific(String)

    var mode: Mode {
        switch self {
        case .unassigned:
            .unassigned
        case .owner:
            .owner
        case .specific:
            .specific
        }
    }

    var specificValue: String {
        guard case .specific(let value) = self else { return "" }
        return value
    }

    var normalized: Self {
        switch self {
        case .unassigned:
            return .unassigned
        case .owner:
            return .owner
        case .specific(let value):
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? .unassigned : .specific(value)
        }
    }

    var displayName: String {
        switch normalized {
        case .unassigned:
            "Unassigned"
        case .owner:
            "Owner"
        case .specific(let value):
            value
        }
    }

    func resolvedAssignee(ownerIdentity: BeadOwnerIdentity) -> String {
        switch normalized {
        case .unassigned:
            ""
        case .owner:
            ownerIdentity.value ?? ""
        case .specific(let value):
            value
        }
    }
}

enum BeadOwnerIdentitySource: Equatable, Sendable {
    case environment
    case gitConfiguration

    var displayName: String {
        switch self {
        case .environment:
            "GIT_AUTHOR_EMAIL"
        case .gitConfiguration:
            "Git configuration"
        }
    }
}

enum BeadOwnerIdentity: Equatable, Sendable {
    case resolving
    case resolved(value: String, source: BeadOwnerIdentitySource)
    case unavailable

    var value: String? {
        guard case .resolved(let value, _) = self else { return nil }
        return value
    }

    var source: BeadOwnerIdentitySource? {
        guard case .resolved(_, let source) = self else { return nil }
        return source
    }
}
