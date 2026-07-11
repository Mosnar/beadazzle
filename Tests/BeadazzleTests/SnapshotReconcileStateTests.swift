import XCTest
@testable import Beadazzle

final class SnapshotReconcileStateTests: XCTestCase {
    func testBeginRequiresPendingRequestAndNoActiveMutation() {
        var state = SnapshotReconcileState()

        XCTAssertFalse(state.beginIfPossible(activeMutationCount: 0))
        state.request(.externalMarker)
        XCTAssertFalse(state.beginIfPossible(activeMutationCount: 1))
        XCTAssertTrue(state.beginIfPossible(activeMutationCount: 0))
        XCTAssertTrue(state.isInFlight)
        XCTAssertFalse(state.hasPendingRequest)
        XCTAssertFalse(state.beginIfPossible(activeMutationCount: 0))
    }

    func testRemovingExternalRequestPreservesMutationRequest() {
        var state = SnapshotReconcileState()
        state.request(.externalMarker)
        state.request(.mutation)

        state.removeExternalMarkerRequest()

        XCTAssertEqual(state.pendingTriggers, [.mutation])
    }

    func testSuccessfulCompletionReplaysDeferredMonitorRoles() {
        var state = SnapshotReconcileState()
        state.request(.externalMarker)
        XCTAssertTrue(state.beginIfPossible(activeMutationCount: 0))
        XCTAssertTrue(state.deferMonitorEvent([.activeSource, .exportState]))

        let roles = state.complete(replaysDeferredEvents: true)

        XCTAssertEqual(roles, [.activeSource, .exportState])
        XCTAssertFalse(state.isInFlight)
    }

    func testFailedCompletionAndMutationCancellationDiscardDeferredRoles() {
        var failedState = SnapshotReconcileState()
        failedState.request(.externalMarker)
        XCTAssertTrue(failedState.beginIfPossible(activeMutationCount: 0))
        XCTAssertTrue(failedState.deferMonitorEvent([.lastTouched]))
        XCTAssertTrue(failedState.complete(replaysDeferredEvents: false).isEmpty)

        var cancelledState = SnapshotReconcileState()
        cancelledState.request(.externalMarker)
        XCTAssertTrue(cancelledState.beginIfPossible(activeMutationCount: 0))
        XCTAssertTrue(cancelledState.deferMonitorEvent([.lastTouched]))
        XCTAssertTrue(cancelledState.cancelInFlightForMutation())
        XCTAssertTrue(cancelledState.deferredMonitorRoles.isEmpty)
    }
}
