import Foundation

struct BeadIssueListQuery: Sendable {
    static func filteredIssueIDs(
        index: BeadProjectIndex,
        bookmark: BeadBookmark,
        statusFilters: Set<String>,
        typeFilters: Set<String>,
        priorityFilters: Set<Int>,
        labelFilters: Set<String>,
        searchText: String,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [String] {
        PerformanceSignposts.query.withIntervalSignpost("Filter") {
            let ignoresFilters = bookmark == .gates
            return index.filteredIssueIDs(
                within: index.issueIDs(for: bookmark),
                statusFilters: ignoresFilters ? [] : statusFilters,
                typeFilters: ignoresFilters ? [] : typeFilters,
                priorityFilters: ignoresFilters ? [] : priorityFilters,
                labelFilters: ignoresFilters ? [] : labelFilters,
                searchText: searchText,
                shouldCancel: shouldCancel
            )
        }
    }

    /// Single-scan variant for the common recompute path: shares the expensive
    /// search/filter pass between the row ID list and the filter counts. Not valid
    /// for the gates bookmark, whose rows ignore active filters while counts don't.
    static func filteredIssueIDsAndCounts(
        index: BeadProjectIndex,
        bookmark: BeadBookmark,
        statusFilters: Set<String>,
        typeFilters: Set<String>,
        priorityFilters: Set<Int>,
        labelFilters: Set<String>,
        searchText: String,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> (matchingIDs: [String], counts: BeadFilterCounts) {
        PerformanceSignposts.query.withIntervalSignpost("Filter") {
            index.filteredIssueIDsAndCounts(
                for: bookmark,
                statusFilters: statusFilters,
                typeFilters: typeFilters,
                priorityFilters: priorityFilters,
                labelFilters: labelFilters,
                searchText: searchText,
                shouldCancel: shouldCancel
            )
        }
    }

    static func sortedIssueIDs(
        index: BeadProjectIndex,
        ids: [String],
        sort: IssueSort,
        direction: SortDirection,
        bookmark: BeadBookmark = .all,
        now: Date = Date()
    ) -> [String] {
        PerformanceSignposts.query.withIntervalSignpost("Sort") {
            if bookmark == .gates {
                return index.sortedGateIssueIDs(ids, now: now)
            }
            let sortOrder = BeadIssueSortOrder(sort: sort, direction: direction)
            return index.sortedIssueIDs(ids, sortOrder: sortOrder)
        }
    }

    static func filterCounts(
        index: BeadProjectIndex,
        bookmark: BeadBookmark,
        statusFilters: Set<String>,
        typeFilters: Set<String>,
        priorityFilters: Set<Int>,
        searchText: String,
        selectedLabels: Set<String>
    ) -> BeadFilterCounts {
        index.filterCounts(
            for: bookmark,
            statusFilters: statusFilters,
            typeFilters: typeFilters,
            priorityFilters: priorityFilters,
            searchText: searchText,
            selectedLabels: selectedLabels
        )
    }

    static func rows(
        index: BeadProjectIndex,
        filteredIssueIDs: [String],
        mode: IssueListMode,
        outlineState: BeadOutlineSelectionState,
        sort: IssueSort,
        direction: SortDirection,
        bookmark: BeadBookmark = .all,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [IssueListRow] {
        PerformanceSignposts.query.withIntervalSignpost("RowBuild") {
            let sortOrder = bookmark == .gates
                ? BeadIssueSortOrder(sort: .priority, direction: .ascending)
                : BeadIssueSortOrder(sort: sort, direction: direction)
            return index.issueListRows(
                for: filteredIssueIDs,
                mode: mode,
                expandedIssueIDs: outlineState.expandedIssueIDs,
                collapsedIssueIDs: outlineState.collapsedIssueIDs,
                sortOrder: sortOrder,
                filteredIssueIDsAreSorted: true,
                bookmark: bookmark,
                shouldCancel: shouldCancel
            )
        }
    }
}

struct BeadOutlineSelectionState: Codable, Equatable, Hashable, Sendable {
    private(set) var expandedIssueIDs: Set<String> = []
    private(set) var collapsedIssueIDs: Set<String> = []

    mutating func clear() {
        expandedIssueIDs.removeAll()
        collapsedIssueIDs.removeAll()
    }

    mutating func setExpansion(issueID: String, isExpanded: Bool) {
        if isExpanded {
            expandedIssueIDs.insert(issueID)
            collapsedIssueIDs.remove(issueID)
        } else {
            expandedIssueIDs.remove(issueID)
            collapsedIssueIDs.insert(issueID)
        }
    }

    mutating func expandAncestors(of issueID: String, in index: BeadProjectIndex) -> Bool {
        let ancestorIDs = Set(index.ancestorIDs(for: issueID))
        let nextExpandedIssueIDs = expandedIssueIDs.union(ancestorIDs)
        let nextCollapsedIssueIDs = collapsedIssueIDs.subtracting(ancestorIDs)
        guard nextExpandedIssueIDs != expandedIssueIDs || nextCollapsedIssueIDs != collapsedIssueIDs else { return false }
        expandedIssueIDs = nextExpandedIssueIDs
        collapsedIssueIDs = nextCollapsedIssueIDs
        return true
    }

    mutating func prune(toValidIssueIDs validIssueIDs: Set<String>) -> Bool {
        let nextExpandedIssueIDs = expandedIssueIDs.intersection(validIssueIDs)
        let nextCollapsedIssueIDs = collapsedIssueIDs.intersection(validIssueIDs)
        guard nextExpandedIssueIDs != expandedIssueIDs || nextCollapsedIssueIDs != collapsedIssueIDs else { return false }
        expandedIssueIDs = nextExpandedIssueIDs
        collapsedIssueIDs = nextCollapsedIssueIDs
        return true
    }

    mutating func prune(toVisibleRows rows: [IssueListRow]) -> Bool {
        guard !expandedIssueIDs.isEmpty || !collapsedIssueIDs.isEmpty else { return false }
        let visibleIssueIDs = Set(rows.map(\.issueID))
        return prune(toValidIssueIDs: visibleIssueIDs)
    }
}
