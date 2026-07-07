import Foundation

struct BeadWorkspaceSnapshot: Equatable, Sendable {
    var bookmark: BeadBookmark
    var selectedIDs: Set<String>
    var fullPageDetailIssueID: String?
    var searchText: String
    var statusFilters: Set<String>
    var typeFilters: Set<String>
    var priorityFilters: Set<Int>
    var labelFilters: Set<String>
    var sort: IssueSort
    var sortDirection: SortDirection
    var issueListMode: IssueListMode
    var outlineState: BeadOutlineSelectionState
    var creationDraft: IssueDraft?
}

struct BeadWorkspaceHistory: Equatable, Sendable {
    var backStack: [BeadWorkspaceSnapshot] = []
    var currentSnapshot: BeadWorkspaceSnapshot?
    var forwardStack: [BeadWorkspaceSnapshot] = []

    var canGoBack: Bool {
        !backStack.isEmpty
    }

    var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    mutating func reset(to snapshot: BeadWorkspaceSnapshot) {
        backStack.removeAll(keepingCapacity: false)
        forwardStack.removeAll(keepingCapacity: false)
        currentSnapshot = snapshot
    }

    mutating func record(_ snapshot: BeadWorkspaceSnapshot) {
        guard currentSnapshot != snapshot else { return }
        if let currentSnapshot {
            backStack.append(currentSnapshot)
        }
        currentSnapshot = snapshot
        forwardStack.removeAll(keepingCapacity: false)
    }

    mutating func updateCurrent(_ snapshot: BeadWorkspaceSnapshot) {
        guard currentSnapshot != nil else { return }
        currentSnapshot = snapshot
    }

    mutating func goBack() -> BeadWorkspaceSnapshot? {
        guard let previousSnapshot = backStack.popLast() else { return nil }
        if let currentSnapshot {
            forwardStack.append(currentSnapshot)
        }
        currentSnapshot = previousSnapshot
        return previousSnapshot
    }

    mutating func goForward() -> BeadWorkspaceSnapshot? {
        guard let nextSnapshot = forwardStack.popLast() else { return nil }
        if let currentSnapshot {
            backStack.append(currentSnapshot)
        }
        currentSnapshot = nextSnapshot
        return nextSnapshot
    }
}
