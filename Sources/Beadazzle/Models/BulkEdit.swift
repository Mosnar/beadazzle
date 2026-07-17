import Foundation

enum BulkEditTarget: Hashable, Sendable {
    case addLabels
    case setProperty(dimension: String)
}

enum BulkEditPayload: Equatable, Sendable {
    case addLabels(BulkAddLabelsContext)
    case setProperty(dimension: String, context: BulkSetPropertyContext)
}

struct BulkEditRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let projectURL: URL
    let issueIDs: [String]
    let payload: BulkEditPayload
}

/// Stable, bead-sized progress shared by every bulk editor. A command may update
/// several beads at once, but progress only advances when the final command for a
/// bead has settled so the totals remain meaningful across different backends.
struct BulkMutationProgress: Equatable, Sendable {
    private(set) var completedCount: Int
    let totalCount: Int
    private(set) var succeededCount: Int
    private(set) var failedCount: Int

    init(
        completedCount: Int = 0,
        totalCount: Int,
        succeededCount: Int = 0,
        failedCount: Int = 0
    ) {
        self.completedCount = completedCount
        self.totalCount = max(0, totalCount)
        self.succeededCount = succeededCount
        self.failedCount = failedCount
    }

    var remainingCount: Int {
        max(0, totalCount - completedCount)
    }

    mutating func recordCompletion(succeeded: Bool) {
        guard completedCount < totalCount else { return }
        completedCount += 1
        if succeeded {
            succeededCount += 1
        } else {
            failedCount += 1
        }
    }
}

enum BulkMutationOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case superseded
    case rejected
}

/// One failed command and the beads it targeted. Keeping each command separate
/// lets the error dialog preserve exact diagnostics without losing later failures.
struct BulkMutationFailureDetail: Equatable, Sendable {
    let issueIDs: [String]
    let command: String?
    let output: String

    init(issueIDs: [String], error: Error) {
        self.issueIDs = Array(Set(issueIDs)).sorted()
        if case let BeadError.commandFailed(command, output) = error {
            self.command = command
            self.output = output
        } else {
            command = nil
            output = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Bounded diagnostic storage for a potentially unbounded number of failures.
/// Retry targeting and counts stay exact, while command output is capped so a
/// broken CLI cannot make a 10,000-bead operation retain 10,000 large strings.
struct BulkMutationFailureCollection: Sendable {
    static let maximumDetailedFailures = 50

    private(set) var commandCount = 0
    private(set) var issueIDs: Set<String> = []
    private(set) var details: [BulkMutationFailureDetail] = []

    var isEmpty: Bool { commandCount == 0 }
    var failedIssueIDs: [String] { issueIDs.sorted() }
    var omittedDetailCount: Int { max(0, commandCount - details.count) }

    mutating func record(issueIDs: [String], error: Error) {
        commandCount += 1
        self.issueIDs.formUnion(issueIDs)
        guard details.count < Self.maximumDetailedFailures else { return }
        details.append(BulkMutationFailureDetail(issueIDs: issueIDs, error: error))
    }
}

struct BulkMutationResult: Equatable, Sendable {
    let progress: BulkMutationProgress
    let outcome: BulkMutationOutcome
    let failures: [BulkMutationFailureDetail]
    let failedIssueIDs: [String]
    let failureCount: Int

    init(
        progress: BulkMutationProgress,
        outcome: BulkMutationOutcome,
        failures: [BulkMutationFailureDetail],
        failedIssueIDs: [String]? = nil,
        failureCount: Int? = nil
    ) {
        self.progress = progress
        self.outcome = outcome
        self.failures = failures
        self.failedIssueIDs = failedIssueIDs
            ?? Array(Set(failures.flatMap(\.issueIDs))).sorted()
        self.failureCount = max(failures.count, failureCount ?? failures.count)
    }

    var isSuccessful: Bool {
        outcome == .completed && failureCount == 0
    }
}

/// Immutable, selection-sized summary built once when the sheet opens. Search-field
/// updates stay proportional to the label catalog rather than rescanning every bead.
struct BulkAddLabelsContext: Equatable, Sendable {
    let issueCount: Int
    let availableLabels: [String]
    let managedDimensions: Set<String>
    private let coverageByLabel: [String: Int]
    private let availableLabelByFoldedName: [String: String]
    private let availableLabelSet: Set<String>

    init(
        issues: [BeadIssue],
        availableLabels: [String],
        managedDimensions: Set<String>
    ) {
        issueCount = issues.count
        self.managedDimensions = managedDimensions
        self.availableLabels = availableLabels.filter { label in
            guard let dimension = BeadStateLabel.dimension(of: label) else { return true }
            return !managedDimensions.contains(dimension)
        }

        var coverage: [String: Int] = [:]
        for issue in issues {
            for label in Set(issue.labels) {
                coverage[label, default: 0] += 1
            }
        }
        coverageByLabel = coverage
        availableLabelSet = Set(self.availableLabels)
        availableLabelByFoldedName = self.availableLabels.reduce(into: [:]) { result, label in
            let key = Self.folded(label)
            if result[key] == nil {
                result[key] = label
            }
        }
    }

    func coverageCount(for label: String) -> Int {
        coverageByLabel[label, default: 0]
    }

    func queryState(for query: String) -> BulkLabelQueryState {
        let normalizedLabels = IssueDraft.normalizedLabels(query)
        let usesManagedProperty = normalizedLabels.contains { label in
            guard let dimension = BeadStateLabel.dimension(of: label) else { return false }
            return managedDimensions.contains(dimension)
        }
        let resolvedLabels = normalizedLabels.map { label in
            availableLabelByFoldedName[Self.folded(label)] ?? label
        }
        let canCreate = !normalizedLabels.isEmpty
            && !usesManagedProperty
            && normalizedLabels.contains { availableLabelByFoldedName[Self.folded($0)] == nil }
        return BulkLabelQueryState(
            resolvedLabels: resolvedLabels,
            usesManagedProperty: usesManagedProperty,
            canCreate: canCreate
        )
    }

    func visibleLabels(query: String, including selectedLabels: Set<String>) -> [String] {
        var candidates = availableLabels
        let newLabels = selectedLabels.filter { !availableLabelSet.contains($0) }
        if !newLabels.isEmpty {
            candidates.append(contentsOf: newLabels)
            candidates.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.localizedStandardContains(query) }
    }

    private static func folded(_ label: String) -> String {
        label.folding(options: .caseInsensitive, locale: .current)
    }
}

struct BulkLabelQueryState: Equatable, Sendable {
    let resolvedLabels: [String]
    let usesManagedProperty: Bool
    let canCreate: Bool
}

/// Immutable property summary. Counting how many beads would change is O(1) for
/// every picker update, even when the request targets thousands of beads.
struct BulkSetPropertyContext: Equatable, Sendable {
    let issueCount: Int
    let displayName: String
    let currentSummary: String
    let catalog: BeadStateValueCatalog
    let candidateValues: [BeadStateValuePresentation]
    private let currentValueCounts: [String: Int]
    private let displayNamesByValue: [String: String]

    init(
        issueCount: Int,
        displayName: String,
        currentSummary: String,
        catalog: BeadStateValueCatalog,
        candidateValues: [BeadStateValuePresentation],
        currentValueCounts: [String: Int]
    ) {
        self.issueCount = issueCount
        self.displayName = displayName
        self.currentSummary = currentSummary
        self.catalog = catalog
        self.candidateValues = candidateValues
        self.currentValueCounts = currentValueCounts
        displayNamesByValue = Dictionary(
            uniqueKeysWithValues: (catalog.active + catalog.archived).map { ($0.value, $0.displayName) }
        )
    }

    func changedIssueCount(for value: String) -> Int {
        issueCount - currentValueCounts[value, default: 0]
    }

    func displayName(for value: String) -> String {
        displayNamesByValue[value] ?? value
    }
}
