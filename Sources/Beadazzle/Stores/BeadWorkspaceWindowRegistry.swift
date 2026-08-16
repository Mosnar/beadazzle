import AppKit
import SwiftUI

/// Lets a `BeadStore` tell its peers that it changed state they all share.
@MainActor
protocol BeadAppStateBroadcasting: AnyObject {
    func appPreferencesDidChange(from store: BeadStore)
    func recentProjectsDidChange(from store: BeadStore)
    /// The store's `bd context` resolved, so its canonical tracker identity is now known.
    func projectTrackerDidResolve(from store: BeadStore)
}

/// Owns one `BeadStore` per workspace window and routes project opens between them.
///
/// Each window needs its own store because a store is bound to a single project: its
/// index, write queue, snapshot monitor, and optimistic mutation state are all
/// project-scoped. The genuinely app-wide state — preferences and the recents list —
/// lives in `UserDefaults`, so the registry keeps windows consistent by asking peers to
/// re-read it rather than by mirroring values between stores.
@Observable
@MainActor
final class BeadWorkspaceWindowRegistry: BeadAppStateBroadcasting {
    /// Observed by auxiliary scenes (Settings, Project Settings) so they re-resolve which
    /// store they read when the frontmost workspace window changes.
    private(set) var frontmostWindowID: UUID?
    /// Bumped whenever a workspace window is added or removed. The set of live windows is
    /// otherwise plain storage, and views that ask which projects are open elsewhere need
    /// something to observe.
    private(set) var windowCompositionRevision = 0

    @ObservationIgnored private var storesByWindowID: [UUID: BeadStore] = [:]
    @ObservationIgnored private var windowsByWindowID: [UUID: NSWindow] = [:]
    /// Closed windows whose stores are still draining queued `bd` writes. They keep their
    /// tracker reserved so a reopen cannot start a second write queue against it.
    @ObservationIgnored private var drainingStoresByWindowID: [UUID: BeadStore] = [:]
    @ObservationIgnored private var drainWaitersByWindowID: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    /// A failed final export is retried on the next in-process open. Both the project root
    /// and canonical tracker identity are retained so an alias of the closed root consumes
    /// the same retry requirement.
    @ObservationIgnored private var snapshotExportRequirements: [SnapshotExportRequirement] = []
    /// Stable creation order for deterministic duplicate-tracker repair. `windowOrder`
    /// reshuffles with key-window changes, so it cannot arbitrate which of two
    /// simultaneously resolving windows keeps a shared tracker.
    @ObservationIgnored private var storeOrdinalByWindowID: [UUID: Int] = [:]
    @ObservationIgnored private var nextStoreOrdinal = 0
    /// Most recently keyed window last. Lookups walk it in reverse so the newest match
    /// wins, without depending on `NSApp.keyWindow`, which points at an auxiliary window
    /// whenever Settings is frontmost.
    @ObservationIgnored private var windowOrder: [UUID] = []
    /// Paths rejected while one window walks the recents after resolving to a tracker that
    /// another window owns. The set spans the entire fallback chain so three aliases of one
    /// tracker cannot bounce forever between one another.
    @ObservationIgnored private var duplicateFallbackExcludedPathsByWindowID: [UUID: Set<String>] = [:]
    /// Identifies the newest deferred open for each window. Context resolution and drain
    /// waits are asynchronous; a later user choice must supersede an older completion.
    @ObservationIgnored private var deferredProjectOpenTokenByWindowID: [UUID: UUID] = [:]
    @ObservationIgnored private var detachedStore: BeadStore?
    @ObservationIgnored private let makeStore: @MainActor () -> BeadStore
    @ObservationIgnored private let projectOpenDestinationPrompter: any ProjectOpenDestinationPrompting
    @ObservationIgnored private var windowObservers: [any NSObjectProtocol] = []

    /// Supplied by the workspace scene, which is where SwiftUI's `openWindow` is reachable.
    /// Injected rather than stored as an `OpenWindowAction` so routing decisions stay
    /// testable without a live scene.
    @ObservationIgnored var openNewWindow: ((BeadWorkspaceWindowRequest) -> Void)?

    private struct SnapshotExportRequirement: Equatable {
        let projectPath: String
        let trackerIdentityPath: String?
    }

    private struct DeferredProjectOpen {
        let windowID: UUID
        let token: UUID
    }

    init(
        projectOpenDestinationPrompter: (any ProjectOpenDestinationPrompting)? = nil,
        makeStore: @escaping @MainActor () -> BeadStore = { BeadStore() }
    ) {
        self.projectOpenDestinationPrompter = projectOpenDestinationPrompter
            ?? AppKitProjectOpenDestinationPrompter()
        self.makeStore = makeStore
        windowObservers = [
            observeWindows(NSWindow.didBecomeKeyNotification) { $0.windowDidBecomeKey($1) },
            // AppKit's close notification, not only SwiftUI's `onDisappear`: teardown
            // persists workspace state and stops file monitors, so it needs a signal with
            // defined semantics rather than one tied to when SwiftUI drops a view.
            observeWindows(NSWindow.willCloseNotification) { $0.windowWillClose($1) }
        ]
    }

    deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Observes an `NSWindow` notification with synchronous delivery (`queue: nil`).
    /// Teardown has to persist workspace state while the closing window still exists, so
    /// the handler must run during the close rather than on a later main-queue turn.
    /// AppKit posts these on the main thread; the guard keeps a stray background post from
    /// tripping the isolation assertion instead of crashing.
    private func observeWindows(
        _ name: Notification.Name,
        handler: @escaping @MainActor (BeadWorkspaceWindowRegistry, NSWindow) -> Void
    ) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard Thread.isMainThread, let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, window)
            }
        }
    }

    // MARK: - Window lifecycle

    /// Returns the store backing the window identified by `windowID`, creating an empty one
    /// on first use.
    ///
    /// `windowID` is the window's own identity, not the id of the value it presents: SwiftUI
    /// can swap a live window's presented value, and a store must survive that.
    ///
    /// Deliberately loads nothing: SwiftUI evaluates window bodies freely, and opening a
    /// project spawns `bd`, starts file-system monitors, and schedules async loads. The
    /// window asks for its project from `prepareWindow(_:request:)` once it is on screen.
    func store(for windowID: UUID) -> BeadStore {
        if let existing = storesByWindowID[windowID] {
            return existing
        }
        let store = makeStore()
        store.appStateBroadcaster = self
        storesByWindowID[windowID] = store
        storeOrdinalByWindowID[windowID] = nextStoreOrdinal
        nextStoreOrdinal += 1
        if !windowOrder.contains(windowID) {
            windowOrder.append(windowID)
        }
        // First resolution happens inside the window body's view update; mutating the
        // observed revision there is undefined behavior, so the bump waits a turn.
        scheduleWindowCompositionRevisionBump()
        return store
    }

    private func scheduleWindowCompositionRevisionBump() {
        Task { @MainActor [weak self] in
            self?.windowCompositionRevision &+= 1
        }
    }

    /// Loads the window's project now that it exists: the one its request asks for, or the
    /// most recent project no sibling window has taken. Idempotent, and a no-op once the
    /// window has a project, so a repeated `onAppear` — or a presented value SwiftUI swaps
    /// in later — never reloads or resets it.
    func prepareWindow(_ windowID: UUID, request: BeadWorkspaceWindowRequest) {
        guard let store = storesByWindowID[windowID], store.projectURL == nil else { return }
        let takenPaths = takenProjectPaths(excludingWindowID: windowID)
        // Restoration can hand two windows the same recorded project, or a project whose
        // folder was deleted while the app was closed. Fall through to the recents rather
        // than opening it twice or landing the window on a missing directory. An explicit
        // "open in new window" is different: the user picked that folder just now, so a
        // missing directory must surface its failure state, not an unrelated project.
        if let projectURL = request.projectURL,
           request.opensProjectExplicitly,
           drainingWindowID(showing: projectURL, trackerIdentityPath: nil) != nil {
            openPreparedProject(
                projectURL,
                in: store,
                forcingSnapshotExport: request.forcesSnapshotExport
            )
            return
        }
        if let projectURL = request.projectURL,
           !takenPaths.contains(projectURL.standardizedFileURL.path),
           request.opensProjectExplicitly || store.projectDirectoryExists(at: projectURL) {
            openPreparedProject(
                projectURL,
                in: store,
                forcingSnapshotExport: request.forcesSnapshotExport
            )
            return
        }
        if let fallbackURL = store.defaultProjectURL(excludingProjectPaths: takenPaths) {
            openPreparedProject(fallbackURL, in: store)
        }
    }

    /// Project paths other windows already show — including closed windows still draining
    /// queued writes, whose trackers stay reserved until the drain finishes.
    private func takenProjectPaths(excludingWindowID excludedID: UUID?) -> Set<String> {
        var paths = Set(
            storesByWindowID
                .filter { $0.key != excludedID }
                .compactMap { $0.value.projectURL?.standardizedFileURL.path }
        )
        for store in drainingStoresByWindowID.values {
            if let path = store.projectURL?.standardizedFileURL.path {
                paths.insert(path)
            }
        }
        return paths
    }

    func registerWindow(_ window: NSWindow, for windowID: UUID) {
        windowsByWindowID[windowID] = window
        if !windowOrder.contains(windowID) {
            windowOrder.append(windowID)
        }
        // Windows report themselves from inside a SwiftUI update pass
        // (`updateNSView`/`viewDidMoveToWindow`), so everything below — retiring a
        // superseded entry, changing which window is frontmost — is deferred out of it
        // rather than mutating observed state the update in progress is reading. Later key
        // changes arrive via the AppKit notification.
        Task { @MainActor [weak self] in
            guard let self, self.windowsByWindowID[windowID] === window else { return }
            self.retireEntriesSuperseded(backedBy: window)
            guard window.isKeyWindow else { return }
            self.windowDidBecomeKey(window)
        }
    }

    /// One `NSWindow` backs exactly one entry. If SwiftUI ever rebuilds a window's root view
    /// — handing the same window a new identity — the superseded entry has to be retired
    /// rather than left holding a project no window shows. A duplicate would also make
    /// `windowID(for:)` answer arbitrarily, since it resolves a window to a single id.
    ///
    /// The newest binding keeps the window, because it is the one the window's current root
    /// view resolves its store from. That is the opposite of `repairDuplicateTrackerBinding`,
    /// where the oldest binding wins: two windows contending for one tracker is a different
    /// question from one window whose older binding is now a phantom. Deciding it from the
    /// stored ordinals rather than from which deferred registration runs first keeps the
    /// outcome the same no matter how the two interleave.
    private func retireEntriesSuperseded(backedBy window: NSWindow) {
        let boundIDs = windowsByWindowID.filter { $0.value === window }.keys
        guard boundIDs.count > 1,
              let currentID = boundIDs.max(by: { lhs, rhs in
                  (storeOrdinalByWindowID[lhs] ?? .min) < (storeOrdinalByWindowID[rhs] ?? .min)
              }) else {
            return
        }
        for supersededID in boundIDs where supersededID != currentID {
            releaseWindow(supersededID)
        }
    }

    /// Tears the window's store down: persists workspace state, then cancels the
    /// subprocesses, tasks, and file monitors it owns so a closed window stops working.
    ///
    /// Idempotent — both `NSWindow.willCloseNotification` and SwiftUI's `onDisappear`
    /// call it, and which arrives first is not worth depending on.
    func releaseWindow(_ windowID: UUID) {
        let hadWindow = storesByWindowID[windowID] != nil || windowsByWindowID[windowID] != nil
        if let store = storesByWindowID.removeValue(forKey: windowID) {
            // The broadcaster reference stays: Settings can remain bound to this store for
            // a beat after the window closes, and an edit made in that gap must still
            // reach the surviving windows. Removal from the maps above already stops
            // broadcasts *to* this store, and the reference is weak.
            store.prepareForWindowClose()
            if store.requiresWindowCloseMutationFinalization {
                // The tracker stays reserved while the closed window's queue drains, so a
                // reopen cannot start a second write queue against it. `openProject` and
                // `prepareWindow` honor the lease; reopen requests wait it out.
                drainingStoresByWindowID[windowID] = store
                Task { @MainActor [weak self] in
                    let exportFailure = await store.finishRetirementAfterWindowClose()
                    self?.completeDrain(
                        of: windowID,
                        projectURL: store.projectURL,
                        trackerIdentityPath: store.resolvedTrackerIdentityPath,
                        exportFailure: exportFailure
                    )
                }
            }
        }
        storeOrdinalByWindowID.removeValue(forKey: windowID)
        duplicateFallbackExcludedPathsByWindowID.removeValue(forKey: windowID)
        deferredProjectOpenTokenByWindowID.removeValue(forKey: windowID)
        windowsByWindowID.removeValue(forKey: windowID)
        windowOrder.removeAll { $0 == windowID }
        if frontmostWindowID == windowID {
            frontmostWindowID = windowOrder.last
        }
        if hadWindow {
            windowCompositionRevision &+= 1
        }
    }

    private func completeDrain(
        of windowID: UUID,
        projectURL: URL?,
        trackerIdentityPath: String?,
        exportFailure: String?
    ) {
        if exportFailure != nil, let projectURL {
            recordSnapshotExportRequirement(
                projectURL: projectURL,
                trackerIdentityPath: trackerIdentityPath
            )
        }
        drainingStoresByWindowID.removeValue(forKey: windowID)
        if let waiters = drainWaitersByWindowID.removeValue(forKey: windowID) {
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func awaitDrainCompletion(of windowID: UUID) async {
        guard drainingStoresByWindowID[windowID] != nil else { return }
        await withCheckedContinuation { continuation in
            drainWaitersByWindowID[windowID, default: []].append(continuation)
        }
    }

    private func drainingWindowID(
        showing projectURL: URL,
        trackerIdentityPath: String?
    ) -> UUID? {
        let path = projectURL.standardizedFileURL.path
        return drainingStoresByWindowID.first { entry in
            if entry.value.projectURL?.standardizedFileURL.path == path {
                return true
            }
            guard let trackerIdentityPath else { return false }
            return entry.value.resolvedTrackerIdentityPath == trackerIdentityPath
        }?.key
    }

    private func recordSnapshotExportRequirement(
        projectURL: URL,
        trackerIdentityPath: String?
    ) {
        let projectPath = projectURL.standardizedFileURL.path
        snapshotExportRequirements.removeAll { requirement in
            requirement.projectPath == projectPath
                || trackerIdentityPath.map { requirement.trackerIdentityPath == $0 } == true
        }
        snapshotExportRequirements.append(SnapshotExportRequirement(
            projectPath: projectPath,
            trackerIdentityPath: trackerIdentityPath
        ))
    }

    private func consumeSnapshotExportRequirement(
        for projectURL: URL,
        trackerIdentityPath: String?
    ) -> Bool {
        let projectPath = projectURL.standardizedFileURL.path
        let matches: (SnapshotExportRequirement) -> Bool = { requirement in
            requirement.projectPath == projectPath
                || trackerIdentityPath.map { requirement.trackerIdentityPath == $0 } == true
        }
        guard snapshotExportRequirements.contains(where: matches) else { return false }
        snapshotExportRequirements.removeAll(where: matches)
        return true
    }

    private var needsCanonicalTrackerPreflight: Bool {
        drainingStoresByWindowID.values.contains { $0.resolvedTrackerIdentityPath != nil }
            || snapshotExportRequirements.contains { $0.trackerIdentityPath != nil }
    }

    /// AppKit may end the process as soon as `applicationShouldTerminate` returns. This
    /// flag lets the delegate defer that reply only when optimistic writes or a closed
    /// window's final export still need to finish.
    var requiresApplicationTerminationFinalization: Bool {
        !drainingStoresByWindowID.isEmpty
            || storesByWindowID.values.contains { $0.requiresWindowCloseMutationFinalization }
    }

    var hasPendingWindowCloseFinalization: Bool {
        !drainingStoresByWindowID.isEmpty
    }

    /// Retires every live workspace store, then waits for all serialized writes and final
    /// readable-snapshot exports. The app delegate calls this while termination is held.
    func finishApplicationTermination() async {
        for windowID in Array(storesByWindowID.keys) {
            releaseWindow(windowID)
        }
        for windowID in Array(drainingStoresByWindowID.keys) {
            await awaitDrainCompletion(of: windowID)
        }
    }

    private func windowWillClose(_ window: NSWindow) {
        guard let windowID = windowID(for: window) else { return }
        releaseWindow(windowID)
    }

    private func windowID(for window: NSWindow) -> UUID? {
        windowsByWindowID.first { $0.value === window }?.key
    }

    private func windowDidBecomeKey(_ window: NSWindow) {
        guard let windowID = windowID(for: window) else {
            return
        }
        windowOrder.removeAll { $0 == windowID }
        windowOrder.append(windowID)
        if frontmostWindowID != windowID {
            frontmostWindowID = windowID
        }
    }

    // MARK: - Store lookup

    /// The store auxiliary scenes should read when they aren't tied to a project: the
    /// frontmost workspace window's, or a detached store when every window is closed.
    var frontmostStore: BeadStore? {
        if let frontmostWindowID, let store = storesByWindowID[frontmostWindowID] {
            return store
        }
        return windowOrder.reversed().compactMap { storesByWindowID[$0] }.first
    }

    /// The frontmost workspace window's project. Menu commands fall back to this when a
    /// non-workspace window (Settings, Project Settings) is key and no scene publishes
    /// focused workspace values. Reads both observable inputs so menus revalidate as
    /// windows come, go, and change key.
    var frontmostProjectURL: URL? {
        _ = windowCompositionRevision
        _ = frontmostWindowID
        return frontmostStore?.projectURL
    }

    /// Never nil, so Settings still works with no workspace window open. The detached
    /// store participates in preference broadcasts but shows no project.
    func auxiliaryStore() -> BeadStore {
        if let frontmostStore {
            return frontmostStore
        }
        if let detachedStore {
            return detachedStore
        }
        let store = makeStore()
        store.appStateBroadcaster = self
        detachedStore = store
        return store
    }

    /// The store showing `projectURL`, falling back to the auxiliary store so a Project
    /// Settings window outlives the workspace window that spawned it.
    func store(forProject projectURL: URL?) -> BeadStore {
        // Both dependencies are deliberate: the match depends on which windows exist, and
        // the fallback depends on which one is frontmost. Either can change while the
        // settings window is already on screen.
        _ = windowCompositionRevision
        _ = frontmostWindowID
        guard let projectURL else { return auxiliaryStore() }
        if let store = store(showing: projectURL) {
            return store
        }
        return auxiliaryStore()
    }

    private func store(showing projectURL: URL) -> BeadStore? {
        let path = projectURL.standardizedFileURL.path
        return windowOrder.reversed().compactMap { windowID -> BeadStore? in
            guard let store = storesByWindowID[windowID],
                  store.projectURL?.standardizedFileURL.path == path else {
                return nil
            }
            return store
        }.first
    }

    // MARK: - Opening projects

    /// Routes an open to the right window. A project already open elsewhere always wins:
    /// that window comes forward instead of a second one contending for the same tracker
    /// directory with its own write queue and snapshot monitor.
    ///
    /// - Returns: `true` when the project opened in `store`'s own window immediately.
    ///   Prompted and otherwise deferred opens return `false`; their eventual routing is
    ///   reflected by the store or new-window request after the asynchronous choice.
    @discardableResult
    func openProject(
        _ url: URL,
        from store: BeadStore,
        destination: BeadProjectOpenDestination,
        forcingSnapshotExport: Bool = false
    ) -> Bool {
        let routing = beginProjectOpen(for: store)
        return routeProjectOpen(
            url.standardizedFileURL,
            from: store,
            destination: destination,
            forcingSnapshotExport: forcingSnapshotExport,
            trackerIdentityPath: nil,
            attemptedTrackerResolution: false,
            routing: routing
        )
    }

    @discardableResult
    private func routeProjectOpen(
        _ standardizedURL: URL,
        from store: BeadStore,
        destination: BeadProjectOpenDestination,
        forcingSnapshotExport: Bool,
        trackerIdentityPath: String?,
        attemptedTrackerResolution: Bool,
        routing: DeferredProjectOpen?
    ) -> Bool {
        guard projectOpenIsCurrent(routing, for: store) else { return false }
        let effectiveTrackerIdentityPath = trackerIdentityPath ?? (
            store.projectURL?.standardizedFileURL == standardizedURL
                ? store.resolvedTrackerIdentityPath
                : nil
        )
        if store.projectURL?.standardizedFileURL == standardizedURL {
            // Reopening the window's own project runs the full reopen rather than treating
            // the request as satisfied: picking the same folder again is the user's retry
            // path when a load failed (missing snapshot, unavailable tracker).
            let forcesSnapshotExport = forcingSnapshotExport || consumeSnapshotExportRequirement(
                for: standardizedURL,
                trackerIdentityPath: effectiveTrackerIdentityPath
            )
            focusWindow(showing: standardizedURL)
            store.openProject(standardizedURL, forcingSnapshotExport: forcesSnapshotExport)
            return true
        }
        // Deliberately keyed on store ownership rather than on being able to focus the
        // window: a window opened moments ago may not have reported its `NSWindow` yet,
        // and duplicating the project is worse than failing to raise the window.
        if let existingWindowID = windowID(showing: standardizedURL) {
            focusWindow(existingWindowID)
            return false
        }
        // A just-closed window is still draining queued writes to this tracker. Opening
        // now would run a second write queue against it, so the open resumes — with the
        // caller's destination — once the drain and its final snapshot export finish.
        if let drainingWindowID = drainingWindowID(
            showing: standardizedURL,
            trackerIdentityPath: trackerIdentityPath
        ) {
            continueProjectOpenAfterDrain(
                drainingWindowID,
                projectURL: standardizedURL,
                from: store,
                destination: destination,
                forcingSnapshotExport: forcingSnapshotExport,
                trackerIdentityPath: trackerIdentityPath
                    ?? drainingStoresByWindowID[drainingWindowID]?.resolvedTrackerIdentityPath,
                routing: routing
            )
            return false
        }
        if !attemptedTrackerResolution, needsCanonicalTrackerPreflight {
            resolveTrackerThenRouteProjectOpen(
                standardizedURL,
                from: store,
                destination: destination,
                forcingSnapshotExport: forcingSnapshotExport,
                routing: routing
            )
            return false
        }
        if let trackerIdentityPath,
           let existingWindowID = windowID(showingTrackerIdentity: trackerIdentityPath) {
            focusWindow(existingWindowID)
            return false
        }
        if destination == .preferred,
           store.projectURL != nil,
           store.projectOpenDestination == .askEveryTime {
            promptForProjectOpenDestination(
                standardizedURL,
                from: store,
                forcingSnapshotExport: forcingSnapshotExport,
                trackerIdentityPath: trackerIdentityPath,
                routing: routing
            )
            return false
        }
        let forcesSnapshotExport = forcingSnapshotExport || consumeSnapshotExportRequirement(
            for: standardizedURL,
            trackerIdentityPath: trackerIdentityPath
        )
        guard resolvedDestination(destination, store: store) == .newWindow,
              let openNewWindow else {
            store.openProject(standardizedURL, forcingSnapshotExport: forcesSnapshotExport)
            return true
        }
        openNewWindow(
            BeadWorkspaceWindowRequest(
                projectURL: standardizedURL,
                opensProjectExplicitly: true,
                forcesSnapshotExport: forcesSnapshotExport
            )
        )
        return false
    }

    private func promptForProjectOpenDestination(
        _ projectURL: URL,
        from store: BeadStore,
        forcingSnapshotExport: Bool,
        trackerIdentityPath: String?,
        routing: DeferredProjectOpen?
    ) {
        let request = ProjectOpenDestinationPromptRequest(
            projectName: projectURL.lastPathComponent,
            currentProjectName: store.projectName
        )
        let window = windowID(for: store).flatMap { windowsByWindowID[$0] }

        Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            let response = await projectOpenDestinationPrompter.prompt(
                request,
                attachedTo: window
            )
            guard projectOpenIsCurrent(routing, for: store),
                  let destination = response.choice.destination else {
                return
            }
            if response.remembersChoice,
               let preference = response.choice.preference {
                store.projectOpenDestination = preference
            }
            _ = routeProjectOpen(
                projectURL,
                from: store,
                destination: destination,
                forcingSnapshotExport: forcingSnapshotExport,
                trackerIdentityPath: trackerIdentityPath,
                attemptedTrackerResolution: true,
                routing: routing
            )
        }
    }

    private func openPreparedProject(
        _ projectURL: URL,
        in store: BeadStore,
        forcingSnapshotExport: Bool = false
    ) {
        routePreparedProjectOpen(
            projectURL.standardizedFileURL,
            in: store,
            forcingSnapshotExport: forcingSnapshotExport,
            trackerIdentityPath: nil,
            attemptedTrackerResolution: false,
            routing: beginProjectOpen(for: store)
        )
    }

    private func routePreparedProjectOpen(
        _ standardizedURL: URL,
        in store: BeadStore,
        forcingSnapshotExport: Bool,
        trackerIdentityPath: String?,
        attemptedTrackerResolution: Bool,
        routing: DeferredProjectOpen?
    ) {
        guard projectOpenIsCurrent(routing, for: store), store.projectURL == nil else { return }
        if let drainingWindowID = drainingWindowID(
            showing: standardizedURL,
            trackerIdentityPath: trackerIdentityPath
        ) {
            let drainingTrackerIdentityPath = trackerIdentityPath
                ?? drainingStoresByWindowID[drainingWindowID]?.resolvedTrackerIdentityPath
            Task { @MainActor [weak self, weak store] in
                await self?.awaitDrainCompletion(of: drainingWindowID)
                guard let self, let store,
                      self.projectOpenIsCurrent(routing, for: store) else { return }
                self.routePreparedProjectOpen(
                    standardizedURL,
                    in: store,
                    forcingSnapshotExport: forcingSnapshotExport,
                    trackerIdentityPath: drainingTrackerIdentityPath,
                    attemptedTrackerResolution: true,
                    routing: routing
                )
            }
            return
        }
        if !attemptedTrackerResolution, needsCanonicalTrackerPreflight {
            Task { @MainActor [weak self, weak store] in
                guard let self, let store else { return }
                let identity = await self.resolveTrackerIdentityPath(
                    for: standardizedURL,
                    using: store
                )
                guard self.projectOpenIsCurrent(routing, for: store) else { return }
                self.routePreparedProjectOpen(
                    standardizedURL,
                    in: store,
                    forcingSnapshotExport: forcingSnapshotExport,
                    trackerIdentityPath: identity,
                    attemptedTrackerResolution: true,
                    routing: routing
                )
            }
            return
        }
        let forcesSnapshotExport = forcingSnapshotExport || consumeSnapshotExportRequirement(
            for: standardizedURL,
            trackerIdentityPath: trackerIdentityPath
        )
        store.openProject(standardizedURL, forcingSnapshotExport: forcesSnapshotExport)
    }

    private func resolveTrackerThenRouteProjectOpen(
        _ projectURL: URL,
        from store: BeadStore,
        destination: BeadProjectOpenDestination,
        forcingSnapshotExport: Bool,
        routing: DeferredProjectOpen?
    ) {
        Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            let identity = await self.resolveTrackerIdentityPath(for: projectURL, using: store)
            guard self.projectOpenIsCurrent(routing, for: store) else { return }
            _ = self.routeProjectOpen(
                projectURL,
                from: store,
                destination: destination,
                forcingSnapshotExport: forcingSnapshotExport,
                trackerIdentityPath: identity,
                attemptedTrackerResolution: true,
                routing: routing
            )
        }
    }

    private func continueProjectOpenAfterDrain(
        _ drainingWindowID: UUID,
        projectURL: URL,
        from store: BeadStore,
        destination: BeadProjectOpenDestination,
        forcingSnapshotExport: Bool,
        trackerIdentityPath: String?,
        routing: DeferredProjectOpen?
    ) {
        Task { @MainActor [weak self, weak store] in
            await self?.awaitDrainCompletion(of: drainingWindowID)
            guard let self, let store,
                  self.projectOpenIsCurrent(routing, for: store) else { return }
            _ = self.routeProjectOpen(
                projectURL,
                from: store,
                destination: destination,
                forcingSnapshotExport: forcingSnapshotExport,
                trackerIdentityPath: trackerIdentityPath,
                attemptedTrackerResolution: true,
                routing: routing
            )
        }
    }

    private func resolveTrackerIdentityPath(for projectURL: URL, using store: BeadStore) async -> String? {
        do {
            let context = try await store.commands.loadProjectContext(projectURL: projectURL)
            return try BeadsProjectEnvironment(
                context: context,
                projectURL: projectURL
            ).beadsDirectoryURL.standardizedFileURL.path
        } catch {
            // The real load repeats the context lookup and owns user-visible error state.
            // A failed routing preflight must not swallow or replace that result.
            return nil
        }
    }

    private func beginProjectOpen(for store: BeadStore) -> DeferredProjectOpen? {
        guard let windowID = windowID(for: store) else { return nil }
        let token = UUID()
        deferredProjectOpenTokenByWindowID[windowID] = token
        return DeferredProjectOpen(windowID: windowID, token: token)
    }

    private func projectOpenIsCurrent(_ routing: DeferredProjectOpen?, for store: BeadStore) -> Bool {
        guard let routing else { return true }
        return storesByWindowID[routing.windowID] === store
            && deferredProjectOpenTokenByWindowID[routing.windowID] == routing.token
    }

    private func resolvedDestination(
        _ destination: BeadProjectOpenDestination,
        store: BeadStore
    ) -> BeadProjectOpenDestination {
        switch destination {
        case .currentWindow, .newWindow:
            return destination
        case .preferred:
            // An empty window is the current window the user is looking at; sending the
            // first project somewhere else would leave them staring at a blank one.
            guard store.projectURL != nil else { return .currentWindow }
            switch store.projectOpenDestination {
            case .askEveryTime, .currentWindow:
                // Ask Every Time is intercepted before this resolver. Treat it as current
                // here as a defensive fallback if a caller reaches this seam directly.
                return .currentWindow
            case .newWindow:
                return .newWindow
            }
        }
    }

    /// Whether some window other than `store`'s is already showing `projectURL`. The
    /// project switcher marks those rows, because activating one raises that window rather
    /// than changing anything in this one.
    func isProjectOpenInAnotherWindow(_ projectURL: URL, from store: BeadStore) -> Bool {
        _ = windowCompositionRevision
        let path = projectURL.standardizedFileURL.path
        guard store.projectURL?.standardizedFileURL.path != path else { return false }
        return storesByWindowID.values.contains { peer in
            peer !== store && peer.projectURL?.standardizedFileURL.path == path
        }
    }

    func windowID(showing projectURL: URL) -> UUID? {
        let path = projectURL.standardizedFileURL.path
        return windowOrder.reversed().first { windowID in
            storesByWindowID[windowID]?.projectURL?.standardizedFileURL.path == path
        }
    }

    private func windowID(showingTrackerIdentity trackerIdentityPath: String) -> UUID? {
        windowOrder.reversed().first { windowID in
            storesByWindowID[windowID]?.resolvedTrackerIdentityPath == trackerIdentityPath
        }
    }

    @discardableResult
    func focusWindow(showing projectURL: URL) -> Bool {
        guard let windowID = windowID(showing: projectURL) else { return false }
        return focusWindow(windowID)
    }

    @discardableResult
    private func focusWindow(_ windowID: UUID) -> Bool {
        guard let window = windowsByWindowID[windowID] else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    // MARK: - BeadAppStateBroadcasting

    /// Two project roots can resolve to one tracker (worktree redirects, configured
    /// Beads directories), which path-based routing cannot see until `bd context`
    /// answers. Once it does, exactly one window may keep the tracker: the one bound
    /// longest ago wins deterministically — two simultaneously resolving windows must
    /// not both resign — and the newer binding falls back like a duplicate restoration.
    ///
    /// Called from inside the store's load pipeline, so the repair — which reenters
    /// store code — runs on a fresh turn and revalidates everything first.
    func projectTrackerDidResolve(from store: BeadStore) {
        Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            self.repairDuplicateTrackerBinding(of: store)
        }
    }

    private func repairDuplicateTrackerBinding(of store: BeadStore) {
        guard let identity = store.resolvedTrackerIdentityPath,
              let windowID = windowID(for: store),
              let ordinal = storeOrdinalByWindowID[windowID] else { return }
        if drainingStoresByWindowID.contains(where: { entry in
            entry.value.resolvedTrackerIdentityPath == identity
        }), let projectURL = store.projectURL {
            // Registry-routed opens preflight before loading. This is a final safety net
            // for direct store opens: release the newly loaded alias and retry it only once
            // the retired owner has finished its write handoff.
            store.closeProject()
            openPreparedProject(projectURL, in: store)
            return
        }
        // Either side of the pair can resolve first, so the repair must be able to
        // resign whichever binding is newer — not only the store that just resolved.
        guard let conflicting = storesByWindowID.first(where: { entry in
            entry.key != windowID && entry.value.resolvedTrackerIdentityPath == identity
        }) else {
            duplicateFallbackExcludedPathsByWindowID.removeValue(forKey: windowID)
            if let projectURL = store.projectURL,
               consumeSnapshotExportRequirement(
                   for: projectURL,
                   trackerIdentityPath: identity
               ) {
                // Normally routing consumes this before opening. If its lightweight
                // context preflight failed but the real load succeeded, retry now that the
                // canonical identity is authoritative rather than stranding the marker.
                store.openProject(projectURL, forcingSnapshotExport: true)
            }
            return
        }
        let conflictingOrdinal = storeOrdinalByWindowID[conflicting.key] ?? .max
        let (loserID, loser, winnerID) = ordinal > conflictingOrdinal
            ? (windowID, store, conflicting.key)
            : (conflicting.key, conflicting.value, windowID)
        var excludedPaths = takenProjectPaths(excludingWindowID: loserID)
        if let duplicatePath = loser.projectURL?.standardizedFileURL.path {
            excludedPaths.insert(duplicatePath)
        }
        excludedPaths.formUnion(duplicateFallbackExcludedPathsByWindowID[loserID] ?? [])
        duplicateFallbackExcludedPathsByWindowID[loserID] = excludedPaths
        let openedFallback = loser.resignProjectWithDuplicateTracker(
            excludingProjectPaths: excludedPaths
        )
        if !openedFallback {
            duplicateFallbackExcludedPathsByWindowID.removeValue(forKey: loserID)
        }
        focusWindow(winnerID)
        windowCompositionRevision &+= 1
    }

    private func windowID(for store: BeadStore) -> UUID? {
        storesByWindowID.first { $0.value === store }?.key
    }

    func appPreferencesDidChange(from store: BeadStore) {
        forEachStore(excluding: store) { $0.reloadAppPreferences() }
    }

    func recentProjectsDidChange(from store: BeadStore) {
        forEachStore(excluding: store) { $0.reloadRecentProjects() }
    }

    private func forEachStore(excluding store: BeadStore, _ body: (BeadStore) -> Void) {
        for peer in storesByWindowID.values where peer !== store {
            body(peer)
        }
        if let detachedStore, detachedStore !== store {
            body(detachedStore)
        }
    }
}
