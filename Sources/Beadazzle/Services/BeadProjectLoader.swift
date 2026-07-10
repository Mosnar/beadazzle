import Foundation

/// The raw status/type definitions read from `bd` (`statuses`/`types --json`), before
/// they are merged with the statuses/types actually observed on issues. These change only
/// when someone edits custom definitions, so they are cached across reloads to avoid
/// spawning two `bd` subprocesses on every project reload (the embedded-Dolt startup cost
/// of those reads dominated the reload path).
struct BeadSemanticDefinitions: Sendable, Equatable {
    var statuses: [BeadStatusDefinition]
    var types: [BeadTypeDefinition]
}

struct LoadedProject: Sendable {
    var source: BeadsDataSource
    var snapshot: BeadsSnapshot
    var index: BeadProjectIndex
    var snapshotRefreshWarning: String?
    /// The definitions used to build `index.semantics`, so the caller can cache them and
    /// pass them back on subsequent reloads. `nil` when the `bd` read failed (built-in
    /// fallbacks were used) — the caller should not cache a failure.
    var definitions: BeadSemanticDefinitions?
}

struct BeadProjectLoader: Sendable {
    private let commands: any BeadsCommanding

    init(commands: any BeadsCommanding) {
        self.commands = commands
    }

    /// - Parameter cachedDefinitions: reuse these status/type definitions instead of
    ///   reading them from `bd`. Pass the definitions returned by a previous load to skip
    ///   the two `bd --readonly` subprocesses on reloads where definitions can't have
    ///   changed (data-source-change reloads, post-mutation reconciles).
    func loadProject(
        projectURL: URL,
        staleCutoffDays: Int = BeadProjectIndex.defaultStaleCutoffDays,
        hidesParentsWithOnlyBlockedChildrenInReady: Bool = true,
        cachedDefinitions: BeadSemanticDefinitions? = nil
    ) async throws -> LoadedProject {
        let loadedSnapshot = try await Task.detached(priority: .userInitiated) {
            try PerformanceSignposts.load.withIntervalSignpost("SnapshotRead") {
                try BeadsSnapshotReader().loadProject(projectURL: projectURL)
            }
        }.value
        let definitions: BeadSemanticDefinitions?
        if let cachedDefinitions {
            definitions = cachedDefinitions
        } else {
            definitions = await loadDefinitions(projectURL: projectURL)
        }
        let metadata = BeadsMetadataService()
        let semantics = metadata.loadSemantics(
            projectURL: projectURL,
            issues: loadedSnapshot.snapshot.issues,
            statusDefinitions: definitions?.statuses,
            typeDefinitions: definitions?.types
        )

        return await Task.detached(priority: .userInitiated) {
            let index = PerformanceSignposts.load.withIntervalSignpost("IndexBuild") {
                BeadProjectIndex(
                    issues: loadedSnapshot.snapshot.issues,
                    dependencies: loadedSnapshot.snapshot.dependencies,
                    semantics: semantics,
                    staleCutoffDays: staleCutoffDays,
                    hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
                )
            }
            return LoadedProject(
                source: loadedSnapshot.source,
                snapshot: loadedSnapshot.snapshot,
                index: index,
                snapshotRefreshWarning: nil,
                definitions: definitions
            )
        }.value
    }

    func initializeAndLoadProject(
        projectURL: URL,
        options: BeadsInitOptions,
        staleCutoffDays: Int = BeadProjectIndex.defaultStaleCutoffDays,
        hidesParentsWithOnlyBlockedChildrenInReady: Bool = true
    ) async throws -> LoadedProject {
        try await commands.initialize(projectURL: projectURL, options: options)
        return try await loadProject(
            projectURL: projectURL,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
        )
    }

    func exportAndLoadProject(
        projectURL: URL,
        staleCutoffDays: Int = BeadProjectIndex.defaultStaleCutoffDays,
        hidesParentsWithOnlyBlockedChildrenInReady: Bool = true,
        cachedDefinitions: BeadSemanticDefinitions? = nil
    ) async throws -> LoadedProject {
        guard Self.beadsDirectoryExists(at: projectURL) else {
            throw BeadError.projectMissingDataSource(projectURL)
        }
        try await commands.exportReadableSnapshot(projectURL: projectURL)
        return try await loadProject(
            projectURL: projectURL,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
            cachedDefinitions: cachedDefinitions
        )
    }

    /// Re-exports the readable JSONL snapshot before reading, then loads.
    ///
    /// Dolt-backed (embedded) projects only back up `issues.jsonl` on a periodic
    /// timer (default: every 15 minutes), so `bd` writes are not reflected in the
    /// snapshot Beadazzle reads until we force an export. Callers that must observe
    /// recent writes — post-mutation reloads and explicit user refreshes — go
    /// through here so the read reflects current state.
    ///
    /// The export is best-effort: if it fails (or `bd` is unavailable) we still
    /// load the existing snapshot rather than surfacing an error.
    func refreshSnapshotAndLoadProject(
        projectURL: URL,
        staleCutoffDays: Int = BeadProjectIndex.defaultStaleCutoffDays,
        hidesParentsWithOnlyBlockedChildrenInReady: Bool = true,
        cachedDefinitions: BeadSemanticDefinitions? = nil
    ) async throws -> LoadedProject {
        var snapshotRefreshWarning: String?
        if Self.beadsDirectoryExists(at: projectURL) {
            do {
                try await commands.exportReadableSnapshot(projectURL: projectURL)
            } catch {
                snapshotRefreshWarning = error.localizedDescription
            }
        }
        var loadedProject = try await loadProject(
            projectURL: projectURL,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
            cachedDefinitions: cachedDefinitions
        )
        loadedProject.snapshotRefreshWarning = snapshotRefreshWarning
        return loadedProject
    }

    /// Reads status/type definitions from `bd`. Returns `nil` if the read fails, so the
    /// caller falls back to built-in definitions without caching the failure.
    private func loadDefinitions(projectURL: URL) async -> BeadSemanticDefinitions? {
        do {
            let statuses = try await commands.loadStatusDefinitions(projectURL: projectURL)
            let types = try await commands.loadTypeDefinitions(projectURL: projectURL)
            return BeadSemanticDefinitions(statuses: statuses, types: types)
        } catch {
            return nil
        }
    }

    private static func beadsDirectoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let beadsURL = url.appendingPathComponent(".beads", isDirectory: true)
        return FileManager.default.fileExists(atPath: beadsURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
