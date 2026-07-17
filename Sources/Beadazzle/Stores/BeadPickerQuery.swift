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
        let sortedCandidateIDs = index.sortedIssueIDs(candidateIDs, sortOrder: sortOrder)
        guard !shouldCancel() else { return .empty }
        let rows = index.issueListRows(
            for: sortedCandidateIDs,
            mode: mode,
            expandedIssueIDs: outlineState.expandedIssueIDs,
            collapsedIssueIDs: outlineState.collapsedIssueIDs,
            sortOrder: sortOrder,
            filteredIssueIDsAreSorted: true,
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
            if !canSelect(issue: issue, index: index, action: configuration.action) {
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

    private static func canSelect(issue: BeadIssue, index: BeadProjectIndex, action: BeadPickerAction) -> Bool {
        switch action {
        case .setParent, .addChild:
            return true
        case .addBlockedBy(let issueID):
            guard let blockedIssue = index.issue(with: issueID) else { return false }
            return BeadIssueWorkflowPolicy.canAddBlockingDependency(
                blockedIssue: blockedIssue,
                blockerIssue: issue
            )
        case .addBlocks(let issueID):
            guard let blockerIssue = index.issue(with: issueID) else { return false }
            return BeadIssueWorkflowPolicy.canAddBlockingDependency(
                blockedIssue: issue,
                blockerIssue: blockerIssue
            )
        }
    }
}
