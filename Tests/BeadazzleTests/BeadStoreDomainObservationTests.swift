import Observation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadStoreDomainObservationTests: XCTestCase {
    func testSelectionActionUpdatesWorkspaceDomain() {
        let store = BeadStore(userDefaults: makeUserDefaults())

        store.select(["bd-1"])

        XCTAssertEqual(store.selectedIDs, ["bd-1"])
        XCTAssertEqual(store.workspace.selectedIDs, ["bd-1"])
    }

    func testWorkspaceMutationDoesNotInvalidateProjectObservation() {
        let store = BeadStore(userDefaults: makeUserDefaults())
        let unexpectedInvalidation = expectation(description: "Project observation remains isolated")
        unexpectedInvalidation.isInverted = true

        withObservationTracking {
            _ = store.project.projectURL
        } onChange: {
            unexpectedInvalidation.fulfill()
        }

        store.select(["bd-1"])
        wait(for: [unexpectedInvalidation], timeout: 0.01)
    }

    func testDetailMutationDoesNotInvalidateWorkspaceObservation() {
        let store = BeadStore(userDefaults: makeUserDefaults())
        let unexpectedInvalidation = expectation(description: "Workspace observation remains isolated")
        unexpectedInvalidation.isInverted = true

        withObservationTracking {
            _ = store.workspace.selectedIDs
        } onChange: {
            unexpectedInvalidation.fulfill()
        }

        store._isLoadingComments = true
        XCTAssertTrue(store.detail.isLoadingComments)
        wait(for: [unexpectedInvalidation], timeout: 0.01)
    }

    func testFacadeProjectReadTracksProjectRegistrar() {
        let store = BeadStore(userDefaults: makeUserDefaults())
        let invalidation = expectation(description: "Facade forwards project observation")

        withObservationTracking {
            _ = store.projectURL
        } onChange: {
            invalidation.fulfill()
        }

        store.openProject(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
        wait(for: [invalidation], timeout: 0.1)
        XCTAssertEqual(store.project.projectURL, store.projectURL)
    }

    func testIndexReplacementInvalidatesIssueReferenceLookupObservation() async {
        let store = BeadStore(userDefaults: makeUserDefaults())
        let invalidation = expectation(description: "Issue-reference lookup invalidates")

        withObservationTracking {
            _ = store.project.issueReferenceLookup
        } onChange: {
            invalidation.fulfill()
        }

        store.applyOptimisticState(issues: [makeIssue(id: "bd-new")], dependencies: [])
        await fulfillment(of: [invalidation], timeout: 0.1)
        XCTAssertTrue(store.project.issueReferenceLookup.issueIDs.contains("bd-new"))
    }

    func testProjectSwitchCancelsTrackedInitialization() {
        let store = BeadStore(userDefaults: makeUserDefaults())
        let initializationTask = Task { _ = try? await Task.sleep(for: .seconds(10)) }
        store.initializationTask = initializationTask

        store.openProject(temporaryProjectURL())

        XCTAssertTrue(initializationTask.isCancelled)
        XCTAssertNil(store.initializationTask)
    }

    func testStaleRefreshCannotTerminateNewProjectReconciliation() {
        let store = BeadStore(userDefaults: makeUserDefaults())
        let oldProjectURL = temporaryProjectURL()
        store.openProject(oldProjectURL)
        let oldGeneration = store.project.beginRefresh()

        let newProjectURL = temporaryProjectURL()
        store.openProject(newProjectURL)
        let newGeneration = store.project.beginRefresh()
        store.reconcileState.request(.mutation)
        XCTAssertTrue(store.reconcileState.beginIfPossible(activeMutationCount: 0))

        store.finishReconcileAfterRefreshTermination(
            projectURL: oldProjectURL,
            refreshGeneration: oldGeneration
        )
        XCTAssertTrue(store.reconcileState.isInFlight)

        store.finishReconcileAfterRefreshTermination(
            projectURL: newProjectURL,
            refreshGeneration: newGeneration
        )
        XCTAssertFalse(store.reconcileState.isInFlight)
    }

    func testCoordinatedIndexReplacementUpdatesDomainsExactlyOnce() async {
        let store = BeadStore(userDefaults: makeUserDefaults())
        store.applyOptimisticState(issues: [makeIssue(id: "bd-old")], dependencies: [])
        await store.waitForPendingQueryRecompute()
        store.applyBookmark(.all)
        await store.waitForPendingQueryRecompute()
        store.select(["bd-old"])
        let previousRevision = store.contentRevision

        store.applyOptimisticState(issues: [makeIssue(id: "bd-new")], dependencies: [])
        await store.waitForPendingQueryRecompute()

        XCTAssertNil(store.recomputeTask)
        XCTAssertEqual(store.contentRevision, previousRevision + 1)
        XCTAssertEqual(store.project.index.allIssueIDs, ["bd-new"])
        XCTAssertEqual(store.workspace.selectedIDs, [])
        XCTAssertEqual(store.workspace.issueListRows.map(\.issueID), ["bd-new"])
        XCTAssertEqual(store.detail.dependencies, [])
    }

    private func makeIssue(id: String) -> BeadIssue {
        BeadIssue(
            id: id,
            title: id,
            description: "",
            design: "",
            acceptanceCriteria: "",
            notes: "",
            status: "open",
            priority: 2,
            issueType: "task",
            labels: [],
            dependencyCount: 0,
            dependentCount: 0,
            commentCount: 0,
            pinned: false,
            ephemeral: false,
            isTemplate: false
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "BeadStoreDomainObservationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func temporaryProjectURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }
}
