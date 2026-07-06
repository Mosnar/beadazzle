import Foundation

enum BeadBookmark: CaseIterable, Hashable, Identifiable, Sendable {
    case ready
    case stale
    case open
    case inProgress
    case blocked
    case closed
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .ready:
            "Ready"
        case .stale:
            "Stale"
        case .open:
            "Open"
        case .inProgress:
            BeadStatusCategory.wip.title
        case .blocked:
            "Blocked"
        case .closed:
            "Closed"
        case .all:
            "All Beads"
        }
    }

    var systemImage: String {
        switch self {
        case .ready:
            "checkmark.circle"
        case .stale:
            "clock.arrow.circlepath"
        case .all:
            "circle.hexagongrid"
        case .open, .inProgress, .blocked, .closed:
            statusCategory?.systemImage ?? "questionmark.circle"
        }
    }

    func statusNames(in semantics: BeadProjectSemantics) -> [String]? {
        switch self {
        case .all:
            return nil
        case .ready, .open:
            return semantics.statuses
                .filter { $0.category == .active }
                .map(\.name)
        case .stale:
            return semantics.statuses
                .filter { status in
                    if status.isBuiltIn {
                        return Self.defaultStaleStatusNames.contains(status.name)
                    }
                    return status.category != .done
                }
                .map(\.name)
        case .inProgress:
            return semantics.statuses
                .filter { $0.category == .wip && !$0.isBuiltInBlocked }
                .map(\.name)
        case .blocked:
            return semantics.statuses
                .filter(\.isBuiltInBlocked)
                .map(\.name)
        case .closed:
            return semantics.statuses
                .filter { $0.category == .done }
                .map(\.name)
        }
    }

    var statusCategory: BeadStatusCategory? {
        switch self {
        case .all:
            nil
        case .ready, .stale, .open:
            .active
        case .inProgress:
            .wip
        case .blocked:
            .frozen
        case .closed:
            .done
        }
    }
}

private extension BeadBookmark {
    static let defaultStaleStatusNames: Set<String> = ["open", "in_progress", "blocked", "deferred"]
}

private extension BeadStatusDefinition {
    var isBuiltInBlocked: Bool {
        isBuiltIn && name == "blocked"
    }
}
