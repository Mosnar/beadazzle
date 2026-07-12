import Foundation

extension BeadStore {
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
        _gateClock = now
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

}
