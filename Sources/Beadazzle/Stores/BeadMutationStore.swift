import Foundation
import Observation

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
    case update(adding: [String], removing: [String])
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
            return replacement
        case .replaceOrdinary(let ordinaryLabels, let dimensions):
            return BeadStateLabel.replacingOrdinaryLabels(
                in: labels,
                with: ordinaryLabels,
                preserving: dimensions
            )
        case .add(let additions):
            return Self.uniqueLabels(labels + additions)
        case .update(let additions, let removals):
            let removalSet = Set(removals)
            return Self.uniqueLabels(labels.filter { !removalSet.contains($0) } + additions)
        case .setState(let dimension, let value):
            return BeadStateLabel.applying(dimension: dimension, value: value, to: labels)
        case .clearState(let dimension):
            return BeadStateLabel.excluding(dimensions: [dimension], from: labels)
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

    init(addingLabels labelsToAdd: [String], removingLabels labelsToRemove: [String]) {
        updatesAssignee = false
        assignee = nil
        labelMutation = .update(adding: labelsToAdd, removing: labelsToRemove)
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

/// Mutation activity is UI-facing because it gates commands. The high-churn mutation
/// internals stay outside Observation so metadata edits do not invalidate unrelated views.
@Observable
@MainActor
final class BeadMutationStore {
    static let maximumPossiblyPersistedLabelsPerIssue = 256

    private(set) var activeMutationCount = 0
    @ObservationIgnored private var mutationIdleWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var optimisticMutationRevision = 0
    /// Set before a serialized command is attempted and cleared only after a readable
    /// snapshot export has completed successfully. Queue occupancy is not enough for this:
    /// a command can finish while its debounced reconcile is still waiting to run.
    @ObservationIgnored private(set) var requiresReadableSnapshotExport = false
    let writeQueue = BeadMutationWriteQueue()
    @ObservationIgnored private var optimisticMutationQueues: [Int: BeadOptimisticMutationQueue] = [:]
    @ObservationIgnored var metadataMutationGeneration = 0
    @ObservationIgnored var metadataMutations: [String: BeadMetadataMutationState] = [:]
    @ObservationIgnored private var possiblyPersistedLabelsByIssue: [String: [String]] = [:]
    @ObservationIgnored private var labelUncertaintyOverflowIssueIDs: Set<String> = []
    // Write versions identify the latest optimistic owner of each metadata field.
    @ObservationIgnored private var metadataFieldWriteVersionsByIssue: [String: BeadMetadataFieldVersions] = [:]
    // Settlements retain both callback order and source ownership so equal-value
    // rollbacks cannot revive a result from an older writer.
    @ObservationIgnored private var metadataSettlementsByIssue: [String: BeadMetadataSettlementState] = [:]
    @ObservationIgnored var projection = BeadMutationProjection()
    @ObservationIgnored var folderAutomationTail: Task<Void, Never>?
    @ObservationIgnored var cancelledFolderAutomationIDs: Set<UUID> = []

    func beginActivity() {
        activeMutationCount += 1
    }

    func endActivity() {
        activeMutationCount = max(0, activeMutationCount - 1)
        guard activeMutationCount == 0 else { return }
        resumeMutationIdleWaiters()
    }

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
        folderAutomationTail?.cancel()
        folderAutomationTail = nil
        cancelledFolderAutomationIDs = []
        metadataMutationGeneration &+= 1
        activeMutationCount = 0
        resumeMutationIdleWaiters()
        optimisticMutationRevision = 0
        requiresReadableSnapshotExport = false
        optimisticMutationQueues = [:]
        metadataMutations = [:]
        metadataFieldWriteVersionsByIssue = [:]
        metadataSettlementsByIssue = [:]
        projection.reset()
        clearPossiblyPersistedLabels()
    }

    func requireReadableSnapshotExport() {
        requiresReadableSnapshotExport = true
    }

    func confirmReadableSnapshotExport() {
        requiresReadableSnapshotExport = false
    }

    func waitUntilIdle() async {
        guard activeMutationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            mutationIdleWaiters.append(continuation)
        }
    }

    private func resumeMutationIdleWaiters() {
        let waiters = mutationIdleWaiters
        mutationIdleWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
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
