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
    /// Gate detail cache keyed by gate bead id. The issue snapshot is the source of truth
    /// for display fields; `bd gate show` only enriches the selected gate with waiters.
    private(set) var gatesByID: [String: BeadGate] = [:]
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
            rebuildIndexForStaleCutoffChange()
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
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var recomputeTask: Task<Void, Never>?
    @ObservationIgnored private var queryGeneration = 0
    @ObservationIgnored private var selectionSideDataTask: Task<Void, Never>?
    @ObservationIgnored private var gateDetailTask: Task<Void, Never>?
    @ObservationIgnored private var dataSourceMonitor: BeadsDataSourceMonitor?
    @ObservationIgnored private var monitoredSourceFingerprint: String?
    @ObservationIgnored private var commentCache: [String: [BeadComment]] = [:]
    @ObservationIgnored private var outlineState = BeadOutlineSelectionState()
    @ObservationIgnored private var workspaceHistory = BeadWorkspaceHistory()
    @ObservationIgnored private var isRestoringWorkspace = false
    @ObservationIgnored private var suppressesHistoryRecording = false
    @ObservationIgnored private var suppressesFilterUpdates = false
    @ObservationIgnored private let userDefaults: UserDefaults

    private var index = BeadProjectIndex.empty

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
        creationDraft = blankDraft()
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
        (index.dependenciesByIssueID[issueID] ?? [])
            .filter(\.isBlocking)
            .compactMap { gate(for: $0.dependsOnID) }
    }

    var availableStatuses: [String] {
        optionStatusDefinitions.map(\.name)
    }

    var availableTypes: [String] {
        optionTypeDefinitions.map(\.name)
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

    func blankDraft() -> IssueDraft {
        IssueDraft.blank(
            defaultType: availableTypes.first ?? index.semantics.typeNames.first ?? "",
            defaultStatus: availableStatuses.first ?? index.semantics.statusNames.first ?? ""
        )
    }

    func statusOptions(including currentStatus: String?) -> [String] {
        options(availableStatuses, including: currentStatus, fallback: index.semantics.statusNames)
    }

    func typeOptions(including currentType: String?) -> [String] {
        options(availableTypes, including: currentType, fallback: index.semantics.typeNames)
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
        loadProjectVisibility(for: url)
        isInitializingBeads = false
        if projectDirectoryExists(at: url) {
            rememberRecentProject(url)
        }
        clearLoadedProjectData()
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

    private func persistProjectVisibility() {
        guard let projectURL else { return }
        userDefaults.set(hiddenTypeNames.sorted(), forKey: BeadazzlePreferenceKeys.hiddenTypes(projectURL: projectURL))
        userDefaults.set(hiddenStatusNames.sorted(), forKey: BeadazzlePreferenceKeys.hiddenStatuses(projectURL: projectURL))
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

        Task { @MainActor [weak self] in
            do {
                let loadedProject = try await projectLoader.initializeAndLoadProject(
                    projectURL: projectURL,
                    options: options,
                    staleCutoffDays: staleCutoffDays
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
        selectedIDs.removeAll()
        creationDraft = nil
        outlineState.clear()
        filterCounts = .empty
        isLoadingComments = false
        isAddingComment = false
        syncWorkspaceHistoryAvailability()
    }

    func select(_ ids: Set<String>) {
        guard selectedIDs != ids else { return }
        if !ids.isEmpty, creationDraft != nil {
            suppressesHistoryRecording = true
            creationDraft = nil
            suppressesHistoryRecording = false
        }
        selectedIDs = ids
        selectionDidChange()
    }

    func clearSelection() {
        select([])
    }

    func refresh() {
        refresh(reason: .manual, showsLoadingIndicator: true)
    }

    private func refreshAfterDataSourceChange() {
        refresh(reason: .dataSourceChanged, showsLoadingIndicator: false)
    }

    private func refresh(reason: RefreshReason, showsLoadingIndicator: Bool) {
        guard let projectURL else { return }
        refreshTask?.cancel()
        if showsLoadingIndicator {
            isLoading = true
        }
        if reason != .dataSourceChanged {
            lastError = nil
        }
        let projectLoader = projectLoader
        let staleCutoffDays = staleCutoffDays

        refreshTask = Task { @MainActor [weak self] in
            do {
                let snapshotTask = Task {
                    try await projectLoader.loadProject(projectURL: projectURL, staleCutoffDays: staleCutoffDays)
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
                    try await projectLoader.exportAndLoadProject(projectURL: projectURL, staleCutoffDays: self.staleCutoffDays)
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
                    self.finishCommentRefreshIfNeeded(projectURL: projectURL)
                }
            } catch {
                guard !Task.isCancelled, self?.projectURL == projectURL else { return }
                self?.lastError = error.localizedDescription
                self?.isLoading = false
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
        // Choosing a bookmark returns you to the list: drop any detail selection so the
        // detail pane collapses back to the bead list instead of stranding you on a page.
        // Recompute exactly once afterward — a stray `applyFilters()` before this would be
        // canceled by the selection change's generation guard, dropping the filter-counts pass.
        if !selectedIDs.isEmpty {
            selectedIDs = []
            scheduleSelectionSideDataRefresh()
        }
        applyFilters()
        recordWorkspaceSnapshotIfNeeded()
    }

    @discardableResult
    func save(_ draft: IssueDraft) async -> Bool {
        guard let projectURL else { return false }
        do {
            if draft.id == nil {
                let createdIssueID = try await commands.create(projectURL: projectURL, draft: draft)
                guard self.projectURL == projectURL else { return false }
                return try await reloadProjectAfterMutation(projectURL: projectURL, revealIssueID: createdIssueID)
            } else {
                let originalIssue = draft.id.flatMap { index.issue(with: $0) }
                try await commands.update(projectURL: projectURL, draft: draft, originalIssue: originalIssue)
            }
            guard self.projectURL == projectURL else { return false }
            refresh(reason: .mutation, showsLoadingIndicator: true)
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            isLoading = false
            lastError = error.localizedDescription
            return false
        }
    }

    private func reloadProjectAfterMutation(projectURL: URL, revealIssueID: String) async throws -> Bool {
        refreshTask?.cancel()
        isLoading = true
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
        revealIssue(id: revealIssueID)
        return true
    }

    private func loadProjectRecoveringMissingDataSource(projectURL: URL) async throws -> LoadedProject {
        do {
            return try await projectLoader.loadProject(projectURL: projectURL, staleCutoffDays: staleCutoffDays)
        } catch BeadError.projectMissingDataSource(let missingURL) {
            guard Self.beadsDirectoryExists(at: projectURL) else {
                throw BeadError.projectMissingDataSource(missingURL)
            }
            return try await projectLoader.exportAndLoadProject(projectURL: projectURL, staleCutoffDays: staleCutoffDays)
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
        do {
            try await commands.close(projectURL: projectURL, ids: ids, reason: reason)
            guard self.projectURL == projectURL else { return false }
            refresh(reason: .mutation, showsLoadingIndicator: true)
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteSelected() async -> Bool {
        guard let projectURL else { return false }
        let ids = Array(selectedIDs).sorted()
        guard !ids.isEmpty else { return false }
        do {
            try await commands.delete(projectURL: projectURL, ids: ids)
            guard self.projectURL == projectURL else { return false }
            selectedIDs = []
            selectionDidChange()
            refresh(reason: .mutation, showsLoadingIndicator: true)
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func bulkSet(status: String? = nil, type: String? = nil, priority: Int? = nil) async -> Bool {
        guard let projectURL else { return false }
        let ids = Array(selectedIDs).sorted()
        guard !ids.isEmpty else { return false }
        do {
            try await commands.bulkUpdate(projectURL: projectURL, ids: ids, status: status, type: type, priority: priority)
            guard self.projectURL == projectURL else { return false }
            refresh(reason: .mutation, showsLoadingIndicator: true)
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func resolveGate(id: String, reason: String?) async -> Bool {
        guard let projectURL else { return false }
        do {
            try await commands.resolveGate(projectURL: projectURL, id: id, reason: reason?.nilIfBlank)
            guard self.projectURL == projectURL else { return false }
            refresh(reason: .mutation, showsLoadingIndicator: true)
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
                refresh(reason: .mutation, showsLoadingIndicator: true)
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
            refresh(reason: .mutation, showsLoadingIndicator: true)
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
            refresh(reason: .mutation, showsLoadingIndicator: true)
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
        do {
            try await commands.addDependency(projectURL: projectURL, issueID: issueID, dependsOnID: dependsOnID, type: type)
            guard self.projectURL == projectURL else { return false }
            refresh(reason: .mutation, showsLoadingIndicator: true)
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
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
                self.refresh(reason: .mutation, showsLoadingIndicator: true)
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
            let allTypes = try await commands.loadTypeDefinitions(projectURL: projectURL)
            try ensureTypeNameIsAvailable(name, in: allTypes)
            var types = try await commands.loadCustomTypes(projectURL: projectURL)
            try ensureTypeNameIsAvailable(name, in: types)
            types.append(BeadTypeDefinition(name: name, description: nil, source: .custom))
            try await commands.saveCustomTypes(projectURL: projectURL, types: types.sorted { $0.name < $1.name })
            guard self.projectURL == projectURL else { return false }
            refresh(reason: .mutation, showsLoadingIndicator: true)
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
            refresh(reason: .mutation, showsLoadingIndicator: true)
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
            refresh(reason: .mutation, showsLoadingIndicator: true)
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
            refresh(reason: .mutation, showsLoadingIndicator: true)
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
        do {
            try await commands.removeDependency(projectURL: projectURL, issueID: dependency.issueID, dependsOnID: dependency.dependsOnID)
            guard self.projectURL == projectURL else { return false }
            refresh(reason: .mutation, showsLoadingIndicator: true)
            return true
        } catch {
            guard self.projectURL == projectURL else { return false }
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

        expandAncestorsForSelection()
        applyFilters()
        scheduleSelectionSideDataRefresh()
        syncWorkspaceHistoryAvailability()
    }

    private func syncWorkspaceHistoryAvailability() {
        canGoBack = workspaceHistory.canGoBack
        canGoForward = workspaceHistory.canGoForward
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
                    direction: direction
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

    private func rebuildIndexForStaleCutoffChange() {
        guard !index.issues.isEmpty || !index.dependencies.isEmpty || index.semantics != .empty else { return }
        index = BeadProjectIndex(
            issues: index.issues,
            dependencies: index.dependencies,
            semantics: index.semantics,
            staleCutoffDays: staleCutoffDays
        )
        contentRevision &+= 1
        selectedIDs = selectedIDs.filter { index.issue(with: $0) != nil }
        pruneExpandedIssueIDs()
        applyFilters()
        loadDependenciesForSelection()
        syncCommentsForSelectionFromCache()
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
        projectReadiness = .ready
        index = loadedProject.index
        issues = loadedProject.snapshot.issues
        contentRevision &+= 1
        currentDataSource = loadedProject.source
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
        let monitor = BeadsDataSourceMonitor(projectURL: projectURL, source: source) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.projectURL == expectedProjectURL,
                      self.monitoredSourceFingerprint == expectedSourceFingerprint else {
                    return
                }
                self.refreshAfterDataSourceChange()
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
