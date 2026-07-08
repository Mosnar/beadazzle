import Foundation

struct BeadIssueListQuery: Sendable {
    static func filteredIssueIDs(
        index: BeadProjectIndex,
        bookmark: BeadBookmark,
        statusFilters: Set<String>,
        typeFilters: Set<String>,
        priorityFilters: Set<Int>,
        labelFilters: Set<String>,
        searchText: String
    ) -> [String] {
        PerformanceSignposts.query.withIntervalSignpost("Filter") {
            index.filteredIssueIDs(
                within: index.issueIDs(for: bookmark),
                statusFilters: statusFilters,
                typeFilters: typeFilters,
                priorityFilters: priorityFilters,
                labelFilters: labelFilters,
                searchText: searchText
            )
        }
    }

    static func sortedIssueIDs(
        index: BeadProjectIndex,
        ids: [String],
        sort: IssueSort,
        direction: SortDirection
    ) -> [String] {
        PerformanceSignposts.query.withIntervalSignpost("Sort") {
            let sortOrder = BeadIssueSortOrder(sort: sort, direction: direction)
            return ids.compactMap(index.issue)
                .sorted(by: sortOrder.areInIncreasingOrder)
                .map(\.id)
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
        bookmark: BeadBookmark = .all
    ) -> [IssueListRow] {
        PerformanceSignposts.query.withIntervalSignpost("RowBuild") {
            index.issueListRows(
                for: filteredIssueIDs,
                mode: mode,
                expandedIssueIDs: outlineState.expandedIssueIDs,
                collapsedIssueIDs: outlineState.collapsedIssueIDs,
                sortOrder: BeadIssueSortOrder(sort: sort, direction: direction),
                bookmark: bookmark
            )
        }
    }
}

struct BeadOutlineSelectionState: Equatable, Hashable, Sendable {
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
        let visibleIssueIDs = Set(rows.map(\.issueID))
        return prune(toValidIssueIDs: visibleIssueIDs)
    }
}
