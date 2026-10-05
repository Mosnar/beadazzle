import Foundation

enum SnapshotReconcileTrigger: Hashable, Sendable {
    case mutation
    case externalMarker
    case journalVerification
    case journalConfiguration
    case remoteSync
}

struct SnapshotReconcileState: Equatable, Sendable {
    private(set) var pendingTriggers: Set<SnapshotReconcileTrigger> = []
    private(set) var isInFlight = false
    private(set) var inFlightTriggers: Set<SnapshotReconcileTrigger> = []
    private(set) var deferredMonitorRoles: Set<BeadsDataSourceMonitor.Role> = []

    var hasPendingRequest: Bool {
        !pendingTriggers.isEmpty
    }

    mutating func request(_ trigger: SnapshotReconcileTrigger) {
        pendingTriggers.insert(trigger)
    }

    mutating func removeExternalMarkerRequest() {
        pendingTriggers.remove(.externalMarker)
    }

    mutating func removeJournalVerificationRequest() {
        pendingTriggers.remove(.journalVerification)
    }

    mutating func removeJournalConfigurationRequest() {
        pendingTriggers.remove(.journalConfiguration)
    }

    mutating func beginIfPossible(activeMutationCount: Int) -> Bool {
        guard hasPendingRequest, activeMutationCount == 0, !isInFlight else { return false }
        inFlightTriggers = pendingTriggers
        pendingTriggers.removeAll()
        isInFlight = true
        return true
    }

    mutating func cancelInFlightForMutation() -> Bool {
        guard isInFlight else { return false }
        isInFlight = false
        inFlightTriggers.removeAll()
        deferredMonitorRoles.removeAll()
        return true
    }

    mutating func deferMonitorEvent(_ roles: Set<BeadsDataSourceMonitor.Role>) -> Bool {
        guard isInFlight else { return false }
        deferredMonitorRoles.formUnion(roles)
        return true
    }

    mutating func complete(replaysDeferredEvents: Bool) -> Set<BeadsDataSourceMonitor.Role> {
        let roles = isInFlight && replaysDeferredEvents ? deferredMonitorRoles : []
        isInFlight = false
        inFlightTriggers.removeAll()
        deferredMonitorRoles.removeAll()
        return roles
    }

    mutating func terminate() {
        isInFlight = false
        inFlightTriggers.removeAll()
        deferredMonitorRoles.removeAll()
    }

    mutating func reset() {
        pendingTriggers.removeAll()
        terminate()
    }
}
