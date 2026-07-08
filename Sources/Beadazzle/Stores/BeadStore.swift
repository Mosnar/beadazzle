import Foundation
import Observation
import SwiftUI

enum BeadProjectReadiness: Equatable {
    case noProject
    case ready
    case missingDataSource(URL)

    var missingDataSourceURL: URL? {
        if case .missingDataSource(let url) = self {
            return url
        }
        return nil
    }

    var isReady: Bool {
        self == .ready
    }
}

@Observable
@MainActor
final class BeadStore {
    var projectURL: URL?
    private(set) var projectReadiness = BeadProjectReadiness.noProject
    private(set) var recentProjects: [RecentProject] = []
    var issues: [BeadIssue] = []
    private(set) var filteredIssueIDs: [String] = []
    private(set) var issueListRows: [IssueListRow] = []
    var dependencies: [BeadDependency] = []
    private(set) var dependencyIssueID: String?
    private(set) var comments: [BeadComment] = []
    private(set) var commentsIssueID: String?
    private(set) var commentRefreshIssueID: String?
    private(set) var selectedIDs: Set<String> = []
    private(set) var fullPageDetailIssueID: String?
    private(set) var selectedBookmark: BeadBookmark = .ready
    var creationDraft: IssueDraft? {
        didSet {
            guard oldValue != creationDraft else { return }
            syncCurrentWorkspaceSnapshotIfNeeded()
        }
    }
    private(set) var filterCounts = BeadFilterCounts.empty
    /// Bumped whenever issue *content* changes (project load/reload after a mutation, index
    /// rebuild) even if the derived row list keeps the same structure. Lets the list view
    /// refresh visible cells for edits (e.g. a title change) without reconfiguring on every
    /// selection change.
    private(set) var contentRevision = 0
    private(set) var currentDataSource: BeadsDataSource?
    private(set) var snapshotFreshness = ProjectSnapshotFreshness.unknown
    private(set) var projectHealthSnapshot: ProjectHealthSnapshot?
    private(set) var isLoadingProjectHealth = false
    private(set) var projectHealthAction: ProjectHealthAction?
    private(set) var projectHealthActionError: String?
    /// Gate detail cache keyed by gate bead id. The issue snapshot is the source of truth
    /// for display fields; `bd gate show` only enriches the selected gate with waiters.
    private(set) var gatesByID: [String: BeadGate] = [:]
    private(set) var gateClock = Date()
    var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            filterStateDidChange(debounce: true)
        }
    }
    var statusFilters: Set<String> = [] {
        didSet {
            guard oldValue != statusFilters else { return }
            filterStateDidChange()
        }
    }
    var typeFilters: Set<String> = [] {
        didSet {
            guard oldValue != typeFilters else { return }
            filterStateDidChange()
        }
    }
    var priorityFilters: Set<Int> = [] {
        didSet {
            guard oldValue != priorityFilters else { return }
            filterStateDidChange()
        }
    }
    var labelFilters: Set<String> = [] {
        didSet {
            guard oldValue != labelFilters else { return }
            filterStateDidChange()
        }
    }
    var sort = IssueSort.priority {
        didSet {
            guard oldValue != sort else { return }
            sortStateDidChange()
        }
    }
    var sortDirection = SortDirection.ascending {
        didSet {
            guard oldValue != sortDirection else { return }
            sortStateDidChange()
        }
    }
    var issueListMode = IssueListMode.outline {
        didSet {
            guard oldValue != issueListMode else { return }
            rebuildIssueListRows()
            syncCurrentWorkspaceSnapshotIfNeeded()
        }
    }
    var bdCLIPath = "" {
        didSet {
            guard oldValue != bdCLIPath else { return }
            persistBDCLIPath()
        }
    }
    var staleCutoffDays = BeadProjectIndex.defaultStaleCutoffDays {
        didSet {
            guard oldValue != staleCutoffDays else { return }
            let normalizedValue = Self.normalizedStaleCutoffDays(staleCutoffDays)
            guard normalizedValue == staleCutoffDays else {
                staleCutoffDays = normalizedValue
                return
            }
            persistStaleCutoffDays()
            rebuildIndexForProjectIndexPreferenceChange()
        }
    }
    var hidesParentsWithOnlyBlockedChildrenInReady = true {
        didSet {
            guard oldValue != hidesParentsWithOnlyBlockedChildrenInReady else { return }
            persistReadyParentRollUpPreference()
            rebuildIndexForProjectIndexPreferenceChange()
        }
    }
    var showsOwnerInBeadList = false {
        didSet {
            guard oldValue != showsOwnerInBeadList else { return }
            userDefaults.set(showsOwnerInBeadList, forKey: BeadazzlePreferenceKeys.showsOwnerInBeadList)
        }
    }
    var showsAssigneeInBeadList = false {
        didSet {
            guard oldValue != showsAssigneeInBeadList else { return }
            userDefaults.set(showsAssigneeInBeadList, forKey: BeadazzlePreferenceKeys.showsAssigneeInBeadList)
        }
    }
    var showsDueDateInBeadList = false {
        didSet {
            guard oldValue != showsDueDateInBeadList else { return }
            userDefaults.set(showsDueDateInBeadList, forKey: BeadazzlePreferenceKeys.showsDueDateInBeadList)
        }
    }
    var showsCommentsInBeadList = true {
        didSet {
            guard oldValue != showsCommentsInBeadList else { return }
            userDefaults.set(showsCommentsInBeadList, forKey: BeadazzlePreferenceKeys.showsCommentsInBeadList)
        }
    }
    var isLoading = false
    private(set) var isInitializingBeads = false
    private(set) var isLoadingComments = false
    private(set) var isAddingComment = false
    var lastError: String?
    private(set) var hiddenTypeNames: Set<String> = []
    private(set) var hiddenStatusNames: Set<String> = []
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored private let commands: any BeadsCommanding
    @ObservationIgnored private let projectLoader: BeadProjectLoader
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var reconcileDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var activeMutationCount = 0
    @ObservationIgnored private var mutationWriteChain: Task<Void, Never>?
    @ObservationIgnored private var mutationWriteGeneration = 0
    @ObservationIgnored private var pendingReconcile = false
    @ObservationIgnored private var isReconcileInFlight = false
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    @ObservationIgnored private var queryGeneration = 0
    @ObservationIgnored private var selectionSideDataTask: Task<Void, Never>?
    @ObservationIgnored private var gateDetailTask: Task<Void, Never>?
    @ObservationIgnored private var projectHealthTask: Task<Void, Never>?
    @ObservationIgnored private var dataSourceMonitor: BeadsDataSourceMonitor?
    @ObservationIgnored private var monitoredSourceFingerprint: String?
    /// Cached status/type definitions, reused across reloads so routine reloads don't
    /// spawn two `bd --readonly` subprocesses. Reloaded on initial/manual refresh, and
    /// after the app edits custom definitions (which set this back to `nil`). A `nil` cache
    /// forces the next reload to re-read from `bd`, so a failed reload naturally retries.
    @ObservationIgnored private var cachedDefinitions: BeadSemanticDefinitions?
    @ObservationIgnored private var commentCache: [String: [BeadComment]] = [:]
    @ObservationIgnored private var outlineState = BeadOutlineSelectionState()
    @ObservationIgnored private var workspaceHistory = BeadWorkspaceHistory()
    @ObservationIgnored private var isRestoringWorkspace = false
    @ObservationIgnored private var suppressesHistoryRecording = false
    @ObservationIgnored private var suppressesFilterUpdates = false
    @ObservationIgnored private let userDefaults: UserDefaults

    private var index = BeadProjectIndex.empty

    var hierarchyMutationPolicy: BeadHierarchyMutationPolicy {
        BeadHierarchyMutationPolicy(index: index)
    }

    private static let lastProjectPathKey = "LastProjectPath"
    private static let recentProjectPathsKey = "RecentProjectPaths"
    private static let maxRecentProjectCount = 8

    init(
        userDefaults: UserDefaults = .standard,
        commands: any BeadsCommanding = BeadsCommandService()
    ) {
        self.userDefaults = userDefaults
        self.commands = commands
        self.projectLoader = BeadProjectLoader(commands: commands)
        bdCLIPath = userDefaults.string(forKey: BeadazzlePreferenceKeys.bdCLIPath) ?? ""
        staleCutoffDays = Self.normalizedStaleCutoffDays(
            userDefaults.object(forKey: BeadazzlePreferenceKeys.staleCutoffDays) as? Int
                ?? BeadProjectIndex.defaultStaleCutoffDays
        )
        showsOwnerInBeadList = Self.boolValue(
            userDefaults,
            key: BeadazzlePreferenceKeys.showsOwnerInBeadList,
            defaultValue: false
        )
        showsAssigneeInBeadList = Self.boolValue(
            userDefaults,
            key: BeadazzlePreferenceKeys.showsAssigneeInBeadList,
            defaultValue: false
        )
        showsDueDateInBeadList = Self.boolValue(
            userDefaults,
            key: BeadazzlePreferenceKeys.showsDueDateInBeadList,
            defaultValue: false
        )
        showsCommentsInBeadList = Self.boolValue(
            userDefaults,
            key: BeadazzlePreferenceKeys.showsCommentsInBeadList,
            defaultValue: true
        )
        recentProjects = Self.loadRecentProjects(from: userDefaults)

        if recentProjects.isEmpty,
           let legacyPath = userDefaults.string(forKey: Self.lastProjectPathKey),
           !legacyPath.isEmpty {
            recentProjects = [RecentProject(url: URL(fileURLWithPath: legacyPath))]
            persistRecentProjects()
        }
    }

    var projectName: String {
        projectURL?.lastPathComponent ?? "No Project"
    }

    var hasReadableProject: Bool {
        projectURL != nil && projectReadiness.isReady
    }

    /// The Gates section has no free-standing "new" — gates are created on an existing bead
    /// (a bead's ⋯ menu), so plain bead creation is suppressed there.
    var canCreateBead: Bool {
        hasReadableProject && selectedBookmark != .gates
    }

    var missingDataSourceURL: URL? {
        projectReadiness.missingDataSourceURL
    }

    var currentWorkspaceSnapshot: BeadWorkspaceSnapshot? {
        workspaceHistory.currentSnapshot
    }

    func beginCreatingBead() {
        guard canCreateBead, creationDraft == nil else { return }
        suppressesHistoryRecording = true
        clearSelection()
        fullPageDetailIssueID = nil
        creationDraft = blankDraft()
        suppressesHistoryRecording = false
        recordWorkspaceSnapshotIfNeeded()
    }

    func canCreateChildBead(parentID: String) -> Bool {
        guard hasReadableProject,
              let parent = index.issue(with: parentID) else {
            return false
        }
        return !parent.isGate
    }

    func beginCreatingChildBead(parentID: String) {
        guard canCreateChildBead(parentID: parentID), creationDraft == nil else { return }
        suppressesHistoryRecording = true
        selectedIDs.removeAll()
        fullPageDetailIssueID = nil
        clearSelectionSideData()
        creationDraft = blankDraft(parentID: parentID)
        suppressesHistoryRecording = false
        recordWorkspaceSnapshotIfNeeded()
    }

    func cancelCreation() {
        guard creationDraft != nil else { return }
        creationDraft = nil
        recordWorkspaceSnapshotIfNeeded()
    }

    func goBack() {
        guard let snapshot = workspaceHistory.goBack() else { return }
        syncWorkspaceHistoryAvailability()
        restoreWorkspace(snapshot)
    }

    func goForward() {
        guard let snapshot = workspaceHistory.goForward() else { return }
        syncWorkspaceHistoryAvailability()
        restoreWorkspace(snapshot)
    }

    var selectedIssue: BeadIssue? {
        guard let id = selectedIDs.first, selectedIDs.count == 1 else { return nil }
        return index.issue(with: id)
    }

    func parentIssue(for issueID: String) -> BeadIssue? {
        guard let parentID = index.parentID(for: issueID) else { return nil }
        return index.issue(with: parentID)
    }

    func subIssueRows(parentID: String) -> [IssueListRow] {
        index.immediateChildRows(
            parentID: parentID,
            sortOrder: BeadIssueSortOrder(sort: sort, direction: sortDirection)
        )
    }

    func beadPickerRows(
        configuration: BeadPickerConfiguration,
        filters: BeadPickerFilters,
        searchText: String,
        mode: IssueListMode,
        outlineState: BeadOutlineSelectionState
    ) async -> BeadPickerQueryResult {
        let index = index
        let sortOrder = BeadIssueSortOrder(sort: sort, direction: sortDirection)
        let queryTask = Task.detached(priority: .userInitiated) {
            BeadPickerQuery.rows(
                index: index,
                configuration: configuration,
                filters: filters,
                searchText: searchText,
                mode: mode,
                outlineState: outlineState,
                sortOrder: sortOrder,
                shouldCancel: { Task.isCancelled }
            )
        }
        return await withTaskCancellationHandler {
            await queryTask.value
        } onCancel: {
            queryTask.cancel()
        }
    }

    func childProgress(parentID: String) -> IssueChildProgress? {
        index.childProgress(for: parentID)
    }

    func activeBlockingIssues(for issueID: String) -> [BeadIssue] {
        index.activeBlockingIssues(
            for: issueID,
            sortOrder: BeadIssueSortOrder(sort: sort, direction: sortDirection)
        )
    }

    func activelyBlockedIssues(by issueID: String) -> [BeadIssue] {
        index.activelyBlockedIssues(
            by: issueID,
            sortOrder: BeadIssueSortOrder(sort: sort, direction: sortDirection)
        )
    }

    func blockedReasonPresentation(
        for issueID: String,
        bookmark: BeadBookmark,
        now: Date = Date()
    ) -> BlockedReasonPresentation? {
        guard bookmark == .blocked else { return nil }
        if let presentation = blockedReasonPresentation(for: issueID, now: now) {
            return presentation
        }
        guard index.issue(with: issueID) != nil else { return nil }
        return blockedDescendantPresentation(for: issueID, now: now)
    }

    func blockedReasonPresentation(for issueID: String, now: Date = Date()) -> BlockedReasonPresentation? {
        guard let issue = index.issue(with: issueID),
              isBuiltInBlockedIssue(issue),
              !isDone(issue) else {
            return nil
        }

        let activeBlockers = activeBlockingPresentations(for: issueID, now: now)
        if let presentation = BlockedReasonPresentation.active(blockers: activeBlockers) {
            return presentation
        }

        if let presentation = blockedDescendantPresentation(for: issueID, now: now) {
            return presentation
        }

        if let presentation = BlockedReasonPresentation.resolvedGate(
            gates: resolvedGatesForStaleBlockedIssue(issueID: issueID),
            now: now
        ) {
            return presentation
        }

        return .unexplained
    }

    /// The gate metadata for an issue, if that issue is a gate bead.
    func gate(for id: String) -> BeadGate? {
        guard let issue = index.issue(with: id),
              var gate = BeadGate(issue: issue) else {
            return nil
        }
        if let detail = gatesByID[id], detail.updatedAt == gate.updatedAt {
            gate.waiters = detail.waiters
        }
        return gate
    }

    func refreshGateClock(_ now: Date = Date()) {
        guard selectedBookmark == .gates || selectedBookmark == .blocked else { return }
        gateClock = now
        rebuildIssueListRows()
    }

    func nextGateTimerExpiry(after now: Date = Date()) -> Date? {
        timerGateIDsForCurrentBookmark()
            .compactMap { id -> Date? in
                guard let gate = gate(for: id),
                      gate.isOpen,
                      gate.awaitType == .timer,
                      let expiresAt = gate.expiresAt,
                      expiresAt > now else {
                    return nil
                }
                return expiresAt
            }
            .min()
    }

    private func timerGateIDsForCurrentBookmark() -> Set<String> {
        switch selectedBookmark {
        case .gates:
            index.issueIDs(for: .gates)
        case .blocked:
            Set(index.issueIDs(for: .blocked).flatMap { issueID in
                (index.dependenciesByIssueID[issueID] ?? [])
                    .filter(\.isBlocking)
                    .map(\.dependsOnID)
            })
        case .ready, .stale, .open, .inProgress, .closed, .all:
            []
        }
    }

    /// The beads a gate blocks, derived from the dependency graph (`blocks` edges pointing
    /// at the gate). This is authoritative — no need to parse the gate description.
    func blockedBeads(byGateID gateID: String) -> [BeadIssue] {
        let fromGraph = (index.dependentsByIssueID[gateID] ?? [])
            .filter(\.isBlocking)
            .compactMap { index.issue(with: $0.issueID) }
        if !fromGraph.isEmpty {
            return fromGraph
        }
        // Fallback: the blocked id parsed from the gate description, for the window before the
        // `blocks` edge lands in the snapshot (or a `bd` that omits it from the export).
        if let blockedID = gate(for: gateID)?.blocksIssueID, let issue = index.issue(with: blockedID) {
            return [issue]
        }
        return []
    }

    /// The gates currently blocking a bead (its `blocks` dependencies whose target is a gate).
    func gatesBlocking(issueID: String) -> [BeadGate] {
        gateBlockers(issueID: issueID).filter(\.isOpen)
    }

    /// Resolved gate dependencies left behind as history. These should not render as active
    /// blockers, but they can explain why a bead is still manually marked blocked.
    func resolvedGatesBlocking(issueID: String) -> [BeadGate] {
        gateBlockers(issueID: issueID).filter { !$0.isOpen }
    }

    func resolvedGatesForStaleBlockedIssue(issueID: String) -> [BeadGate] {
        guard let issue = index.issue(with: issueID),
              isBuiltInBlockedIssue(issue),
              !isDone(issue) else {
            return []
        }
        let gates = gateBlockers(issueID: issueID)
        let resolvedGates = gates.filter { !$0.isOpen }
        guard !resolvedGates.isEmpty,
              gates.allSatisfy({ !$0.isOpen }),
              !hasActiveBlocker(issueID: issueID, excludingGateID: nil) else {
            return []
        }
        return resolvedGates
    }

    func gateDecisionAffectedBeads(for gateID: String) -> [BeadIssue] {
        directBlockedBeads(byGateID: gateID)
            .filter { isEligibleForGateDecision($0, excludingGateID: gateID) }
            .sorted { lhs, rhs in lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending }
    }

    private func gateBlockers(issueID: String) -> [BeadGate] {
        (index.dependenciesByIssueID[issueID] ?? [])
            .filter(\.isBlocking)
            .compactMap { gate(for: $0.dependsOnID) }
    }

    private func directBlockedBeads(byGateID gateID: String) -> [BeadIssue] {
        (index.dependentsByIssueID[gateID] ?? [])
            .filter(\.isBlocking)
            .compactMap { index.issue(with: $0.issueID) }
    }

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
                return !issue.isGate
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
        options(availableTypes, including: currentType, fallback: index.semantics.typeNames)
    }

    func mutableTypeOptions(including currentType: String?) -> [String] {
        let currentType = currentType.flatMap {
            BeadIssueWorkflowPolicy.isReservedIssueType($0) ? nil : $0
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

    private func options(_ choices: [String], including currentValue: String?, fallback: [String]) -> [String] {
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

    var reopenStatusName: String? {
        if index.semantics.statuses.contains(where: { $0.name == "open" && $0.category == .active }) {
            return "open"
        }
        return index.semantics.statuses.first { $0.category == .active }?.name
    }

    private var gateApprovalStatusName: String? {
        reopenStatusName
    }

    private func isBuiltInBlockedIssue(_ issue: BeadIssue) -> Bool {
        index.semantics.statuses.contains { status in
            status.name == issue.status && status.isBuiltIn && status.name == "blocked"
        }
    }

    private func isEligibleForGateDecision(_ issue: BeadIssue, excludingGateID gateID: String) -> Bool {
        isBuiltInBlockedIssue(issue)
            && !isDone(issue)
            && !hasActiveBlocker(issueID: issue.id, excludingGateID: gateID)
    }

    private func hasActiveBlocker(issueID: String, excludingGateID gateID: String?) -> Bool {
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

    private func blockedDescendantPresentation(for issueID: String, now: Date) -> BlockedReasonPresentation? {
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

    private func activeBlockingPresentations(
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

    func openDefaultProjectIfAvailable() {
        guard projectURL == nil else { return }
        guard let url = recentProjects.first(where: { projectDirectoryExists(at: $0.url) })?.url else { return }
        openProject(url)
    }

    func openProject(_ url: URL) {
        let url = url.standardizedFileURL
        refreshTask?.cancel()
        filterTask?.cancel()
        recomputeTask?.cancel()
        stopDataSourceMonitor()
        projectURL = url
        resetProjectHealthStatus()
        loadProjectVisibility(for: url)
        isInitializingBeads = false
        if projectDirectoryExists(at: url) {
            rememberRecentProject(url)
        }
        clearLoadedProjectData()
        loadReadyParentRollUpPreference(for: url)
        selectedBookmark = .ready
        resetWorkspaceHistory()
        if isMissingDataSourceProject(url) {
            setMissingDataSource(url)
            if Self.beadsDirectoryExists(at: url) {
                refresh(reason: .initial, showsLoadingIndicator: true)
            }
            return
        }
        projectReadiness = .ready
        refresh(reason: .initial, showsLoadingIndicator: true)
    }

    func openRecentProject(_ project: RecentProject) {
        openProject(project.url)
    }

    func removeRecentProject(_ project: RecentProject) {
        recentProjects.removeAll { $0.id == project.id }
        persistRecentProjects()
    }

    private func rememberRecentProject(_ url: URL) {
        let project = RecentProject(url: url)
        var nextProjects = recentProjects.filter { $0.id != project.id }
        nextProjects.insert(project, at: 0)
        recentProjects = Array(nextProjects.prefix(Self.maxRecentProjectCount))
        persistRecentProjects()
    }

    private func persistRecentProjects() {
        userDefaults.set(recentProjects.map(\.path), forKey: Self.recentProjectPathsKey)

        if let lastProjectPath = recentProjects.first?.path {
            userDefaults.set(lastProjectPath, forKey: Self.lastProjectPathKey)
        } else {
            userDefaults.removeObject(forKey: Self.lastProjectPathKey)
        }
    }

    private static func loadRecentProjects(from userDefaults: UserDefaults) -> [RecentProject] {
        let paths = userDefaults.stringArray(forKey: recentProjectPathsKey) ?? []
        var seenIDs: Set<String> = []
        var projects: [RecentProject] = []

        for path in paths where !path.isEmpty {
            let project = RecentProject(url: URL(fileURLWithPath: path))
            guard seenIDs.insert(project.id).inserted else { continue }
            projects.append(project)
            if projects.count == maxRecentProjectCount {
                break
            }
        }

        return projects
    }

    private static func boolValue(_ userDefaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return defaultValue }
        return userDefaults.bool(forKey: key)
    }

    private static func normalizedStaleCutoffDays(_ days: Int) -> Int {
        min(max(days, 1), 3_650)
    }

    private func persistBDCLIPath() {
        let path = bdCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            userDefaults.removeObject(forKey: BeadazzlePreferenceKeys.bdCLIPath)
        } else {
            userDefaults.set(path, forKey: BeadazzlePreferenceKeys.bdCLIPath)
        }
    }

    private func persistStaleCutoffDays() {
        userDefaults.set(staleCutoffDays, forKey: BeadazzlePreferenceKeys.staleCutoffDays)
    }

    private func loadProjectVisibility(for url: URL) {
        hiddenTypeNames = Set(userDefaults.stringArray(forKey: BeadazzlePreferenceKeys.hiddenTypes(projectURL: url)) ?? [])
        hiddenStatusNames = Set(userDefaults.stringArray(forKey: BeadazzlePreferenceKeys.hiddenStatuses(projectURL: url)) ?? [])
    }

    private func loadReadyParentRollUpPreference(for url: URL) {
        hidesParentsWithOnlyBlockedChildrenInReady = Self.boolValue(
            userDefaults,
            key: BeadazzlePreferenceKeys.hidesParentsWithOnlyBlockedChildrenInReady(projectURL: url),
            defaultValue: true
        )
    }

    private func persistProjectVisibility() {
        guard let projectURL else { return }
        userDefaults.set(hiddenTypeNames.sorted(), forKey: BeadazzlePreferenceKeys.hiddenTypes(projectURL: projectURL))
        userDefaults.set(hiddenStatusNames.sorted(), forKey: BeadazzlePreferenceKeys.hiddenStatuses(projectURL: projectURL))
    }

    private func persistReadyParentRollUpPreference() {
        guard let projectURL else { return }
        userDefaults.set(
            hidesParentsWithOnlyBlockedChildrenInReady,
            forKey: BeadazzlePreferenceKeys.hidesParentsWithOnlyBlockedChildrenInReady(projectURL: projectURL)
        )
    }

    func isTypeHidden(_ name: String) -> Bool {
        hiddenTypeNames.contains(name)
    }

    func isStatusHidden(_ name: String) -> Bool {
        hiddenStatusNames.contains(name)
    }

    func setType(_ name: String, isHidden: Bool) {
        if isHidden {
            hiddenTypeNames.insert(name)
        } else {
            hiddenTypeNames.remove(name)
        }
        projectVisibilityDidChange()
    }

    func setStatus(_ name: String, isHidden: Bool) {
        if isHidden {
            hiddenStatusNames.insert(name)
        } else {
            hiddenStatusNames.remove(name)
        }
        projectVisibilityDidChange()
    }

    private func projectVisibilityDidChange() {
        persistProjectVisibility()
        applyFilters()
    }

    private func projectDirectoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private nonisolated static func beadsDirectoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let beadsURL = url.appendingPathComponent(".beads", isDirectory: true)
        return FileManager.default.fileExists(atPath: beadsURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func initializeBeads(options: BeadsInitOptions) {
        guard let projectURL, !isInitializingBeads else { return }
        isInitializingBeads = true
        lastError = nil
        let projectLoader = projectLoader
        let staleCutoffDays = staleCutoffDays
        let hidesParentsWithOnlyBlockedChildrenInReady = hidesParentsWithOnlyBlockedChildrenInReady

        Task { @MainActor [weak self] in
            do {
                let loadedProject = try await projectLoader.initializeAndLoadProject(
                    projectURL: projectURL,
                    options: options,
                    staleCutoffDays: staleCutoffDays,
                    hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
                )
                guard let self, self.projectURL == projectURL else { return }
                self.isInitializingBeads = false
                self.rememberRecentProject(projectURL)
                self.applyLoadedProject(loadedProject, projectURL: projectURL)
            } catch {
                guard let self, self.projectURL == projectURL else { return }
                self.isInitializingBeads = false
                self.projectReadiness = .missingDataSource(projectURL)
                self.lastError = error.localizedDescription
            }
        }
    }

    private func isMissingDataSourceProject(_ url: URL) -> Bool {
        do {
            _ = try BeadsDataSourceDiscovery().discover(projectURL: url)
            return false
        } catch BeadError.projectMissingDataSource {
            return true
        } catch {
            return false
        }
    }

    private func setMissingDataSource(_ url: URL) {
        projectReadiness = .missingDataSource(url)
        isLoading = false
        lastError = nil
        stopDataSourceMonitor()
        clearLoadedProjectData()
        resetWorkspaceHistory()
    }

    private func clearLoadedProjectData() {
        index = .empty
        issues = []
        filteredIssueIDs = []
        issueListRows = []
        dependencies = []
        dependencyIssueID = nil
        comments = []
        commentsIssueID = nil
        commentCache = [:]
        commentRefreshIssueID = nil
        selectionSideDataTask?.cancel()
        selectionSideDataTask = nil
        gateDetailTask?.cancel()
        gateDetailTask = nil
        gatesByID = [:]
        currentDataSource = nil
        snapshotFreshness = .unknown
        cachedDefinitions = nil
        selectedIDs.removeAll()
        fullPageDetailIssueID = nil
        creationDraft = nil
        outlineState.clear()
        filterCounts = .empty
        isLoadingComments = false
        isAddingComment = false
        syncWorkspaceHistoryAvailability()
    }

    func select(_ ids: Set<String>) {
        let nextFullPageDetailIssueID = fullPageDetailIssueID.flatMap { ids == [$0] ? $0 : nil }
        guard selectedIDs != ids || fullPageDetailIssueID != nextFullPageDetailIssueID else { return }
        if !ids.isEmpty, creationDraft != nil {
            suppressesHistoryRecording = true
            creationDraft = nil
            suppressesHistoryRecording = false
        }
        selectedIDs = ids
        fullPageDetailIssueID = nextFullPageDetailIssueID
        selectionDidChange()
    }

    func clearSelection() {
        select([])
    }

    func openIssueFromDetail(issueID: String) {
        guard index.issue(with: issueID) != nil else { return }
        if fullPageDetailIssueID != nil {
            openFullPageDetail(issueID: issueID)
        } else {
            select([issueID])
        }
    }

    func openFullPageDetail(issueID: String) {
        guard index.issue(with: issueID) != nil else { return }
        let targetSelection: Set<String> = [issueID]
        guard selectedIDs != targetSelection || fullPageDetailIssueID != issueID else { return }

        let wasSuppressingHistory = suppressesHistoryRecording
        suppressesHistoryRecording = true
        if creationDraft != nil {
            creationDraft = nil
        }
        selectedIDs = targetSelection
        fullPageDetailIssueID = issueID
        selectionDidChange()
        suppressesHistoryRecording = wasSuppressingHistory
        recordWorkspaceSnapshotIfNeeded()
    }

    func refresh() {
        refresh(reason: .manual, showsLoadingIndicator: true)
    }

    func loadProjectHealthStatus() {
        guard let projectURL else {
            resetProjectHealthStatus()
            return
        }

        projectHealthTask?.cancel()
        isLoadingProjectHealth = true
        projectHealthActionError = nil

        let commands = commands
        let activeDataSource = currentDataSource
        projectHealthTask = Task { @MainActor [weak self] in
            let snapshot = await ProjectHealthSnapshot.load(
                projectURL: projectURL,
                activeDataSource: activeDataSource,
                commands: commands
            )
            guard !Task.isCancelled, let self, self.projectURL == projectURL else { return }
            self.projectHealthSnapshot = snapshot
            self.isLoadingProjectHealth = false
        }
    }

    @discardableResult
    func exportProjectSnapshotNow() async -> Bool {
        guard let projectURL = beginProjectHealthAction(.exportingSnapshot) else { return false }
        defer { finishProjectHealthAction(for: projectURL) }

        do {
            try await commands.exportReadableSnapshot(projectURL: projectURL)
            guard self.projectURL == projectURL else { return false }
            refresh(reason: .dataSourceChanged, showsLoadingIndicator: true)
            return true
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            return false
        }
    }

    @discardableResult
    func installProjectHooks() async -> Bool {
        guard projectHealthSnapshot?.hooks.value?.hasMissingHooks == true else { return false }
        guard let projectURL = beginProjectHealthAction(.installingHooks) else { return false }
        defer { finishProjectHealthAction(for: projectURL) }

        do {
            try await commands.installHooks(projectURL: projectURL)
            return self.projectURL == projectURL
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            return false
        }
    }

    @discardableResult
    func syncProjectBackup() async -> Bool {
        guard projectHealthSnapshot?.backup.value?.isConfigured == true else { return false }
        guard let projectURL = beginProjectHealthAction(.syncingBackup) else { return false }
        defer { finishProjectHealthAction(for: projectURL) }

        do {
            try await commands.syncBackup(projectURL: projectURL)
            return self.projectURL == projectURL
        } catch {
            setProjectHealthActionError(error, projectURL: projectURL)
            return false
        }
    }

    private func refreshAfterDataSourceChange() {
        refresh(reason: .dataSourceChanged, showsLoadingIndicator: false)
    }

    private func resetProjectHealthStatus() {
        projectHealthTask?.cancel()
        projectHealthTask = nil
        projectHealthSnapshot = nil
        isLoadingProjectHealth = false
        projectHealthAction = nil
        projectHealthActionError = nil
    }

    private func beginProjectHealthAction(_ action: ProjectHealthAction) -> URL? {
        guard let projectURL, projectHealthAction == nil else { return nil }
        projectHealthAction = action
        projectHealthActionError = nil
        return projectURL
    }

    private func finishProjectHealthAction(for actionProjectURL: URL) {
        guard projectURL == actionProjectURL else { return }
        projectHealthAction = nil
        loadProjectHealthStatus()
    }

    private func setProjectHealthActionError(_ error: Error, projectURL actionProjectURL: URL) {
        guard projectURL == actionProjectURL else { return }
        projectHealthActionError = error.localizedDescription
    }

    private func refresh(reason: RefreshReason, showsLoadingIndicator: Bool) {
        guard let projectURL else { return }
        refreshTask?.cancel()
        // A manual refresh or project (re)load reads authoritative state directly, so any
        // queued coalesced reconcile would just be a redundant reload — drop it.
        if reason == .manual || reason == .initial {
            reconcileDebounceTask?.cancel()
            reconcileDebounceTask = nil
            pendingReconcile = false
        }
        if showsLoadingIndicator {
            isLoading = true
        }
        if reason != .dataSourceChanged {
            lastError = nil
        }
        let projectLoader = projectLoader
        let staleCutoffDays = staleCutoffDays
        let hidesParentsWithOnlyBlockedChildrenInReady = hidesParentsWithOnlyBlockedChildrenInReady

        // Mutations and explicit user refreshes must re-export the readable JSONL
        // snapshot first: Dolt-backed (embedded) projects only back it up on a
        // periodic timer, so `bd` writes would otherwise not appear for minutes.
        let forcesSnapshotExport = reason == .mutation || reason == .manual

        // Status/type definitions rarely change, and reading them costs two `bd`
        // subprocesses. Reuse the cache except when the user explicitly refreshes, on the
        // first load, or after the app edited definitions (which clears the cache) —
        // otherwise every routine reload would re-run `bd`.
        let reloadsDefinitions = reason == .initial || reason == .manual || cachedDefinitions == nil
        let definitionsForLoad = reloadsDefinitions ? nil : cachedDefinitions
        if let currentDataSource {
            snapshotFreshness = snapshotFreshness.refreshing(projectURL: projectURL, source: currentDataSource)
        }

        refreshTask = Task { @MainActor [weak self] in
            do {
                let snapshotTask = Task {
                    if forcesSnapshotExport {
                        return try await projectLoader.refreshSnapshotAndLoadProject(
                            projectURL: projectURL,
                            staleCutoffDays: staleCutoffDays,
                            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
                            cachedDefinitions: definitionsForLoad
                        )
                    }
                    return try await projectLoader.loadProject(
                        projectURL: projectURL,
                        staleCutoffDays: staleCutoffDays,
                        hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
                        cachedDefinitions: definitionsForLoad
                    )
                }
                let loadedProject = try await withTaskCancellationHandler {
                    try await snapshotTask.value
                } onCancel: {
                    snapshotTask.cancel()
                }
                guard !Task.isCancelled, self?.projectURL == projectURL else { return }
                if reason == .dataSourceChanged, self?.currentDataSource == loadedProject.source {
                    if showsLoadingIndicator {
                        self?.isLoading = false
                    }
                    self?.markSnapshotFreshnessLoaded(projectURL: projectURL, source: loadedProject.source)
                    self?.finishCommentRefreshIfNeeded(projectURL: projectURL)
                    return
                }
                self?.applyLoadedProject(loadedProject, projectURL: projectURL)
            } catch is CancellationError {
                self?.finishCommentRefreshIfNeeded(projectURL: projectURL)
                return
            } catch BeadError.projectMissingDataSource(let missingURL) {
                guard let self, !Task.isCancelled, self.projectURL == projectURL else { return }
                guard Self.beadsDirectoryExists(at: projectURL) else {
                    self.setMissingDataSource(missingURL)
                    return
                }
                let recoveryTask = Task {
                    try await projectLoader.exportAndLoadProject(
                        projectURL: projectURL,
                        staleCutoffDays: self.staleCutoffDays,
                        hidesParentsWithOnlyBlockedChildrenInReady: self.hidesParentsWithOnlyBlockedChildrenInReady,
                        cachedDefinitions: definitionsForLoad
                    )
                }
                do {
                    let recoveredProject = try await withTaskCancellationHandler(operation: {
                        try await recoveryTask.value
                    }, onCancel: {
                        recoveryTask.cancel()
                    })
                    guard !Task.isCancelled, self.projectURL == projectURL else { return }
                    self.applyLoadedProject(recoveredProject, projectURL: projectURL)
                } catch is CancellationError {
                    self.finishCommentRefreshIfNeeded(projectURL: projectURL)
                    return
                } catch {
                    guard !Task.isCancelled, self.projectURL == projectURL else { return }
                    self.setMissingDataSource(missingURL)
                    self.lastError = error.localizedDescription
                    self.markSnapshotFreshnessFailed(error.localizedDescription)
                    self.finishCommentRefreshIfNeeded(projectURL: projectURL)
                }
            } catch {
                guard !Task.isCancelled, self?.projectURL == projectURL else { return }
                self?.lastError = error.localizedDescription
                self?.isLoading = false
                self?.markSnapshotFreshnessFailed(error.localizedDescription)
                self?.finishCommentRefreshIfNeeded(projectURL: projectURL)
            }
        }
    }

    func loadDependenciesForSelection() {
        guard let issue = selectedIssue else {
            if dependencyIssueID != nil {
                dependencyIssueID = nil
            }
            if !dependencies.isEmpty {
                dependencies = []
            }
            return
        }
        let nextDependencies = index.dependenciesTouching(issueID: issue.id)
        if dependencyIssueID != issue.id {
            dependencyIssueID = issue.id
        }
        if dependencies != nextDependencies {
            dependencies = nextDependencies
        }
    }

    func dependencies(for issueID: String) -> [BeadDependency] {
        if dependencyIssueID == issueID {
            return dependencies
        }
        return index.dependenciesTouching(issueID: issueID)
    }

    func syncCommentsForSelectionFromCache() {
        guard let issue = selectedIssue else {
            if commentsIssueID != nil {
                commentsIssueID = nil
            }
            if !comments.isEmpty {
                comments = []
            }
            isLoadingComments = false
            commentRefreshIssueID = nil
            return
        }

        let nextComments = commentCache[issue.id] ?? []
        if commentsIssueID != issue.id {
            commentsIssueID = issue.id
        }
        if comments != nextComments {
            comments = nextComments
        }
        if commentRefreshIssueID != issue.id {
            commentRefreshIssueID = nil
            isLoadingComments = false
        }
    }

    func comments(for issueID: String) -> [BeadComment] {
        if commentsIssueID == issueID {
            return comments
        }
        return commentCache[issueID] ?? []
    }

    private func clearSelectionSideData() {
        selectionSideDataTask?.cancel()
        selectionSideDataTask = nil
        if dependencyIssueID != nil {
            dependencyIssueID = nil
        }
        if !dependencies.isEmpty {
            dependencies = []
        }
        if commentsIssueID != nil {
            commentsIssueID = nil
        }
        if !comments.isEmpty {
            comments = []
        }
        commentRefreshIssueID = nil
        isLoadingComments = false
    }

    func isLoadingComments(for issueID: String) -> Bool {
        isLoadingComments && commentRefreshIssueID == issueID
    }

    private func finishCommentRefreshIfNeeded(projectURL expectedProjectURL: URL) {
        guard commentRefreshIssueID != nil, projectURL == expectedProjectURL else { return }
        commentRefreshIssueID = nil
        isLoadingComments = false
        syncCommentsForSelectionFromCache()
    }

    func loadCommentsForSelection(force: Bool = false) {
        syncCommentsForSelectionFromCache()
        if force {
            guard let issue = selectedIssue else { return }
            commentRefreshIssueID = issue.id
            isLoadingComments = true
            refresh()
        }
    }

    func issue(with id: String) -> BeadIssue? {
        index.issue(with: id)
    }

    func toggleIssueExpansion(issueID: String, isExpanded: Bool) {
        setIssueExpansion(issueID: issueID, isExpanded: !isExpanded)
    }

    @discardableResult
    func expandSelectedIssueChildren() -> Bool {
        setSelectedIssueChildrenExpanded(true)
    }

    @discardableResult
    func collapseSelectedIssueChildren() -> Bool {
        setSelectedIssueChildrenExpanded(false)
    }

    @discardableResult
    func navigateIssueOutlineRight() -> Bool {
        guard let selectedRow = selectedOutlineRow,
              selectedRow.hasChildren else {
            return false
        }

        if !selectedRow.isExpanded {
            setIssueExpansion(issueID: selectedRow.issueID, isExpanded: true)
            return true
        }

        guard let firstChildID = firstVisibleChildID(of: selectedRow) else {
            return false
        }
        select([firstChildID])
        return true
    }

    @discardableResult
    func navigateIssueOutlineLeft() -> Bool {
        guard let selectedRow = selectedOutlineRow else {
            return false
        }

        if selectedRow.hasChildren, selectedRow.isExpanded {
            setIssueExpansion(issueID: selectedRow.issueID, isExpanded: false)
            return true
        }

        guard let parentID = visibleParentID(of: selectedRow) else {
            return false
        }
        select([parentID])
        return true
    }

    func expandAncestorsForSelection() {
        expandAncestorsForSelection(rebuildRows: true)
    }

    func revealIssue(id: String) {
        guard index.issue(with: id) != nil else { return }
        selectedIDs = [id]
        fullPageDetailIssueID = nil
        expandAncestors(of: id, rebuildRows: false)

        if !index.issueIDs(for: selectedBookmark).contains(id) {
            selectedBookmark = .all
        }

        // Compute membership directly rather than reading `filteredIssueIDs`, which is
        // now updated asynchronously and may be stale at this point.
        let matchesCurrentFilters = BeadIssueListQuery.filteredIssueIDs(
            index: index,
            bookmark: selectedBookmark,
            statusFilters: statusFilters,
            typeFilters: typeFilters,
            priorityFilters: priorityFilters,
            labelFilters: labelFilters,
            searchText: searchText
        ).contains(id)

        if !matchesCurrentFilters {
            clearFilters()
            searchText = ""
            applyFilters()
        } else {
            rebuildIssueListRows()
        }
        loadDependenciesForSelection()
        syncCommentsForSelectionFromCache()
        recordWorkspaceSnapshotIfNeeded()
    }

    func applyBookmark(_ bookmark: BeadBookmark) {
        guard selectedBookmark != bookmark else { return }
        selectedBookmark = bookmark
        if bookmark == .gates {
            gateClock = Date()
        }
        // Choosing a bookmark returns you to the list: drop any detail selection so the
        // detail pane collapses back to the bead list instead of stranding you on a page.
        // Recompute exactly once afterward — a stray `applyFilters()` before this would be
        // canceled by the selection change's generation guard, dropping the filter-counts pass.
        if !selectedIDs.isEmpty {
            selectedIDs = []
            fullPageDetailIssueID = nil
            scheduleSelectionSideDataRefresh()
        }
        applyFilters()
        recordWorkspaceSnapshotIfNeeded()
    }

    // MARK: Optimistic mutations

    /// Built-in status `bd close` moves an issue to; used for optimistic close patches.
    private static let closedStatusName = "closed"
    private static let deferredStatusName = "deferred"

    /// The in-memory issues/dependencies captured before an optimistic mutation, so a
    /// failed `bd` write can be rolled back to the last authoritative state.
    private struct MutationSnapshot {
        let issues: [BeadIssue]
        let dependencies: [BeadDependency]
    }

    private func currentMutationSnapshot() -> MutationSnapshot {
        MutationSnapshot(issues: index.issues, dependencies: index.dependencies)
    }

    /// Rebuilds the in-memory index from patched issues/dependencies and refreshes derived
    /// state immediately — no disk access, no loading indicator. This is what makes edits
    /// feel instant: the UI reflects the change before `bd` has even run. Correctness is
    /// preserved by writing through `bd` afterward and reconciling silently.
    private func applyOptimisticState(issues: [BeadIssue], dependencies: [BeadDependency]) {
        index = BeadProjectIndex(
            issues: issues,
            dependencies: dependencies,
            semantics: index.semantics,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
        )
        self.issues = issues
        contentRevision &+= 1
        selectedIDs = selectedIDs.filter { index.issue(with: $0) != nil }
        syncFullPageDetailWithSelection()
        pruneExpandedIssueIDs()
        expandAncestorsForSelection(rebuildRows: false)
        applyFilters()
        loadDependenciesForSelection()
        syncCommentsForSelectionFromCache()
        pruneGateDetailsForCurrentSnapshot()
    }

    private func rollbackOptimisticState(to snapshot: MutationSnapshot) {
        applyOptimisticState(issues: snapshot.issues, dependencies: snapshot.dependencies)
    }

    /// Debounce window after the last mutation settles before a single reconcile runs.
    private static let reconcileDebounce: Duration = .milliseconds(600)

    /// Marks the start of an optimistic mutation. Increments the in-flight count and
    /// supersedes any queued or running reconcile: a fresh edit must not be clobbered by
    /// a reload of pre-edit state (that was the rapid-edit flicker). The mutation's own
    /// completion reschedules a reconcile.
    private func beginMutation() {
        activeMutationCount += 1
        reconcileDebounceTask?.cancel()
        reconcileDebounceTask = nil
        if isReconcileInFlight {
            refreshTask?.cancel()
            isReconcileInFlight = false
        }
    }

    private func endMutation() {
        activeMutationCount = max(0, activeMutationCount - 1)
        scheduleReconcileIfIdle()
    }

    /// Serializes the `bd` writes behind optimistic mutations. The optimistic patch still
    /// happens immediately, but the subprocesses commit in the same order the user made
    /// changes so a slow earlier write cannot overwrite a newer live metadata edit.
    private func enqueueMutationWrite(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previousWrite = mutationWriteChain
        mutationWriteGeneration += 1
        let generation = mutationWriteGeneration
        let resultTask = Task { () -> Result<Void, any Error> in
            await previousWrite?.value
            do {
                try await operation()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        mutationWriteChain = Task {
            _ = await resultTask.value
        }

        defer {
            if mutationWriteGeneration == generation {
                mutationWriteChain = nil
            }
        }

        switch await resultTask.value {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    /// Requests a coalesced reconcile without participating in the in-flight count —
    /// used by non-optimistic mutations that have already awaited their `bd` write.
    private func requestReconcile() {
        pendingReconcile = true
        scheduleReconcileIfIdle()
    }

    /// Coalesces reconciles: one silent reload fires ~`reconcileDebounce` after the last
    /// mutation settles, instead of an export + reparse per mutation. Optimistic patches
    /// already show the change; the reconcile only lets `bd`-computed fields (timestamps,
    /// auto-cascades, ready state) converge. Skipped while any mutation is still in flight
    /// — the last one to finish schedules it.
    private func scheduleReconcileIfIdle() {
        guard pendingReconcile, activeMutationCount == 0 else { return }
        reconcileDebounceTask?.cancel()
        reconcileDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.reconcileDebounce)
            guard let self, !Task.isCancelled else { return }
            guard self.activeMutationCount == 0, self.pendingReconcile else { return }
            self.pendingReconcile = false
            self.isReconcileInFlight = true
            self.refresh(reason: .mutation, showsLoadingIndicator: false)
        }
    }

    private func optimisticallyUpdatedIssue(_ issue: BeadIssue, from draft: IssueDraft) -> BeadIssue {
        var copy = issue
        copy.title = draft.title
        copy.description = draft.description
        copy.design = draft.design
        copy.acceptanceCriteria = draft.acceptanceCriteria
        copy.notes = draft.notes
        copy.status = draft.status
        copy.priority = draft.priority
        copy.issueType = draft.issueType
        copy.assignee = draft.assignee.nilIfBlank
        copy.labels = draft.labels
        copy.dueAt = draft.dueAt
        copy.deferUntil = draft.deferUntil
        copy.updatedAt = Date()
        if statusClosesBeads(draft.status) {
            copy.closedAt = copy.closedAt ?? Date()
        } else {
            copy.closedAt = nil
        }
        return copy
    }

    @discardableResult
    func save(_ draft: IssueDraft) async -> Bool {
        await save(draft, closingChildIssueIDs: [], reopeningAncestorIssueIDs: [])
    }

    @discardableResult
    func save(_ draft: IssueDraft, closingChildIssueIDs childIssueIDs: [String]) async -> Bool {
        await save(draft, closingChildIssueIDs: childIssueIDs, reopeningAncestorIssueIDs: [])
    }

    @discardableResult
    func save(_ draft: IssueDraft, reopeningAncestorIssueIDs ancestorIssueIDs: [String]) async -> Bool {
        await save(draft, closingChildIssueIDs: [], reopeningAncestorIssueIDs: ancestorIssueIDs)
    }

    @discardableResult
    func save(
        _ draft: IssueDraft,
        closingChildIssueIDs childIssueIDs: [String],
        reopeningAncestorIssueIDs ancestorIssueIDs: [String]
    ) async -> Bool {
        guard let projectURL else { return false }

        // Create can't be optimistic — the id is minted by `bd`. Await the write, then
        // reconcile silently and reveal the new bead (no full-screen loading indicator).
        guard let draftID = draft.id, let originalIssue = index.issue(with: draftID) else {
            guard BeadIssueWorkflowPolicy.isNormalMutableIssueType(draft.issueType) else {
                lastError = BeadIssueWorkflowPolicy.reservedIssueTypeError
                return false
            }

            return await createBead(draft, revealCreated: true) != nil
        }

        guard BeadIssueWorkflowPolicy.canChangeIssueTypeThroughNormalMutation(
            originalIssue,
            to: draft.issueType
        ) else {
            lastError = BeadIssueWorkflowPolicy.reservedIssueTypeError
            return false
        }

        let childIDs = Array(Set(childIssueIDs).subtracting([draftID])).sorted()
        let ancestorIDs = Array(Set(ancestorIssueIDs).subtracting([draftID]).subtracting(childIDs)).sorted()
        let makesDone = statusClosesBeads(draft.status)
        let originalIsDone = isDone(originalIssue)
        if makesDone && !originalIsDone {
            guard guardHierarchyAllowsCompletion(
                issueIDs: [draftID],
                includedIssueIDs: [draftID] + childIDs
            ) else { return false }
        } else if !makesDone && originalIsDone {
            guard guardHierarchyAllowsUncompletion(
                issueIDs: [draftID],
                includedIssueIDs: [draftID] + ancestorIDs
            ) else { return false }
        }
        let ancestorReopenStatus: String?
        if ancestorIDs.isEmpty {
            ancestorReopenStatus = nil
        } else if let status = reopenStatusName {
            ancestorReopenStatus = status
        } else {
            lastError = "No active status is configured for reopened beads."
            return false
        }
        let childIDSet = Set(childIDs)
        let ancestorIDSet = Set(ancestorIDs)
        let snapshot = currentMutationSnapshot()
        let now = Date()
        let optimisticIssues = snapshot.issues.map { issue -> BeadIssue in
            if issue.id == draftID {
                return optimisticallyUpdatedIssue(issue, from: draft)
            }
            if ancestorIDSet.contains(issue.id), let ancestorReopenStatus {
                var copy = issue
                copy.status = ancestorReopenStatus
                copy.closedAt = nil
                copy.updatedAt = now
                return copy
            }
            guard childIDSet.contains(issue.id) else { return issue }
            var copy = issue
            copy.status = draft.status
            copy.closedAt = copy.closedAt ?? now
            copy.updatedAt = now
            return copy
        }
        beginMutation()
        defer { endMutation() }
        applyOptimisticState(issues: optimisticIssues, dependencies: snapshot.dependencies)

        let ancestorIDsForWrite = hierarchyReopenWriteOrder(ancestorIDs)
        let childIDsForWrite = hierarchyCompletionWriteOrder(childIDs)
        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                if !ancestorIDsForWrite.isEmpty, let ancestorReopenStatus {
                    try await commands.bulkUpdate(
                        projectURL: projectURL,
                        ids: ancestorIDsForWrite,
                        status: ancestorReopenStatus,
                        type: nil,
                        priority: nil
                    )
                }
                if !childIDsForWrite.isEmpty {
                    try await commands.bulkUpdate(
                        projectURL: projectURL,
                        ids: childIDsForWrite,
                        status: draft.status,
                        type: nil,
                        priority: nil
                    )
                }
                try await commands.update(projectURL: projectURL, draft: draft, originalIssue: originalIssue)
            }
            guard self.projectURL == projectURL else { return false }
            pendingReconcile = true
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            if attemptedWrite {
                pendingReconcile = true
            }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func createBead(_ draft: IssueDraft, revealCreated: Bool) async -> String? {
        guard let projectURL else { return nil }
        guard draft.id == nil else { return nil }
        guard BeadIssueWorkflowPolicy.isNormalMutableIssueType(draft.issueType) else {
            lastError = BeadIssueWorkflowPolicy.reservedIssueTypeError
            return nil
        }

        do {
            let createdIssueID = try await commands.create(projectURL: projectURL, draft: draft)
            guard self.projectURL == projectURL else { return nil }
            _ = try await reloadProjectAfterMutation(
                projectURL: projectURL,
                revealIssueID: createdIssueID,
                revealCreated: revealCreated
            )
            return createdIssueID
        } catch {
            guard self.projectURL == projectURL else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    private func reloadProjectAfterMutation(projectURL: URL, revealIssueID: String) async throws -> Bool {
        try await reloadProjectAfterMutation(projectURL: projectURL, revealIssueID: revealIssueID, revealCreated: true)
    }

    private func reloadProjectAfterMutation(projectURL: URL, revealIssueID: String, revealCreated: Bool) async throws -> Bool {
        refreshTask?.cancel()
        lastError = nil

        let loadedProject = try await loadProjectRecoveringMissingDataSource(projectURL: projectURL)
        guard self.projectURL == projectURL else { return false }

        applyLoadedProject(loadedProject, projectURL: projectURL)
        guard index.issue(with: revealIssueID) != nil else {
            throw BeadError.commandFailed(
                command: "bd create --silent",
                output: "Created bead \(revealIssueID) was not found after refresh."
            )
        }
        if revealCreated {
            revealIssue(id: revealIssueID)
        }
        return true
    }

    private func loadProjectRecoveringMissingDataSource(projectURL: URL) async throws -> LoadedProject {
        do {
            return try await projectLoader.refreshSnapshotAndLoadProject(
                projectURL: projectURL,
                staleCutoffDays: staleCutoffDays,
                hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
            )
        } catch BeadError.projectMissingDataSource(let missingURL) {
            guard Self.beadsDirectoryExists(at: projectURL) else {
                throw BeadError.projectMissingDataSource(missingURL)
            }
            return try await projectLoader.exportAndLoadProject(
                projectURL: projectURL,
                staleCutoffDays: staleCutoffDays,
                hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
            )
        }
    }

    func closeSelected() {
        let ids = Array(selectedIDs)
        Task { @MainActor in
            await close(issueIDs: ids, reason: "Closed in Beadazzle")
        }
    }

    @discardableResult
    func close(issueIDs: [String], reason: String?) async -> Bool {
        guard let projectURL else { return false }
        let ids = issueIDs.sorted()
        guard !ids.isEmpty else { return false }
        guard guardHierarchyAllowsCompletion(issueIDs: ids, includedIssueIDs: ids) else { return false }

        let snapshot = currentMutationSnapshot()
        let idSet = Set(ids)
        let now = Date()
        let optimisticIssues = snapshot.issues.map { issue -> BeadIssue in
            guard idSet.contains(issue.id) else { return issue }
            var copy = issue
            copy.status = Self.closedStatusName
            copy.closedAt = copy.closedAt ?? now
            copy.updatedAt = now
            return copy
        }
        beginMutation()
        defer { endMutation() }
        applyOptimisticState(issues: optimisticIssues, dependencies: snapshot.dependencies)

        let idsForWrite = hierarchyCompletionWriteOrder(ids)
        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                try await commands.close(projectURL: projectURL, ids: idsForWrite, reason: reason)
            }
            guard self.projectURL == projectURL else { return false }
            pendingReconcile = true
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            if attemptedWrite {
                pendingReconcile = true
            }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func reopen(issueIDs: [String], reopeningAncestorIssueIDs ancestorIssueIDs: [String] = []) async -> Bool {
        guard let status = reopenStatusName else {
            lastError = "No active status is configured for reopened beads."
            return false
        }
        let ids = issueIDs
            .compactMap { index.issue(with: $0) }
            .filter(isDone)
            .map(\.id)
            .sorted()
        guard !ids.isEmpty else { return false }
        return await bulkSet(issueIDs: ids, status: status, reopeningAncestorIssueIDs: ancestorIssueIDs)
    }

    @discardableResult
    func reopenBlockedIssue(issueID: String) async -> Bool {
        guard let status = reopenStatusName else {
            lastError = "No active status is configured for reopened beads."
            return false
        }
        return await bulkSet(issueIDs: [issueID], status: status)
    }

    @discardableResult
    func deleteSelected() async -> Bool {
        await delete(issueIDs: Array(selectedIDs))
    }

    @discardableResult
    func delete(issueIDs: [String]) async -> Bool {
        guard let projectURL else { return false }
        let ids = issueIDs.sorted()
        guard !ids.isEmpty else { return false }

        let snapshot = currentMutationSnapshot()
        let idSet = Set(ids)
        let optimisticIssues = snapshot.issues.filter { !idSet.contains($0.id) }
        let optimisticDependencies = snapshot.dependencies.filter {
            !idSet.contains($0.issueID) && !idSet.contains($0.dependsOnID)
        }
        beginMutation()
        defer { endMutation() }
        selectedIDs.subtract(idSet)
        syncFullPageDetailWithSelection()
        applyOptimisticState(issues: optimisticIssues, dependencies: optimisticDependencies)

        let commands = commands
        do {
            try await enqueueMutationWrite {
                try await commands.delete(projectURL: projectURL, ids: ids)
            }
            guard self.projectURL == projectURL else { return false }
            pendingReconcile = true
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func bulkSet(
        status: String? = nil,
        type: String? = nil,
        priority: Int? = nil,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) async -> Bool {
        await bulkSet(
            issueIDs: Array(selectedIDs),
            status: status,
            type: type,
            priority: priority,
            deferUntil: deferUntil
        )
    }

    @discardableResult
    func bulkSet(
        issueIDs: [String],
        status: String? = nil,
        type: String? = nil,
        priority: Int? = nil,
        deferUntil: IssueMetadataDateUpdate = .unchanged,
        reopeningAncestorIssueIDs ancestorIssueIDs: [String] = []
    ) async -> Bool {
        guard let projectURL else { return false }
        let ids = issueIDs.sorted()
        guard !ids.isEmpty else { return false }
        if let type {
            guard BeadIssueWorkflowPolicy.isNormalMutableIssueType(type),
                  ids.allSatisfy({ id in
                      guard let issue = index.issue(with: id) else { return false }
                      return !issue.isGate
                  }) else {
                lastError = BeadIssueWorkflowPolicy.reservedIssueTypeError
                return false
            }
        }

        let makesDone = status.map(statusClosesBeads) ?? false
        let ancestorIDs = Array(Set(ancestorIssueIDs).subtracting(ids)).sorted()
        let ancestorReopenStatus: String?
        if let status, statusClosesBeads(status) {
            guard guardHierarchyAllowsCompletion(issueIDs: ids, includedIssueIDs: ids) else { return false }
            ancestorReopenStatus = nil
        } else if status != nil {
            guard guardHierarchyAllowsUncompletion(
                issueIDs: ids,
                includedIssueIDs: ids + ancestorIDs
            ) else { return false }
            if ancestorIDs.isEmpty {
                ancestorReopenStatus = nil
            } else if let reopenStatusName {
                ancestorReopenStatus = reopenStatusName
            } else {
                lastError = "No active status is configured for reopened beads."
                return false
            }
        } else {
            ancestorReopenStatus = nil
        }

        let snapshot = currentMutationSnapshot()
        let idSet = Set(ids)
        let ancestorIDSet = Set(ancestorIDs)
        let now = Date()
        let optimisticIssues = snapshot.issues.map { issue -> BeadIssue in
            if ancestorIDSet.contains(issue.id), let ancestorReopenStatus {
                var copy = issue
                copy.status = ancestorReopenStatus
                copy.closedAt = nil
                copy.updatedAt = now
                return copy
            }
            guard idSet.contains(issue.id) else { return issue }
            var copy = issue
            if let status { copy.status = status }
            if let type { copy.issueType = type }
            if let priority { copy.priority = priority }
            switch deferUntil {
            case .unchanged:
                break
            case .set(let date):
                copy.deferUntil = date
            }
            if let status {
                copy.closedAt = statusClosesBeads(status) ? (copy.closedAt ?? now) : nil
            }
            copy.updatedAt = now
            return copy
        }
        beginMutation()
        defer { endMutation() }
        applyOptimisticState(issues: optimisticIssues, dependencies: snapshot.dependencies)

        let idsForWrite: [String]
        if makesDone {
            idsForWrite = hierarchyCompletionWriteOrder(ids)
        } else if status != nil {
            idsForWrite = hierarchyReopenWriteOrder(ids)
        } else {
            idsForWrite = ids
        }
        let ancestorIDsForWrite = hierarchyReopenWriteOrder(ancestorIDs)
        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                if !ancestorIDsForWrite.isEmpty, let ancestorReopenStatus {
                    try await commands.bulkUpdate(
                        projectURL: projectURL,
                        ids: ancestorIDsForWrite,
                        status: ancestorReopenStatus,
                        type: nil,
                        priority: nil,
                        deferUntil: .unchanged
                    )
                }
                try await commands.bulkUpdate(
                    projectURL: projectURL,
                    ids: idsForWrite,
                    status: status,
                    type: type,
                    priority: priority,
                    deferUntil: deferUntil
                )
            }
            guard self.projectURL == projectURL else { return false }
            pendingReconcile = true
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            if attemptedWrite {
                pendingReconcile = true
            }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateMetadata(
        issueID: String,
        labels: [String]? = nil,
        dueAt: IssueMetadataDateUpdate = .unchanged,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) async -> Bool {
        guard let projectURL, let originalIssue = index.issue(with: issueID) else { return false }

        var draft = IssueDraft(issue: originalIssue)
        if let labels {
            draft.labels = labels
        }
        switch dueAt {
        case .unchanged:
            break
        case .set(let date):
            draft.dueAt = date
        }
        switch deferUntil {
        case .unchanged:
            break
        case .set(let date):
            draft.deferUntil = date
        }

        guard draft != IssueDraft(issue: originalIssue) else { return true }

        let snapshot = currentMutationSnapshot()
        let optimisticIssues = snapshot.issues.map { issue -> BeadIssue in
            guard issue.id == issueID else { return issue }
            return optimisticallyUpdatedIssue(issue, from: draft)
        }
        beginMutation()
        defer { endMutation() }
        applyOptimisticState(issues: optimisticIssues, dependencies: snapshot.dependencies)

        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                try await commands.updateMetadata(
                    projectURL: projectURL,
                    issueID: issueID,
                    labels: labels,
                    originalLabels: originalIssue.labels,
                    dueAt: dueAt,
                    deferUntil: deferUntil
                )
            }
            guard self.projectURL == projectURL else { return false }
            pendingReconcile = true
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            if attemptedWrite {
                pendingReconcile = true
            }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func setParent(issueID: String, parentID: String?) async -> Bool {
        guard let projectURL, let originalIssue = index.issue(with: issueID) else { return false }
        let normalizedParentID = parentID?.nilIfBlank
        guard normalizedParentID != issueID else {
            lastError = "A bead cannot be its own parent."
            return false
        }
        if let normalizedParentID {
            guard index.issue(with: normalizedParentID) != nil else {
                lastError = "Bead \(normalizedParentID) was not found."
                return false
            }
            guard !index.descendantIDs(for: issueID).contains(normalizedParentID) else {
                lastError = "A bead cannot be moved under one of its child beads."
                return false
            }
            guard guardHierarchyAllowsParentChildDependency(
                issueID: issueID,
                dependsOnID: normalizedParentID,
                type: "parent-child"
            ) else { return false }
        }
        guard originalIssue.parentID != normalizedParentID else { return true }

        let snapshot = currentMutationSnapshot()
        let now = Date()
        let optimisticIssues = snapshot.issues.map { issue -> BeadIssue in
            guard issue.id == issueID else { return issue }
            var copy = issue
            copy.parentID = normalizedParentID
            copy.updatedAt = now
            return copy
        }
        var optimisticDependencies = snapshot.dependencies.filter {
            !($0.issueID == issueID && $0.type == "parent-child")
        }
        if let normalizedParentID {
            optimisticDependencies.append(
                BeadDependency(
                    issueID: issueID,
                    dependsOnID: normalizedParentID,
                    type: "parent-child",
                    createdAt: now
                )
            )
        }

        beginMutation()
        defer { endMutation() }
        applyOptimisticState(issues: optimisticIssues, dependencies: optimisticDependencies)

        let commands = commands
        var attemptedWrite = false
        do {
            attemptedWrite = true
            try await enqueueMutationWrite {
                try await commands.setParent(
                    projectURL: projectURL,
                    issueID: issueID,
                    parentID: normalizedParentID
                )
            }
            guard self.projectURL == projectURL else { return false }
            pendingReconcile = true
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            if attemptedWrite {
                pendingReconcile = true
            }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func applyBeadPickerSelection(_ selectedIssueID: String, action: BeadPickerAction) async -> Bool {
        switch action {
        case .setParent(let issueID):
            return await setParent(issueID: issueID, parentID: selectedIssueID)
        case .addBlockedBy(let issueID):
            return await addDependency(issueID: issueID, dependsOnID: selectedIssueID, type: "blocks")
        case .addBlocks(let issueID):
            return await addDependency(issueID: selectedIssueID, dependsOnID: issueID, type: "blocks")
        case .addChild(let parentID):
            return await setParent(issueID: selectedIssueID, parentID: parentID)
        }
    }

    @discardableResult
    func applyBeadPickerQuickCreate(_ createdIssueID: String, action: BeadPickerAction) async -> Bool {
        guard action.needsPostCreateRelationship else { return true }
        return await applyBeadPickerSelection(createdIssueID, action: action)
    }

    @discardableResult
    func approveGate(id: String, reason: String?) async -> Bool {
        let affectedIDs = gateDecisionAffectedBeads(for: id).map(\.id)
        guard !affectedIDs.isEmpty else {
            return await resolveGate(id: id, reason: reason)
        }
        guard let approvalStatus = gateApprovalStatusName else {
            let didResolve = await resolveGate(id: id, reason: reason)
            if didResolve {
                lastError = "Gate approved, but no active status is configured for unblocked beads."
            }
            return false
        }
        guard await resolveGate(id: id, reason: reason) else { return false }
        return await bulkSet(issueIDs: affectedIDs, status: approvalStatus)
    }

    @discardableResult
    func rejectGate(
        id: String,
        reason: String,
        targetStatus: String,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) async -> Bool {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else {
            lastError = "A rejection reason is required."
            return false
        }
        let status = targetStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty else {
            lastError = "Choose a status for rejected beads."
            return false
        }

        let affectedIDs = gateDecisionAffectedBeads(for: id).map(\.id)
        let rejectionReason = "Rejected: \(trimmedReason)"
        if statusClosesBeads(status) {
            guard guardHierarchyAllowsCompletion(issueIDs: affectedIDs, includedIssueIDs: affectedIDs) else { return false }
        }
        guard await resolveGate(id: id, reason: rejectionReason) else { return false }
        guard !affectedIDs.isEmpty else { return true }

        if status.lowercased() == Self.closedStatusName {
            return await close(issueIDs: affectedIDs, reason: rejectionReason)
        }
        let deferredStatusUpdate: IssueMetadataDateUpdate
        if isDeferredStatus(status) {
            switch deferUntil {
            case .unchanged:
                deferredStatusUpdate = .set(nil)
            case .set:
                deferredStatusUpdate = deferUntil
            }
        } else {
            deferredStatusUpdate = .unchanged
        }
        return await bulkSet(
            issueIDs: affectedIDs,
            status: status,
            deferUntil: deferredStatusUpdate
        )
    }

    @discardableResult
    func resolveGate(id: String, reason: String?) async -> Bool {
        guard let projectURL else { return false }
        do {
            try await commands.resolveGate(projectURL: projectURL, id: id, reason: reason?.nilIfBlank)
            guard self.projectURL == projectURL else { return false }
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    /// Evaluate open gates (auto-closing resolved timers/GitHub gates). Returns the `bd`
    /// summary output, or nil on failure.
    @discardableResult
    func checkGates(type: String? = nil, escalate: Bool = false, dryRun: Bool = false) async -> String? {
        guard let projectURL else { return nil }
        do {
            let output = try await commands.checkGates(projectURL: projectURL, type: type, escalate: escalate, dryRun: dryRun)
            guard self.projectURL == projectURL else { return nil }
            if !dryRun {
                requestReconcile()
            }
            return output
        } catch {
            guard self.projectURL == projectURL else { return nil }
            lastError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createGate(blocks: String, type: GateAwaitType, reason: String?, timeout: String?, awaitID: String?) async -> Bool {
        guard let projectURL else { return false }
        guard let issue = index.issue(with: blocks) else {
            lastError = "Bead \(blocks) was not found."
            return false
        }
        if let unavailableMessage = BeadIssueWorkflowPolicy.gateCreationUnavailableMessage(
            blocking: issue,
            isDone: isDone(issue)
        ) {
            lastError = unavailableMessage
            return false
        }
        do {
            _ = try await commands.createGate(
                projectURL: projectURL,
                blocks: blocks,
                type: type,
                reason: reason?.nilIfBlank,
                timeout: timeout?.nilIfBlank,
                awaitID: awaitID?.nilIfBlank
            )
            guard self.projectURL == projectURL else { return false }
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addGateWaiter(id: String, waiter: String) async -> Bool {
        guard let projectURL else { return false }
        let trimmed = waiter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try await commands.addGateWaiter(projectURL: projectURL, id: id, waiter: trimmed)
            guard self.projectURL == projectURL else { return false }
            gatesByID[id] = nil
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addDependency(issueID: String, dependsOnID: String, type: String) async -> Bool {
        guard let projectURL else { return false }
        guard guardHierarchyAllowsParentChildDependency(
            issueID: issueID,
            dependsOnID: dependsOnID,
            type: type
        ) else { return false }
        guard guardWorkflowAllowsBlockingDependency(
            issueID: issueID,
            dependsOnID: dependsOnID,
            type: type
        ) else { return false }

        let snapshot = currentMutationSnapshot()
        let newDependency = BeadDependency(issueID: issueID, dependsOnID: dependsOnID, type: type, createdAt: Date())
        beginMutation()
        defer { endMutation() }
        if !snapshot.dependencies.contains(where: { $0.id == newDependency.id }) {
            applyOptimisticState(issues: snapshot.issues, dependencies: snapshot.dependencies + [newDependency])
        }

        let commands = commands
        do {
            try await enqueueMutationWrite {
                try await commands.addDependency(projectURL: projectURL, issueID: issueID, dependsOnID: dependsOnID, type: type)
            }
            guard self.projectURL == projectURL else { return false }
            pendingReconcile = true
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            lastError = error.localizedDescription
            return false
        }
    }

    func addComment(issueID: String, text: String) {
        guard let projectURL else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        isAddingComment = true
        let commands = commands
        Task { @MainActor [weak self] in
            do {
                try await commands.addComment(projectURL: projectURL, issueID: issueID, text: trimmedText)
                guard let self else { return }
                guard self.projectURL == projectURL else {
                    self.isAddingComment = false
                    return
                }
                self.cacheOptimisticComment(issueID: issueID, text: trimmedText)
                if self.selectedIssue?.id == issueID {
                    self.isLoadingComments = false
                }
                self.isAddingComment = false
                self.requestReconcile()
            } catch {
                guard self?.projectURL == projectURL else { return }
                self?.isAddingComment = false
                self?.lastError = error.localizedDescription
            }
        }
    }

    @discardableResult
    func addCustomType(named rawName: String) async -> Bool {
        guard let projectURL else { return false }
        do {
            let name = try WorkflowValueValidator.normalizedIdentifier(rawName)
            guard BeadIssueWorkflowPolicy.isNormalMutableIssueType(name) else {
                lastError = BeadIssueWorkflowPolicy.reservedIssueTypeError
                return false
            }
            let allTypes = try await commands.loadTypeDefinitions(projectURL: projectURL)
            try ensureTypeNameIsAvailable(name, in: allTypes)
            var types = try await commands.loadCustomTypes(projectURL: projectURL)
            try ensureTypeNameIsAvailable(name, in: types)
            types.append(BeadTypeDefinition(name: name, description: nil, source: .custom))
            try await commands.saveCustomTypes(projectURL: projectURL, types: types.sorted { $0.name < $1.name })
            guard self.projectURL == projectURL else { return false }
            cachedDefinitions = nil // definitions changed — force the reconcile to re-read them
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteCustomType(named name: String) async -> Bool {
        guard let projectURL else { return false }
        do {
            let types = try await commands.loadCustomTypes(projectURL: projectURL)
            guard types.contains(where: { $0.name == name }) else { return false }
            let updatedTypes = types.filter { $0.name != name }
            try await commands.saveCustomTypes(projectURL: projectURL, types: updatedTypes.sorted { $0.name < $1.name })
            guard self.projectURL == projectURL else { return false }
            hiddenTypeNames.remove(name)
            persistProjectVisibility()
            cachedDefinitions = nil // definitions changed — force the reconcile to re-read them
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func addCustomStatus(named rawName: String, category: BeadStatusCategory) async -> Bool {
        guard let projectURL else { return false }
        do {
            let name = try WorkflowValueValidator.normalizedIdentifier(rawName)
            let allStatuses = try await commands.loadStatusDefinitions(projectURL: projectURL)
            try ensureStatusNameIsAvailable(name, in: allStatuses)
            var statuses = try await commands.loadCustomStatuses(projectURL: projectURL)
            try ensureStatusNameIsAvailable(name, in: statuses)
            statuses.append(
                BeadStatusDefinition(
                    name: name,
                    category: category,
                    icon: nil,
                    description: nil,
                    isBuiltIn: false,
                    source: .custom
                )
            )
            try await commands.saveCustomStatuses(projectURL: projectURL, statuses: statuses.sorted { $0.name < $1.name })
            guard self.projectURL == projectURL else { return false }
            cachedDefinitions = nil // definitions changed — force the reconcile to re-read them
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteCustomStatus(named name: String) async -> Bool {
        guard let projectURL else { return false }
        do {
            let statuses = try await commands.loadCustomStatuses(projectURL: projectURL)
            guard statuses.contains(where: { $0.name == name }) else { return false }
            let updatedStatuses = statuses.filter { $0.name != name }
            try await commands.saveCustomStatuses(projectURL: projectURL, statuses: updatedStatuses.sorted { $0.name < $1.name })
            guard self.projectURL == projectURL else { return false }
            hiddenStatusNames.remove(name)
            persistProjectVisibility()
            cachedDefinitions = nil // definitions changed — force the reconcile to re-read them
            requestReconcile()
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    private func ensureTypeNameIsAvailable(_ name: String, in types: [BeadTypeDefinition]) throws {
        guard types.allSatisfy({ $0.name != name }) else {
            throw BeadError.commandFailed(command: "bd config", output: "\(name) already exists.")
        }
    }

    private func ensureStatusNameIsAvailable(_ name: String, in statuses: [BeadStatusDefinition]) throws {
        guard statuses.allSatisfy({ $0.name != name }) else {
            throw BeadError.commandFailed(command: "bd config", output: "\(name) already exists.")
        }
    }

    @discardableResult
    func removeDependency(_ dependency: BeadDependency) async -> Bool {
        guard let projectURL else { return false }

        let snapshot = currentMutationSnapshot()
        let optimisticDependencies = snapshot.dependencies.filter {
            !($0.issueID == dependency.issueID && $0.dependsOnID == dependency.dependsOnID)
        }
        beginMutation()
        defer { endMutation() }
        applyOptimisticState(issues: snapshot.issues, dependencies: optimisticDependencies)

        do {
            try await commands.removeDependency(projectURL: projectURL, issueID: dependency.issueID, dependsOnID: dependency.dependsOnID)
            guard self.projectURL == projectURL else { return false }
            pendingReconcile = true
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            rollbackOptimisticState(to: snapshot)
            lastError = error.localizedDescription
            return false
        }
    }

    func setStatusFilter(_ status: String, isOn: Bool) {
        setFilter(&statusFilters, value: status, isOn: isOn)
    }

    func setTypeFilter(_ type: String, isOn: Bool) {
        setFilter(&typeFilters, value: type, isOn: isOn)
    }

    func setPriorityFilter(_ priority: Int, isOn: Bool) {
        setFilter(&priorityFilters, value: priority, isOn: isOn)
    }

    func setLabelFilter(_ label: String, isOn: Bool) {
        setFilter(&labelFilters, value: label, isOn: isOn)
    }

    func clearFilters() {
        guard hasActiveFilters else { return }
        suppressesFilterUpdates = true
        statusFilters = []
        typeFilters = []
        priorityFilters = []
        labelFilters = []
        suppressesFilterUpdates = false
        applyFilters()
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    private func setFilter<Value: Hashable>(_ filters: inout Set<Value>, value: Value, isOn: Bool) {
        var next = filters
        if isOn {
            next.insert(value)
        } else {
            next.remove(value)
        }
        guard next != filters else { return }
        filters = next
    }

    private func filterStateDidChange(debounce: Bool = false) {
        guard !suppressesFilterUpdates else { return }
        scheduleFilterUpdate(debounce: debounce)
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    private func sortStateDidChange() {
        guard !suppressesFilterUpdates else { return }
        applySortOnly()
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    private func selectionDidChange() {
        expandAncestorsForSelection()
        scheduleSelectionSideDataRefresh()
        recordWorkspaceSnapshotIfNeeded()
    }

    private func makeWorkspaceSnapshot() -> BeadWorkspaceSnapshot {
        BeadWorkspaceSnapshot(
            bookmark: selectedBookmark,
            selectedIDs: selectedIDs,
            fullPageDetailIssueID: fullPageDetailIssueID,
            searchText: searchText,
            statusFilters: statusFilters,
            typeFilters: typeFilters,
            priorityFilters: priorityFilters,
            labelFilters: labelFilters,
            sort: sort,
            sortDirection: sortDirection,
            issueListMode: issueListMode,
            outlineState: outlineState,
            creationDraft: creationDraft
        )
    }

    private func resetWorkspaceHistory() {
        workspaceHistory.reset(to: makeWorkspaceSnapshot())
        syncWorkspaceHistoryAvailability()
    }

    private func recordWorkspaceSnapshotIfNeeded() {
        guard !isRestoringWorkspace, !suppressesHistoryRecording, hasReadableProject else { return }
        workspaceHistory.record(makeWorkspaceSnapshot())
        syncWorkspaceHistoryAvailability()
    }

    private func syncCurrentWorkspaceSnapshotIfNeeded() {
        guard !isRestoringWorkspace, !suppressesHistoryRecording, hasReadableProject else { return }
        workspaceHistory.updateCurrent(makeWorkspaceSnapshot())
        syncWorkspaceHistoryAvailability()
    }

    private func restoreWorkspace(_ snapshot: BeadWorkspaceSnapshot) {
        guard hasReadableProject else { return }

        isRestoringWorkspace = true
        suppressesFilterUpdates = true
        selectedBookmark = snapshot.bookmark
        selectedIDs = snapshot.selectedIDs.intersection(index.allIssueIDs)
        fullPageDetailIssueID = snapshot.fullPageDetailIssueID
        creationDraft = snapshot.creationDraft
        searchText = snapshot.searchText
        statusFilters = snapshot.statusFilters
        typeFilters = snapshot.typeFilters
        priorityFilters = snapshot.priorityFilters
        labelFilters = snapshot.labelFilters
        sort = snapshot.sort
        sortDirection = snapshot.sortDirection
        issueListMode = snapshot.issueListMode
        outlineState = snapshot.outlineState
        suppressesFilterUpdates = false
        isRestoringWorkspace = false

        syncFullPageDetailWithSelection()
        expandAncestorsForSelection()
        applyFilters()
        scheduleSelectionSideDataRefresh()
        syncWorkspaceHistoryAvailability()
    }

    private func syncWorkspaceHistoryAvailability() {
        canGoBack = workspaceHistory.canGoBack
        canGoForward = workspaceHistory.canGoForward
    }

    private func syncFullPageDetailWithSelection() {
        guard let fullPageDetailIssueID else { return }
        if selectedIDs != [fullPageDetailIssueID] || index.issue(with: fullPageDetailIssueID) == nil {
            self.fullPageDetailIssueID = nil
        }
    }

    private func scheduleSelectionSideDataRefresh() {
        selectionSideDataTask?.cancel()
        let expectedSelectedIDs = selectedIDs

        selectionSideDataTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.selectedIDs == expectedSelectedIDs else { return }
            self.loadDependenciesForSelection()
            self.syncCommentsForSelectionFromCache()
            self.loadWaitersForSelectedGateIfNeeded()
        }
    }

    private func scheduleFilterUpdate(debounce: Bool = false) {
        filterTask?.cancel()
        filterTask = Task { @MainActor [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(140))
            }
            guard !Task.isCancelled else { return }
            self?.applyFilters()
        }
    }

    private func applyFilters() {
        scheduleQueryRecompute(recomputeCounts: true, pruneExpansion: true)
    }

    private func applySortOnly() {
        scheduleQueryRecompute(recomputeCounts: false, pruneExpansion: false)
    }

    private var selectedOutlineRow: IssueListRow? {
        guard issueListMode == .outline,
              selectedIDs.count == 1,
              let selectedID = selectedIDs.first else {
            return nil
        }
        return issueListRows.first { $0.issueID == selectedID }
    }

    private func setSelectedIssueChildrenExpanded(_ isExpanded: Bool) -> Bool {
        guard let selectedRow = selectedOutlineRow,
              selectedRow.hasChildren,
              selectedRow.isExpanded != isExpanded else {
            return false
        }

        setIssueExpansion(issueID: selectedRow.issueID, isExpanded: isExpanded)
        return true
    }

    private func setIssueExpansion(issueID: String, isExpanded: Bool) {
        outlineState.setExpansion(issueID: issueID, isExpanded: isExpanded)
        rebuildIssueListRows()
        syncCurrentWorkspaceSnapshotIfNeeded()
    }

    private func firstVisibleChildID(of row: IssueListRow) -> String? {
        guard let selectedIndex = issueListRows.firstIndex(where: { $0.issueID == row.issueID }) else {
            return nil
        }
        let childDepth = row.depth + 1
        return issueListRows.dropFirst(selectedIndex + 1).first { $0.depth == childDepth }?.issueID
    }

    private func visibleParentID(of row: IssueListRow) -> String? {
        guard row.depth > 0,
              let selectedIndex = issueListRows.firstIndex(where: { $0.issueID == row.issueID }) else {
            return nil
        }
        let parentDepth = row.depth - 1
        return issueListRows[..<selectedIndex].reversed().first { $0.depth == parentDepth }?.issueID
    }

    private func rebuildIssueListRows(pruneExpansion: Bool = false) {
        scheduleQueryRecompute(recomputeCounts: false, pruneExpansion: pruneExpansion)
    }

    /// Computes the filtered/sorted ID list, list rows, and (optionally) filter counts
    /// off the main actor, then applies the result back on the main actor. Successive
    /// calls cancel the in-flight computation and a generation token guards against
    /// applying stale results.
    private func scheduleQueryRecompute(recomputeCounts: Bool, pruneExpansion: Bool) {
        // Keep outline state coherent on the main actor: dropping IDs that no longer
        // exist is cheap and must not race with the background computation.
        _ = outlineState.prune(toValidIssueIDs: index.allIssueIDs)

        queryGeneration &+= 1
        let generation = queryGeneration
        recomputeTask?.cancel()

        let index = index
        let bookmark = selectedBookmark
        let statusFilters = statusFilters
        let typeFilters = typeFilters
        let priorityFilters = priorityFilters
        let labelFilters = labelFilters
        let searchText = searchText
        let sort = sort
        let direction = sortDirection
        let mode = issueListMode
        let gateClock = gateClock
        let outlineSnapshot = outlineState

        recomputeTask = Task { @MainActor [weak self] in
            let results = await Task.detached(priority: .userInitiated) { () -> QueryResults in
                let filteredIDs = BeadIssueListQuery.filteredIssueIDs(
                    index: index,
                    bookmark: bookmark,
                    statusFilters: statusFilters,
                    typeFilters: typeFilters,
                    priorityFilters: priorityFilters,
                    labelFilters: labelFilters,
                    searchText: searchText
                )
                let sortedIDs = BeadIssueListQuery.sortedIssueIDs(
                    index: index,
                    ids: filteredIDs,
                    sort: sort,
                    direction: direction,
                    bookmark: bookmark,
                    now: gateClock
                )

                var outlineState = outlineSnapshot
                var rows = BeadIssueListQuery.rows(
                    index: index,
                    filteredIssueIDs: sortedIDs,
                    mode: mode,
                    outlineState: outlineState,
                    sort: sort,
                    direction: direction,
                    bookmark: bookmark
                )
                let didPruneExpansion = pruneExpansion && outlineState.prune(toVisibleRows: rows)
                if didPruneExpansion {
                    rows = BeadIssueListQuery.rows(
                        index: index,
                        filteredIssueIDs: sortedIDs,
                        mode: mode,
                        outlineState: outlineState,
                        sort: sort,
                        direction: direction,
                        bookmark: bookmark
                    )
                }

                let counts = recomputeCounts
                    ? BeadIssueListQuery.filterCounts(
                        index: index,
                        bookmark: bookmark,
                        statusFilters: statusFilters,
                        typeFilters: typeFilters,
                        priorityFilters: priorityFilters,
                        searchText: searchText,
                        selectedLabels: labelFilters
                    )
                    : nil

                return QueryResults(
                    filteredIssueIDs: sortedIDs,
                    rows: rows,
                    outlineState: didPruneExpansion ? outlineState : nil,
                    filterCounts: counts
                )
            }.value

            guard !Task.isCancelled, let self, self.queryGeneration == generation else { return }
            self.applyQueryResults(results)
        }
    }

    private func applyQueryResults(_ results: QueryResults) {
        if let prunedOutlineState = results.outlineState {
            outlineState = prunedOutlineState
        }
        if filteredIssueIDs != results.filteredIssueIDs {
            filteredIssueIDs = results.filteredIssueIDs
        }
        if issueListRows != results.rows {
            issueListRows = results.rows
        }
        if let counts = results.filterCounts, filterCounts != counts {
            filterCounts = counts
        }
    }

    private struct QueryResults: Sendable {
        var filteredIssueIDs: [String]
        var rows: [IssueListRow]
        var outlineState: BeadOutlineSelectionState?
        var filterCounts: BeadFilterCounts?
    }

    /// Awaits the in-flight filtered/sorted/rows recomputation, if any, so callers can
    /// observe settled derived state (`filteredIssueIDs`, `issueListRows`, `filterCounts`).
    /// Intended for tests; production UI simply re-renders when the recompute lands.
    func waitForPendingQueryRecompute() async {
        await recomputeTask?.value
    }

    func waitForPendingProjectHealthLoad() async {
        await projectHealthTask?.value
    }

    private func rebuildIndexForProjectIndexPreferenceChange() {
        guard !index.issues.isEmpty || !index.dependencies.isEmpty || index.semantics != .empty else { return }
        index = BeadProjectIndex(
            issues: index.issues,
            dependencies: index.dependencies,
            semantics: index.semantics,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
        )
        contentRevision &+= 1
        selectedIDs = selectedIDs.filter { index.issue(with: $0) != nil }
        pruneExpandedIssueIDs()
        applyFilters()
        loadDependenciesForSelection()
        syncCommentsForSelectionFromCache()
    }

    private func indexMatchingCurrentProjectPreferences(from loadedIndex: BeadProjectIndex) -> BeadProjectIndex {
        guard loadedIndex.staleCutoffDays != staleCutoffDays
            || loadedIndex.hidesParentsWithOnlyBlockedChildrenInReady != hidesParentsWithOnlyBlockedChildrenInReady
        else {
            return loadedIndex
        }

        return BeadProjectIndex(
            issues: loadedIndex.issues,
            dependencies: loadedIndex.dependencies,
            semantics: loadedIndex.semantics,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
        )
    }

    private func expandAncestorsForSelection(rebuildRows: Bool) {
        guard let issue = selectedIssue else { return }
        expandAncestors(of: issue.id, rebuildRows: rebuildRows)
    }

    private func expandAncestors(of issueID: String, rebuildRows: Bool) {
        guard outlineState.expandAncestors(of: issueID, in: index) else { return }
        if rebuildRows {
            rebuildIssueListRows()
        }
    }

    private func pruneExpandedIssueIDs() {
        _ = outlineState.prune(toValidIssueIDs: index.allIssueIDs)
    }

    private func applyLoadedProject(_ loadedProject: LoadedProject, projectURL: URL) {
        isReconcileInFlight = false
        projectReadiness = .ready
        index = indexMatchingCurrentProjectPreferences(from: loadedProject.index)
        issues = loadedProject.snapshot.issues
        contentRevision &+= 1
        if let definitions = loadedProject.definitions {
            cachedDefinitions = definitions
        }
        currentDataSource = loadedProject.source
        markSnapshotFreshnessLoaded(projectURL: projectURL, source: loadedProject.source)
        selectedIDs = selectedIDs.filter { index.issue(with: $0) != nil }
        pruneExpandedIssueIDs()
        expandAncestorsForSelection(rebuildRows: false)
        mergeCommentCache(from: loadedProject.snapshot.commentsByIssueID)
        applyFilters()
        loadDependenciesForSelection()
        syncCommentsForSelectionFromCache()
        isLoading = false
        lastError = nil
        synchronizeDataSourceMonitor(projectURL: projectURL, source: loadedProject.source)
        finishCommentRefreshIfNeeded(projectURL: projectURL)
        pruneGateDetailsForCurrentSnapshot()
        loadWaitersForSelectedGateIfNeeded()
        resetWorkspaceHistory()
    }

    private func pruneGateDetailsForCurrentSnapshot() {
        let gateIssueIDs = index.issueIDsByType[BeadProjectIndex.gateIssueType, default: []]
        let pruned = gatesByID.filter { id, detail in
            guard gateIssueIDs.contains(id),
                  let issue = index.issue(with: id),
                  let gate = BeadGate(issue: issue) else {
                return false
            }
            return detail.updatedAt == gate.updatedAt
        }
        if pruned != gatesByID {
            gatesByID = pruned
        }
        if gateIssueIDs.isEmpty {
            gateDetailTask?.cancel()
            gateDetailTask = nil
        }
    }

    /// Enrich the selected gate with waiters via `bd gate show`, skipping unchanged gates.
    private func loadWaitersForSelectedGateIfNeeded() {
        guard let projectURL,
              let id = selectedIDs.first, selectedIDs.count == 1,
              let gate = gate(for: id) else {
            gateDetailTask?.cancel()
            gateDetailTask = nil
            return
        }
        guard gatesByID[id]?.updatedAt != gate.updatedAt else {
            return
        }
        gateDetailTask?.cancel()
        let commands = commands
        gateDetailTask = Task { @MainActor [weak self] in
            let detail = try? await commands.loadGateDetail(projectURL: projectURL, id: id)
            guard !Task.isCancelled, let self, let detail,
                  self.projectURL == projectURL,
                  self.selectedIDs.first == id else {
                return
            }
            self.gatesByID[id] = detail
        }
    }

    private func synchronizeDataSourceMonitor(projectURL: URL, source: BeadsDataSource) {
        guard monitoredSourceFingerprint != source.fingerprint else { return }
        stopDataSourceMonitor()
        let expectedProjectURL = projectURL
        let expectedSourceFingerprint = source.fingerprint
        let monitor = BeadsDataSourceMonitor(projectURL: projectURL, source: source) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self,
                      self.projectURL == expectedProjectURL,
                      self.monitoredSourceFingerprint == expectedSourceFingerprint else {
                    return
                }
                self.handleDataSourceMonitorEvent(event, projectURL: expectedProjectURL)
            }
        }
        dataSourceMonitor = monitor
        monitoredSourceFingerprint = source.fingerprint
        monitor.start()
    }

    private func stopDataSourceMonitor() {
        dataSourceMonitor?.stop()
        dataSourceMonitor = nil
        monitoredSourceFingerprint = nil
    }

    private func handleDataSourceMonitorEvent(_ event: BeadsDataSourceMonitor.Event, projectURL: URL) {
        guard !event.roles.isEmpty, self.projectURL == projectURL, let currentDataSource else { return }
        if currentDataSource.kind == .jsonl,
           event.roles.contains(.beadsDirectory),
           let discoveredSource = try? BeadsDataSourceDiscovery().discover(projectURL: projectURL),
           discoveredSource != currentDataSource {
            snapshotFreshness = snapshotFreshness.refreshing(projectURL: projectURL, source: currentDataSource)
            refreshAfterDataSourceChange()
            return
        }
        let evaluation = snapshotFreshness.evaluatingCurrentFiles(
            projectURL: projectURL,
            source: currentDataSource
        )
        snapshotFreshness = evaluation.freshness
        guard evaluation.requiresReload else { return }
        refreshAfterDataSourceChange()
    }

    private func markSnapshotFreshnessLoaded(projectURL: URL, source: BeadsDataSource) {
        snapshotFreshness = .loaded(projectURL: projectURL, source: source)
    }

    private func markSnapshotFreshnessFailed(_ message: String) {
        snapshotFreshness = snapshotFreshness.failed(message)
    }

    private func mergeCommentCache(from snapshotComments: [String: [BeadComment]]) {
        let existingComments = commentCache
        commentCache = snapshotComments
        for (issueID, cachedComments) in existingComments where cachedComments.count > commentCache[issueID, default: []].count {
            commentCache[issueID] = cachedComments
        }
    }

    private func cacheOptimisticComment(issueID: String, text: String) {
        let comment = BeadComment(
            id: "local-\(UUID().uuidString)",
            issueID: issueID,
            author: nil,
            text: text,
            createdAt: Date(),
            updatedAt: nil
        )
        commentCache[issueID, default: []].append(comment)
        if selectedIssue?.id == issueID {
            commentsIssueID = issueID
            comments = commentCache[issueID] ?? []
        }
    }
}

private enum RefreshReason: Sendable {
    case initial
    case manual
    case mutation
    case dataSourceChanged
}
