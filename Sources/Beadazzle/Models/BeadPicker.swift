import Foundation

struct BeadPickerConfiguration: Hashable, Identifiable, Sendable {
    var id: String { action.id }
    var title: String
    var prompt: String
    var action: BeadPickerAction
    var scope: BeadPickerScope
    var quickCreate: QuickCreateConfiguration?
    var initialFilters = BeadPickerFilters()
    var initialMode = IssueListMode.outline

    static func parent(issue: BeadIssue) -> BeadPickerConfiguration {
        BeadPickerConfiguration(
            title: "Change Parent",
            prompt: "Find a parent bead",
            action: .setParent(issueID: issue.id),
            scope: .parentCandidates(for: issue.id),
            quickCreate: QuickCreateConfiguration(
                title: "Create Parent",
                defaultParentID: nil,
                createButtonTitle: "Create Parent"
            )
        )
    }

    static func blockedBy(issue: BeadIssue) -> BeadPickerConfiguration {
        BeadPickerConfiguration(
            title: "Blocked By",
            prompt: "Find the bead blocking this",
            action: .addBlockedBy(issueID: issue.id),
            scope: .relationshipCandidates(excluding: [issue.id]),
            quickCreate: QuickCreateConfiguration(
                title: "Create Blocker",
                defaultParentID: nil,
                createButtonTitle: "Create Blocker"
            )
        )
    }

    static func blocks(issue: BeadIssue) -> BeadPickerConfiguration {
        BeadPickerConfiguration(
            title: "Blocks Bead",
            prompt: "Find the bead this blocks",
            action: .addBlocks(issueID: issue.id),
            scope: .relationshipCandidates(excluding: [issue.id]),
            quickCreate: QuickCreateConfiguration(
                title: "Create Blocked Bead",
                defaultParentID: nil,
                createButtonTitle: "Create Blocked"
            )
        )
    }

    static func child(parent: BeadIssue) -> BeadPickerConfiguration {
        BeadPickerConfiguration(
            title: "Add Sub-issue",
            prompt: "Find an existing bead or create a child",
            action: .addChild(parentID: parent.id),
            scope: .childCandidates(parentID: parent.id),
            quickCreate: QuickCreateConfiguration(
                title: "Create Sub-issue",
                defaultParentID: parent.id,
                createButtonTitle: "Create Sub-issue"
            )
        )
    }
}

struct BeadPickerScope: Hashable, Sendable {
    var includesDone = false
    var includesGates = false
    var excludedIssueIDs: Set<String> = []
    var excludedDescendantRootIDs: Set<String> = []
    var excludedAncestorRootIDs: Set<String> = []

    static func relationshipCandidates(excluding ids: Set<String>) -> BeadPickerScope {
        BeadPickerScope(excludedIssueIDs: ids)
    }

    static func parentCandidates(for issueID: String) -> BeadPickerScope {
        BeadPickerScope(
            excludedIssueIDs: [issueID],
            excludedDescendantRootIDs: [issueID]
        )
    }

    static func childCandidates(parentID: String) -> BeadPickerScope {
        BeadPickerScope(
            excludedIssueIDs: [parentID],
            excludedDescendantRootIDs: [parentID],
            excludedAncestorRootIDs: [parentID]
        )
    }
}

enum BeadPickerAction: Hashable, Sendable {
    case setParent(issueID: String)
    case addBlockedBy(issueID: String)
    case addBlocks(issueID: String)
    case addChild(parentID: String)

    var id: String {
        switch self {
        case .setParent(let issueID):
            "set-parent|\(issueID)"
        case .addBlockedBy(let issueID):
            "blocked-by|\(issueID)"
        case .addBlocks(let issueID):
            "blocks|\(issueID)"
        case .addChild(let parentID):
            "add-child|\(parentID)"
        }
    }

    var allowsClearParent: Bool {
        if case .setParent = self { return true }
        return false
    }

    var needsPostCreateRelationship: Bool {
        switch self {
        case .addChild:
            false
        case .setParent, .addBlockedBy, .addBlocks:
            true
        }
    }
}

struct QuickCreateConfiguration: Hashable, Sendable {
    var title: String
    var defaultParentID: String?
    var createButtonTitle: String
}

struct BeadPickerFilters: Hashable, Sendable {
    var statusFilters: Set<String> = []
    var typeFilters: Set<String> = []
    var priorityFilters: Set<Int> = []
    var labelFilters: Set<String> = []

    var isEmpty: Bool {
        statusFilters.isEmpty
            && typeFilters.isEmpty
            && priorityFilters.isEmpty
            && labelFilters.isEmpty
    }
}

struct BeadPickerRow: Identifiable, Hashable, Sendable {
    var id: String { issue.id }
    var issue: BeadIssue
    var row: IssueListRow
    var isSelectable: Bool
}

struct BeadPickerQueryResult: Equatable, Sendable {
    var rows: [BeadPickerRow]
    var matchingIssueIDs: [String]

    static let empty = BeadPickerQueryResult(rows: [], matchingIssueIDs: [])
}
