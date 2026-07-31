import Foundation

enum BeadSearchCoverage: Hashable, Sendable {
    case currentView
    case allBeads
}

struct BeadIssueListQueryContext: Sendable {
    var bookmark: BeadBookmark
    var statusFilters: Set<String>
    var typeFilters: Set<String>
    var priorityFilters: Set<Int>
    var labelFilters: Set<String>
    var searchText: String
    var advancedPredicate: BeadFilterGroup?
    var sort: IssueSort
    var direction: SortDirection
    var listOrdering: BeadListOrdering
    var folderOrderedIssueIDs: [String]?
    var mode: IssueListMode
    var isGlobalSearch: Bool
}

extension BeadStore {
    var isGlobalSearchActive: Bool {
        searchCoverage == .allBeads
            && !trimmedSearchText.isEmpty
    }

    var effectiveIssueListBookmark: BeadBookmark {
        isGlobalSearchActive ? .all : selectedBookmark
    }

    var activeIssueListFolderSavedView: BeadSavedView? {
        isGlobalSearchActive ? nil : activeFolderSavedView
    }

    var currentViewSearchTitle: String {
        if let id = activeSavedViewID ?? sourceSavedViewID,
           let savedView = savedViews.first(where: { $0.id == id }) {
            return savedView.name
        }
        if selectedBookmark == .all,
           hasActiveFilters || activeAdvancedPredicate != nil {
            return "Current View"
        }
        return selectedBookmark.title
    }

    var activeSearchCoverageTitle: String {
        isGlobalSearchActive ? BeadBookmark.all.title : currentViewSearchTitle
    }

    var hasCurrentViewConstraintsBeyondSearch: Bool {
        selectedBookmark != .all
            || activeFolderSavedView != nil
            || hasActiveFilters
            || activeAdvancedPredicate != nil
    }

    var canExpandCurrentSearchToAllBeads: Bool {
        !isGlobalSearchActive
            && hasCurrentViewConstraintsBeyondSearch
            && !trimmedSearchText.isEmpty
    }

    var canReturnSearchToCurrentView: Bool {
        isGlobalSearchActive
    }

    var searchFieldPrompt: String {
        "Search \(currentViewSearchTitle)"
    }

    func searchAllBeadsUsingCurrentSearchText() {
        guard canExpandCurrentSearchToAllBeads else { return }
        filterTask?.cancel()
        filterTask = nil
        _searchCoverageSourceSort = BeadSavedViewSort(
            field: sort,
            direction: sortDirection
        )
        _searchCoverage = .allBeads
        applyFilters()
    }

    func searchCurrentViewUsingCurrentSearchText() {
        guard isGlobalSearchActive else { return }
        resetSearchCoverageToCurrentView()
        applyFilters()
    }

    @discardableResult
    internal func resetSearchCoverageToCurrentView() -> Bool {
        let wasGlobalSearch = searchCoverage == .allBeads
        if wasGlobalSearch {
            filterTask?.cancel()
            filterTask = nil
        }
        _searchCoverage = .currentView
        if let sourceSort = _searchCoverageSourceSort {
            let wasSuppressingFilterUpdates = suppressesFilterUpdates
            suppressesFilterUpdates = true
            sort = sourceSort.field
            sortDirection = sourceSort.direction
            suppressesFilterUpdates = wasSuppressingFilterUpdates
            _searchCoverageSourceSort = nil
        }
        return wasGlobalSearch
    }

    var effectiveIssueListQueryContext: BeadIssueListQueryContext {
        if isGlobalSearchActive {
            return BeadIssueListQueryContext(
                bookmark: .all,
                statusFilters: [],
                typeFilters: [],
                priorityFilters: [],
                labelFilters: [],
                searchText: searchText,
                advancedPredicate: nil,
                sort: sort,
                direction: sortDirection,
                listOrdering: .sorted(BeadSavedViewSort(
                    field: sort,
                    direction: sortDirection
                )),
                folderOrderedIssueIDs: nil,
                mode: effectiveIssueListMode,
                isGlobalSearch: true
            )
        }

        return BeadIssueListQueryContext(
            bookmark: selectedBookmark,
            statusFilters: statusFilters,
            typeFilters: typeFilters,
            priorityFilters: priorityFilters,
            labelFilters: labelFilters,
            searchText: searchText,
            advancedPredicate: activeAdvancedPredicate,
            sort: sort,
            direction: sortDirection,
            listOrdering: listOrdering,
            folderOrderedIssueIDs: activeFolderSavedView?.folder?.orderedIssueIDs,
            mode: effectiveIssueListMode,
            isGlobalSearch: false
        )
    }
}
