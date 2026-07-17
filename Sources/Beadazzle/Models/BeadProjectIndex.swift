import Foundation

struct BeadFilterCounts: Equatable, Sendable {
    var statusCounts: [(String, Int)] = []
    var typeCounts: [(String, Int)] = []
    var priorityCounts: [(Int, Int)] = []
    var labelCounts: [(String, Int)] = []

    static let empty = BeadFilterCounts(
        statusCounts: [],
        typeCounts: [],
        priorityCounts: (0...4).map { ($0, 0) },
        labelCounts: []
    )

    static func == (lhs: BeadFilterCounts, rhs: BeadFilterCounts) -> Bool {
        stringCountsEqual(lhs.statusCounts, rhs.statusCounts)
            && stringCountsEqual(lhs.typeCounts, rhs.typeCounts)
            && intCountsEqual(lhs.priorityCounts, rhs.priorityCounts)
            && stringCountsEqual(lhs.labelCounts, rhs.labelCounts)
    }

    private static func stringCountsEqual(_ lhs: [(String, Int)], _ rhs: [(String, Int)]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { left, right in
            left.0 == right.0 && left.1 == right.1
        }
    }

    private static func intCountsEqual(_ lhs: [(Int, Int)], _ rhs: [(Int, Int)]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { left, right in
            left.0 == right.0 && left.1 == right.1
        }
    }
}

private extension ComparisonResult {
    func then(_ next: ComparisonResult) -> ComparisonResult {
        self == .orderedSame ? next : self
    }
}

struct BeadProjectIndex: Sendable {
    static let empty = BeadProjectIndex(issues: [], dependencies: [], semantics: .empty)
    static let defaultStaleCutoffDays = 14

    private static let secondsPerDay: TimeInterval = 24 * 60 * 60

    let issues: [BeadIssue]
    let dependencies: [BeadDependency]
    let semantics: BeadProjectSemantics
    let staleCutoffDays: Int
    let hidesParentsWithOnlyBlockedChildrenInReady: Bool
    let issueByID: [String: BeadIssue]
    /// All issue ids, precomputed once so hot paths (e.g. per-recompute outline pruning)
    /// don't rebuild this set on the main thread.
    let allIssueIDs: Set<String>
    let issueIDsByStatus: [String: Set<String>]
    let issueIDsByStatusCategory: [BeadStatusCategory: Set<String>]
    let issueIDsByType: [String: Set<String>]
    let issueIDsByPriority: [Int: Set<String>]
    let issueIDsByLabel: [String: Set<String>]
    let dependenciesByIssueID: [String: [BeadDependency]]
    let dependentsByIssueID: [String: [BeadDependency]]
    let parentIDByIssueID: [String: String]
    let childIDsByParentID: [String: [String]]
    let childProgressByParentID: [String: IssueChildProgress]
    let dependencyTypeNames: [String]
    let labelNames: [String]
    /// State dimensions with explicit provenance from `bd set-state` event beads.
    /// Ordinary colon labels are intentionally absent.
    let stateDimensionNames: [String]
    let stateValuesByDimension: [String: [String]]
    let ownerNames: [String]
    let assigneeNames: [String]
    /// Per-issue searchable text, pre-folded once at build time (case-, diacritic-, and
    /// width-insensitive), prefixed with the issue id, and stored as UTF-8 bytes. Searching
    /// folds the query the same way and does a byte-subsequence scan — equivalent to
    /// `localizedStandardContains` on folded text (UTF-8 is self-synchronizing and folding
    /// strips combining marks) but far cheaper than a grapheme-aware `String.contains`.
    let foldedSearchBytesByID: [String: ContiguousArray<UInt8>]
    let baseFilterCountsByBookmark: [BeadBookmark: BeadFilterCounts]

    private let issueIDsByBookmark: [BeadBookmark: Set<String>]

    /// - Parameter reusingSearchTextFrom: a previous index to carry pre-folded search
    ///   bytes from for issues whose searchable fields are unchanged. Folding is the
    ///   dominant cost of a rebuild, so optimistic single-issue edits pass the outgoing
    ///   index here instead of re-folding every issue.
    init(
        issues: [BeadIssue],
        dependencies: [BeadDependency],
        semantics: BeadProjectSemantics,
        staleCutoffDays: Int = Self.defaultStaleCutoffDays,
        hidesParentsWithOnlyBlockedChildrenInReady: Bool = true,
        reusingSearchTextFrom previousIndex: BeadProjectIndex? = nil
    ) {
        self.issues = issues
        self.dependencies = dependencies
        self.semantics = semantics
        self.hidesParentsWithOnlyBlockedChildrenInReady = hidesParentsWithOnlyBlockedChildrenInReady
        let normalizedStaleCutoffDays = max(1, staleCutoffDays)
        self.staleCutoffDays = normalizedStaleCutoffDays

        var issueByID: [String: BeadIssue] = [:]
        var issueIDsByStatus: [String: Set<String>] = [:]
        var issueIDsByStatusCategory: [BeadStatusCategory: Set<String>] = [:]
        var issueIDsByType: [String: Set<String>] = [:]
        var issueIDsByPriority: [Int: Set<String>] = [:]
        var issueIDsByLabel: [String: Set<String>] = [:]
        var foldedSearchBytesByID: [String: ContiguousArray<UInt8>] = [:]
        var parentIDCandidatesByIssueID: [String: String] = [:]
        var childIDsByParentID: [String: [String]] = [:]
        var ownerNames: Set<String> = []
        var assigneeNames: Set<String> = []
        var recordedStateValuesByDimension: [String: Set<String>] = [:]
        var ambiguousStateEventIndices: [Int] = []
        issueByID.reserveCapacity(issues.count)
        foldedSearchBytesByID.reserveCapacity(issues.count)

        for (issueIndex, issue) in issues.enumerated() {
            if BeadStateLabel.isRecordedChangeEvent(
                issueType: issue.issueType,
                title: issue.title
            ) {
                if BeadStateLabel.recordedChangeRequiresDisambiguation(title: issue.title) {
                    ambiguousStateEventIndices.append(issueIndex)
                } else if let stateChange = BeadStateLabel.recordedChange(
                    issueType: issue.issueType,
                    title: issue.title
                ) {
                    recordedStateValuesByDimension[stateChange.dimension, default: []]
                        .insert(stateChange.value)
                }
            }
            issueByID[issue.id] = issue
            issueIDsByStatus[issue.status, default: []].insert(issue.id)
            issueIDsByStatusCategory[semantics.category(forStatus: issue.status), default: []].insert(issue.id)
            issueIDsByType[issue.issueType, default: []].insert(issue.id)
            issueIDsByPriority[issue.priority, default: []].insert(issue.id)
            if let previousIndex,
               let priorIssue = previousIndex.issueByID[issue.id],
               let priorBytes = previousIndex.foldedSearchBytesByID[issue.id],
               issue.hasSameSearchText(as: priorIssue) {
                foldedSearchBytesByID[issue.id] = priorBytes
            } else {
                foldedSearchBytesByID[issue.id] = ContiguousArray(Self.foldedForSearch(issue.id + " " + issue.summaryText).utf8)
            }
            for label in issue.labels {
                issueIDsByLabel[label, default: []].insert(issue.id)
            }
            if let owner = issue.owner, !owner.isEmpty { ownerNames.insert(owner) }
            if let assignee = issue.assignee, !assignee.isEmpty { assigneeNames.insert(assignee) }
        }
        self.issueByID = issueByID
        self.ownerNames = ownerNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.assigneeNames = assigneeNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.issueIDsByStatus = issueIDsByStatus
        self.issueIDsByStatusCategory = issueIDsByStatusCategory
        self.issueIDsByType = issueIDsByType
        self.issueIDsByPriority = issueIDsByPriority
        self.issueIDsByLabel = issueIDsByLabel
        labelNames = issueIDsByLabel.keys.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        if !ambiguousStateEventIndices.isEmpty {
            let knownLabels = Set(labelNames)
            var knownDimensions: Set<String> = []
            knownDimensions.reserveCapacity(labelNames.count)
            for label in labelNames {
                if let dimension = BeadStateLabel.dimension(of: label) {
                    knownDimensions.insert(dimension)
                }
            }
            for issueIndex in ambiguousStateEventIndices {
                let issue = issues[issueIndex]
                guard let stateChange = BeadStateLabel.recordedChange(
                    issueType: issue.issueType,
                    title: issue.title,
                    knownLabels: knownLabels,
                    knownDimensions: knownDimensions
                ) else { continue }
                recordedStateValuesByDimension[stateChange.dimension, default: []]
                    .insert(stateChange.value)
            }
        }
        if !recordedStateValuesByDimension.isEmpty {
            for label in labelNames {
                guard let parsed = BeadStateLabel.parse(label),
                      recordedStateValuesByDimension[parsed.dimension] != nil else {
                    continue
                }
                recordedStateValuesByDimension[parsed.dimension, default: []].insert(parsed.value)
            }
        }
        stateDimensionNames = recordedStateValuesByDimension.keys.sorted(by: BeadStateLabel.isOrderedBefore)
        stateValuesByDimension = recordedStateValuesByDimension.mapValues { values in
            values.sorted(by: BeadStateLabel.isOrderedBefore)
        }
        self.foldedSearchBytesByID = foldedSearchBytesByID
        let allIssueIDs = Set(issueByID.keys)
        self.allIssueIDs = allIssueIDs

        var dependenciesByIssueID: [String: [BeadDependency]] = [:]
        var dependentsByIssueID: [String: [BeadDependency]] = [:]
        dependenciesByIssueID.reserveCapacity(dependencies.count)
        dependentsByIssueID.reserveCapacity(dependencies.count)
        for dependency in dependencies {
            dependenciesByIssueID[dependency.issueID, default: []].append(dependency)
            dependentsByIssueID[dependency.dependsOnID, default: []].append(dependency)
        }
        self.dependenciesByIssueID = dependenciesByIssueID
        self.dependentsByIssueID = dependentsByIssueID

        for issue in issues {
            guard let parentID = issue.parentID,
                  !parentID.isEmpty,
                  parentID != issue.id,
                  issueByID[parentID] != nil else {
                continue
            }
            parentIDCandidatesByIssueID[issue.id] = parentID
        }
        for dependency in dependencies where dependency.type == "parent-child" {
            guard parentIDCandidatesByIssueID[dependency.issueID] == nil,
                  dependency.issueID != dependency.dependsOnID,
                  issueByID[dependency.issueID] != nil,
                  issueByID[dependency.dependsOnID] != nil else {
                continue
            }
            parentIDCandidatesByIssueID[dependency.issueID] = dependency.dependsOnID
        }
        let parentIDByIssueID = Self.normalizedParentIDs(
            candidates: parentIDCandidatesByIssueID,
            issueByID: issueByID
        )
        self.parentIDByIssueID = parentIDByIssueID
        for (issueID, parentID) in parentIDByIssueID {
            childIDsByParentID[parentID, default: []].append(issueID)
        }
        self.childIDsByParentID = childIDsByParentID
        childProgressByParentID = Self.childProgressByParentID(
            childIDsByParentID: childIDsByParentID,
            issueByID: issueByID,
            semantics: semantics
        )
        dependencyTypeNames = Array(Set(dependencies.map(\.type).filter { !$0.isEmpty })).sorted()

        let issueIDsByBookmark = Dictionary(
            uniqueKeysWithValues: BeadBookmark.allCases.map { bookmark in
                let ids = Self.issueIDs(
                    for: bookmark,
                    allIssueIDs: allIssueIDs,
                    semantics: semantics,
                    issueIDsByStatus: issueIDsByStatus,
                    issueIDsByType: issueIDsByType,
                    issueByID: issueByID,
                    dependenciesByIssueID: dependenciesByIssueID,
                    childIDsByParentID: childIDsByParentID,
                    hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
                    staleCutoffDays: normalizedStaleCutoffDays
                )
                return (bookmark, ids)
            }
        )
        self.issueIDsByBookmark = issueIDsByBookmark
        baseFilterCountsByBookmark = Dictionary(
            uniqueKeysWithValues: BeadBookmark.allCases.map { bookmark in
                let ids = issueIDsByBookmark[bookmark, default: []]
                return (bookmark, Self.baseFilterCounts(for: ids, issueByID: issueByID, semantics: semantics))
            }
        )
    }

    func issue(with id: String) -> BeadIssue? {
        issueByID[id]
    }

    func sortedIssueIDs(_ ids: [String], sortOrder: BeadIssueSortOrder) -> [String] {
        var candidates: [BeadIssueSortCandidate] = []
        candidates.reserveCapacity(ids.count)
        for id in ids {
            guard let issue = issueByID[id] else { continue }
            candidates.append(sortOrder.candidate(for: issue))
        }
        candidates.sort(by: sortOrder.areInIncreasingOrder)
        return candidates.map(\.id)
    }

    func parentID(for issueID: String) -> String? {
        parentIDByIssueID[issueID]
    }

    func childProgress(for parentID: String) -> IssueChildProgress? {
        childProgressByParentID[parentID]
    }

    func immediateChildRows(parentID: String, sortOrder: BeadIssueSortOrder) -> [IssueListRow] {
        let childIDs = childIDsByParentID[parentID] ?? []
        guard !childIDs.isEmpty else { return [] }
        let sortedChildIDs = sortedIssueIDs(childIDs, sortOrder: sortOrder)
        return dependencyOrderedSiblingIDs(sortedChildIDs).map { issueID in
            IssueListRow(
                issueID: issueID,
                depth: 0,
                hasChildren: !(childIDsByParentID[issueID] ?? []).isEmpty,
                childProgress: childProgressByParentID[issueID],
                isExpanded: false,
                isContext: false
            )
        }
    }

    func ancestorIDs(for issueID: String) -> [String] {
        var ancestors: [String] = []
        var visited: Set<String> = [issueID]
        var nextID = parentID(for: issueID)

        while let currentID = nextID, !visited.contains(currentID) {
            ancestors.append(currentID)
            visited.insert(currentID)
            nextID = parentID(for: currentID)
        }

        return ancestors
    }

    func descendantIDs(for issueID: String) -> Set<String> {
        var descendants: Set<String> = []
        var stack = childIDsByParentID[issueID] ?? []

        while let childID = stack.popLast() {
            guard descendants.insert(childID).inserted else { continue }
            stack.append(contentsOf: childIDsByParentID[childID] ?? [])
        }

        return descendants
    }

    func openChildIssues(forClosing issueIDs: [String]) -> [BeadIssue] {
        BeadHierarchyMutationPolicy(index: self)
            .unresolvedDescendantsPreventingCompletion(of: issueIDs, includedIssueIDs: issueIDs)
    }

    func dependenciesTouching(issueID: String) -> [BeadDependency] {
        let outgoing = dependenciesByIssueID[issueID] ?? []
        let incoming = dependentsByIssueID[issueID] ?? []
        return (outgoing + incoming).sorted { lhs, rhs in
            if lhs.type == rhs.type {
                return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
            }
            return lhs.type < rhs.type
        }
    }

    func activeBlockingIssues(for issueID: String, sortOrder: BeadIssueSortOrder) -> [BeadIssue] {
        guard let issue = issueByID[issueID], canBeActivelyBlocked(issue) else { return [] }

        return (dependenciesByIssueID[issueID] ?? [])
            .filter(\.isBlocking)
            .compactMap { issueByID[$0.dependsOnID] }
            .filter(isActiveBlocker)
            .sorted(by: sortOrder.areInIncreasingOrder)
    }

    func activelyBlockedIssues(by issueID: String, sortOrder: BeadIssueSortOrder) -> [BeadIssue] {
        guard let issue = issueByID[issueID], isActiveBlocker(issue) else { return [] }

        return (dependentsByIssueID[issueID] ?? [])
            .filter(\.isBlocking)
            .compactMap { issueByID[$0.issueID] }
            .filter(canBeActivelyBlocked)
            .sorted(by: sortOrder.areInIncreasingOrder)
    }

    func activeBlockingIssueCount(for issueID: String) -> Int {
        guard let issue = issueByID[issueID], canBeActivelyBlocked(issue) else { return 0 }
        return (dependenciesByIssueID[issueID] ?? []).lazy
            .filter(\.isBlocking)
            .compactMap { issueByID[$0.dependsOnID] }
            .filter(isActiveBlocker)
            .count
    }

    func activelyBlockedIssueCount(by issueID: String) -> Int {
        guard let issue = issueByID[issueID], isActiveBlocker(issue) else { return 0 }
        return (dependentsByIssueID[issueID] ?? []).lazy
            .filter(\.isBlocking)
            .compactMap { issueByID[$0.issueID] }
            .filter(canBeActivelyBlocked)
            .count
    }

    private func isActiveBlocker(_ issue: BeadIssue) -> Bool {
        if let gate = BeadGate(issue: issue) {
            return gate.isOpen
        }
        return !semantics.isDone(issue)
    }

    private func canBeActivelyBlocked(_ issue: BeadIssue) -> Bool {
        !semantics.isDone(issue)
    }

    func count(for bookmark: BeadBookmark) -> Int {
        issueIDsByBookmark[bookmark]?.count ?? 0
    }

    func count(forLabel label: String) -> Int {
        issueIDsByLabel[label]?.count ?? 0
    }

    func issueIDs(for bookmark: BeadBookmark) -> Set<String> {
        issueIDsByBookmark[bookmark, default: []]
    }

    func filteredIssueIDs(
        within baseIDs: Set<String>,
        statusFilters: Set<String>,
        typeFilters: Set<String>,
        priorityFilters: Set<Int>,
        labelFilters: Set<String>,
        searchText: String,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [String] {
        var candidateIDs = baseIDs
        guard !shouldCancel() else { return [] }
        if !statusFilters.isEmpty {
            candidateIDs.formIntersection(unionSets(statusFilters.map { issueIDsByStatus[$0, default: []] }))
        }
        guard !shouldCancel() else { return [] }
        if !typeFilters.isEmpty {
            candidateIDs.formIntersection(unionSets(typeFilters.map { issueIDsByType[$0, default: []] }))
        }
        guard !shouldCancel() else { return [] }
        if !priorityFilters.isEmpty {
            candidateIDs.formIntersection(unionSets(priorityFilters.map { issueIDsByPriority[$0, default: []] }))
        }
        for label in labelFilters {
            guard !shouldCancel() else { return [] }
            candidateIDs.formIntersection(issueIDsByLabel[label, default: []])
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return Array(candidateIDs)
        }

        // Fold the query once into UTF-8 bytes, then scan each candidate's pre-folded
        // bytes for that subsequence. This matches `localizedStandardContains` semantics
        // on folded text without a locale-aware (or grapheme-aware) scan per keystroke.
        let foldedQuery = ContiguousArray(Self.foldedForSearch(query).utf8)
        var matchingIDs: [String] = []
        matchingIDs.reserveCapacity(candidateIDs.count)
        for id in candidateIDs {
            guard !shouldCancel() else { return [] }
            guard let bytes = foldedSearchBytesByID[id] else { continue }
            if Self.containsSubsequence(bytes, foldedQuery) {
                matchingIDs.append(id)
            }
        }
        return matchingIDs
    }

    /// Case-, diacritic-, and width-insensitive folding using the current locale — the
    /// same option set that `localizedStandardContains` applies.
    static func foldedForSearch(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    /// Naive byte-subsequence search. For the short needles typed into a search field over
    /// contiguous byte storage this is far faster than grapheme-aware `String.contains`.
    static func containsSubsequence(_ haystack: ContiguousArray<UInt8>, _ needle: ContiguousArray<UInt8>) -> Bool {
        guard let first = needle.first else { return true }
        let needleCount = needle.count
        guard haystack.count >= needleCount else { return false }
        return haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { need in
                let limit = hay.count - needleCount
                var i = 0
                while i <= limit {
                    if hay[i] == first {
                        var j = 1
                        while j < needleCount && hay[i + j] == need[j] { j += 1 }
                        if j == needleCount { return true }
                    }
                    i += 1
                }
                return false
            }
        }
    }

    func issueListRows(
        for filteredIssueIDs: [String],
        mode: IssueListMode,
        expandedIssueIDs: Set<String>,
        collapsedIssueIDs: Set<String> = [],
        sortOrder: BeadIssueSortOrder,
        filteredIssueIDsAreSorted: Bool = false,
        bookmark: BeadBookmark = .all,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [IssueListRow] {
        guard !shouldCancel() else { return [] }
        // Gates have no parent-child children, so the generic outline is meaningless for
        // them. The Gates section always renders as gate → the beads it blocks, regardless
        // of the global flat/outline mode (which is hidden there).
        if bookmark == .gates {
            return gateOutlineRows(
                gateIDs: filteredIssueIDs,
                collapsedIssueIDs: collapsedIssueIDs,
                sortOrder: sortOrder
            )
        }
        switch mode {
        case .flat:
            var rows: [IssueListRow] = []
            rows.reserveCapacity(filteredIssueIDs.count)
            for issueID in filteredIssueIDs {
                guard !shouldCancel() else { return [] }
                rows.append(IssueListRow(
                    issueID: issueID,
                    depth: 0,
                    hasChildren: !(childIDsByParentID[issueID] ?? []).isEmpty,
                    childProgress: childProgressByParentID[issueID],
                    isExpanded: expandedIssueIDs.contains(issueID) && !collapsedIssueIDs.contains(issueID),
                    isContext: false
                ))
            }
            return rows
        case .outline:
            return outlineRows(
                matchingIssueIDs: filteredIssueIDs,
                expandedIssueIDs: expandedIssueIDs,
                collapsedIssueIDs: collapsedIssueIDs,
                sortOrder: sortOrder,
                matchingIssueIDsAreSorted: filteredIssueIDsAreSorted,
                shouldCancel: shouldCancel
            )
        }
    }

    /// Beads a gate blocks (`blocks` edges pointing at the gate), sorted for display.
    func blockedBeadIDs(forGate gateID: String, sortOrder: BeadIssueSortOrder) -> [String] {
        let blocked = (dependentsByIssueID[gateID] ?? [])
            .filter(\.isBlocking)
            .compactMap { issueByID[$0.issueID] }
        return blocked.sorted(by: sortOrder.areInIncreasingOrder).map(\.id)
    }

    func sortedGateIssueIDs(_ gateIDs: [String], now: Date = Date()) -> [String] {
        gateIDs
            .compactMap { gateSortCandidate(issueID: $0, now: now) }
            .sorted(by: areGateSortCandidatesInIncreasingOrder)
            .map(\.issue.id)
    }

    /// Two-level outline for the Gates section: each gate, then the beads it blocks as
    /// context children. Gates default to expanded (blocked beads visible) unless the user
    /// collapses them, since seeing what a gate holds up is the point of the view.
    private func gateOutlineRows(
        gateIDs: [String],
        collapsedIssueIDs: Set<String>,
        sortOrder: BeadIssueSortOrder
    ) -> [IssueListRow] {
        var rows: [IssueListRow] = []
        for gateID in gateIDs {
            let blockedIDs = blockedBeadIDs(forGate: gateID, sortOrder: sortOrder)
            let hasChildren = !blockedIDs.isEmpty
            let isExpanded = hasChildren && !collapsedIssueIDs.contains(gateID)
            rows.append(
                IssueListRow(
                    issueID: gateID,
                    depth: 0,
                    hasChildren: hasChildren,
                    childProgress: nil,
                    isExpanded: isExpanded,
                    isContext: false
                )
            )
            guard isExpanded else { continue }
            for blockedID in blockedIDs {
                rows.append(
                    IssueListRow(
                        issueID: blockedID,
                        depth: 1,
                        hasChildren: false,
                        childProgress: nil,
                        isExpanded: false,
                        isContext: true
                    )
                )
            }
        }
        return rows
    }

    private struct GateSortCandidate {
        var issue: BeadIssue
        var state: GateActionState
        var bestBlockedPriority: Int?
    }

    private func gateSortCandidate(issueID: String, now: Date) -> GateSortCandidate? {
        guard let issue = issueByID[issueID],
              let gate = BeadGate(issue: issue) else {
            return nil
        }
        let bestBlockedPriority = (dependentsByIssueID[issueID] ?? [])
            .filter(\.isBlocking)
            .compactMap { issueByID[$0.issueID]?.priority }
            .min()
        return GateSortCandidate(
            issue: issue,
            state: gate.actionState(now: now),
            bestBlockedPriority: bestBlockedPriority
        )
    }

    private func areGateSortCandidatesInIncreasingOrder(_ lhs: GateSortCandidate, _ rhs: GateSortCandidate) -> Bool {
        let comparison = compareGateSortCandidates(lhs, rhs)
        guard comparison != .orderedSame else { return false }
        return comparison == .orderedAscending
    }

    private func compareGateSortCandidates(_ lhs: GateSortCandidate, _ rhs: GateSortCandidate) -> ComparisonResult {
        compareBools(lhs.state.isReady, rhs.state.isReady, trueFirst: true)
            .then(compareOptionalInts(lhs.bestBlockedPriority, rhs.bestBlockedPriority, nilLast: true))
            .then(compareInts(lhs.state.rawValue, rhs.state.rawValue))
            .then(compareInts(lhs.issue.priority, rhs.issue.priority))
            .then(compareDates(rhs.issue.updatedAt, lhs.issue.updatedAt))
            .then(compareStrings(lhs.issue.id, rhs.issue.id))
    }

    private func compareBools(_ lhs: Bool, _ rhs: Bool, trueFirst: Bool) -> ComparisonResult {
        guard lhs != rhs else { return .orderedSame }
        if trueFirst {
            return lhs ? .orderedAscending : .orderedDescending
        }
        return lhs ? .orderedDescending : .orderedAscending
    }

    private func compareOptionalInts(_ lhs: Int?, _ rhs: Int?, nilLast: Bool) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?):
            return compareInts(left, right)
        case (nil, nil):
            return .orderedSame
        case (nil, _?):
            return nilLast ? .orderedDescending : .orderedAscending
        case (_?, nil):
            return nilLast ? .orderedAscending : .orderedDescending
        }
    }

    private func compareInts(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let left = lhs ?? .distantPast
        let right = rhs ?? .distantPast
        if left < right { return .orderedAscending }
        if left > right { return .orderedDescending }
        return .orderedSame
    }

    private func compareStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.naturalCompare(rhs)
    }

    func filterCounts(
        for bookmark: BeadBookmark,
        statusFilters: Set<String>,
        typeFilters: Set<String>,
        priorityFilters: Set<Int>,
        searchText: String,
        selectedLabels: Set<String>
    ) -> BeadFilterCounts {
        let nonLabelIDs = filteredIssueIDs(
            within: issueIDs(for: bookmark),
            statusFilters: statusFilters,
            typeFilters: typeFilters,
            priorityFilters: priorityFilters,
            labelFilters: [],
            searchText: searchText
        )
        return filterCounts(for: bookmark, nonLabelFilteredIDs: nonLabelIDs, selectedLabels: selectedLabels)
    }

    /// Computes the filtered ID list and the filter counts from a single scan.
    /// The search-text pass over all candidates is the expensive part of both, so
    /// the non-label-filtered set is computed once and shared: the row set is its
    /// intersection with the label filters, and label counts read it directly.
    func filteredIssueIDsAndCounts(
        for bookmark: BeadBookmark,
        statusFilters: Set<String>,
        typeFilters: Set<String>,
        priorityFilters: Set<Int>,
        labelFilters: Set<String>,
        searchText: String,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> (matchingIDs: [String], counts: BeadFilterCounts) {
        let nonLabelIDs = filteredIssueIDs(
            within: issueIDs(for: bookmark),
            statusFilters: statusFilters,
            typeFilters: typeFilters,
            priorityFilters: priorityFilters,
            labelFilters: [],
            searchText: searchText,
            shouldCancel: shouldCancel
        )
        guard !shouldCancel() else { return ([], .empty) }
        let counts = filterCounts(
            for: bookmark,
            nonLabelFilteredIDs: nonLabelIDs,
            selectedLabels: labelFilters,
            shouldCancel: shouldCancel
        )

        guard !labelFilters.isEmpty else {
            return (nonLabelIDs, counts)
        }
        var matchingIDs = Set(nonLabelIDs)
        for label in labelFilters {
            guard !shouldCancel() else { return ([], .empty) }
            matchingIDs.formIntersection(issueIDsByLabel[label, default: []])
        }
        return (Array(matchingIDs), counts)
    }

    private func filterCounts(
        for bookmark: BeadBookmark,
        nonLabelFilteredIDs: [String],
        selectedLabels: Set<String>,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> BeadFilterCounts {
        let baseCounts = baseFilterCountsByBookmark[bookmark]
            ?? Self.baseFilterCounts(for: issueIDs(for: bookmark), issueByID: issueByID, semantics: semantics)

        var labelCounts: [String: Int] = [:]
        for id in nonLabelFilteredIDs {
            guard !shouldCancel() else { return .empty }
            guard let issue = issueByID[id] else { continue }
            for label in issue.labels {
                labelCounts[label, default: 0] += 1
            }
        }
        for label in selectedLabels where labelCounts[label] == nil {
            labelCounts[label] = 0
        }

        return BeadFilterCounts(
            statusCounts: baseCounts.statusCounts,
            typeCounts: baseCounts.typeCounts,
            priorityCounts: baseCounts.priorityCounts,
            labelCounts: Self.sortedStringCounts(labelCounts, defaults: [])
        )
    }

    private func unionSets(_ sets: [Set<String>]) -> Set<String> {
        sets.reduce(into: Set<String>()) { partialResult, ids in
            partialResult.formUnion(ids)
        }
    }

    private func outlineRows(
        matchingIssueIDs: [String],
        expandedIssueIDs: Set<String>,
        collapsedIssueIDs: Set<String>,
        sortOrder: BeadIssueSortOrder,
        matchingIssueIDsAreSorted: Bool,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [IssueListRow] {
        let matchingIDSet = Set(matchingIssueIDs)
        let visibleContextIDs = outlineVisibleIDs(
            matchingIssueIDs: matchingIDSet,
            expandedIssueIDs: expandedIssueIDs,
            collapsedIssueIDs: collapsedIssueIDs,
            shouldCancel: shouldCancel
        )
        guard !shouldCancel() else { return [] }

        let orderedMatchingIDs = matchingIssueIDsAreSorted
            ? matchingIssueIDs
            : sortedIssueIDs(matchingIssueIDs, sortOrder: sortOrder)
        var rootIDs: [String] = []
        rootIDs.reserveCapacity(orderedMatchingIDs.count)
        var visibleChildIDsByParentID: [String: [String]] = [:]
        for issueID in orderedMatchingIDs {
            guard !shouldCancel() else { return [] }
            if let parentID = parentID(for: issueID), visibleContextIDs.contains(parentID) {
                visibleChildIDsByParentID[parentID, default: []].append(issueID)
            } else {
                rootIDs.append(issueID)
            }
        }

        // Matching IDs already follow the requested sort. Append context separately and
        // re-sort only sibling groups whose order can have been disturbed. This avoids a
        // project-wide context sort and merge when a sparse match has a deep ancestor chain.
        var rootIDsNeedSorting = false
        var childGroupsNeedingSort: Set<String> = []
        for issueID in visibleContextIDs where !matchingIDSet.contains(issueID) {
            guard !shouldCancel() else { return [] }
            if let parentID = parentID(for: issueID), visibleContextIDs.contains(parentID) {
                if !(visibleChildIDsByParentID[parentID]?.isEmpty ?? true) {
                    childGroupsNeedingSort.insert(parentID)
                }
                visibleChildIDsByParentID[parentID, default: []].append(issueID)
            } else {
                rootIDsNeedSorting = rootIDsNeedSorting || !rootIDs.isEmpty
                rootIDs.append(issueID)
            }
        }
        if rootIDsNeedSorting {
            rootIDs = sortedIssueIDs(rootIDs, sortOrder: sortOrder)
        }
        for parentID in childGroupsNeedingSort {
            guard !shouldCancel() else { return [] }
            guard let childIDs = visibleChildIDsByParentID[parentID] else { continue }
            visibleChildIDsByParentID[parentID] = sortedIssueIDs(childIDs, sortOrder: sortOrder)
        }

        var rows: [IssueListRow] = []
        rows.reserveCapacity(visibleContextIDs.count)

        var nodesToVisit = dependencyOrderedSiblingIDs(rootIDs)
            .reversed()
            .map { OutlineNode(issueID: $0, depth: 0) }

        while let node = nodesToVisit.popLast() {
            guard !shouldCancel() else { return [] }
            let childIDs = childIDsByParentID[node.issueID] ?? []
            let visibleChildIDs = visibleChildIDsByParentID[node.issueID] ?? []
            let isContext = !matchingIDSet.contains(node.issueID)
            let isExpanded = !collapsedIssueIDs.contains(node.issueID)
                && (expandedIssueIDs.contains(node.issueID) || (isContext && !visibleChildIDs.isEmpty))
            rows.append(
                IssueListRow(
                    issueID: node.issueID,
                    depth: node.depth,
                    hasChildren: !childIDs.isEmpty,
                    childProgress: childProgressByParentID[node.issueID],
                    isExpanded: isExpanded,
                    isContext: isContext
                )
            )

            guard isExpanded, !visibleChildIDs.isEmpty else { continue }
            let childNodes = dependencyOrderedSiblingIDs(visibleChildIDs)
                .reversed()
                .map { OutlineNode(issueID: $0, depth: node.depth + 1) }
            nodesToVisit.append(contentsOf: childNodes)
        }

        return rows
    }

    private func outlineVisibleIDs(
        matchingIssueIDs: Set<String>,
        expandedIssueIDs: Set<String>,
        collapsedIssueIDs: Set<String>,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> Set<String> {
        var visibleIDs = matchingIssueIDs
        var visitedAncestorIDs: Set<String> = []
        for issueID in matchingIssueIDs {
            guard !shouldCancel() else { return [] }
            var nextID = parentID(for: issueID)
            while let currentID = nextID, visitedAncestorIDs.insert(currentID).inserted {
                guard !shouldCancel() else { return [] }
                visibleIDs.insert(currentID)
                nextID = parentID(for: currentID)
            }
        }

        var visitedExpandedIDs: Set<String> = []
        var expandedIDsToVisit = Array(visibleIDs.intersection(expandedIssueIDs).subtracting(collapsedIssueIDs))
        while let issueID = expandedIDsToVisit.popLast() {
            guard !shouldCancel() else { return [] }
            guard visitedExpandedIDs.insert(issueID).inserted else { continue }

            for childID in childIDsByParentID[issueID] ?? [] {
                guard !shouldCancel() else { return [] }
                guard issueByID[childID] != nil else { continue }
                let inserted = visibleIDs.insert(childID).inserted
                if inserted, expandedIssueIDs.contains(childID), !collapsedIssueIDs.contains(childID) {
                    expandedIDsToVisit.append(childID)
                }
            }
        }

        return visibleIDs
    }

    /// Applies blocker-before-blocked ordering only when a sibling group actually has
    /// an internal dependency edge. The incoming IDs already follow the requested list
    /// sort, so the overwhelmingly common no-edge path is allocation-free.
    private func dependencyOrderedSiblingIDs(_ ids: [String]) -> [String] {
        guard ids.count > 1 else { return ids }
        guard ids.contains(where: { issueID in
            (dependenciesByIssueID[issueID] ?? []).contains(where: \.isBlocking)
        }) else { return ids }

        var baseRank: [String: Int] = [:]
        baseRank.reserveCapacity(ids.count)
        for (rank, issueID) in ids.enumerated() {
            baseRank[issueID] = rank
        }

        var edges: [(blockerID: String, blockedID: String)] = []
        for issueID in ids {
            for dependency in dependenciesByIssueID[issueID] ?? [] where dependency.isBlocking {
                guard baseRank[dependency.issueID] != nil,
                      baseRank[dependency.dependsOnID] != nil else {
                    continue
                }
                edges.append((blockerID: dependency.dependsOnID, blockedID: dependency.issueID))
            }
        }
        guard !edges.isEmpty else { return ids }

        var indegree: [String: Int] = [:]
        indegree.reserveCapacity(ids.count)
        for issueID in ids {
            indegree[issueID] = 0
        }
        var blockedIDsByBlockerID: [String: [String]] = [:]
        for edge in edges {
            blockedIDsByBlockerID[edge.blockerID, default: []].append(edge.blockedID)
            indegree[edge.blockedID, default: 0] += 1
        }

        var readyIDs = Array(ids.filter { indegree[$0, default: 0] == 0 }.reversed())
        var orderedIDs: [String] = []
        orderedIDs.reserveCapacity(ids.count)

        while let issueID = readyIDs.popLast() {
            orderedIDs.append(issueID)

            for blockedID in blockedIDsByBlockerID[issueID] ?? [] {
                indegree[blockedID, default: 0] -= 1
                if indegree[blockedID, default: 0] == 0 {
                    insertReadyID(blockedID, into: &readyIDs, baseRank: baseRank)
                }
            }
        }

        guard orderedIDs.count == ids.count else {
            let orderedSet = Set(orderedIDs)
            return orderedIDs + ids.filter { !orderedSet.contains($0) }
        }

        return orderedIDs
    }

    private func insertReadyID(_ issueID: String, into readyIDs: inout [String], baseRank: [String: Int]) {
        let rank = baseRank[issueID, default: Int.max]
        var lowerBound = 0
        var upperBound = readyIDs.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if baseRank[readyIDs[midpoint], default: Int.max] > rank {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        readyIDs.insert(issueID, at: lowerBound)
    }

    private struct OutlineNode {
        var issueID: String
        var depth: Int
    }

    private static func normalizedParentIDs(
        candidates: [String: String],
        issueByID: [String: BeadIssue]
    ) -> [String: String] {
        candidates.reduce(into: [:]) { result, candidate in
            let issueID = candidate.key
            let parentID = candidate.value
            guard issueByID[issueID] != nil, issueByID[parentID] != nil else { return }

            var visited: Set<String> = [issueID]
            var nextID: String? = parentID
            while let currentID = nextID {
                guard !visited.contains(currentID) else {
                    return
                }
                visited.insert(currentID)
                nextID = candidates[currentID]
            }

            result[issueID] = parentID
        }
    }

    private static func childProgressByParentID(
        childIDsByParentID: [String: [String]],
        issueByID: [String: BeadIssue],
        semantics: BeadProjectSemantics
    ) -> [String: IssueChildProgress] {
        childIDsByParentID.reduce(into: [:]) { result, entry in
            var completedCount = 0
            var workedCount = 0
            var totalCount = 0
            for childID in entry.value {
                guard let child = issueByID[childID] else { continue }
                totalCount += 1
                if semantics.isDone(child) {
                    completedCount += 1
                }
                if semantics.isWorkedOn(child) {
                    workedCount += 1
                }
            }
            guard totalCount > 0 else { return }

            result[entry.key] = IssueChildProgress(
                completedCount: completedCount,
                workedCount: workedCount,
                totalCount: totalCount
            )
        }
    }

    private static func issueIDs(
        for bookmark: BeadBookmark,
        allIssueIDs: Set<String>,
        semantics: BeadProjectSemantics,
        issueIDsByStatus: [String: Set<String>],
        issueIDsByType: [String: Set<String>],
        issueByID: [String: BeadIssue],
        dependenciesByIssueID: [String: [BeadDependency]],
        childIDsByParentID: [String: [String]],
        hidesParentsWithOnlyBlockedChildrenInReady: Bool,
        staleCutoffDays: Int
    ) -> Set<String> {
        if bookmark == .gates {
            return openGateIssueIDs(issueIDsByType: issueIDsByType, issueByID: issueByID, semantics: semantics)
        }
        guard let statusNames = bookmark.statusNames(in: semantics) else {
            return allIssueIDs
        }
        let statusIDs = statusNames.reduce(into: Set<String>()) { partialResult, status in
            partialResult.formUnion(issueIDsByStatus[status, default: []])
        }
        if bookmark == .stale {
            return staleIssueIDs(
                from: statusIDs,
                issueByID: issueByID,
                semantics: semantics,
                staleCutoffDays: staleCutoffDays
            )
        }
        guard bookmark == .ready else {
            return statusIDs
        }
        return readyIssueIDs(
            from: statusIDs,
            issueByID: issueByID,
            dependenciesByIssueID: dependenciesByIssueID,
            childIDsByParentID: childIDsByParentID,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
            semantics: semantics
        )
    }

    /// Open (not-done) gate beads — the base set for the Gates sidebar section.
    static let gateIssueType = "gate"

    private static func openGateIssueIDs(
        issueIDsByType: [String: Set<String>],
        issueByID: [String: BeadIssue],
        semantics: BeadProjectSemantics
    ) -> Set<String> {
        (issueIDsByType[gateIssueType] ?? []).filter { issueID in
            guard let issue = issueByID[issueID] else { return false }
            return !semantics.isDone(issue)
        }
    }

    private static func staleIssueIDs(
        from candidateIDs: Set<String>,
        issueByID: [String: BeadIssue],
        semantics: BeadProjectSemantics,
        staleCutoffDays: Int
    ) -> Set<String> {
        let cutoff = Date().addingTimeInterval(-TimeInterval(max(1, staleCutoffDays)) * secondsPerDay)
        return candidateIDs.filter { issueID in
            guard let issue = issueByID[issueID], !semantics.isDone(issue) else { return false }
            guard let activityDate = issue.updatedAt ?? issue.createdAt else { return false }
            return activityDate <= cutoff
        }
    }

    private static func readyIssueIDs(
        from candidateIDs: Set<String>,
        issueByID: [String: BeadIssue],
        dependenciesByIssueID: [String: [BeadDependency]],
        childIDsByParentID: [String: [String]],
        hidesParentsWithOnlyBlockedChildrenInReady: Bool,
        semantics: BeadProjectSemantics
    ) -> Set<String> {
        let now = Date()
        return candidateIDs.filter { issueID in
            guard let issue = issueByID[issueID] else { return false }
            guard !issue.isGate else { return false }
            guard !isDeferred(issue, relativeTo: now) else { return false }
            return !hasActiveBlocker(
                issueID: issueID,
                issueByID: issueByID,
                dependenciesByIssueID: dependenciesByIssueID,
                semantics: semantics
            )
            && !shouldHideReadyParent(
                issueID: issueID,
                issueByID: issueByID,
                dependenciesByIssueID: dependenciesByIssueID,
                childIDsByParentID: childIDsByParentID,
                hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
                semantics: semantics
            )
        }
    }

    private static func isDeferred(_ issue: BeadIssue, relativeTo now: Date) -> Bool {
        guard let deferUntil = issue.deferUntil else { return false }
        return deferUntil > now
    }

    private static func hasActiveBlocker(
        issueID: String,
        issueByID: [String: BeadIssue],
        dependenciesByIssueID: [String: [BeadDependency]],
        semantics: BeadProjectSemantics
    ) -> Bool {
        for dependency in dependenciesByIssueID[issueID] ?? [] where isBlockingDependency(dependency) {
            guard let blocker = issueByID[dependency.dependsOnID] else {
                return true
            }
            if !semantics.isDone(blocker) {
                return true
            }
        }
        return false
    }

    private static func shouldHideReadyParent(
        issueID: String,
        issueByID: [String: BeadIssue],
        dependenciesByIssueID: [String: [BeadDependency]],
        childIDsByParentID: [String: [String]],
        hidesParentsWithOnlyBlockedChildrenInReady: Bool,
        semantics: BeadProjectSemantics
    ) -> Bool {
        guard hidesParentsWithOnlyBlockedChildrenInReady else { return false }
        let unfinishedChildren = (childIDsByParentID[issueID] ?? [])
            .compactMap { issueByID[$0] }
            .filter { !semantics.isDone($0) }
        guard !unfinishedChildren.isEmpty else { return false }

        return unfinishedChildren.allSatisfy { child in
            isBuiltInBlockedStatus(child.status, semantics: semantics)
                || hasActiveBlocker(
                    issueID: child.id,
                    issueByID: issueByID,
                    dependenciesByIssueID: dependenciesByIssueID,
                    semantics: semantics
                )
        }
    }

    private static func isBuiltInBlockedStatus(_ statusName: String, semantics: BeadProjectSemantics) -> Bool {
        semantics.statuses.contains { status in
            status.name == statusName && status.isBuiltIn && status.name == "blocked"
        }
    }

    private static func isBlockingDependency(_ dependency: BeadDependency) -> Bool {
        dependency.isBlocking
    }

    private static func baseFilterCounts(
        for ids: Set<String>,
        issueByID: [String: BeadIssue],
        semantics: BeadProjectSemantics
    ) -> BeadFilterCounts {
        var statusCounts: [String: Int] = [:]
        var typeCounts: [String: Int] = [:]
        var priorityCounts: [Int: Int] = [:]
        for id in ids {
            guard let issue = issueByID[id] else { continue }
            statusCounts[issue.status, default: 0] += 1
            typeCounts[issue.issueType, default: 0] += 1
            priorityCounts[issue.priority, default: 0] += 1
        }
        return BeadFilterCounts(
            statusCounts: sortedStringCounts(statusCounts, defaults: semantics.statusNames),
            typeCounts: sortedStringCounts(typeCounts, defaults: semantics.typeNames),
            priorityCounts: (0...4).map { ($0, priorityCounts[$0, default: 0]) },
            labelCounts: []
        )
    }

    private static func sortedStringCounts(_ counts: [String: Int], defaults: [String]) -> [(String, Int)] {
        var result = counts
        for value in defaults where result[value] == nil {
            result[value] = 0
        }
        return result.sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value > rhs.value
        }
    }
}
