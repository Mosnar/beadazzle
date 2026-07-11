import Foundation

enum SnapshotReconcileTrigger: Hashable, Sendable {
    case mutation
    case externalMarker
}

struct SnapshotReconcileState: Equatable, Sendable {
    private(set) var pendingTriggers: Set<SnapshotReconcileTrigger> = []
    private(set) var isInFlight = false
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

    mutating func beginIfPossible(activeMutationCount: Int) -> Bool {
        guard hasPendingRequest, activeMutationCount == 0, !isInFlight else { return false }
        pendingTriggers.removeAll()
        isInFlight = true
        return true
    }

    mutating func cancelInFlightForMutation() -> Bool {
        guard isInFlight else { return false }
        isInFlight = false
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
        deferredMonitorRoles.removeAll()
        return roles
    }

    mutating func terminate() {
        isInFlight = false
        deferredMonitorRoles.removeAll()
    }

    mutating func reset() {
        pendingTriggers.removeAll()
        terminate()
    }
}
