import Foundation
import SwiftUI

extension BeadStore {
    var availableStatuses: [String] {
        optionStatusDefinitions.map(\.name)
    }

    var gateRejectionStatusOptions: [String] {
        options(availableStatuses, including: defaultGateRejectionStatus, fallback: index.semantics.statusNames)
    }

    var defaultGateRejectionStatus: String? {
        if index.semantics.statusNames.contains(Self.closedStatusName) {
            return Self.closedStatusName
        }
        return index.semantics.statuses.first { $0.category == .done }?.name
    }

    var availableTypes: [String] {
        optionTypeDefinitions.map(\.name)
    }

    var availableMutableTypes: [String] {
        BeadIssueWorkflowPolicy.normalMutableIssueTypes(optionTypeDefinitions.map(\.name))
    }

    var availableDependencyTypes: [String] {
        index.dependencyTypeNames
    }

    var availableLabels: [String] {
        index.labelNames
    }

    var availableOwners: [String] {
        index.ownerNames
    }

    var availableAssignees: [String] {
        index.assigneeNames
    }

    var statusCounts: [(String, Int)] {
        filterCounts.statusCounts.filter { !hiddenStatusNames.contains($0.0) || $0.1 > 0 }
    }

    var typeCounts: [(String, Int)] {
        filterCounts.typeCounts.filter { !hiddenTypeNames.contains($0.0) || $0.1 > 0 }
    }

    var priorityCounts: [(Int, Int)] {
        filterCounts.priorityCounts
    }

    var labelCounts: [(String, Int)] {
        filterCounts.labelCounts
    }

    var activeFilterCount: Int {
        statusFilters.count + typeFilters.count + priorityFilters.count + labelFilters.count
    }

    var hasActiveFilters: Bool {
        activeFilterCount > 0
    }

    var canSetTypeForSelection: Bool {
        !selectedIDs.isEmpty
            && selectedIDs.allSatisfy { id in
                guard let issue = index.issue(with: id) else { return false }
                return !issue.isGate && !issue.isSystemRecord
            }
    }

    var beadListDisplayOptions: BeadListDisplayOptions {
        BeadListDisplayOptions(
            showsOwner: showsOwnerInBeadList,
            showsAssignee: showsAssigneeInBeadList,
            showsDueDate: showsDueDateInBeadList,
            showsComments: showsCommentsInBeadList
        )
    }

    var allStatusDefinitions: [BeadStatusDefinition] {
        index.semantics.statuses
    }

    var allTypeDefinitions: [BeadTypeDefinition] {
        index.semantics.types
    }

    private var optionStatusDefinitions: [BeadStatusDefinition] {
        index.semantics.statuses.filter { !hiddenStatusNames.contains($0.name) }
    }

    private var optionTypeDefinitions: [BeadTypeDefinition] {
        index.semantics.types.filter { !hiddenTypeNames.contains($0.name) }
    }

    var bdCLIPathValidationMessage: String {
        let path = bdCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return "Using BEADAZZLE_BD_PATH, PATH, and fallback directories."
        }
        if FileManager.default.isExecutableFile(atPath: path) {
            return "Executable path configured."
        }
        return "Path is not executable; Beadazzle will continue searching."
    }

    var resolvedBDCLIPathDisplay: String {
        let executable = BeadsCLI.executable()
        return ([executable.url.path] + executable.prefix).joined(separator: " ")
    }

    var filteredIssueCount: Int {
        filteredIssueIDs.count
    }

    var canExpandSelectedIssueChildren: Bool {
        guard let selectedRow = selectedOutlineRow else { return false }
        return selectedRow.hasChildren && !selectedRow.isExpanded
    }

    var canCollapseSelectedIssueChildren: Bool {
        guard let selectedRow = selectedOutlineRow else { return false }
        return selectedRow.hasChildren && selectedRow.isExpanded
    }

    func count(for bookmark: BeadBookmark) -> Int {
        index.count(for: bookmark)
    }

    func blankDraft(parentID: String? = nil) -> IssueDraft {
        let fallbackType = BeadIssueWorkflowPolicy.normalMutableIssueTypes(index.semantics.typeNames).first ?? ""
        return IssueDraft.blank(
            defaultType: availableMutableTypes.first ?? fallbackType,
            defaultStatus: availableStatuses.first ?? index.semantics.statusNames.first ?? "",
            parentID: parentID
        )
    }

    func beadPickerDefaultDraft(for configuration: BeadPickerConfiguration) -> IssueDraft {
        var draft = blankDraft(parentID: configuration.quickCreate?.defaultParentID)
        if configuration.quickCreate != nil {
            draft.issueType = beadPickerQuickCreateTypeOptions(
                action: configuration.action,
                including: nil
            ).first ?? ""
        }
        return draft
    }

    func statusOptions(including currentStatus: String?) -> [String] {
        options(availableStatuses, including: currentStatus, fallback: index.semantics.statusNames)
    }

    func statusChangeOptions(excluding currentStatus: String?) -> [String] {
        let currentStatus = currentStatus?.nilIfBlank
        return availableStatuses.filter { $0 != currentStatus }
    }

    func statusChangeOptions(forIssueIDs issueIDs: Set<String>) -> [String] {
        let selectedStatuses = issueIDs.compactMap { index.issue(with: $0)?.status }
        guard !selectedStatuses.isEmpty else { return [] }
        return availableStatuses.filter { option in
            selectedStatuses.contains { $0 != option }
        }
    }

    func typeOptions(including currentType: String?) -> [String] {
        let currentType = currentType.flatMap {
            BeadIssueWorkflowPolicy.isSystemRecordIssueType($0) ? nil : $0
        }
        return options(availableTypes, including: currentType, fallback: index.semantics.typeNames)
    }

    func mutableTypeOptions(including currentType: String?) -> [String] {
        let currentType = currentType.flatMap {
            BeadIssueWorkflowPolicy.isNormalMutableIssueType($0) ? $0 : nil
        }
        return options(
            availableMutableTypes,
            including: currentType,
            fallback: BeadIssueWorkflowPolicy.normalMutableIssueTypes(index.semantics.typeNames)
        )
    }

    func beadPickerQuickCreateTypeOptions(action: BeadPickerAction, including currentType: String?) -> [String] {
        let options = mutableTypeOptions(including: currentType)
        switch action {
        case .setParent, .addChild:
            return options
        case .addBlockedBy(let issueID), .addBlocks(let issueID):
            guard let issue = index.issue(with: issueID) else { return options }
            let compatibleOptions = BeadIssueWorkflowPolicy.blockingCompatibleIssueTypes(
                with: issue.issueType,
                candidates: options
            )
            return compatibleOptions
        }
    }

    internal func options(_ choices: [String], including currentValue: String?, fallback: [String]) -> [String] {
        var result = choices
        if let currentValue = currentValue?.nilIfBlank, !result.contains(currentValue) {
            result.insert(currentValue, at: 0)
        }
        if result.isEmpty {
            result = fallback
        }
        return result
    }

    func statusSymbol(for status: String) -> String {
        BeadVisualStyle.symbol(forCategory: statusCategory(for: status))
    }

    func statusColor(for status: String) -> Color {
        BeadVisualStyle.color(forCategory: statusCategory(for: status))
    }

    func statusCategory(for status: String) -> BeadStatusCategory {
        index.semantics.category(forStatus: status)
    }

    func statusClosesBeads(_ status: String) -> Bool {
        hierarchyMutationPolicy.statusClosesBeads(status)
    }

    func isDeferredStatus(_ status: String) -> Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.deferredStatusName
    }

    func isDone(_ issue: BeadIssue) -> Bool {
        index.semantics.isDone(issue) || statusClosesBeads(issue.status)
    }

    func completionAction(for issueIDs: [String]) -> BeadCompletionAction {
        let issues = issueIDs.compactMap { index.issue(with: $0) }
        return BeadIssueWorkflowPolicy.completionAction(for: issues, isDone: isDone)
    }

    func completionActionTitle(for issueIDs: [String]) -> String {
        let count = Set(issueIDs).count
        let issues = issueIDs.compactMap { index.issue(with: $0) }
        return BeadIssueWorkflowPolicy.completionTitle(issueCount: count, issues: issues, isDone: isDone)
    }

    func completionActionSystemImage(for issueIDs: [String]) -> String {
        BeadIssueWorkflowPolicy.completionSystemImage(for: completionAction(for: issueIDs))
    }

    func canCreateGate(blocking issue: BeadIssue) -> Bool {
        BeadIssueWorkflowPolicy.canCreateGate(blocking: issue, isDone: isDone(issue))
    }

    enum StatusChangeConfirmation: Equatable {
        case closeChildren([BeadIssue])
        case reopenAncestors([BeadIssue])
        case deferDate
        case proceed
    }

    /// Decides which confirmation, if any, setting `status` on `issueIDs` requires,
    /// so views present the matching sheet without re-deriving hierarchy policy.
    func statusChangeConfirmation(forSetting status: String, on issueIDs: [String]) -> StatusChangeConfirmation {
        if statusClosesBeads(status) {
            let childIssues = openChildIssues(forClosing: issueIDs)
            if !childIssues.isEmpty { return .closeChildren(childIssues) }
        } else {
            let ancestorIssues = doneAncestorIssues(forReopening: issueIDs)
            if !ancestorIssues.isEmpty { return .reopenAncestors(ancestorIssues) }
        }
        if isDeferredStatus(status) { return .deferDate }
        return .proceed
    }

    enum ReopenConfirmation: Equatable {
        case reopenAncestors([BeadIssue], reopenStatus: String)
        case missingReopenStatus
        case proceed
    }

    func reopenConfirmation(for issueIDs: [String]) -> ReopenConfirmation {
        let ancestorIssues = doneAncestorIssues(forReopening: issueIDs)
        guard !ancestorIssues.isEmpty else { return .proceed }
        guard let reopenStatus = reopenStatusName else { return .missingReopenStatus }
        return .reopenAncestors(ancestorIssues, reopenStatus: reopenStatus)
    }

    var reopenStatusName: String? {
        if index.semantics.statuses.contains(where: { $0.name == "open" && $0.category == .active }) {
            return "open"
        }
        return index.semantics.statuses.first { $0.category == .active }?.name
    }

    internal var gateApprovalStatusName: String? {
        reopenStatusName
    }

    internal func isBuiltInBlockedIssue(_ issue: BeadIssue) -> Bool {
        index.semantics.statuses.contains { status in
            status.name == issue.status && status.isBuiltIn && status.name == "blocked"
        }
    }

    internal func isEligibleForGateDecision(_ issue: BeadIssue, excludingGateID gateID: String) -> Bool {
        isBuiltInBlockedIssue(issue)
            && !isDone(issue)
            && !hasActiveBlocker(issueID: issue.id, excludingGateID: gateID)
    }

    internal func hasActiveBlocker(issueID: String, excludingGateID gateID: String?) -> Bool {
        hasDirectActiveBlocker(issueID: issueID, excludingGateID: gateID)
            || hasActiveBlockedDescendant(issueID: issueID, excludingGateID: gateID)
    }

    private func hasDirectActiveBlocker(issueID: String, excludingGateID gateID: String?) -> Bool {
        for dependency in index.dependenciesByIssueID[issueID] ?? [] where dependency.isBlocking {
            if dependency.dependsOnID == gateID {
                continue
            }
            guard let blocker = index.issue(with: dependency.dependsOnID) else {
                return true
            }
            if !isDone(blocker) {
                return true
            }
        }
        return false
    }

    private func hasActiveBlockedDescendant(issueID: String, excludingGateID gateID: String?) -> Bool {
        containsOpenDescendant(of: issueID) { descendant in
            hasDirectActiveBlocker(issueID: descendant.id, excludingGateID: gateID)
        }
    }

    private func containsOpenDescendant(
        of issueID: String,
        where predicate: (BeadIssue) -> Bool
    ) -> Bool {
        visitOpenDescendants(of: issueID) { descendant in
            predicate(descendant)
        }
    }

    private func bestOpenDescendant(
        of issueID: String,
        where predicate: (BeadIssue) -> Bool
    ) -> BeadIssue? {
        let sortOrder = BeadIssueSortOrder(sort: .priority, direction: .ascending)
        var bestMatch: BeadIssue?

        visitOpenDescendants(of: issueID) { descendant in
            guard predicate(descendant) else { return false }
            if let current = bestMatch {
                if sortOrder.areInIncreasingOrder(descendant, current) {
                    bestMatch = descendant
                }
            } else {
                bestMatch = descendant
            }
            return false
        }

        return bestMatch
    }

    @discardableResult
    private func visitOpenDescendants(
        of issueID: String,
        _ visit: (BeadIssue) -> Bool
    ) -> Bool {
        var visitedIDs = Set([issueID])
        var stack = index.childIDsByParentID[issueID] ?? []

        while let descendantID = stack.popLast() {
            guard visitedIDs.insert(descendantID).inserted,
                  let descendant = index.issue(with: descendantID) else {
                continue
            }
            stack.append(contentsOf: index.childIDsByParentID[descendantID] ?? [])
            guard !isDone(descendant) else { continue }
            if visit(descendant) {
                return true
            }
        }

        return false
    }

    internal func blockedDescendantPresentation(for issueID: String, now: Date) -> BlockedReasonPresentation? {
        if let descendant = bestOpenDescendant(
            of: issueID,
            where: { !activeBlockingPresentations(for: $0.id, now: now).isEmpty }
        ) {
            return BlockedReasonPresentation.subissue(
                descendant,
                blockers: activeBlockingPresentations(for: descendant.id, now: now)
            )
        }

        guard let blockedDescendant = bestOpenDescendant(of: issueID, where: isBuiltInBlockedIssue) else {
            return nil
        }
        return BlockedReasonPresentation.subissue(blockedDescendant, blockers: [])
    }

    internal func activeBlockingPresentations(
        for issueID: String,
        now: Date
    ) -> [BlockedReasonPresentation.Blocker] {
        let activeIssueBlockers = activeBlockingIssues(for: issueID).map { issue in
            if let gate = gate(for: issue.id) {
                return BlockedReasonPresentation.Blocker.gate(gate, now: now)
            }
            return BlockedReasonPresentation.Blocker.issue(issue)
        }

        let externalBlockers = externalBlockingReferences(for: issueID).map {
            BlockedReasonPresentation.Blocker.external(reference: $0)
        }

        return activeIssueBlockers + externalBlockers
    }

    private func externalBlockingReferences(for issueID: String) -> [String] {
        var references: Set<String> = []
        for dependency in index.dependenciesByIssueID[issueID] ?? [] where dependency.isBlocking {
            guard index.issue(with: dependency.dependsOnID) == nil else { continue }
            references.insert(dependency.dependsOnID)
        }
        return references.sorted { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

}
