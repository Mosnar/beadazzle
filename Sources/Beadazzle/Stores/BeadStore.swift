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

/// Project-scoped source-of-truth state. `BeadStore` coordinates behavior while this
/// model provides a narrow observation registrar for project lifecycle changes.
@Observable
@MainActor
final class BeadProjectStore {
    fileprivate(set) var projectURL: URL?
    fileprivate(set) var projectReadiness = BeadProjectReadiness.noProject
    fileprivate(set) var recentProjects: [RecentProject] = []
    fileprivate(set) var contentRevision = 0
    fileprivate(set) var currentDataSource: BeadsDataSource?
    fileprivate(set) var snapshotFreshness = ProjectSnapshotFreshness.unknown
    fileprivate(set) var projectHealthSnapshot: ProjectHealthSnapshot?
    fileprivate(set) var isLoadingProjectHealth = false
    fileprivate(set) var projectHealthAction: ProjectHealthAction?
    fileprivate(set) var projectHealthActionError: String?
    fileprivate(set) var isLoading = false
    fileprivate(set) var isInitializingBeads = false
    fileprivate(set) var hiddenTypeNames: Set<String> = []
    fileprivate(set) var hiddenStatusNames: Set<String> = []
    fileprivate(set) var issueReferenceLookup = IssueReferenceLookup.empty

    @ObservationIgnored fileprivate(set) var refreshTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var initializationTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var refreshGeneration = 0
    @ObservationIgnored fileprivate(set) var initializationGeneration = 0
    @ObservationIgnored fileprivate(set) var projectHealthGeneration = 0
    @ObservationIgnored fileprivate(set) var reconcileDebounceTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var reconcileState = SnapshotReconcileState()
    @ObservationIgnored fileprivate(set) var projectHealthTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var dataSourceMonitor: BeadsDataSourceMonitor?
    @ObservationIgnored fileprivate(set) var monitoredSourceFingerprint: String?
    @ObservationIgnored fileprivate(set) var cachedDefinitions: BeadSemanticDefinitions?
    @ObservationIgnored fileprivate(set) var isLoadingProjectPreferences = false
    @ObservationIgnored fileprivate(set) var issueReferenceRevision = 0

    fileprivate(set) var index = BeadProjectIndex.empty {
        didSet {
            guard oldValue.allIssueIDs != index.allIssueIDs else { return }
            issueReferenceRevision &+= 1
            issueReferenceLookup = IssueReferenceLookup(
                issueIDs: index.allIssueIDs,
                revision: issueReferenceRevision
            )
        }
    }

    func cancelLifecycleWork() {
        initializationGeneration &+= 1
        initializationTask?.cancel()
        initializationTask = nil
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        cancelReconciliationWork()
        projectHealthTask?.cancel()
        projectHealthTask = nil
    }

    func cancelReconciliationWork() {
        reconcileDebounceTask?.cancel()
        reconcileDebounceTask = nil
    }

    func beginRefresh() -> Int {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        return refreshGeneration
    }

    func ownsRefresh(projectURL expectedProjectURL: URL, generation: Int) -> Bool {
        projectURL == expectedProjectURL && refreshGeneration == generation
    }

    func beginInitialization() -> Int {
        initializationGeneration &+= 1
        initializationTask?.cancel()
        return initializationGeneration
    }

    func ownsInitialization(projectURL expectedProjectURL: URL, generation: Int) -> Bool {
        projectURL == expectedProjectURL && initializationGeneration == generation
    }

    func finishRefresh(generation: Int) {
        guard refreshGeneration == generation else { return }
        refreshTask = nil
    }

    func finishInitialization(generation: Int) {
        guard initializationGeneration == generation else { return }
        initializationTask = nil
    }

    func beginProjectHealthLoad() -> Int {
        projectHealthGeneration &+= 1
        projectHealthTask?.cancel()
        return projectHealthGeneration
    }

    func finishProjectHealthLoad(generation: Int) {
        guard projectHealthGeneration == generation else { return }
        projectHealthTask = nil
    }
}

/// Ephemeral workspace state: list presentation, selection, saved views and history.
@Observable
@MainActor
final class BeadWorkspaceStore {
    fileprivate(set) var filteredIssueIDs: [String] = []
    fileprivate(set) var issueListRows: [IssueListRow] = []
    fileprivate(set) var selectedIDs: Set<String> = []
    fileprivate(set) var fullPageDetailIssueID: String?
    fileprivate(set) var selectedBookmark: BeadBookmark = .ready
    fileprivate(set) var savedViewTree = BeadSavedViewTree()
    var savedViews: [BeadSavedView] { savedViewTree.savedViews }
    fileprivate(set) var activeSavedViewID: UUID?
    fileprivate(set) var sourceSavedViewID: UUID?
    fileprivate(set) var activeAdvancedPredicate: BeadFilterGroup?
    fileprivate(set) var savedViewCounts: [UUID: Int] = [:]
    fileprivate(set) var isRebuildingSavedViewCounts = false
    fileprivate(set) var savedViewPersistenceState = BeadSavedViewPersistenceState.ready
    fileprivate(set) var filterCounts = BeadFilterCounts.empty
    fileprivate(set) var savedViewFilterClock = Date()
    fileprivate(set) var requestedSavedViewEditorID: UUID?
    fileprivate(set) var canGoBack = false
    fileprivate(set) var canGoForward = false

    @ObservationIgnored fileprivate(set) var filterTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var recomputeTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var queryGeneration = 0
    @ObservationIgnored fileprivate(set) var savedViewCountTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var savedViewCountGeneration = 0
    @ObservationIgnored fileprivate(set) var sidebarSelectionTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var outlineState = BeadOutlineSelectionState()
    @ObservationIgnored fileprivate(set) var workspaceHistory = BeadWorkspaceHistory()
    @ObservationIgnored fileprivate(set) var isRestoringWorkspace = false
    @ObservationIgnored fileprivate(set) var suppressesHistoryRecording = false
    @ObservationIgnored fileprivate(set) var suppressesFilterUpdates = false

    func cancelQueryWork() {
        filterTask?.cancel()
        filterTask = nil
        recomputeTask?.cancel()
        recomputeTask = nil
        savedViewCountTask?.cancel()
        savedViewCountTask = nil
        sidebarSelectionTask?.cancel()
        sidebarSelectionTask = nil
    }
}

/// Selection-dependent data that should not invalidate list- or project-only views.
@Observable
@MainActor
final class BeadDetailStore {
    fileprivate(set) var dependencies: [BeadDependency] = []
    fileprivate(set) var dependencyIssueID: String?
    fileprivate(set) var comments: [BeadComment] = []
    fileprivate(set) var commentsIssueID: String?
    fileprivate(set) var commentRefreshIssueID: String?
    fileprivate(set) var commentLoadError: String?
    fileprivate(set) var isLoadingComments = false
    fileprivate(set) var isAddingComment = false
    fileprivate(set) var gatesByID: [String: BeadGate] = [:]
    fileprivate(set) var gateClock = Date()

    @ObservationIgnored fileprivate(set) var selectionSideDataTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var commentLoadTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var gateDetailTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var commentCache: [String: [BeadComment]] = [:]

    func cancelSelectionWork() {
        selectionSideDataTask?.cancel()
        selectionSideDataTask = nil
        commentLoadTask?.cancel()
        commentLoadTask = nil
        gateDetailTask?.cancel()
        gateDetailTask = nil
    }
}

/// Runtime-only mutation coordination. Keeping these values outside observable project
/// and workspace state prevents task bookkeeping from participating in view tracking.
@MainActor
final class BeadMutationStore {
    fileprivate(set) var activeMutationCount = 0
    let writeQueue = BeadMutationWriteQueue()
}

@Observable
@MainActor
final class BeadStore {
    @ObservationIgnored let project = BeadProjectStore()
    @ObservationIgnored let workspace = BeadWorkspaceStore()
    @ObservationIgnored let detail = BeadDetailStore()
    @ObservationIgnored let mutations = BeadMutationStore()

    var projectURL: URL? { project.projectURL }
    internal var _projectURL: URL? { get { project.projectURL } set { project.projectURL = newValue } }
    var projectReadiness: BeadProjectReadiness { project.projectReadiness }
    internal var _projectReadiness: BeadProjectReadiness { get { project.projectReadiness } set { project.projectReadiness = newValue } }
    var recentProjects: [RecentProject] { project.recentProjects }
    internal var _recentProjects: [RecentProject] { get { project.recentProjects } set { project.recentProjects = newValue } }
    /// Derived from `index` so the two can never disagree; `index` is the single
    /// authoritative snapshot state.
    var issues: [BeadIssue] { index.issues }
    var filteredIssueIDs: [String] { workspace.filteredIssueIDs }
    internal var _filteredIssueIDs: [String] { get { workspace.filteredIssueIDs } set { workspace.filteredIssueIDs = newValue } }
    var issueListRows: [IssueListRow] { workspace.issueListRows }
    internal var _issueListRows: [IssueListRow] { get { workspace.issueListRows } set { workspace.issueListRows = newValue } }
    var dependencies: [BeadDependency] { detail.dependencies }
    internal var _dependencies: [BeadDependency] { get { detail.dependencies } set { detail.dependencies = newValue } }
    var dependencyIssueID: String? { detail.dependencyIssueID }
    internal var _dependencyIssueID: String? { get { detail.dependencyIssueID } set { detail.dependencyIssueID = newValue } }
    var comments: [BeadComment] { detail.comments }
    internal var _comments: [BeadComment] { get { detail.comments } set { detail.comments = newValue } }
    var commentsIssueID: String? { detail.commentsIssueID }
    internal var _commentsIssueID: String? { get { detail.commentsIssueID } set { detail.commentsIssueID = newValue } }
    var commentRefreshIssueID: String? { detail.commentRefreshIssueID }
    internal var _commentRefreshIssueID: String? { get { detail.commentRefreshIssueID } set { detail.commentRefreshIssueID = newValue } }
    var commentLoadError: String? { detail.commentLoadError }
    internal var _commentLoadError: String? { get { detail.commentLoadError } set { detail.commentLoadError = newValue } }
    var selectedIDs: Set<String> { workspace.selectedIDs }
    internal var _selectedIDs: Set<String> { get { workspace.selectedIDs } set { workspace.selectedIDs = newValue } }
    var fullPageDetailIssueID: String? { workspace.fullPageDetailIssueID }
    internal var _fullPageDetailIssueID: String? { get { workspace.fullPageDetailIssueID } set { workspace.fullPageDetailIssueID = newValue } }
    var selectedBookmark: BeadBookmark { workspace.selectedBookmark }
    internal var _selectedBookmark: BeadBookmark { get { workspace.selectedBookmark } set { workspace.selectedBookmark = newValue } }
    var savedViews: [BeadSavedView] { workspace.savedViews }
    var savedViewTree: BeadSavedViewTree { workspace.savedViewTree }
    internal var _savedViewTree: BeadSavedViewTree { get { workspace.savedViewTree } set { workspace.savedViewTree = newValue } }
    var activeSavedViewID: UUID? { workspace.activeSavedViewID }
    internal var _activeSavedViewID: UUID? { get { workspace.activeSavedViewID } set { workspace.activeSavedViewID = newValue } }
    var sourceSavedViewID: UUID? { workspace.sourceSavedViewID }
    internal var _sourceSavedViewID: UUID? { get { workspace.sourceSavedViewID } set { workspace.sourceSavedViewID = newValue } }
    var activeAdvancedPredicate: BeadFilterGroup? { workspace.activeAdvancedPredicate }
    internal var _activeAdvancedPredicate: BeadFilterGroup? { get { workspace.activeAdvancedPredicate } set { workspace.activeAdvancedPredicate = newValue } }
    var savedViewCounts: [UUID: Int] { workspace.savedViewCounts }
    internal var _savedViewCounts: [UUID: Int] { get { workspace.savedViewCounts } set { workspace.savedViewCounts = newValue } }
    var isRebuildingSavedViewCounts: Bool { workspace.isRebuildingSavedViewCounts }
    internal var _isRebuildingSavedViewCounts: Bool { get { workspace.isRebuildingSavedViewCounts } set { workspace.isRebuildingSavedViewCounts = newValue } }
    var savedViewPersistenceState: BeadSavedViewPersistenceState { workspace.savedViewPersistenceState }
    internal var _savedViewPersistenceState: BeadSavedViewPersistenceState {
        get { workspace.savedViewPersistenceState }
        set { workspace.savedViewPersistenceState = newValue }
    }
    var savedViewsHaveUnsupportedVersion: Bool { savedViewPersistenceState.hasUnsupportedVersion }
    var savedViewsPayloadIsCorrupt: Bool { savedViewPersistenceState.isCorrupt }
    var savedViewRecoveryIssueCount: Int { savedViewPersistenceState.recoveryIssueCount }
    var savedViewsPersistenceMessage: String? { savedViewPersistenceState.message }
    var creationDraft: IssueDraft? {
        didSet {
            guard oldValue != creationDraft else { return }
            syncCurrentWorkspaceSnapshotIfNeeded()
        }
    }
    var filterCounts: BeadFilterCounts { workspace.filterCounts }
    internal var _filterCounts: BeadFilterCounts { get { workspace.filterCounts } set { workspace.filterCounts = newValue } }
    /// Bumped whenever issue *content* changes (project load/reload after a mutation, index
    /// rebuild) even if the derived row list keeps the same structure. Lets the list view
    /// refresh visible cells for edits (e.g. a title change) without reconfiguring on every
    /// selection change.
    var contentRevision: Int { project.contentRevision }
    internal var _contentRevision: Int { get { project.contentRevision } set { project.contentRevision = newValue } }
    var currentDataSource: BeadsDataSource? { project.currentDataSource }
    internal var _currentDataSource: BeadsDataSource? { get { project.currentDataSource } set { project.currentDataSource = newValue } }
    var snapshotFreshness: ProjectSnapshotFreshness { project.snapshotFreshness }
    internal var _snapshotFreshness: ProjectSnapshotFreshness { get { project.snapshotFreshness } set { project.snapshotFreshness = newValue } }
    var projectHealthSnapshot: ProjectHealthSnapshot? { project.projectHealthSnapshot }
    internal var _projectHealthSnapshot: ProjectHealthSnapshot? { get { project.projectHealthSnapshot } set { project.projectHealthSnapshot = newValue } }
    var isLoadingProjectHealth: Bool { project.isLoadingProjectHealth }
    internal var _isLoadingProjectHealth: Bool { get { project.isLoadingProjectHealth } set { project.isLoadingProjectHealth = newValue } }
    var projectHealthAction: ProjectHealthAction? { project.projectHealthAction }
    internal var _projectHealthAction: ProjectHealthAction? { get { project.projectHealthAction } set { project.projectHealthAction = newValue } }
    var projectHealthActionError: String? { project.projectHealthActionError }
    internal var _projectHealthActionError: String? { get { project.projectHealthActionError } set { project.projectHealthActionError = newValue } }
    /// Gate detail cache keyed by gate bead id. The issue snapshot is the source of truth
    /// for display fields; `bd gate show` only enriches the selected gate with waiters.
    var gatesByID: [String: BeadGate] { detail.gatesByID }
    internal var _gatesByID: [String: BeadGate] { get { detail.gatesByID } set { detail.gatesByID = newValue } }
    var gateClock: Date { detail.gateClock }
    internal var _gateClock: Date { get { detail.gateClock } set { detail.gateClock = newValue } }
    var savedViewFilterClock: Date { workspace.savedViewFilterClock }
    internal var _savedViewFilterClock: Date { get { workspace.savedViewFilterClock } set { workspace.savedViewFilterClock = newValue } }
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
            guard !isLoadingProjectPreferences else { return }
            persistStaleCutoffDays()
            rebuildIndexForProjectIndexPreferenceChange()
        }
    }
    var hidesParentsWithOnlyBlockedChildrenInReady = true {
        didSet {
            guard oldValue != hidesParentsWithOnlyBlockedChildrenInReady else { return }
            guard !isLoadingProjectPreferences else { return }
            persistReadyParentRollUpPreference()
            rebuildIndexForProjectIndexPreferenceChange()
        }
    }
    var automaticallyRefreshesExternalChanges = true {
        didSet {
            guard oldValue != automaticallyRefreshesExternalChanges else { return }
            guard !isLoadingProjectPreferences else { return }
            persistExternalRefreshPreference()
            externalRefreshPreferenceDidChange()
        }
    }
    var showsOwnerInBeadList = false {
        didSet {
            guard oldValue != showsOwnerInBeadList else { return }
            guard !isLoadingProjectPreferences else { return }
            persistProjectListDisplayOptions()
        }
    }
    var showsAssigneeInBeadList = false {
        didSet {
            guard oldValue != showsAssigneeInBeadList else { return }
            guard !isLoadingProjectPreferences else { return }
            persistProjectListDisplayOptions()
        }
    }
    var showsDueDateInBeadList = false {
        didSet {
            guard oldValue != showsDueDateInBeadList else { return }
            guard !isLoadingProjectPreferences else { return }
            persistProjectListDisplayOptions()
        }
    }
    var showsCommentsInBeadList = true {
        didSet {
            guard oldValue != showsCommentsInBeadList else { return }
            guard !isLoadingProjectPreferences else { return }
            persistProjectListDisplayOptions()
        }
    }
    var isLoading: Bool { project.isLoading }
    internal var _isLoading: Bool { get { project.isLoading } set { project.isLoading = newValue } }
    var isInitializingBeads: Bool { project.isInitializingBeads }
    internal var _isInitializingBeads: Bool { get { project.isInitializingBeads } set { project.isInitializingBeads = newValue } }
    var isLoadingComments: Bool { detail.isLoadingComments }
    internal var _isLoadingComments: Bool { get { detail.isLoadingComments } set { detail.isLoadingComments = newValue } }
    var isAddingComment: Bool { detail.isAddingComment }
    internal var _isAddingComment: Bool { get { detail.isAddingComment } set { detail.isAddingComment = newValue } }
    var lastError: String?
    var requestedSavedViewEditorID: UUID? { workspace.requestedSavedViewEditorID }
    internal var _requestedSavedViewEditorID: UUID? { get { workspace.requestedSavedViewEditorID } set { workspace.requestedSavedViewEditorID = newValue } }
    var hiddenTypeNames: Set<String> { project.hiddenTypeNames }
    internal var _hiddenTypeNames: Set<String> { get { project.hiddenTypeNames } set { project.hiddenTypeNames = newValue } }
    var hiddenStatusNames: Set<String> { project.hiddenStatusNames }
    internal var _hiddenStatusNames: Set<String> { get { project.hiddenStatusNames } set { project.hiddenStatusNames = newValue } }
    var canGoBack: Bool { workspace.canGoBack }
    internal var _canGoBack: Bool { get { workspace.canGoBack } set { workspace.canGoBack = newValue } }
    var canGoForward: Bool { workspace.canGoForward }
    internal var _canGoForward: Bool { get { workspace.canGoForward } set { workspace.canGoForward = newValue } }
    var issueReferenceLookup: IssueReferenceLookup { project.issueReferenceLookup }

    @ObservationIgnored internal let commands: any BeadsCommanding
    @ObservationIgnored internal let projectLoader: BeadProjectLoader
    @ObservationIgnored internal let savedViewRepository: BeadSavedViewRepository
    internal var refreshTask: Task<Void, Never>? { get { project.refreshTask } set { project.refreshTask = newValue } }
    internal var initializationTask: Task<Void, Never>? { get { project.initializationTask } set { project.initializationTask = newValue } }
    internal var reconcileDebounceTask: Task<Void, Never>? { get { project.reconcileDebounceTask } set { project.reconcileDebounceTask = newValue } }
    internal var activeMutationCount: Int { get { mutations.activeMutationCount } set { mutations.activeMutationCount = newValue } }
    internal var reconcileState: SnapshotReconcileState { get { project.reconcileState } set { project.reconcileState = newValue } }
    internal var filterTask: Task<Void, Never>? { get { workspace.filterTask } set { workspace.filterTask = newValue } }
    internal var recomputeTask: Task<Void, Never>? { get { workspace.recomputeTask } set { workspace.recomputeTask = newValue } }
    internal var queryGeneration: Int { get { workspace.queryGeneration } set { workspace.queryGeneration = newValue } }
    internal var savedViewCountTask: Task<Void, Never>? { get { workspace.savedViewCountTask } set { workspace.savedViewCountTask = newValue } }
    internal var savedViewCountGeneration: Int { get { workspace.savedViewCountGeneration } set { workspace.savedViewCountGeneration = newValue } }
    internal var sidebarSelectionTask: Task<Void, Never>? { get { workspace.sidebarSelectionTask } set { workspace.sidebarSelectionTask = newValue } }
    internal var selectionSideDataTask: Task<Void, Never>? { get { detail.selectionSideDataTask } set { detail.selectionSideDataTask = newValue } }
    internal var commentLoadTask: Task<Void, Never>? { get { detail.commentLoadTask } set { detail.commentLoadTask = newValue } }
    internal var gateDetailTask: Task<Void, Never>? { get { detail.gateDetailTask } set { detail.gateDetailTask = newValue } }
    internal var projectHealthTask: Task<Void, Never>? { get { project.projectHealthTask } set { project.projectHealthTask = newValue } }
    internal var dataSourceMonitor: BeadsDataSourceMonitor? { get { project.dataSourceMonitor } set { project.dataSourceMonitor = newValue } }
    internal var monitoredSourceFingerprint: String? { get { project.monitoredSourceFingerprint } set { project.monitoredSourceFingerprint = newValue } }
    /// Cached status/type definitions, reused across reloads so routine reloads don't
    /// spawn two `bd --readonly` subprocesses. Reloaded on initial/manual refresh, and
    /// after the app edits custom definitions (which set this back to `nil`). A `nil` cache
    /// forces the next reload to re-read from `bd`, so a failed reload naturally retries.
    internal var cachedDefinitions: BeadSemanticDefinitions? { get { project.cachedDefinitions } set { project.cachedDefinitions = newValue } }
    internal var commentCache: [String: [BeadComment]] { get { detail.commentCache } set { detail.commentCache = newValue } }
    internal var outlineState: BeadOutlineSelectionState { get { workspace.outlineState } set { workspace.outlineState = newValue } }
    internal var workspaceHistory: BeadWorkspaceHistory { get { workspace.workspaceHistory } set { workspace.workspaceHistory = newValue } }
    internal var isRestoringWorkspace: Bool { get { workspace.isRestoringWorkspace } set { workspace.isRestoringWorkspace = newValue } }
    internal var isLoadingProjectPreferences: Bool { get { project.isLoadingProjectPreferences } set { project.isLoadingProjectPreferences = newValue } }
    internal var suppressesHistoryRecording: Bool { get { workspace.suppressesHistoryRecording } set { workspace.suppressesHistoryRecording = newValue } }
    internal var suppressesFilterUpdates: Bool { get { workspace.suppressesFilterUpdates } set { workspace.suppressesFilterUpdates = newValue } }
    @ObservationIgnored internal let userDefaults: UserDefaults

    internal var index: BeadProjectIndex { get { project.index } set { project.index = newValue } }

    var hierarchyMutationPolicy: BeadHierarchyMutationPolicy {
        BeadHierarchyMutationPolicy(index: index)
    }

    internal static let lastProjectPathKey = "LastProjectPath"
    internal static let recentProjectPathsKey = "RecentProjectPaths"
    internal static let maxRecentProjectCount = 8

    init(
        userDefaults: UserDefaults = .standard,
        commands: any BeadsCommanding = BeadsCommandService()
    ) {
        self.userDefaults = userDefaults
        self.commands = commands
        self.projectLoader = BeadProjectLoader(commands: commands)
        self.savedViewRepository = BeadSavedViewRepository(userDefaults: userDefaults)
        bdCLIPath = userDefaults.string(forKey: BeadazzlePreferenceKeys.bdCLIPath) ?? ""
        _recentProjects = Self.loadRecentProjects(from: userDefaults)

        if recentProjects.isEmpty,
           let legacyPath = userDefaults.string(forKey: Self.lastProjectPathKey),
           !legacyPath.isEmpty {
            _recentProjects = [RecentProject(url: URL(fileURLWithPath: legacyPath))]
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

    func clearRequestedSavedViewEditor() {
        _requestedSavedViewEditorID = nil
    }

}

internal enum RefreshReason: Sendable {
    case initial
    case manual
    case reconcile
    case dataSourceChanged
}
