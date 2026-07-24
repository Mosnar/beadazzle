import Foundation
import Observation
import SwiftUI

enum BeadProjectReadiness: Equatable {
    case noProject
    case ready
    case missingDataSource(URL)
    case projectUnavailable(URL, String)
    case unsupportedProject(URL, String)

    var missingDataSourceURL: URL? {
        if case .missingDataSource(let url) = self {
            return url
        }
        return nil
    }

    var isReady: Bool {
        self == .ready
    }

    var unsupportedProject: (url: URL, detail: String)? {
        if case .unsupportedProject(let url, let detail) = self {
            return (url, detail)
        }
        return nil
    }

    var unavailableProject: (url: URL, detail: String)? {
        if case .projectUnavailable(let url, let detail) = self {
            return (url, detail)
        }
        return nil
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
    fileprivate(set) var projectEnvironment: BeadsProjectEnvironment?
    fileprivate(set) var snapshotFreshness = ProjectSnapshotFreshness.unknown
    fileprivate(set) var projectHealthSnapshot: ProjectHealthSnapshot?
    fileprivate(set) var isLoadingProjectHealth = false
    fileprivate(set) var projectHealthAction: ProjectHealthAction?
    fileprivate(set) var projectHealthActionError: ProjectHealthActionFailure?
    fileprivate(set) var isLoading = false
    fileprivate(set) var isInitializingBeads = false
    fileprivate(set) var hiddenTypeNames: Set<String> = []
    fileprivate(set) var hiddenStatusNames: Set<String> = []
    fileprivate(set) var issueReferenceLookup = IssueReferenceLookup.empty
    /// Tiny per-issue overlays make state rows update in O(1) without rebuilding
    /// the project-wide index on the main actor. Authoritative reloads retire
    /// entries once the exported snapshot contains the same value.
    fileprivate(set) var stateLabelOverridesByIssueID: [String: [String: BeadStateLabelOverride]] = [:]

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
    @ObservationIgnored fileprivate(set) var lastServerActivationRefreshAt: Date?
    @ObservationIgnored fileprivate(set) var isLoadingProjectPreferences = false
    @ObservationIgnored fileprivate(set) var issueReferenceRevision = 0
    @ObservationIgnored fileprivate(set) var projectionMaterializationTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var projectionGeneration = 0
    @ObservationIgnored let projectionMaterializer = BeadProjectionMaterializer()

    /// The last snapshot known to have come from disk/`bd`. `index` may additionally
    /// include optimistic projection entries while writes are settling.
    fileprivate(set) var authoritativeIndex = BeadProjectIndex.empty

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
        projectionGeneration &+= 1
        projectionMaterializationTask?.cancel()
        projectionMaterializationTask = nil
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

enum BeadQueryRecomputeScope: Sendable {
    case rowsOnly
    case resort
    case full

    func merging(_ other: Self) -> Self {
        switch (self, other) {
        case (.full, _), (_, .full): .full
        case (.resort, _), (_, .resort): .resort
        case (.rowsOnly, .rowsOnly): .rowsOnly
        }
    }
}

struct BeadQueryRecomputeRequest: Sendable {
    let scope: BeadQueryRecomputeScope
    let recomputeCounts: Bool
    let pruneExpansion: Bool

    func merging(_ other: Self) -> Self {
        Self(
            scope: scope.merging(other.scope),
            recomputeCounts: recomputeCounts || other.recomputeCounts,
            pruneExpansion: pruneExpansion || other.pruneExpansion
        )
    }
}

/// Ephemeral workspace state: list presentation, selection, saved views and history.
@Observable
@MainActor
final class BeadWorkspaceStore {
    fileprivate(set) var filteredIssueIDs: [String] = []
    fileprivate(set) var issueListRows: [IssueListRow] = []
    /// Changes only when the derived row content or order changes. The AppKit table uses
    /// this to distinguish a selection-only SwiftUI update from a list reconciliation.
    @ObservationIgnored fileprivate(set) var issueListRowsRevision = 0
    fileprivate(set) var selectedIDs: Set<String> = []
    fileprivate(set) var fullPageDetailIssueID: String?
    fileprivate(set) var selectedBookmark: BeadBookmark = .ready
    fileprivate(set) var savedViews: [BeadSavedView] = []
    fileprivate(set) var activeSavedViewID: UUID?
    fileprivate(set) var sourceSavedViewID: UUID?
    fileprivate(set) var listOrdering = BeadListOrdering.sorted(
        BeadSavedViewSort(field: .priority, direction: .ascending)
    )
    fileprivate(set) var activeAdvancedPredicate: BeadFilterGroup?
    fileprivate(set) var savedViewCounts: [UUID: Int] = [:]
    fileprivate(set) var isRebuildingSavedViewCounts = false
    fileprivate(set) var savedViewPersistenceState = BeadSavedViewPersistenceState.ready
    fileprivate(set) var filterCounts = BeadFilterCounts.empty
    fileprivate(set) var savedViewFilterClock = Date()
    fileprivate(set) var requestedSavedViewEditorID: UUID?
    fileprivate(set) var requestedFolderIssueIDs: [String]?
    fileprivate(set) var canGoBack = false
    fileprivate(set) var canGoForward = false

    @ObservationIgnored fileprivate(set) var filterTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var recomputeTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var queryGeneration = 0
    @ObservationIgnored fileprivate(set) var pendingQueryRecomputeRequest: BeadQueryRecomputeRequest?
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
        pendingQueryRecomputeRequest = nil
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
    fileprivate(set) var activityItems: [IssueActivityItem] = []
    fileprivate(set) var activityIssueID: String?
    fileprivate(set) var activityRefreshIssueID: String?
    fileprivate(set) var activityLoadError: String?
    fileprivate(set) var isLoadingActivity = false
    fileprivate(set) var gatesByID: [String: BeadGate] = [:]
    fileprivate(set) var gateClock = Date()

    @ObservationIgnored fileprivate(set) var selectionSideDataTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var commentLoadTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var activityLoadTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var gateDetailTask: Task<Void, Never>?
    @ObservationIgnored fileprivate(set) var commentCache: [String: [BeadComment]] = [:]
    @ObservationIgnored fileprivate(set) var activityEvents: [BeadIssueEvent] = []
    @ObservationIgnored fileprivate(set) var activityLoadedIssueID: String?
    @ObservationIgnored fileprivate(set) var activityLoadGeneration = 0

    func cancelSelectionWork() {
        selectionSideDataTask?.cancel()
        selectionSideDataTask = nil
        commentLoadTask?.cancel()
        commentLoadTask = nil
        activityLoadGeneration &+= 1
        activityLoadTask?.cancel()
        activityLoadTask = nil
        gateDetailTask?.cancel()
        gateDetailTask = nil
    }

    func beginActivityLoad() -> Int {
        activityLoadGeneration &+= 1
        activityLoadTask?.cancel()
        return activityLoadGeneration
    }

    func ownsActivityLoad(issueID: String, generation: Int) -> Bool {
        activityIssueID == issueID && activityLoadGeneration == generation
    }

    func finishActivityLoad(generation: Int) {
        guard activityLoadGeneration == generation else { return }
        activityLoadTask = nil
    }
}

/// Runtime-only mutation coordination. Keeping these values outside observable project
/// and workspace state prevents task bookkeeping from participating in view tracking.
enum BeadStateLabelOverride: Equatable, Sendable {
    case value(String)
    case cleared

    var value: String? {
        guard case .value(let value) = self else { return nil }
        return value
    }
}

enum BeadLabelMutation: Sendable {
    case replace([String])
    case replaceOrdinary([String], preservingDimensions: [String])
    case add([String])
    case setState(dimension: String, value: String)
    case clearState(dimension: String)

    /// Only a complete replacement can prove that every previously attempted
    /// label is absent or present. Granular ordinary/state writes must leave any
    /// older ambiguity in place until an authoritative project refresh.
    var confirmsCompleteLabelSetOnSuccess: Bool {
        if case .replace = self { return true }
        return false
    }

    func applying(to labels: [String]) -> [String] {
        switch self {
        case .replace(let replacement):
            replacement
        case .replaceOrdinary(let ordinaryLabels, let dimensions):
            BeadStateLabel.replacingOrdinaryLabels(
                in: labels,
                with: ordinaryLabels,
                preserving: dimensions
            )
        case .add(let additions):
            Self.uniqueLabels(labels + additions)
        case .setState(let dimension, let value):
            BeadStateLabel.applying(dimension: dimension, value: value, to: labels)
        case .clearState(let dimension):
            BeadStateLabel.excluding(dimensions: [dimension], from: labels)
        }
    }

    private static func uniqueLabels(_ labels: [String]) -> [String] {
        var seen: Set<String> = []
        return labels.filter { seen.insert($0).inserted }
    }
}

struct BeadMetadataMutationPatch {
    let updatesAssignee: Bool
    let assignee: String?
    let labelMutation: BeadLabelMutation?
    let dueAt: IssueMetadataDateUpdate
    let deferUntil: IssueMetadataDateUpdate

    var updatesLabels: Bool {
        labelMutation != nil
    }

    var confirmsCompleteLabelSetOnSuccess: Bool {
        labelMutation?.confirmsCompleteLabelSetOnSuccess == true
    }

    var fields: BeadMetadataMutationFields {
        var fields: BeadMetadataMutationFields = []
        if updatesAssignee { fields.insert(.assignee) }
        if updatesLabels { fields.insert(.labels) }
        if case .set = dueAt { fields.insert(.dueAt) }
        if case .set = deferUntil { fields.insert(.deferUntil) }
        return fields
    }

    init(
        assignee: String?,
        labels: [String]?,
        preservingStateDimensions: [String] = [],
        dueAt: IssueMetadataDateUpdate,
        deferUntil: IssueMetadataDateUpdate
    ) {
        updatesAssignee = assignee != nil
        self.assignee = assignee?.nilIfBlank
        self.labelMutation = labels.map { labels in
            let normalizedLabels = IssueDraft.normalizedLabels(IssueDraft.normalizedLabelText(labels))
            if preservingStateDimensions.isEmpty {
                return .replace(normalizedLabels)
            }
            return .replaceOrdinary(
                BeadStateLabel.excluding(
                    dimensions: preservingStateDimensions,
                    from: normalizedLabels
                ),
                preservingDimensions: preservingStateDimensions
            )
        }
        self.dueAt = dueAt
        self.deferUntil = deferUntil
    }

    init(stateDimension: String, value: String) {
        updatesAssignee = false
        assignee = nil
        labelMutation = .setState(dimension: stateDimension, value: value)
        dueAt = .unchanged
        deferUntil = .unchanged
    }

    init(clearingStateDimension stateDimension: String) {
        updatesAssignee = false
        assignee = nil
        labelMutation = .clearState(dimension: stateDimension)
        dueAt = .unchanged
        deferUntil = .unchanged
    }

    init(addingLabels labels: [String]) {
        updatesAssignee = false
        assignee = nil
        labelMutation = .add(labels)
        dueAt = .unchanged
        deferUntil = .unchanged
    }

    func proposedLabels(for issue: BeadIssue) -> [String]? {
        labelMutation?.applying(to: issue.labels)
    }

    func changes(_ issue: BeadIssue) -> Bool {
        if updatesAssignee, issue.assignee != assignee {
            return true
        }
        if let proposedLabels = proposedLabels(for: issue), issue.labels != proposedLabels {
            return true
        }
        if case .set(let date) = dueAt, issue.dueAt != date {
            return true
        }
        if case .set(let date) = deferUntil, issue.deferUntil != date {
            return true
        }
        return false
    }

    func applying(to issue: BeadIssue) -> BeadIssue {
        var copy = issue
        if updatesAssignee, copy.assignee != assignee {
            copy.assignee = assignee
        }
        if let proposedLabels = proposedLabels(for: copy), copy.labels != proposedLabels {
            copy.labels = proposedLabels
        }
        if case .set(let date) = dueAt, copy.dueAt != date {
            copy.dueAt = date
        }
        if case .set(let date) = deferUntil, copy.deferUntil != date {
            copy.deferUntil = date
        }
        return copy
    }
}

struct BeadMetadataMutationFields: OptionSet {
    let rawValue: UInt8

    static let assignee = Self(rawValue: 1 << 0)
    static let labels = Self(rawValue: 1 << 1)
    static let dueAt = Self(rawValue: 1 << 2)
    static let deferUntil = Self(rawValue: 1 << 3)
    static let all: Self = [.assignee, .labels, .dueAt, .deferUntil]
}

struct BeadMetadataFieldVersions: Equatable {
    var assignee: UInt64 = 0
    var labels: UInt64 = 0
    var dueAt: UInt64 = 0
    var deferUntil: UInt64 = 0

    mutating func recordWrite(to fields: BeadMetadataMutationFields) {
        if fields.contains(.assignee) { assignee &+= 1 }
        if fields.contains(.labels) { labels &+= 1 }
        if fields.contains(.dueAt) { dueAt &+= 1 }
        if fields.contains(.deferUntil) { deferUntil &+= 1 }
    }

    mutating func replace(
        _ fields: BeadMetadataMutationFields,
        with versions: BeadMetadataFieldVersions
    ) {
        if fields.contains(.assignee) { assignee = versions.assignee }
        if fields.contains(.labels) { labels = versions.labels }
        if fields.contains(.dueAt) { dueAt = versions.dueAt }
        if fields.contains(.deferUntil) { deferUntil = versions.deferUntil }
    }

    func matchingFields(
        _ versions: BeadMetadataFieldVersions,
        among fields: BeadMetadataMutationFields
    ) -> BeadMetadataMutationFields {
        var matches: BeadMetadataMutationFields = []
        if fields.contains(.assignee), assignee == versions.assignee { matches.insert(.assignee) }
        if fields.contains(.labels), labels == versions.labels { matches.insert(.labels) }
        if fields.contains(.dueAt), dueAt == versions.dueAt { matches.insert(.dueAt) }
        if fields.contains(.deferUntil), deferUntil == versions.deferUntil { matches.insert(.deferUntil) }
        return matches
    }

    func differingFields(from versions: BeadMetadataFieldVersions) -> BeadMetadataMutationFields {
        BeadMetadataMutationFields.all.subtracting(matchingFields(versions, among: .all))
    }
}

struct BeadMetadataReloadBaseline {
    let fieldWriteVersions: [String: BeadMetadataFieldVersions]
    let settlementRevisions: [String: BeadMetadataFieldVersions]
}

struct BeadMetadataSettlementState {
    var issue: BeadIssue
    var revisions = BeadMetadataFieldVersions()
    var sourceWriteVersions = BeadMetadataFieldVersions()
}

struct BeadPendingMetadataMutation {
    let id: UUID
    let patch: BeadMetadataMutationPatch
    var possiblePersistedLabels: [String]
    let proposedLabels: [String]?
    let fieldWriteVersions: BeadMetadataFieldVersions
    var writeWasAttempted: Bool
    var succeeded: Bool?

    init(
        id: UUID,
        patch: BeadMetadataMutationPatch,
        possiblePersistedLabels: [String] = [],
        proposedLabels: [String]? = nil,
        fieldWriteVersions: BeadMetadataFieldVersions = .init(),
        writeWasAttempted: Bool = true,
        succeeded: Bool? = nil
    ) {
        self.id = id
        self.patch = patch
        self.possiblePersistedLabels = possiblePersistedLabels
        self.proposedLabels = proposedLabels
        self.fieldWriteVersions = fieldWriteVersions
        self.writeWasAttempted = writeWasAttempted
        self.succeeded = succeeded
    }
}

struct BeadMetadataMutationState {
    var confirmedIssue: BeadIssue
    var pendingMutations: [BeadPendingMetadataMutation]

    var resolvedIssue: BeadIssue {
        pendingMutations.reduce(confirmedIssue) { issue, mutation in
            mutation.succeeded == false ? issue : mutation.patch.applying(to: issue)
        }
    }

    var pendingFields: BeadMetadataMutationFields {
        pendingMutations.reduce(into: []) { fields, mutation in
            fields.formUnion(mutation.patch.fields)
        }
    }

    var latestFieldWriteVersions: BeadMetadataFieldVersions {
        pendingMutations.reduce(into: BeadMetadataFieldVersions()) { versions, mutation in
            versions.replace(mutation.patch.fields, with: mutation.fieldWriteVersions)
        }
    }

    mutating func recordCompletion(id: UUID, succeeded: Bool) -> [BeadPendingMetadataMutation]? {
        guard let index = pendingMutations.firstIndex(where: { $0.id == id }) else { return nil }
        pendingMutations[index].succeeded = succeeded

        var completedMutations: [BeadPendingMetadataMutation] = []
        while !pendingMutations.isEmpty, let firstSucceeded = pendingMutations[0].succeeded {
            let completed = pendingMutations.removeFirst()
            if firstSucceeded {
                confirmedIssue = completed.patch.applying(to: confirmedIssue)
            }
            completedMutations.append(completed)
        }
        return completedMutations
    }
}

@MainActor
final class BeadMutationStore {
    static let maximumPossiblyPersistedLabelsPerIssue = 256

    fileprivate(set) var activeMutationCount = 0
    var optimisticMutationRevision = 0
    let writeQueue = BeadMutationWriteQueue()
    private var optimisticMutationQueues: [Int: BeadOptimisticMutationQueue] = [:]
    var metadataMutationGeneration = 0
    var metadataMutations: [String: BeadMetadataMutationState] = [:]
    private var possiblyPersistedLabelsByIssue: [String: [String]] = [:]
    private var labelUncertaintyOverflowIssueIDs: Set<String> = []
    // Write versions identify the latest optimistic owner of each metadata field.
    private var metadataFieldWriteVersionsByIssue: [String: BeadMetadataFieldVersions] = [:]
    // Settlements retain both callback order and source ownership so equal-value
    // rollbacks cannot revive a result from an older writer.
    private var metadataSettlementsByIssue: [String: BeadMetadataSettlementState] = [:]
    var projection = BeadMutationProjection()

    func possiblyPersistedLabels(for issueID: String) -> [String] {
        possiblyPersistedLabelsByIssue[issueID, default: []]
    }

    func recordPossiblyPersistedLabels(_ labels: [String], for issueID: String) {
        var candidates = possiblyPersistedLabels(for: issueID)
        var seen = Set(candidates)
        for label in labels where seen.insert(label).inserted {
            guard candidates.count < Self.maximumPossiblyPersistedLabelsPerIssue else {
                labelUncertaintyOverflowIssueIDs.insert(issueID)
                break
            }
            candidates.append(label)
        }
        if candidates.isEmpty {
            possiblyPersistedLabelsByIssue.removeValue(forKey: issueID)
        } else {
            possiblyPersistedLabelsByIssue[issueID] = candidates
        }
    }

    func recordMetadataWrite(
        _ fields: BeadMetadataMutationFields,
        for issueID: String
    ) -> BeadMetadataFieldVersions {
        var versions = metadataFieldWriteVersionsByIssue[issueID, default: .init()]
        versions.recordWrite(to: fields)
        metadataFieldWriteVersionsByIssue[issueID] = versions
        return versions
    }

    func metadataFieldWriteVersions(for issueID: String) -> BeadMetadataFieldVersions {
        metadataFieldWriteVersionsByIssue[issueID, default: .init()]
    }

    func recordMetadataSettlement(
        _ fields: BeadMetadataMutationFields,
        issue: BeadIssue,
        sourceWriteVersions: BeadMetadataFieldVersions
    ) {
        guard !fields.isEmpty else { return }
        var settlement = metadataSettlementsByIssue[issue.id]
            ?? BeadMetadataSettlementState(issue: issue)
        if fields.contains(.assignee) { settlement.issue.assignee = issue.assignee }
        if fields.contains(.labels) { settlement.issue.labels = issue.labels }
        if fields.contains(.dueAt) { settlement.issue.dueAt = issue.dueAt }
        if fields.contains(.deferUntil) { settlement.issue.deferUntil = issue.deferUntil }
        settlement.revisions.recordWrite(to: fields)
        settlement.sourceWriteVersions.replace(fields, with: sourceWriteVersions)
        metadataSettlementsByIssue[issue.id] = settlement
    }

    func metadataSettlement(for issueID: String) -> BeadMetadataSettlementState? {
        metadataSettlementsByIssue[issueID]
    }

    func metadataFieldWriteVersionsSnapshot() -> [String: BeadMetadataFieldVersions] {
        metadataFieldWriteVersionsByIssue
    }

    func metadataSettlementRevisionsSnapshot() -> [String: BeadMetadataFieldVersions] {
        metadataSettlementsByIssue.mapValues(\.revisions)
    }

    func reloadBaseline() -> BeadMetadataReloadBaseline {
        BeadMetadataReloadBaseline(
            fieldWriteVersions: metadataFieldWriteVersionsSnapshot(),
            settlementRevisions: metadataSettlementRevisionsSnapshot()
        )
    }

    func labelUncertaintyOverflowed(for issueID: String) -> Bool {
        labelUncertaintyOverflowIssueIDs.contains(issueID)
    }

    func confirmPersistedLabels(for issueID: String) {
        possiblyPersistedLabelsByIssue.removeValue(forKey: issueID)
        labelUncertaintyOverflowIssueIDs.remove(issueID)
    }

    func discardMetadataMutations(for issueIDs: [String]) {
        for issueID in issueIDs {
            metadataMutations.removeValue(forKey: issueID)
            confirmPersistedLabels(for: issueID)
            metadataFieldWriteVersionsByIssue.removeValue(forKey: issueID)
            metadataSettlementsByIssue.removeValue(forKey: issueID)
        }
    }

    func clearPossiblyPersistedLabels() {
        possiblyPersistedLabelsByIssue = [:]
        labelUncertaintyOverflowIssueIDs = []
    }

    func confirmAuthoritativeMetadata() {
        guard metadataMutations.isEmpty else { return }
        clearPossiblyPersistedLabels()
        metadataFieldWriteVersionsByIssue = [:]
        metadataSettlementsByIssue = [:]
    }

    func resetMetadataMutations() {
        metadataMutationGeneration &+= 1
        activeMutationCount = 0
        optimisticMutationRevision = 0
        optimisticMutationQueues = [:]
        metadataMutations = [:]
        metadataFieldWriteVersionsByIssue = [:]
        metadataSettlementsByIssue = [:]
        projection.reset()
        clearPossiblyPersistedLabels()
    }

    func optimisticMutationQueue(for generation: Int) -> BeadOptimisticMutationQueue {
        if let queue = optimisticMutationQueues[generation] {
            return queue
        }
        let queue = BeadOptimisticMutationQueue()
        optimisticMutationQueues[generation] = queue
        return queue
    }
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
    var issues: BeadUserFacingIssueCollection { index.userFacingIssues }
    var filteredIssueIDs: [String] { workspace.filteredIssueIDs }
    internal var _filteredIssueIDs: [String] { get { workspace.filteredIssueIDs } set { workspace.filteredIssueIDs = newValue } }
    var issueListRows: [IssueListRow] { workspace.issueListRows }
    internal var _issueListRows: [IssueListRow] {
        get { workspace.issueListRows }
        set {
            guard workspace.issueListRows != newValue else { return }
            workspace.issueListRowsRevision &+= 1
            workspace.issueListRows = newValue
        }
    }
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
    var activityItems: [IssueActivityItem] { detail.activityItems }
    internal var _activityItems: [IssueActivityItem] { get { detail.activityItems } set { detail.activityItems = newValue } }
    var activityIssueID: String? { detail.activityIssueID }
    internal var _activityIssueID: String? { get { detail.activityIssueID } set { detail.activityIssueID = newValue } }
    var activityRefreshIssueID: String? { detail.activityRefreshIssueID }
    internal var _activityRefreshIssueID: String? { get { detail.activityRefreshIssueID } set { detail.activityRefreshIssueID = newValue } }
    var activityLoadError: String? { detail.activityLoadError }
    internal var _activityLoadError: String? { get { detail.activityLoadError } set { detail.activityLoadError = newValue } }
    var selectedIDs: Set<String> { workspace.selectedIDs }
    internal var _selectedIDs: Set<String> { get { workspace.selectedIDs } set { workspace.selectedIDs = newValue } }
    var fullPageDetailIssueID: String? { workspace.fullPageDetailIssueID }
    internal var _fullPageDetailIssueID: String? { get { workspace.fullPageDetailIssueID } set { workspace.fullPageDetailIssueID = newValue } }
    var selectedBookmark: BeadBookmark { workspace.selectedBookmark }
    internal var _selectedBookmark: BeadBookmark { get { workspace.selectedBookmark } set { workspace.selectedBookmark = newValue } }
    var savedViews: [BeadSavedView] { workspace.savedViews }
    internal var _savedViews: [BeadSavedView] { get { workspace.savedViews } set { workspace.savedViews = newValue } }
    var activeSavedViewID: UUID? { workspace.activeSavedViewID }
    internal var _activeSavedViewID: UUID? { get { workspace.activeSavedViewID } set { workspace.activeSavedViewID = newValue } }
    var sourceSavedViewID: UUID? { workspace.sourceSavedViewID }
    internal var _sourceSavedViewID: UUID? { get { workspace.sourceSavedViewID } set { workspace.sourceSavedViewID = newValue } }
    var listOrdering: BeadListOrdering { workspace.listOrdering }
    internal var _listOrdering: BeadListOrdering { get { workspace.listOrdering } set { workspace.listOrdering = newValue } }
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
    var projectEnvironment: BeadsProjectEnvironment? { project.projectEnvironment }
    internal var _projectEnvironment: BeadsProjectEnvironment? {
        get { project.projectEnvironment }
        set { project.projectEnvironment = newValue }
    }
    var snapshotFreshness: ProjectSnapshotFreshness { project.snapshotFreshness }
    internal var _snapshotFreshness: ProjectSnapshotFreshness { get { project.snapshotFreshness } set { project.snapshotFreshness = newValue } }
    var projectHealthSnapshot: ProjectHealthSnapshot? { project.projectHealthSnapshot }
    internal var _projectHealthSnapshot: ProjectHealthSnapshot? { get { project.projectHealthSnapshot } set { project.projectHealthSnapshot = newValue } }
    var isLoadingProjectHealth: Bool { project.isLoadingProjectHealth }
    internal var _isLoadingProjectHealth: Bool { get { project.isLoadingProjectHealth } set { project.isLoadingProjectHealth = newValue } }
    var projectHealthAction: ProjectHealthAction? { project.projectHealthAction }
    internal var _projectHealthAction: ProjectHealthAction? { get { project.projectHealthAction } set { project.projectHealthAction = newValue } }
    var projectHealthActionError: ProjectHealthActionFailure? { project.projectHealthActionError }
    internal var _projectHealthActionError: ProjectHealthActionFailure? { get { project.projectHealthActionError } set { project.projectHealthActionError = newValue } }
    /// Gate detail cache keyed by gate bead id. The issue snapshot is the source of truth
    /// for display fields; `bd gate show` only enriches the selected gate with waiters.
    var gatesByID: [String: BeadGate] { detail.gatesByID }
    internal var _gatesByID: [String: BeadGate] { get { detail.gatesByID } set { detail.gatesByID = newValue } }
    var gateClock: Date { detail.gateClock }
    internal var _gateClock: Date { get { detail.gateClock } set { detail.gateClock = newValue } }
    var savedViewFilterClock: Date { workspace.savedViewFilterClock }
    internal var _savedViewFilterClock: Date { get { workspace.savedViewFilterClock } set { workspace.savedViewFilterClock = newValue } }
    var requestedFolderIssueIDs: [String]? { workspace.requestedFolderIssueIDs }
    internal var _requestedFolderIssueIDs: [String]? {
        get { workspace.requestedFolderIssueIDs }
        set { workspace.requestedFolderIssueIDs = newValue }
    }
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
    /// State dimensions (`bd set-state` label prefixes, e.g. `phase`) the user
    /// pinned as editable property rows in the inspector for this project.
    var pinnedStateDimensions: [String] = [] {
        didSet {
            guard oldValue != pinnedStateDimensions else { return }
            guard !isLoadingProjectPreferences else { return }
            persistPinnedStateDimensions()
        }
    }
    /// Project-local presentation names for state dimensions. The dictionary is
    /// intentionally tiny and separate from issue data, so rendering a pinned
    /// property is a constant-time lookup and never scans the tracker.
    var stateDimensionDisplayNames: [String: String] = [:] {
        didSet {
            guard oldValue != stateDimensionDisplayNames else { return }
            guard !isLoadingProjectPreferences else { return }
            persistStateDimensionDisplayNames()
        }
    }
    /// Sparse project-local presentation overrides keyed first by state
    /// dimension, then by the event-backed raw value.
    var stateValueDisplayNames: [String: [String: String]] = [:] {
        didSet {
            guard oldValue != stateValueDisplayNames else { return }
            guard !isLoadingProjectPreferences else { return }
            persistStateValueDisplayNames()
        }
    }
    /// Sparse project-local retirement catalog. Archived values remain in the
    /// index and on existing beads, but are not offered as new choices.
    var archivedStateValuesByDimension: [String: Set<String>] = [:] {
        didSet {
            guard oldValue != archivedStateValuesByDimension else { return }
            guard !isLoadingProjectPreferences else { return }
            persistArchivedStateValues()
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
    var isLoadingActivity: Bool { detail.isLoadingActivity }
    internal var _isLoadingActivity: Bool { get { detail.isLoadingActivity } set { detail.isLoadingActivity = newValue } }
    /// Coalesced queue of mutation/command failures. The head is presented in the
    /// standardized error dialog (`MutationErrorDialog`); Cancel/Try Again pop it.
    /// This is the single feedback channel; `lastError` remains as a string shim so
    /// legacy call sites keep compiling while surfaces migrate to `reportMutationFailure`.
    var pendingFailures: [BeadMutationFailure] = []

    /// The failure currently shown in the standardized error dialog.
    var currentFailure: BeadMutationFailure? { pendingFailures.first }

    /// String view over `pendingFailures` for legacy call sites. Assigning a non-nil
    /// string enqueues a plain, non-retryable failure; assigning `nil` clears the queue
    /// (matches the prior "clear stale error" semantics used at load/reconcile start).
    var lastError: String? {
        // Reads return the most recent failure's message (last-write-wins), matching the
        // legacy single-slot semantics; the dialog itself presents `currentFailure` (the
        // queue head) so failures are shown in the order they occurred.
        get { pendingFailures.last?.message }
        set {
            // Only a non-nil assignment enqueues. Clearing via `nil` is intentionally a no-op:
            // the failure queue is user-managed (dismissed through the dialog or resolved by a
            // successful Try Again) and must survive the incidental `lastError = nil` calls made
            // at the start of loads/reconciles — otherwise the mutation-triggered reconcile that
            // follows a failed write would wipe the failure before the dialog could be acted on.
            // The queue is cleared explicitly only on project switch (`clearLoadedProjectData`).
            if let newValue {
                enqueueFailure(BeadMutationFailure(title: Self.genericFailureTitle, message: newValue))
            }
        }
    }

    /// Title used for legacy string errors that don't carry a more specific headline.
    static let genericFailureTitle = "Beadazzle"

    /// Issue IDs whose in-flight write has outlived the perceptible-latency threshold and
    /// should show a small local progress indicator. Empty for fast (quiet) writes — the
    /// indicator never appears for edits that settle quickly, and never blocks navigation.
    var perceptiblyBusyIssueIDs: Set<String> = []

    @ObservationIgnored internal var perceptibleBusyAnchors: [Int: Set<String>] = [:]
    @ObservationIgnored internal var perceptibleBusyTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored internal var perceptibleBusyTokenSeed = 0
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
    @ObservationIgnored internal let activityHistoryRepository: BeadActivityHistoryRepository
    @ObservationIgnored internal let savedViewRepository: BeadSavedViewRepository
    @ObservationIgnored internal let workspaceStateRepository: BeadWorkspaceStateRepository
    /// Set in `openProject` from the persisted payload and consumed once by `applyLoadedProject`
    /// after the index loads, so restoration runs a single time per open (not on live reloads).
    @ObservationIgnored internal var pendingRestoredWorkspaceSnapshot: BeadWorkspaceSnapshot?
    @ObservationIgnored internal var workspaceStatePersistTask: Task<Void, Never>?
    internal var refreshTask: Task<Void, Never>? { get { project.refreshTask } set { project.refreshTask = newValue } }
    internal var initializationTask: Task<Void, Never>? { get { project.initializationTask } set { project.initializationTask = newValue } }
    internal var reconcileDebounceTask: Task<Void, Never>? { get { project.reconcileDebounceTask } set { project.reconcileDebounceTask = newValue } }
    internal var activeMutationCount: Int { get { mutations.activeMutationCount } set { mutations.activeMutationCount = newValue } }
    internal var reconcileState: SnapshotReconcileState { get { project.reconcileState } set { project.reconcileState = newValue } }
    internal var filterTask: Task<Void, Never>? { get { workspace.filterTask } set { workspace.filterTask = newValue } }
    internal var recomputeTask: Task<Void, Never>? { get { workspace.recomputeTask } set { workspace.recomputeTask = newValue } }
    internal var queryGeneration: Int { get { workspace.queryGeneration } set { workspace.queryGeneration = newValue } }
    internal var pendingQueryRecomputeRequest: BeadQueryRecomputeRequest? {
        get { workspace.pendingQueryRecomputeRequest }
        set { workspace.pendingQueryRecomputeRequest = newValue }
    }
    internal var savedViewCountTask: Task<Void, Never>? { get { workspace.savedViewCountTask } set { workspace.savedViewCountTask = newValue } }
    internal var savedViewCountGeneration: Int { get { workspace.savedViewCountGeneration } set { workspace.savedViewCountGeneration = newValue } }
    internal var sidebarSelectionTask: Task<Void, Never>? { get { workspace.sidebarSelectionTask } set { workspace.sidebarSelectionTask = newValue } }
    internal var selectionSideDataTask: Task<Void, Never>? { get { detail.selectionSideDataTask } set { detail.selectionSideDataTask = newValue } }
    internal var commentLoadTask: Task<Void, Never>? { get { detail.commentLoadTask } set { detail.commentLoadTask = newValue } }
    internal var activityLoadTask: Task<Void, Never>? { get { detail.activityLoadTask } set { detail.activityLoadTask = newValue } }
    internal var gateDetailTask: Task<Void, Never>? { get { detail.gateDetailTask } set { detail.gateDetailTask = newValue } }
    internal var projectHealthTask: Task<Void, Never>? { get { project.projectHealthTask } set { project.projectHealthTask = newValue } }
    internal var projectionMaterializationTask: Task<Void, Never>? {
        get { project.projectionMaterializationTask }
        set { project.projectionMaterializationTask = newValue }
    }
    internal var projectionGeneration: Int {
        get { project.projectionGeneration }
        set { project.projectionGeneration = newValue }
    }
    internal var projectionMaterializer: BeadProjectionMaterializer { project.projectionMaterializer }
    internal var dataSourceMonitor: BeadsDataSourceMonitor? { get { project.dataSourceMonitor } set { project.dataSourceMonitor = newValue } }
    internal var monitoredSourceFingerprint: String? { get { project.monitoredSourceFingerprint } set { project.monitoredSourceFingerprint = newValue } }
    /// Cached status/type definitions, reused across reloads so routine reloads don't
    /// spawn two `bd --readonly` subprocesses. Reloaded on initial/manual refresh, and
    /// after the app edits custom definitions (which set this back to `nil`). A `nil` cache
    /// forces the next reload to re-read from `bd`, so a failed reload naturally retries.
    internal var cachedDefinitions: BeadSemanticDefinitions? { get { project.cachedDefinitions } set { project.cachedDefinitions = newValue } }
    internal var lastServerActivationRefreshAt: Date? {
        get { project.lastServerActivationRefreshAt }
        set { project.lastServerActivationRefreshAt = newValue }
    }
    internal var commentCache: [String: [BeadComment]] { get { detail.commentCache } set { detail.commentCache = newValue } }
    internal var activityEvents: [BeadIssueEvent] { get { detail.activityEvents } set { detail.activityEvents = newValue } }
    internal var activityLoadedIssueID: String? { get { detail.activityLoadedIssueID } set { detail.activityLoadedIssueID = newValue } }
    internal var outlineState: BeadOutlineSelectionState { get { workspace.outlineState } set { workspace.outlineState = newValue } }
    internal var workspaceHistory: BeadWorkspaceHistory { get { workspace.workspaceHistory } set { workspace.workspaceHistory = newValue } }
    internal var isRestoringWorkspace: Bool { get { workspace.isRestoringWorkspace } set { workspace.isRestoringWorkspace = newValue } }
    internal var isLoadingProjectPreferences: Bool { get { project.isLoadingProjectPreferences } set { project.isLoadingProjectPreferences = newValue } }
    internal var suppressesHistoryRecording: Bool { get { workspace.suppressesHistoryRecording } set { workspace.suppressesHistoryRecording = newValue } }
    internal var suppressesFilterUpdates: Bool { get { workspace.suppressesFilterUpdates } set { workspace.suppressesFilterUpdates = newValue } }
    internal var stateLabelOverridesByIssueID: [String: [String: BeadStateLabelOverride]] {
        get { project.stateLabelOverridesByIssueID }
        set { project.stateLabelOverridesByIssueID = newValue }
    }
    @ObservationIgnored internal let userDefaults: UserDefaults

    internal var index: BeadProjectIndex { get { project.index } set { project.index = newValue } }
    internal var authoritativeIndex: BeadProjectIndex {
        get { project.authoritativeIndex }
        set { project.authoritativeIndex = newValue }
    }

    var hierarchyMutationPolicy: BeadHierarchyMutationPolicy {
        BeadHierarchyMutationPolicy(index: index)
    }

    internal static let lastProjectPathKey = "LastProjectPath"
    internal static let recentProjectPathsKey = "RecentProjectPaths"
    internal static let maxRecentProjectCount = 8

    init(
        userDefaults: UserDefaults = .standard,
        commands: any BeadsCommanding = BeadsCommandService(),
        activityHistoryRepository: BeadActivityHistoryRepository = BeadActivityHistoryRepository()
    ) {
        self.userDefaults = userDefaults
        self.commands = commands
        self.projectLoader = BeadProjectLoader(commands: commands)
        self.activityHistoryRepository = activityHistoryRepository
        self.savedViewRepository = BeadSavedViewRepository(userDefaults: userDefaults)
        self.workspaceStateRepository = BeadWorkspaceStateRepository(userDefaults: userDefaults)
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
        hasReadableProject
            && selectedBookmark != .gates
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
