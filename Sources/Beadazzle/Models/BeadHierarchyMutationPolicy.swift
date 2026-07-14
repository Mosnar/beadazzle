import Foundation

struct BeadHierarchyMutationPolicy: Sendable {
    private static let closedStatusName = "closed"
    private static let parentChildDependencyType = "parent-child"

    private let index: BeadProjectIndex

    init(index: BeadProjectIndex) {
        self.index = index
    }

    func statusClosesBeads(_ status: String) -> Bool {
        normalized(status) == Self.closedStatusName || index.semantics.category(forStatus: status) == .done
    }

    func isDone(_ issue: BeadIssue) -> Bool {
        index.semantics.isDone(issue) || statusClosesBeads(issue.status)
    }

    func unresolvedDescendantsPreventingCompletion(
        of issueIDs: [String],
        includedIssueIDs: [String]
    ) -> [BeadIssue] {
        let includedIDSet = Set(includedIssueIDs)
        var visitedIDs = Set(issueIDs)
        var parentIDsToVisit = issueIDs.sorted()
        var parentIndex = 0
        var unresolvedChildren: [BeadIssue] = []

        while parentIndex < parentIDsToVisit.count {
            let parentID = parentIDsToVisit[parentIndex]
            parentIndex += 1

            for childID in (index.childIDsByParentID[parentID] ?? []).sorted() {
                guard visitedIDs.insert(childID).inserted,
                      let child = index.issue(with: childID)
                else { continue }

                parentIDsToVisit.append(childID)
                if !includedIDSet.contains(childID), !isDone(child) {
                    unresolvedChildren.append(child)
                }
            }
        }

        return unresolvedChildren.sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    func descendants(of issueIDs: [String], excluding excludedIssueIDs: [String]) -> [BeadIssue] {
        let excludedIDSet = Set(excludedIssueIDs)
        var visitedIDs = Set(issueIDs)
        var parentIDsToVisit = issueIDs.sorted()
        var parentIndex = 0
        var descendants: [BeadIssue] = []

        while parentIndex < parentIDsToVisit.count {
            let parentID = parentIDsToVisit[parentIndex]
            parentIndex += 1

            for childID in (index.childIDsByParentID[parentID] ?? []).sorted() {
                guard visitedIDs.insert(childID).inserted,
                      let child = index.issue(with: childID)
                else { continue }

                parentIDsToVisit.append(childID)
                if !excludedIDSet.contains(childID) {
                    descendants.append(child)
                }
            }
        }

        return descendants.sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    func doneAncestorsPreventingUncompletion(
        of issueIDs: [String],
        includedIssueIDs: [String]
    ) -> [BeadIssue] {
        let includedIDSet = Set(includedIssueIDs)
        var ancestorByID: [String: BeadIssue] = [:]

        for issueID in issueIDs.sorted() {
            for ancestorID in index.ancestorIDs(for: issueID) {
                guard !includedIDSet.contains(ancestorID),
                      ancestorByID[ancestorID] == nil,
                      let ancestor = index.issue(with: ancestorID),
                      isDone(ancestor)
                else { continue }
                ancestorByID[ancestorID] = ancestor
            }
        }

        return ancestorByID.values.sorted { lhs, rhs in
            let lhsDepth = index.ancestorIDs(for: lhs.id).count
            let rhsDepth = index.ancestorIDs(for: rhs.id).count
            if lhsDepth != rhsDepth {
                return lhsDepth < rhsDepth
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    func completionWriteOrder(_ issueIDs: [String]) -> [String] {
        orderedByDepth(issueIDs, deepestFirst: true)
    }

    func reopenWriteOrder(_ issueIDs: [String]) -> [String] {
        orderedByDepth(issueIDs, deepestFirst: false)
    }

    func unresolvedIssuesCreatedByParentChildDependency(
        issueID: String,
        dependsOnID: String,
        type: String
    ) -> [BeadIssue] {
        guard normalized(type) == Self.parentChildDependencyType,
              let child = index.issue(with: issueID),
              let parent = index.issue(with: dependsOnID),
              isDone(parent)
        else { return [] }

        var unresolvedIssuesByID: [String: BeadIssue] = [:]
        if !isDone(child) {
            unresolvedIssuesByID[child.id] = child
        }
        for descendant in unresolvedDescendantsPreventingCompletion(of: [issueID], includedIssueIDs: [issueID]) {
            unresolvedIssuesByID[descendant.id] = descendant
        }

        return unresolvedIssuesByID.values.sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private func orderedByDepth(_ issueIDs: [String], deepestFirst: Bool) -> [String] {
        let uniqueIDs = Array(Set(issueIDs)).sorted()
        let depthByID = Dictionary(uniqueKeysWithValues: uniqueIDs.map { issueID in
            (issueID, index.ancestorIDs(for: issueID).count)
        })
        return uniqueIDs.sorted { lhs, rhs in
            let lhsDepth = depthByID[lhs, default: 0]
            let rhsDepth = depthByID[rhs, default: 0]
            if lhsDepth != rhsDepth {
                return deepestFirst ? lhsDepth > rhsDepth : lhsDepth < rhsDepth
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
