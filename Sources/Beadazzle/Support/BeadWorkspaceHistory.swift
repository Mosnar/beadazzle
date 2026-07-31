import Foundation

struct BeadWorkspaceSnapshot: Equatable, Sendable {
    var bookmark: BeadBookmark
    var activeSavedViewID: UUID?
    var sourceSavedViewID: UUID? = nil
    var savedViewOrdering: BeadSavedViewOrdering? = nil
    var listOrdering: BeadListOrdering = .sorted(
        BeadSavedViewSort(field: .priority, direction: .ascending)
    )
    var selectedIDs: Set<String>
    var fullPageDetailIssueID: String?
    var searchText: String
    var statusFilters: Set<String>
    var typeFilters: Set<String>
    var priorityFilters: Set<Int>
    var labelFilters: Set<String>
    var advancedPredicate: BeadFilterGroup?
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

    /// Removes a successfully submitted creation draft from every navigation entry so Back
    /// cannot resurrect it and accidentally create the same logical bead twice.
    mutating func clearCreationDraft(matching draft: IssueDraft) {
        for index in backStack.indices where backStack[index].creationDraft == draft {
            backStack[index].creationDraft = nil
        }
        if currentSnapshot?.creationDraft == draft {
            currentSnapshot?.creationDraft = nil
        }
        for index in forwardStack.indices where forwardStack[index].creationDraft == draft {
            forwardStack[index].creationDraft = nil
        }
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
