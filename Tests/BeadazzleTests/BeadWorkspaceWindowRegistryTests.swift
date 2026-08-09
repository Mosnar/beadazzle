import AppKit
import Foundation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadWorkspaceWindowRegistryTests: XCTestCase {
    func testPreferredDestinationOpensInCurrentWindowByDefault() throws {
        let context = try makeContext()
        let window = context.makeWindow()
        window.store.openProject(context.projectA)

        let openedHere = context.registry.openProject(
            context.projectB,
            from: window.store,
            destination: .preferred
        )

        XCTAssertTrue(openedHere)
        XCTAssertEqual(window.store.projectURL?.path, context.projectB.standardizedFileURL.path)
        XCTAssertTrue(context.openedRequests.isEmpty)
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
    }

    /// An empty window is the one the user is looking at, so the first project has to land
    /// there even when the preference says new window — otherwise they keep a blank window.
    func testPreferredDestinationFillsAnEmptyWindowInsteadOfOpeningAnother() throws {
        let context = try makeContext()
        let window = context.makeWindow()
        window.store.projectOpenDestination = .newWindow

        let openedHere = context.registry.openProject(
            context.projectA,
            from: window.store,
            destination: .preferred
        )

        XCTAssertTrue(openedHere)
        XCTAssertEqual(window.store.projectURL?.path, context.projectA.standardizedFileURL.path)
        XCTAssertTrue(context.openedRequests.isEmpty)
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
            destination: .newWindow
        )

        XCTAssertFalse(openedHere)
        XCTAssertEqual(second.store.projectURL?.path, context.projectB.standardizedFileURL.path)
        XCTAssertTrue(context.openedRequests.isEmpty)
        XCTAssertEqual(context.registry.windowID(showing: context.projectA), first.id)
    }

    func testReopeningTheWindowsOwnProjectIsANoOp() throws {
        let context = try makeContext()
        let window = context.makeWindow()
        window.store.openProject(context.projectA)

        let openedHere = context.registry.openProject(
            context.projectA,
            from: window.store,
            destination: .newWindow
        )

        XCTAssertTrue(openedHere)
        XCTAssertTrue(context.openedRequests.isEmpty)
    }

    // MARK: - Window preparation

    /// Opening a project spawns `bd` and starts file monitors, so resolving a window's
    /// store — which SwiftUI does on every body evaluation — must not trigger any of it.
    func testResolvingAStoreDoesNotLoadAProject() throws {
        let context = try makeContext()
        let request = BeadWorkspaceWindowRequest(projectURL: context.projectA)

        let store = context.registry.store(for: request)

        XCTAssertNil(store.projectURL)
    }

    func testPreparingAWindowOpensTheRequestedProject() throws {
        let context = try makeContext()
        let request = BeadWorkspaceWindowRequest(projectURL: context.projectA)
        let store = context.registry.store(for: request)

        context.registry.prepareWindow(request)

        XCTAssertEqual(store.projectURL?.path, context.projectA.standardizedFileURL.path)
    }

    /// `onAppear` can fire more than once for a window; a repeat must not reload the
    /// project or throw away a project the user switched to in the meantime.
    func testPreparingAWindowTwiceLeavesTheCurrentProjectAlone() throws {
        let context = try makeContext()
        let request = BeadWorkspaceWindowRequest(projectURL: context.projectA)
        let store = context.registry.store(for: request)
        context.registry.prepareWindow(request)
        store.openProject(context.projectB)

        context.registry.prepareWindow(request)

        XCTAssertEqual(store.projectURL?.path, context.projectB.standardizedFileURL.path)
    }

    func testPreparingAWindowWithoutAProjectFallsBackToRecents() throws {
        let context = try makeContext()
        let first = context.makeWindow()
        first.store.openProject(context.projectA)

        let request = BeadWorkspaceWindowRequest()
        let store = context.registry.store(for: request)
        context.registry.prepareWindow(request)

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
        let store = context.registry.store(for: request)
        context.registry.prepareWindow(request)

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
        let store = context.registry.store(for: request)
        context.registry.prepareWindow(request)

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
        let store = context.registry.store(for: request)
        store.openProject(context.projectA)
        let window = makeWindow()
        context.registry.registerWindow(window, for: request.id)
        // Guards against passing vacuously if the store were never registered.
        XCTAssertNotNil(context.registry.windowID(showing: context.projectA))

        window.close()

        XCTAssertNil(context.registry.windowID(showing: context.projectA))
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
    /// open elsewhere; if it doesn't move, the switcher shows stale markers.
    func testWindowCompositionRevisionMovesWhenWindowsComeAndGo() throws {
        let context = try makeContext()
        let start = context.registry.windowCompositionRevision

        let window = context.makeWindow()
        let afterOpen = context.registry.windowCompositionRevision
        context.registry.releaseWindow(window.id)
        let afterClose = context.registry.windowCompositionRevision

        XCTAssertGreaterThan(afterOpen, start)
        XCTAssertGreaterThan(afterClose, afterOpen)
        // A repeat release changed nothing, so it must not look like a change either.
        context.registry.releaseWindow(window.id)
        XCTAssertEqual(context.registry.windowCompositionRevision, afterClose)
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
    private final class Context {
        let registry: BeadWorkspaceWindowRegistry
        let defaults: UserDefaults
        let projectA: URL
        let projectB: URL
        /// Windows the registry asked SwiftUI to open. Stands in for real windows, which a
        /// unit test has no scene to create.
        var openedRequests: [BeadWorkspaceWindowRequest] = []

        init(registry: BeadWorkspaceWindowRegistry, defaults: UserDefaults, projectA: URL, projectB: URL) {
            self.registry = registry
            self.defaults = defaults
            self.projectA = projectA
            self.projectB = projectB
        }

        func makeWindow() -> WorkspaceWindow {
            let request = BeadWorkspaceWindowRequest()
            return WorkspaceWindow(id: request.id, store: registry.store(for: request))
        }
    }

    private func makeContext() throws -> Context {
        let defaults = makeUserDefaults()
        let registry = BeadWorkspaceWindowRegistry {
            BeadStore(userDefaults: defaults, commands: CurrentDoltTestCommands())
        }
        let context = Context(
            registry: registry,
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
        let suiteName = "BeadazzleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
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
}
