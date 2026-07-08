import Foundation

struct BeadPickerQuery: Sendable {
    static func rows(
        index: BeadProjectIndex,
        configuration: BeadPickerConfiguration,
        filters: BeadPickerFilters,
        searchText: String,
        mode: IssueListMode,
        outlineState: BeadOutlineSelectionState,
        sortOrder: BeadIssueSortOrder,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> BeadPickerQueryResult {
        let candidateIDs = candidateIssueIDs(
            index: index,
            configuration: configuration,
            filters: filters,
            searchText: searchText,
            shouldCancel: shouldCancel
        )
        guard !shouldCancel() else { return .empty }
        let candidateIDSet = Set(candidateIDs)
        let rows = index.issueListRows(
            for: candidateIDs,
            mode: mode,
            expandedIssueIDs: outlineState.expandedIssueIDs,
            collapsedIssueIDs: outlineState.collapsedIssueIDs,
            sortOrder: sortOrder,
            shouldCancel: shouldCancel
        )
        guard !shouldCancel() else { return .empty }
        var pickerRows: [BeadPickerRow] = []
        pickerRows.reserveCapacity(rows.count)
        for row in rows {
            guard !shouldCancel() else { return .empty }
            guard let issue = index.issue(with: row.issueID) else { continue }
            pickerRows.append(
                BeadPickerRow(
                    issue: issue,
                    row: row,
                    isSelectable: candidateIDSet.contains(row.issueID)
                )
            )
        }

        return BeadPickerQueryResult(rows: pickerRows, matchingIssueIDs: candidateIDs)
    }

    static func candidateIssueIDs(
        index: BeadProjectIndex,
        configuration: BeadPickerConfiguration,
        filters: BeadPickerFilters,
        searchText: String,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [String] {
        let excludedIDs = excludedIssueIDs(index: index, configuration: configuration)
        let policy = BeadHierarchyMutationPolicy(index: index)
        var baseIDs: Set<String> = []
        baseIDs.reserveCapacity(index.allIssueIDs.count)
        for issueID in index.allIssueIDs {
            guard !shouldCancel() else { return [] }
            guard !excludedIDs.contains(issueID),
                  let issue = index.issue(with: issueID) else {
                continue
            }
            if !configuration.scope.includesGates, issue.isGate {
                continue
            }
            if !configuration.scope.includesDone, policy.isDone(issue) {
                continue
            }
            baseIDs.insert(issueID)
        }

        return index.filteredIssueIDs(
            within: baseIDs,
            statusFilters: filters.statusFilters,
            typeFilters: filters.typeFilters,
            priorityFilters: filters.priorityFilters,
            labelFilters: filters.labelFilters,
            searchText: searchText,
            shouldCancel: shouldCancel
        )
    }

    static func excludedIssueIDs(
        index: BeadProjectIndex,
        configuration: BeadPickerConfiguration
    ) -> Set<String> {
        var excludedIDs = configuration.scope.excludedIssueIDs
        for rootID in configuration.scope.excludedDescendantRootIDs {
            excludedIDs.formUnion(index.descendantIDs(for: rootID))
        }
        for rootID in configuration.scope.excludedAncestorRootIDs {
            excludedIDs.formUnion(index.ancestorIDs(for: rootID))
        }

        switch configuration.action {
        case .setParent:
            break
        case .addBlockedBy(let issueID):
            for dependency in index.dependenciesByIssueID[issueID] ?? [] where dependency.isBlocking {
                excludedIDs.insert(dependency.dependsOnID)
            }
        case .addBlocks(let issueID):
            for dependency in index.dependentsByIssueID[issueID] ?? [] where dependency.isBlocking {
                excludedIDs.insert(dependency.issueID)
            }
        case .addChild(let parentID):
            for childID in index.childIDsByParentID[parentID] ?? [] {
                excludedIDs.insert(childID)
            }
        }

        return excludedIDs
    }
}
