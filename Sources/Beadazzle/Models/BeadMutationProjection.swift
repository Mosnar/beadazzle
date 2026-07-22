import Foundation

struct BeadMutationSubmission: Sendable {
    let completion: Task<Bool, Never>

    var value: Bool {
        get async { await completion.value }
    }
}

struct BeadCreateSubmission: Sendable {
    let issueID: String
    let completion: Task<Bool, Never>

    var value: Bool {
        get async { await completion.value }
    }
}

enum BeadMutationValue<Value: Sendable>: Sendable {
    case unchanged
    case set(Value)

    func replacing(with newer: Self) -> Self {
        switch newer {
        case .unchanged:
            self
        case .set:
            newer
        }
    }
}

/// A sparse, composable update to one issue. Optional-valued fields use
/// `BeadMutationValue` so "leave unchanged" remains distinct from "set nil".
struct BeadIssueMutationPatch: Sendable {
    var title: BeadMutationValue<String> = .unchanged
    var description: BeadMutationValue<String> = .unchanged
    var design: BeadMutationValue<String> = .unchanged
    var acceptanceCriteria: BeadMutationValue<String> = .unchanged
    var notes: BeadMutationValue<String> = .unchanged
    var status: BeadMutationValue<String> = .unchanged
    var priority: BeadMutationValue<Int> = .unchanged
    var issueType: BeadMutationValue<String> = .unchanged
    var assignee: BeadMutationValue<String?> = .unchanged
    var owner: BeadMutationValue<String?> = .unchanged
    var updatedAt: BeadMutationValue<Date?> = .unchanged
    var closedAt: BeadMutationValue<Date?> = .unchanged
    var closeReason: BeadMutationValue<String?> = .unchanged
    var dueAt: BeadMutationValue<Date?> = .unchanged
    var deferUntil: BeadMutationValue<Date?> = .unchanged
    var externalRef: BeadMutationValue<String?> = .unchanged
    var parentID: BeadMutationValue<String?> = .unchanged
    var labels: BeadMutationValue<[String]> = .unchanged
    var pinned: BeadMutationValue<Bool> = .unchanged

    func merging(_ newer: Self) -> Self {
        Self(
            title: title.replacing(with: newer.title),
            description: description.replacing(with: newer.description),
            design: design.replacing(with: newer.design),
            acceptanceCriteria: acceptanceCriteria.replacing(with: newer.acceptanceCriteria),
            notes: notes.replacing(with: newer.notes),
            status: status.replacing(with: newer.status),
            priority: priority.replacing(with: newer.priority),
            issueType: issueType.replacing(with: newer.issueType),
            assignee: assignee.replacing(with: newer.assignee),
            owner: owner.replacing(with: newer.owner),
            updatedAt: updatedAt.replacing(with: newer.updatedAt),
            closedAt: closedAt.replacing(with: newer.closedAt),
            closeReason: closeReason.replacing(with: newer.closeReason),
            dueAt: dueAt.replacing(with: newer.dueAt),
            deferUntil: deferUntil.replacing(with: newer.deferUntil),
            externalRef: externalRef.replacing(with: newer.externalRef),
            parentID: parentID.replacing(with: newer.parentID),
            labels: labels.replacing(with: newer.labels),
            pinned: pinned.replacing(with: newer.pinned)
        )
    }

    func applying(to issue: BeadIssue) -> BeadIssue {
        var copy = issue
        if case .set(let value) = title { copy.title = value }
        if case .set(let value) = description { copy.description = value }
        if case .set(let value) = design { copy.design = value }
        if case .set(let value) = acceptanceCriteria { copy.acceptanceCriteria = value }
        if case .set(let value) = notes { copy.notes = value }
        if case .set(let value) = status { copy.status = value }
        if case .set(let value) = priority { copy.priority = value }
        if case .set(let value) = issueType { copy.issueType = value }
        if case .set(let value) = assignee { copy.assignee = value }
        if case .set(let value) = owner { copy.owner = value }
        if case .set(let value) = updatedAt { copy.updatedAt = value }
        if case .set(let value) = closedAt { copy.closedAt = value }
        if case .set(let value) = closeReason { copy.closeReason = value }
        if case .set(let value) = dueAt { copy.dueAt = value }
        if case .set(let value) = deferUntil { copy.deferUntil = value }
        if case .set(let value) = externalRef { copy.externalRef = value }
        if case .set(let value) = parentID { copy.parentID = value }
        if case .set(let value) = labels { copy.labels = value }
        if case .set(let value) = pinned { copy.pinned = value }
        return copy
    }
}

enum BeadProjectedIssueChange: Sendable {
    case insert(BeadIssue)
    case update(BeadIssueMutationPatch)
    case delete
}

struct BeadMutationProjectionEntry: Identifiable, Sendable {
    enum Settlement: Sendable {
        case pending
        case succeeded
    }

    let id: UUID
    var issueChanges: [String: BeadProjectedIssueChange]
    var addedDependencies: [BeadDependency]
    var removedDependencies: [BeadDependency]
    var settlement: Settlement

    init(
        id: UUID = UUID(),
        issueChanges: [String: BeadProjectedIssueChange] = [:],
        addedDependencies: [BeadDependency] = [],
        removedDependencies: [BeadDependency] = [],
        settlement: Settlement = .pending
    ) {
        self.id = id
        self.issueChanges = issueChanges
        self.addedDependencies = addedDependencies
        self.removedDependencies = removedDependencies
        self.settlement = settlement
    }

    func mergingSucceededEntry(_ newer: Self) -> Self {
        var mergedChanges = issueChanges
        for (issueID, newerChange) in newer.issueChanges {
            guard let olderChange = mergedChanges[issueID] else {
                mergedChanges[issueID] = newerChange
                continue
            }
            switch (olderChange, newerChange) {
            case (.insert(let issue), .update(let patch)):
                mergedChanges[issueID] = .insert(patch.applying(to: issue))
            case (.update(let olderPatch), .update(let newerPatch)):
                mergedChanges[issueID] = .update(olderPatch.merging(newerPatch))
            case (_, .insert), (_, .delete):
                mergedChanges[issueID] = newerChange
            case (.delete, .update):
                mergedChanges[issueID] = .delete
            }
        }

        var additions = Set(addedDependencies)
        var removals = Set(removedDependencies)
        for dependency in newer.removedDependencies {
            additions.remove(dependency)
            removals.insert(dependency)
        }
        for dependency in newer.addedDependencies {
            removals.remove(dependency)
            additions.insert(dependency)
        }
        return Self(
            id: id,
            issueChanges: mergedChanges,
            addedDependencies: Array(additions),
            removedDependencies: Array(removals),
            settlement: .succeeded
        )
    }
}

/// Ordered optimistic state layered over the most recent authoritative snapshot.
/// The journal is intentionally sparse: foreground mutation work is proportional to
/// the number of touched issues/relationships, never the tracker size.
struct BeadMutationProjection: Sendable {
    private(set) var entries: [BeadMutationProjectionEntry] = []

    var isEmpty: Bool { entries.isEmpty }

    mutating func append(_ entry: BeadMutationProjectionEntry) {
        entries.append(entry)
    }

    mutating func markSucceeded(_ id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[index].settlement = .succeeded
        compactSucceededEntries()
        return true
    }

    private mutating func compactSucceededEntries() {
        guard entries.count > 1 else { return }
        var compacted: [BeadMutationProjectionEntry] = []
        compacted.reserveCapacity(entries.count)
        for entry in entries {
            if let previous = compacted.last,
               case .succeeded = previous.settlement,
               case .succeeded = entry.settlement {
                compacted[compacted.count - 1] = previous.mergingSucceededEntry(entry)
            } else {
                compacted.append(entry)
            }
        }
        entries = compacted
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    mutating func reconcile(authoritative: Bool) {
        guard authoritative else { return }
        entries.removeAll { entry in
            if case .succeeded = entry.settlement { return true }
            return false
        }
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: false)
    }

    func issue(with id: String, in base: BeadProjectIndex) -> BeadIssue? {
        var issue = base.issue(with: id)
        for entry in entries {
            guard let change = entry.issueChanges[id] else { continue }
            switch change {
            case .insert(let inserted):
                issue = inserted
            case .update(let patch):
                if let current = issue {
                    issue = patch.applying(to: current)
                }
            case .delete:
                issue = nil
            }
        }
        return issue
    }

    func dependencies(for issueID: String, in base: BeadProjectIndex) -> [BeadDependency] {
        var dependencies = base.dependenciesByIssueID[issueID] ?? []
        var dependencySet = Set(dependencies)
        for entry in entries {
            if !entry.removedDependencies.isEmpty {
                let removals = Set(entry.removedDependencies.filter { $0.issueID == issueID })
                dependencies.removeAll { removals.contains($0) }
                dependencySet.subtract(removals)
            }
            for dependency in entry.addedDependencies
            where dependency.issueID == issueID && dependencySet.insert(dependency).inserted {
                dependencies.append(dependency)
            }
        }
        return dependencies
    }

    func dependencies(touching issueIDs: Set<String>, in base: BeadProjectIndex) -> [BeadDependency] {
        var dependencySet: Set<BeadDependency> = []
        for issueID in issueIDs {
            dependencySet.formUnion(base.dependenciesByIssueID[issueID] ?? [])
            dependencySet.formUnion(base.dependentsByIssueID[issueID] ?? [])
        }
        for entry in entries {
            dependencySet.subtract(entry.removedDependencies)
            dependencySet.formUnion(entry.addedDependencies.filter {
                issueIDs.contains($0.issueID) || issueIDs.contains($0.dependsOnID)
            })
        }
        return Array(dependencySet)
    }

    func materialized(over base: BeadProjectIndex) -> (issues: [BeadIssue], dependencies: [BeadDependency]) {
        materialized(over: base, shouldCancel: { false })!
    }

    func materialized(
        over base: BeadProjectIndex,
        shouldCancel: @Sendable () -> Bool
    ) -> (issues: [BeadIssue], dependencies: [BeadDependency])? {
        var issues = base.issues
        var offsetsByID: [String: Int] = [:]
        offsetsByID.reserveCapacity(issues.count)
        for (offset, issue) in issues.enumerated() {
            if offset.isMultiple(of: 256), shouldCancel() { return nil }
            offsetsByID[issue.id] = offset
        }
        var deletedIssueIDs: Set<String> = []

        for entry in entries {
            if shouldCancel() { return nil }
            for (issueID, change) in entry.issueChanges {
                switch change {
                case .insert(let issue):
                    deletedIssueIDs.remove(issueID)
                    if let offset = offsetsByID[issueID] {
                        issues[offset] = issue
                    } else {
                        offsetsByID[issueID] = issues.endIndex
                        issues.append(issue)
                    }
                case .update(let patch):
                    guard let offset = offsetsByID[issueID], !deletedIssueIDs.contains(issueID) else {
                        continue
                    }
                    issues[offset] = patch.applying(to: issues[offset])
                case .delete:
                    deletedIssueIDs.insert(issueID)
                }
            }
        }
        if !deletedIssueIDs.isEmpty {
            var retainedIssues: [BeadIssue] = []
            retainedIssues.reserveCapacity(issues.count - min(issues.count, deletedIssueIDs.count))
            for (offset, issue) in issues.enumerated() {
                if offset.isMultiple(of: 256), shouldCancel() { return nil }
                if !deletedIssueIDs.contains(issue.id) {
                    retainedIssues.append(issue)
                }
            }
            issues = retainedIssues
        }

        var dependencies = base.dependencies
        var dependencySet = Set(dependencies)
        for entry in entries {
            if shouldCancel() { return nil }
            if !entry.removedDependencies.isEmpty {
                let removals = Set(entry.removedDependencies)
                var retainedDependencies: [BeadDependency] = []
                retainedDependencies.reserveCapacity(dependencies.count)
                for (offset, dependency) in dependencies.enumerated() {
                    if offset.isMultiple(of: 256), shouldCancel() { return nil }
                    if !removals.contains(dependency) {
                        retainedDependencies.append(dependency)
                    }
                }
                dependencies = retainedDependencies
                dependencySet.subtract(removals)
            }
            for dependency in entry.addedDependencies where dependencySet.insert(dependency).inserted {
                dependencies.append(dependency)
            }
        }
        return (issues, dependencies)
    }
}

/// Serializes full index materialization so rapid edits can coalesce without leaving
/// multiple database-sized rebuilds competing for CPU and memory.
actor BeadProjectionMaterializer {
    func materialize(
        projection: BeadMutationProjection,
        over base: BeadProjectIndex,
        previousIndex: BeadProjectIndex,
        staleCutoffDays: Int,
        hidesParentsWithOnlyBlockedChildrenInReady: Bool
    ) -> BeadProjectIndex? {
        guard !Task.isCancelled,
              let materialized = projection.materialized(
                over: base,
                shouldCancel: { Task.isCancelled }
              ),
              !Task.isCancelled else {
            return nil
        }
        return BeadProjectIndex(
            issues: materialized.issues,
            dependencies: materialized.dependencies,
            semantics: base.semantics,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
            reusingSearchTextFrom: previousIndex
        )
    }
}
