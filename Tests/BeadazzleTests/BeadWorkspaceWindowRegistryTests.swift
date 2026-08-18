import AppKit
import Foundation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadWorkspaceWindowRegistryTests: XCTestCase {
    func testPreferredDestinationOpensInCurrentWindowWhenPreferenceSaysSo() throws {
        let context = try makeContext()
        let window = context.makeWindow()
        window.store.openProject(context.projectA)
        window.store.projectOpenDestination = .currentWindow

        let openedHere = context.registry.openProject(
            context.projectB,
            from: window.store,
            destination: .preferred
        )

        XCTAssertTrue(openedHere)
        XCTAssertEqual(window.store.projectURL?.path, context.projectB.standardizedFileURL.path)
        XCTAssertTrue(context.openedRequests.isEmpty)
        XCTAssertTrue(context.destinationPrompter.requests.isEmpty)
    }

    func testPreferredDestinationPromptsByDefaultAndUsesChoiceWithoutRemembering() async throws {
        let context = try makeContext(promptResponses: [
            ProjectOpenDestinationPromptResponse(
                choice: .newWindow,
                remembersChoice: false
            )
        ])
        let window = context.makeWindow()
        window.store.openProject(context.projectA)

        let openedHere = context.registry.openProject(
            context.projectB,
            from: window.store,
            destination: .preferred
        )

        XCTAssertFalse(openedHere)
        try await waitUntil { context.openedRequests.count == 1 }
        XCTAssertEqual(window.store.projectURL?.path, context.projectA.standardizedFileURL.path)
        XCTAssertEqual(window.store.projectOpenDestination, .askEveryTime)
        XCTAssertEqual(
            context.destinationPrompter.requests,
            [
                ProjectOpenDestinationPromptRequest(
                    projectName: "Beta",
                    currentProjectName: "Alpha"
                )
            ]
        )
    }

    func testRememberingPromptChoicePersistsAndReachesPeerWindows() async throws {
        let context = try makeContext(promptResponses: [
            ProjectOpenDestinationPromptResponse(
                choice: .currentWindow,
                remembersChoice: true
            )
        ])
        let first = context.makeWindow()
        let second = context.makeWindow()
        first.store.openProject(context.projectA)

        let openedHere = context.registry.openProject(
            context.projectB,
            from: first.store,
            destination: .preferred
        )

        XCTAssertFalse(openedHere)
        try await waitUntil {
            first.store.projectURL?.standardizedFileURL == context.projectB.standardizedFileURL
        }
        XCTAssertEqual(first.store.projectOpenDestination, .currentWindow)
        XCTAssertEqual(second.store.projectOpenDestination, .currentWindow)
        XCTAssertEqual(
            context.defaults.string(forKey: BeadazzlePreferenceKeys.projectOpenDestination),
            BeadProjectOpenDestinationPreference.currentWindow.rawValue
        )
    }

    func testPreferredDestinationOpensNewWindowWhenPreferenceSaysSo() throws {
        let context = try makeContext()
        let window = context.makeWindow()
        window.store.openProject(context.projectA)
        window.store.projectOpenDestination = .newWindow

        let openedHere = context.registry.openProject(
            context.projectB,
            from: window.store,
            destination: .preferred
        )

        XCTAssertFalse(openedHere)
        XCTAssertEqual(window.store.projectURL?.path, context.projectA.standardizedFileURL.path)
        XCTAssertEqual(
            context.openedRequests.map(\.projectPath),
            [context.projectB.standardizedFileURL.path]
        )
        XCTAssertTrue(context.destinationPrompter.requests.isEmpty)
    }

    /// An empty window is the one the user is looking at, so the first project has to land
    /// there even when the preference says new window — otherwise they keep a blank window.
    func testPreferredDestinationFillsAnEmptyWindowInsteadOfOpeningAnother() throws {
        let context = try makeContext()
        let window = context.makeWindow()

        let openedHere = context.registry.openProject(
            context.projectA,
            from: window.store,
            destination: .preferred
        )

        XCTAssertTrue(openedHere)
        XCTAssertEqual(window.store.projectURL?.path, context.projectA.standardizedFileURL.path)
        XCTAssertTrue(context.openedRequests.isEmpty)
        XCTAssertTrue(context.destinationPrompter.requests.isEmpty)
    }

    func testExplicitNewWindowIgnoresCurrentWindowPreference() throws {
        let context = try makeContext()
        let window = context.makeWindow()
        window.store.openProject(context.projectA)
        window.store.projectOpenDestination = .currentWindow

        let openedHere = context.registry.openProject(
            context.projectB,
            from: window.store,
            destination: .newWindow
        )

        XCTAssertFalse(openedHere)
        XCTAssertEqual(window.store.projectURL?.path, context.projectA.standardizedFileURL.path)
        XCTAssertEqual(context.openedRequests.count, 1)
        XCTAssertTrue(context.destinationPrompter.requests.isEmpty)
    }

    /// Two windows on one project would each run their own write queue and snapshot
    /// monitor against the same tracker directory, so a duplicate open is refused.
    func testProjectAlreadyOpenElsewhereDoesNotOpenAgain() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        let second = context.makeWindow()
        first.store.openProject(context.projectA)
        second.store.openProject(context.projectB)

        let openedHere = context.registry.openProject(
            context.projectA,
            from: second.store,
            destination: .preferred
        )

        XCTAssertFalse(openedHere)
        XCTAssertEqual(second.store.projectURL?.path, context.projectB.standardizedFileURL.path)
        XCTAssertTrue(context.openedRequests.isEmpty)
        XCTAssertEqual(context.registry.windowID(showing: context.projectA), first.id)
        XCTAssertTrue(context.destinationPrompter.requests.isEmpty)
    }

    /// Picking the current project again is the user's retry path after a failed load, so
    /// it reruns the full reopen in place instead of opening another window — or worse,
    /// being swallowed as already satisfied.
    func testReopeningTheWindowsOwnProjectReloadsItInPlace() throws {
        let context = try makeContext()
        let window = context.makeWindow()
        window.store.openProject(context.projectA)
        window.store.statusFilters = ["in_progress"]

        let openedHere = context.registry.openProject(
            context.projectA,
            from: window.store,
            destination: .newWindow
        )

        XCTAssertTrue(openedHere)
        XCTAssertTrue(context.openedRequests.isEmpty)
        XCTAssertEqual(window.store.projectURL?.path, context.projectA.standardizedFileURL.path)
        // The reopen persisted and re-restored workspace state, the observable side effect
        // of a real reload rather than a swallowed request.
        XCTAssertEqual(
            BeadWorkspaceStateRepository(userDefaults: context.defaults)
                .load(projectURL: context.projectA)?
                .snapshot()
                .statusFilters,
            ["in_progress"]
        )
    }

    // MARK: - Window preparation

    /// Opening a project spawns `bd` and starts file monitors, so resolving a window's
    /// store — which SwiftUI does on every body evaluation — must not trigger any of it.
    func testResolvingAStoreDoesNotLoadAProject() throws {
        let context = try makeContext()
        let request = BeadWorkspaceWindowRequest(projectURL: context.projectA)

        let store = context.registry.store(for: request.id)

        XCTAssertNil(store.projectURL)
    }

    func testPreparingAWindowOpensTheRequestedProject() throws {
        let context = try makeContext()
        let request = BeadWorkspaceWindowRequest(projectURL: context.projectA)
        let store = context.registry.store(for: request.id)

        context.registry.prepareWindow(request.id, request: request)

        XCTAssertEqual(store.projectURL?.path, context.projectA.standardizedFileURL.path)
    }

    /// `onAppear` can fire more than once for a window; a repeat must not reload the
    /// project or throw away a project the user switched to in the meantime.
    func testPreparingAWindowTwiceLeavesTheCurrentProjectAlone() throws {
        let context = try makeContext()
        let request = BeadWorkspaceWindowRequest(projectURL: context.projectA)
        let store = context.registry.store(for: request.id)
        context.registry.prepareWindow(request.id, request: request)
        store.openProject(context.projectB)

        context.registry.prepareWindow(request.id, request: request)

        XCTAssertEqual(store.projectURL?.path, context.projectB.standardizedFileURL.path)
    }

    /// The whole second-window flow at the seam the window root drives: the request the
    /// registry hands SwiftUI, the store the new window resolves from its own identity, the
    /// project each window ends up on, what the switcher reports from both, and what closing
    /// the first one frees.
    func testOpeningASecondWindowGivesItItsOwnStoreAndProject() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        first.store.openProject(context.projectA)

        let openedHere = context.registry.openProject(
            context.projectB,
            from: first.store,
            destination: .newWindow
        )

        XCTAssertFalse(openedHere)
        let request = try XCTUnwrap(context.openedRequests.first)
        // SwiftUI creates the window: a fresh identity resolves a store, then the request is
        // prepared into it — the sequence `WorkspaceWindowRoot` performs when it appears.
        let secondID = UUID()
        let second = context.registry.store(for: secondID)
        context.registry.prepareWindow(secondID, request: request)

        XCTAssertFalse(second === first.store)
        XCTAssertEqual(second.projectURL?.path, context.projectB.standardizedFileURL.path)
        XCTAssertEqual(first.store.projectURL?.path, context.projectA.standardizedFileURL.path)
        XCTAssertTrue(
            context.registry.isProjectOpenInAnotherWindow(context.projectA, from: second)
        )
        XCTAssertTrue(
            context.registry.isProjectOpenInAnotherWindow(context.projectB, from: first.store)
        )

        context.registry.releaseWindow(first.id)

        XCTAssertEqual(second.projectURL?.path, context.projectB.standardizedFileURL.path)
        XCTAssertEqual(context.registry.windowID(showing: context.projectB), secondID)
        XCTAssertFalse(
            context.registry.isProjectOpenInAnotherWindow(context.projectA, from: second)
        )
    }

    /// A window opened for a specific project keeps it when SwiftUI swaps its presented
    /// value a beat later. A second window is where this bites hardest: it has a project it
    /// was explicitly opened with and nothing else to fall back to, so losing it to the swap
    /// leaves the user looking at a window that came up and then emptied itself.
    func testASecondWindowKeepsItsProjectWhenItsRequestIsSwapped() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        first.store.openProject(context.projectA)
        context.registry.openProject(
            context.projectB,
            from: first.store,
            destination: .newWindow
        )
        let request = try XCTUnwrap(context.openedRequests.first)
        let secondID = UUID()
        let second = context.registry.store(for: secondID)
        context.registry.prepareWindow(secondID, request: request)
        XCTAssertEqual(second.projectURL?.path, context.projectB.standardizedFileURL.path)

        // Restoration hands the window a value it never appeared with, carrying no project.
        context.registry.prepareWindow(secondID, request: BeadWorkspaceWindowRequest())

        XCTAssertTrue(context.registry.store(for: secondID) === second)
        XCTAssertEqual(second.projectURL?.path, context.projectB.standardizedFileURL.path)
        XCTAssertEqual(first.store.projectURL?.path, context.projectA.standardizedFileURL.path)
    }

    /// SwiftUI can hand a live window a different presented value after it has appeared —
    /// scene restoration swaps its own stored value in a beat after launch — without a
    /// second `onAppear`. The window's registry identity is its own, so the replacement
    /// must find the same store, still showing the project the window loaded, rather than
    /// rebinding the window to an empty one and stranding the loaded store.
    func testAReplacementRequestKeepsTheWindowsStoreAndProject() throws {
        let context = try makeContext()
        let windowID = UUID()
        let store = context.registry.store(for: windowID)
        let opened = BeadWorkspaceWindowRequest(projectURL: context.projectA)
        context.registry.prepareWindow(windowID, request: opened)
        XCTAssertEqual(store.projectURL?.path, context.projectA.standardizedFileURL.path)

        // The value restoration swaps in carries no project of its own.
        context.registry.prepareWindow(windowID, request: BeadWorkspaceWindowRequest())

        XCTAssertTrue(context.registry.store(for: windowID) === store)
        XCTAssertEqual(store.projectURL?.path, context.projectA.standardizedFileURL.path)
        XCTAssertEqual(context.registry.windowID(showing: context.projectA), windowID)
        XCTAssertFalse(
            context.registry.isProjectOpenInAnotherWindow(context.projectA, from: store)
        )
    }

    func testPreparingAWindowWithoutAProjectFallsBackToRecents() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        first.store.openProject(context.projectA)

        let request = BeadWorkspaceWindowRequest()
        let store = context.registry.store(for: request.id)
        context.registry.prepareWindow(request.id, request: request)

        XCTAssertNil(store.projectURL)
        XCTAssertEqual(
            first.store.recentProjects.map(\.path),
            [context.projectA.standardizedFileURL.path]
        )
    }

    func testPreparingAWindowSkipsAProjectAnotherWindowAlreadyShows() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        first.store.openProject(context.projectB)
        first.store.openProject(context.projectA)
        XCTAssertEqual(
            first.store.recentProjects.map(\.path),
            [context.projectA, context.projectB].map(\.standardizedFileURL.path)
        )

        let request = BeadWorkspaceWindowRequest()
        let store = context.registry.store(for: request.id)
        context.registry.prepareWindow(request.id, request: request)

        XCTAssertEqual(store.projectURL?.path, context.projectB.standardizedFileURL.path)
    }

    /// Two restored windows can carry the same recorded project. The second must not open
    /// it a second time; it takes the next untaken recent instead.
    func testPreparingADuplicateRestoredProjectFallsBackInstead() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        first.store.openProject(context.projectB)
        first.store.openProject(context.projectA)

        let request = BeadWorkspaceWindowRequest(projectURL: context.projectA)
        let store = context.registry.store(for: request.id)
        context.registry.prepareWindow(request.id, request: request)

        XCTAssertEqual(store.projectURL?.path, context.projectB.standardizedFileURL.path)
    }

    /// An explicit "open in new window" of a folder that disappeared must surface that
    /// project's failure state, not silently show an unrelated recent project. Only
    /// restoration — which decodes the request without the explicit flag — falls back.
    func testExplicitNewWindowRequestOpensAMissingFolderIntoItsFailureState() throws {
        let context = try makeContext()
        let seeded = context.makeWindow()
        seeded.store.openProject(context.projectB)
        context.registry.releaseWindow(seeded.id)
        try FileManager.default.removeItem(at: context.projectA)

        let request = BeadWorkspaceWindowRequest(
            projectURL: context.projectA,
            opensProjectExplicitly: true
        )
        let store = context.registry.store(for: request.id)
        context.registry.prepareWindow(request.id, request: request)

        XCTAssertEqual(store.projectURL?.path, context.projectA.standardizedFileURL.path)
    }

    func testExplicitFlagDoesNotSurviveEncoding() throws {
        let request = BeadWorkspaceWindowRequest(
            projectURL: URL(fileURLWithPath: "/tmp/example"),
            opensProjectExplicitly: true
        )

        let decoded = try JSONDecoder().decode(
            BeadWorkspaceWindowRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded.id, request.id)
        XCTAssertEqual(decoded.projectPath, request.projectPath)
        XCTAssertFalse(decoded.opensProjectExplicitly)
        XCTAssertFalse(decoded.forcesSnapshotExport)
    }

    /// A project folder can vanish while the app is closed. Restoration must fall back to
    /// the recents like the launch path always has, not open the missing directory into a
    /// load-error window.
    func testPreparingAWindowSkipsARestoredProjectWhoseFolderIsGone() throws {
        let context = try makeContext()
        let seeded = context.makeWindow()
        seeded.store.openProject(context.projectB)
        context.registry.releaseWindow(seeded.id)
        try FileManager.default.removeItem(at: context.projectA)

        let request = BeadWorkspaceWindowRequest(projectURL: context.projectA)
        let store = context.registry.store(for: request.id)
        context.registry.prepareWindow(request.id, request: request)

        XCTAssertEqual(store.projectURL?.path, context.projectB.standardizedFileURL.path)
    }

    func testReleasingAWindowFreesItsProjectForReuse() throws {
        let context = try makeContext()
        let window = context.makeWindow()
        window.store.openProject(context.projectA)
        XCTAssertNotNil(context.registry.windowID(showing: context.projectA))

        context.registry.releaseWindow(window.id)

        XCTAssertNil(context.registry.windowID(showing: context.projectA))
    }

    /// Filter changes persist on a debounce, so closing a window has to flush them or the
    /// last thing the user did before closing is lost.
    func testReleasingAWindowPersistsItsPendingWorkspaceState() throws {
        let context = try makeContext()
        let window = context.makeWindow()
        window.store.openProject(context.projectA)
        window.store.statusFilters = ["in_progress"]

        context.registry.releaseWindow(window.id)

        let repository = BeadWorkspaceStateRepository(userDefaults: context.defaults)
        let restored = repository.load(projectURL: context.projectA)?.snapshot()
        XCTAssertEqual(restored?.statusFilters, ["in_progress"])
    }

    /// Teardown must not hinge on SwiftUI's `onDisappear`, whose timing is undefined.
    /// Closing the `NSWindow` is the signal with real semantics.
    func testClosingTheWindowReleasesItsStore() throws {
        let context = try makeContext()
        let request = BeadWorkspaceWindowRequest()
        let store = context.registry.store(for: request.id)
        store.openProject(context.projectA)
        let window = makeWindow()
        context.registry.registerWindow(window, for: request.id)
        // Guards against passing vacuously if the store were never registered.
        XCTAssertNotNil(context.registry.windowID(showing: context.projectA))

        window.close()

        XCTAssertNil(context.registry.windowID(showing: context.projectA))
    }

    /// One `NSWindow` backs one registry entry. If a window ever reports itself under a new
    /// identity, the superseded entry has to be retired: otherwise its project stays
    /// reserved and the switcher advertises it as open in a window nobody can bring forward.
    func testReRegisteringOneWindowUnderANewIdentityRetiresTheSupersededEntry() async throws {
        let context = try makeContext()
        let supersededID = UUID()
        let supersededStore = context.registry.store(for: supersededID)
        supersededStore.openProject(context.projectA)
        let window = makeWindow()
        context.registry.registerWindow(window, for: supersededID)
        XCTAssertEqual(context.registry.windowID(showing: context.projectA), supersededID)

        let currentID = UUID()
        let currentStore = context.registry.store(for: currentID)
        context.registry.registerWindow(window, for: currentID)

        // Retirement is deferred out of the SwiftUI update pass that reports the window.
        try await waitUntil { context.registry.windowID(showing: context.projectA) == nil }
        XCTAssertFalse(
            context.registry.isProjectOpenInAnotherWindow(context.projectA, from: currentStore)
        )
        // The freed project is available again rather than permanently reserved.
        context.registry.prepareWindow(currentID, request: BeadWorkspaceWindowRequest())
        XCTAssertEqual(currentStore.projectURL?.path, context.projectA.standardizedFileURL.path)
    }

    /// `willClose` and `onDisappear` both release, and their order is not worth depending
    /// on, so a second release has to be harmless.
    func testReleasingAWindowTwiceIsHarmless() throws {
        let context = try makeContext()
        let window = context.makeWindow()
        window.store.openProject(context.projectA)

        context.registry.releaseWindow(window.id)
        context.registry.releaseWindow(window.id)

        XCTAssertNil(context.registry.windowID(showing: context.projectA))
    }

    /// A released store must stop reacting to shared-state changes; otherwise every closed
    /// window keeps doing work for the lifetime of the app.
    func testReleasedWindowsStopReceivingBroadcasts() throws {
        let context = try makeContext()
        let closed = context.makeWindow()
        let open = context.makeWindow()
        context.registry.releaseWindow(closed.id)

        open.store.showsClosedBeadsInSidebar = false

        XCTAssertTrue(closed.store.showsClosedBeadsInSidebar)
        XCTAssertFalse(open.store.showsClosedBeadsInSidebar)
    }

    /// Settings can stay bound to a closing window's store for a beat after the window
    /// goes away; a preference edited in that gap must still reach surviving windows.
    func testReleasedStoreStillBroadcastsToSurvivingWindows() throws {
        let context = try makeContext()
        let closed = context.makeWindow()
        let open = context.makeWindow()
        context.registry.releaseWindow(closed.id)

        closed.store.showsClosedBeadsInSidebar = false

        XCTAssertFalse(open.store.showsClosedBeadsInSidebar)
    }

    // MARK: - Tracker identity

    func testCanonicalRecoveryReservationSerializesDifferentStores() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        let second = context.makeWindow()
        let trackerPath = context.projectA
            .appendingPathComponent(".beads", isDirectory: true)
            .path

        XCTAssertNil(
            context.registry.reserveTrackerRecovery(
                for: first.store,
                trackerIdentityPath: trackerPath
            )
        )
        XCTAssertNotNil(
            context.registry.reserveTrackerRecovery(
                for: second.store,
                trackerIdentityPath: trackerPath
            )
        )

        context.registry.releaseTrackerRecovery(
            for: first.store,
            trackerIdentityPath: trackerPath
        )
        XCTAssertNil(
            context.registry.reserveTrackerRecovery(
                for: second.store,
                trackerIdentityPath: trackerPath
            )
        )
    }

    func testReleasingRecoveryOwnerWindowReleasesCanonicalReservation() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        let second = context.makeWindow()
        let trackerPath = context.projectA
            .appendingPathComponent(".beads", isDirectory: true)
            .path
        XCTAssertNil(
            context.registry.reserveTrackerRecovery(
                for: first.store,
                trackerIdentityPath: trackerPath
            )
        )

        context.registry.releaseWindow(first.id)

        XCTAssertNil(
            context.registry.reserveTrackerRecovery(
                for: second.store,
                trackerIdentityPath: trackerPath
            )
        )
    }

    /// Two project roots can resolve to one effective tracker (worktree redirects, routed
    /// `.beads` directories), which path-based routing cannot see until `bd context`
    /// answers. The registry repairs it at resolve time: the older binding keeps the
    /// tracker, and the newer one resigns like a duplicate restoration.
    func testProjectRootsSharingOneTrackerCollapseToASingleBinding() async throws {
        let trackerURL = try makeSharedTracker()
        let context = try makeContext(
            commands: SharedTrackerTestCommands(trackerDirectoryURL: trackerURL)
        )
        let first = context.makeWindow()
        first.store.openProject(context.projectA)
        try await waitUntil { first.store.resolvedTrackerIdentityPath != nil }

        let second = context.makeWindow()
        second.store.openProject(context.projectB)

        try await waitUntil { second.store.projectURL == nil }
        XCTAssertEqual(first.store.projectURL?.path, context.projectA.standardizedFileURL.path)
        XCTAssertEqual(second.store.projectReadiness, .noProject)
    }

    /// Automatic duplicate fallback must remember every rejected alias, not only the
    /// immediately previous one. Otherwise B falls back to C, C falls back to B, and the
    /// window continuously reloads two roots that both resolve to A's tracker.
    func testDuplicateTrackerFallbackStopsAfterRejectingEveryAlias() async throws {
        let trackerURL = try makeSharedTracker()
        let context = try makeContext(
            commands: SharedTrackerTestCommands(trackerDirectoryURL: trackerURL)
        )
        let projectC = try makeProject(named: "Gamma")
        context.defaults.set(
            [context.projectB.path, projectC.path],
            forKey: BeadStore.recentProjectPathsKey
        )

        let first = context.makeWindow()
        first.store.openProject(context.projectA)
        try await waitUntil { first.store.resolvedTrackerIdentityPath != nil }

        let second = context.makeWindow()
        second.store.openProject(context.projectB)
        XCTAssertEqual(second.store.projectURL?.path, context.projectB.standardizedFileURL.path)

        try await waitUntil { second.store.projectURL == nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(second.store.projectURL)
        XCTAssertEqual(first.store.projectURL?.path, context.projectA.standardizedFileURL.path)
    }

    // MARK: - Project switcher state

    func testProjectOpenInAnotherWindowIsReportedToTheSwitcher() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        let second = context.makeWindow()
        first.store.openProject(context.projectA)
        second.store.openProject(context.projectB)

        XCTAssertTrue(
            context.registry.isProjectOpenInAnotherWindow(context.projectA, from: second.store)
        )
        XCTAssertFalse(
            context.registry.isProjectOpenInAnotherWindow(context.projectB, from: second.store)
        )
    }

    /// The switcher already marks the asking window's own project as current, so reporting
    /// it as "open elsewhere" too would show two markers for one project.
    func testOwnProjectIsNotReportedAsOpenElsewhere() throws {
        let context = try makeContext()
        let window = context.makeWindow()
        window.store.openProject(context.projectA)

        XCTAssertFalse(
            context.registry.isProjectOpenInAnotherWindow(context.projectA, from: window.store)
        )
    }

    func testClosedWindowsProjectIsNoLongerReportedAsOpenElsewhere() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        let second = context.makeWindow()
        first.store.openProject(context.projectA)
        XCTAssertTrue(
            context.registry.isProjectOpenInAnotherWindow(context.projectA, from: second.store)
        )

        context.registry.releaseWindow(first.id)

        XCTAssertFalse(
            context.registry.isProjectOpenInAnotherWindow(context.projectA, from: second.store)
        )
    }

    /// Views observe the composition revision to know when to re-ask which projects are
    /// open elsewhere; if it doesn't move, the switcher shows stale markers. Store
    /// creation happens inside a window body's view update, so its bump lands a turn
    /// later rather than mutating observed state mid-update.
    func testWindowCompositionRevisionMovesWhenWindowsComeAndGo() async throws {
        let context = try makeContext()
        let start = context.registry.windowCompositionRevision

        let window = context.makeWindow()
        try await waitUntilRevision(of: context.registry, exceeds: start)
        let afterOpen = context.registry.windowCompositionRevision
        context.registry.releaseWindow(window.id)
        let afterClose = context.registry.windowCompositionRevision

        XCTAssertGreaterThan(afterOpen, start)
        XCTAssertGreaterThan(afterClose, afterOpen)
        // A repeat release changed nothing, so it must not look like a change either.
        context.registry.releaseWindow(window.id)
        XCTAssertEqual(context.registry.windowCompositionRevision, afterClose)
    }

    private func waitUntilRevision(
        of registry: BeadWorkspaceWindowRegistry,
        exceeds value: Int,
        timeout: TimeInterval = 3.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while registry.windowCompositionRevision <= value {
            if Date() > deadline {
                XCTFail("Timed out waiting for the composition revision to advance")
                return
            }
            await Task.yield()
        }
    }

    // MARK: - Shared app state

    func testAppPreferenceChangeReachesPeerWindows() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        let second = context.makeWindow()
        XCTAssertTrue(second.store.showsClosedBeadsInSidebar)

        first.store.showsClosedBeadsInSidebar = false

        XCTAssertFalse(second.store.showsClosedBeadsInSidebar)
    }

    func testOpenDestinationPreferenceChangeReachesPeerWindows() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        let second = context.makeWindow()

        first.store.projectOpenDestination = .newWindow

        XCTAssertEqual(second.store.projectOpenDestination, .newWindow)
    }

    func testOpeningAProjectUpdatesRecentsInPeerWindows() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        let second = context.makeWindow()

        first.store.openProject(context.projectA)

        XCTAssertEqual(
            second.store.recentProjects.map(\.path),
            [context.projectA.standardizedFileURL.path]
        )
    }

    func testRemovingARecentProjectReachesPeerWindows() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        let second = context.makeWindow()
        first.store.openProject(context.projectA)
        let recent = try XCTUnwrap(first.store.recentProjects.first)

        first.store.removeRecentProject(recent)

        XCTAssertTrue(second.store.recentProjects.isEmpty)
    }

    /// The reload path writes the values it just read back through each `didSet`, which
    /// persists them again. Without the reload guard that would rebroadcast and bounce
    /// between windows until the stack ran out, so reaching the assertions is the check.
    func testPreferenceFanOutSettlesAcrossThreeWindows() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        let second = context.makeWindow()
        let third = context.makeWindow()

        first.store.showsGatesInSidebar = false

        XCTAssertFalse(second.store.showsGatesInSidebar)
        XCTAssertFalse(third.store.showsGatesInSidebar)
        XCTAssertFalse(first.store.showsGatesInSidebar)
        XCTAssertFalse(
            context.defaults.bool(forKey: BeadazzleAppBoolPreferences.showsGatesInSidebar.key)
        )
    }

    // MARK: - Helpers

    private struct WorkspaceWindow {
        let id: UUID
        let store: BeadStore
    }

    @MainActor
    private final class RecordingProjectOpenDestinationPrompter: ProjectOpenDestinationPrompting {
        private var responses: [ProjectOpenDestinationPromptResponse]
        private(set) var requests: [ProjectOpenDestinationPromptRequest] = []

        init(responses: [ProjectOpenDestinationPromptResponse]) {
            self.responses = responses
        }

        func prompt(
            _ request: ProjectOpenDestinationPromptRequest,
            attachedTo window: NSWindow?
        ) async -> ProjectOpenDestinationPromptResponse {
            requests.append(request)
            guard !responses.isEmpty else {
                return ProjectOpenDestinationPromptResponse(
                    choice: .cancel,
                    remembersChoice: false
                )
            }
            return responses.removeFirst()
        }
    }

    @MainActor
    private final class Context {
        let registry: BeadWorkspaceWindowRegistry
        let destinationPrompter: RecordingProjectOpenDestinationPrompter
        let defaults: UserDefaults
        let projectA: URL
        let projectB: URL
        /// Windows the registry asked SwiftUI to open. Stands in for real windows, which a
        /// unit test has no scene to create.
        var openedRequests: [BeadWorkspaceWindowRequest] = []

        init(
            registry: BeadWorkspaceWindowRegistry,
            destinationPrompter: RecordingProjectOpenDestinationPrompter,
            defaults: UserDefaults,
            projectA: URL,
            projectB: URL
        ) {
            self.registry = registry
            self.destinationPrompter = destinationPrompter
            self.defaults = defaults
            self.projectA = projectA
            self.projectB = projectB
        }

        func makeWindow() -> WorkspaceWindow {
            let windowID = UUID()
            return WorkspaceWindow(id: windowID, store: registry.store(for: windowID))
        }
    }

    private func makeContext(
        commands: (any BeadsCommanding)? = nil,
        promptResponses: [ProjectOpenDestinationPromptResponse] = []
    ) throws -> Context {
        let defaults = makeUserDefaults()
        let destinationPrompter = RecordingProjectOpenDestinationPrompter(
            responses: promptResponses
        )
        let registry = BeadWorkspaceWindowRegistry(
            projectOpenDestinationPrompter: destinationPrompter
        ) {
            BeadStore(userDefaults: defaults, commands: commands ?? CurrentDoltTestCommands())
        }
        let context = Context(
            registry: registry,
            destinationPrompter: destinationPrompter,
            defaults: defaults,
            projectA: try makeProject(named: "Alpha"),
            projectB: try makeProject(named: "Beta")
        )
        registry.openNewWindow = { [weak context] request in
            context?.openedRequests.append(request)
        }
        return context
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in
            window.close()
        }
        return window
    }

    private func makeUserDefaults() -> UserDefaults {
        makeIsolatedUserDefaults()
    }

    private func makeProject(named name: String) throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadazzleWindowRegistryTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }
        return projectURL
    }

    /// A tracker directory with a readable snapshot, standing in for the effective Beads
    /// directory that several project roots can share through `bd context`.
    private func makeSharedTracker() throws -> URL {
        let trackerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadazzleWindowRegistryTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: trackerURL, withIntermediateDirectories: true)
        let snapshot = """
        {"_type":"issue","id":"bd-1","title":"Example","status":"open","priority":1,"issue_type":"task"}
        """
        try snapshot.write(
            to: trackerURL.appendingPathComponent("issues.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: trackerURL.deletingLastPathComponent())
        }
        return trackerURL
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Routes every project root to one shared tracker directory, the shape `bd context`
/// reports for worktree redirects and explicitly configured Beads directories.
private struct SharedTrackerTestCommands: BeadsCommanding {
    let trackerDirectoryURL: URL

    func exportReadableSnapshot(projectURL: URL) async throws {}
    func create(projectURL: URL, draft: IssueDraft) async throws -> String { "bd-created" }
    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws {}
    func updateMetadata(
        projectURL: URL,
        issueID: String,
        assignee: String?,
        labels: [String]?,
        originalLabels: [String]?,
        dueAt: IssueMetadataDateUpdate,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {}
    func close(projectURL: URL, ids: [String], reason: String?) async throws {}
    func delete(projectURL: URL, ids: [String]) async throws {}
    func bulkUpdate(
        projectURL: URL,
        ids: [String],
        status: String?,
        type: String?,
        priority: Int?,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {}
    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {}
    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {}
    func addComment(projectURL: URL, issueID: String, text: String) async throws {}
    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition] { [] }
    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] { [] }
    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws {}
    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws {}
    func loadProjectContext(projectURL: URL) async throws -> BeadsProjectContext {
        .testContext(projectURL: projectURL, beadsDirectoryURL: trackerDirectoryURL)
    }
}
