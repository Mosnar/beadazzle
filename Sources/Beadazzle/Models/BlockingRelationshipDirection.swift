import Foundation

enum BlockingRelationshipDirection: String, CaseIterable, Sendable {
    case blockedBy
    case blocking

    var title: String {
        switch self {
        case .blockedBy:
            "Blocked by"
        case .blocking:
            "Blocking"
        }
    }

    var actionTitle: String {
        switch self {
        case .blockedBy:
            "Blocked by..."
        case .blocking:
            "Blocks bead..."
        }
    }

    var systemImage: String {
        switch self {
        case .blockedBy:
            BeadIconography.blockedBy
        case .blocking:
            BeadIconography.blocking
        }
    }

    func summary(count: Int) -> String {
        let bead = count == 1 ? "bead" : "beads"
        switch self {
        case .blockedBy:
            return "Blocked by \(count.formatted()) active \(bead)"
        case .blocking:
            return "Blocking \(count.formatted()) active \(bead)"
        }
    }

    var accessibilityHint: String {
        "Shows active blocking relationships"
    }
}

struct BlockingRelationshipItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let status: String
    let statusCategory: BeadStatusCategory

    init(issue: BeadIssue, statusCategory: BeadStatusCategory) {
        id = issue.id
        title = issue.title
        status = issue.status
        self.statusCategory = statusCategory
    }
}
