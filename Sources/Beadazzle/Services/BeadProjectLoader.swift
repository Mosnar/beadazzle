import Foundation

/// The raw status/type definitions read from `bd` (`statuses`/`types --json`), before
/// they are merged with the statuses/types actually observed on issues. These change only
/// when someone edits custom definitions, so they are cached across reloads to avoid
/// spawning two `bd` subprocesses on every project reload (the embedded-Dolt startup cost
/// of those reads dominated the reload path).
struct BeadSemanticDefinitions: Codable, Sendable, Equatable {
    var statuses: [BeadStatusDefinition]
    var types: [BeadTypeDefinition]
}

/// The outcome of reading status/type definitions from `bd`.
struct LoadedSemanticDefinitions: Sendable {
    var definitions: BeadSemanticDefinitions?
    /// Set when the read failed because the tracker needs a one-time `bd` migration.
    var schemaSkew: BeadsSchemaSkew?
}

struct LoadedProject: Sendable {
    var environment: BeadsProjectEnvironment
    var source: BeadsDataSource
    var snapshot: BeadsSnapshot
    var index: BeadProjectIndex
    var snapshotRefreshWarning: String?
    /// Set when `bd` refused to read this tracker because its schema is incompatible with
    /// the installed binary. The snapshot still loads (it is a plain file), so the project
    /// opens read-only while an upward migration or guarded recovery is offered.
    var schemaSkew: BeadsSchemaSkew?
    /// The definitions used to build `index.semantics`, so the caller can cache them and
    /// pass them back on subsequent reloads. `nil` when the `bd` read failed (built-in
    /// fallbacks were used) — the caller should not cache a failure.
    var definitions: BeadSemanticDefinitions?
    /// True only when this load actually ran the metadata commands. Cached definitions
    /// must not renew their own freshness timestamp.
    var definitionsLoadedFromCommands: Bool
    var journalBaseline: BeadsJournalBaseline? = nil
    var journalDiscoveryCache: BeadsJournalDiscoveryCache? = nil
    var journalRefresh: BeadsJournalRefreshResult = .none
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
        cachedDefinitions: BeadSemanticDefinitions? = nil,
        cachedDefinitionsTrackerDirectoryURL: URL? = nil,
        cachedEnvironment: BeadsProjectEnvironment? = nil,
        loadsDefinitionsIfMissing: Bool = true,
        preparedSnapshot: LoadedBeadsSnapshot? = nil
    ) async throws -> LoadedProject {
        let environment = try await resolveEnvironment(
            projectURL: projectURL,
            cachedEnvironment: cachedEnvironment
        )
        var exportPreparedSnapshot = preparedSnapshot
        if preparedSnapshot == nil,
           cachedEnvironment == nil,
           environment.storageMode.refreshesWhenAppActivates {
            do {
                let exportResult = try await commands.exportReadableSnapshotWithResult(
                    projectURL: projectURL,
                    beadsDirectoryURL: environment.beadsDirectoryURL
                )
                exportPreparedSnapshot = exportResult.loadedSnapshot
            } catch {
                let exportError = error
                do {
                    var loadedProject = try await loadResolvedProject(
                        projectURL: projectURL,
                        environment: environment,
                        staleCutoffDays: staleCutoffDays,
                        hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
                        cachedDefinitions: cachedDefinitions,
                        cachedDefinitionsTrackerDirectoryURL: cachedDefinitionsTrackerDirectoryURL,
                        loadsDefinitionsIfMissing: loadsDefinitionsIfMissing,
                        preparedSnapshot: nil
                    )
                    loadedProject.snapshotRefreshWarning = exportError.localizedDescription
                    return loadedProject
                } catch BeadError.projectMissingDataSource {
                    throw exportError
                }
            }
        }
        return try await loadResolvedProject(
            projectURL: projectURL,
            environment: environment,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
            cachedDefinitions: cachedDefinitions,
            cachedDefinitionsTrackerDirectoryURL: cachedDefinitionsTrackerDirectoryURL,
            loadsDefinitionsIfMissing: loadsDefinitionsIfMissing,
            preparedSnapshot: exportPreparedSnapshot
        )
    }

    private func loadResolvedProject(
        projectURL: URL,
        environment: BeadsProjectEnvironment,
        staleCutoffDays: Int,
        hidesParentsWithOnlyBlockedChildrenInReady: Bool,
        cachedDefinitions: BeadSemanticDefinitions?,
        cachedDefinitionsTrackerDirectoryURL: URL?,
        loadsDefinitionsIfMissing: Bool,
        preparedSnapshot: LoadedBeadsSnapshot?
    ) async throws -> LoadedProject {
        let loadedSnapshot: LoadedBeadsSnapshot
        if let preparedSnapshot,
           preparedSnapshot.source.url.deletingLastPathComponent().standardizedFileURL.path
                == environment.beadsDirectoryURL.standardizedFileURL.path {
            loadedSnapshot = preparedSnapshot
        } else {
            let snapshotTask = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let snapshot = try PerformanceSignposts.load.withIntervalSignpost("SnapshotRead") {
                    try BeadsSnapshotReader().loadProject(
                        projectURL: projectURL,
                        beadsDirectoryURL: environment.beadsDirectoryURL
                    )
                }
                try Task.checkCancellation()
                return snapshot
            }
            loadedSnapshot = try await withTaskCancellationHandler {
                try await snapshotTask.value
            } onCancel: {
                snapshotTask.cancel()
            }
        }
        try Task.checkCancellation()
        let definitions: BeadSemanticDefinitions?
        let definitionsLoadedFromCommands: Bool
        var schemaSkew: BeadsSchemaSkew?
        let cacheMatchesResolvedTracker = cachedDefinitionsTrackerDirectoryURL?
            .standardizedFileURL.path == environment.beadsDirectoryURL.standardizedFileURL.path
        if let cachedDefinitions, cacheMatchesResolvedTracker {
            definitions = cachedDefinitions
            definitionsLoadedFromCommands = false
        } else if loadsDefinitionsIfMissing {
            let loadedDefinitions = await loadDefinitions(projectURL: projectURL)
            definitions = loadedDefinitions.definitions
            definitionsLoadedFromCommands = loadedDefinitions.definitions != nil
            schemaSkew = loadedDefinitions.schemaSkew
        } else {
            definitions = nil
            definitionsLoadedFromCommands = false
        }
        try Task.checkCancellation()
        let metadata = BeadsMetadataService()
        let semantics = metadata.loadSemantics(
            projectURL: projectURL,
            issues: loadedSnapshot.snapshot.issues,
            statusDefinitions: definitions?.statuses,
            typeDefinitions: definitions?.types
        )

        let indexTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let index = PerformanceSignposts.load.withIntervalSignpost("IndexBuild") {
                BeadProjectIndex(
                    issues: loadedSnapshot.snapshot.issues,
                    dependencies: loadedSnapshot.snapshot.dependencies,
                    semantics: semantics,
                    staleCutoffDays: staleCutoffDays,
                    hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady
                )
            }
            try Task.checkCancellation()
            return LoadedProject(
                environment: environment,
                source: loadedSnapshot.source,
                snapshot: loadedSnapshot.snapshot,
                index: index,
                snapshotRefreshWarning: nil,
                schemaSkew: schemaSkew,
                definitions: definitions,
                definitionsLoadedFromCommands: definitionsLoadedFromCommands
            )
        }
        return try await withTaskCancellationHandler {
            try await indexTask.value
        } onCancel: {
            indexTask.cancel()
        }
    }

    func exportAndLoadProject(
        projectURL: URL,
        staleCutoffDays: Int = BeadProjectIndex.defaultStaleCutoffDays,
        hidesParentsWithOnlyBlockedChildrenInReady: Bool = true,
        cachedDefinitions: BeadSemanticDefinitions? = nil,
        cachedDefinitionsTrackerDirectoryURL: URL? = nil,
        cachedEnvironment: BeadsProjectEnvironment? = nil,
        loadsDefinitionsIfMissing: Bool = true
    ) async throws -> LoadedProject {
        let environment = try await resolveEnvironment(
            projectURL: projectURL,
            cachedEnvironment: cachedEnvironment
        )
        guard Self.directoryExists(at: environment.beadsDirectoryURL) else {
            throw BeadError.commandFailed(
                command: "bd context --json",
                output: "The reported tracker directory does not exist: \(environment.beadsDirectoryURL.path)"
            )
        }
        let exportResult: ReadableSnapshotExportResult
        do {
            exportResult = try await commands.exportReadableSnapshotWithResult(
                projectURL: projectURL,
                beadsDirectoryURL: environment.beadsDirectoryURL
            )
        } catch {
            // There is no snapshot to fall back on here, so this failure blocks the whole
            // project. A schema mismatch is a common and fixable cause — `bd` can refuse
            // to open either older or newer schemas, and a first-run upward migration on
            // a large tracker can outlast the export timeout. Ask `bd` directly rather than
            // guessing from the export failure, which reports a timeout, not the skew.
            if let skew = try await detectSchemaSkew(projectURL: projectURL, exportError: error) {
                throw BeadError.trackerSchemaIncompatible(skew)
            }
            throw error
        }
        return try await loadResolvedProject(
            projectURL: projectURL,
            environment: environment,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
            cachedDefinitions: cachedDefinitions,
            cachedDefinitionsTrackerDirectoryURL: cachedDefinitionsTrackerDirectoryURL,
            loadsDefinitionsIfMissing: loadsDefinitionsIfMissing,
            preparedSnapshot: exportResult.loadedSnapshot
        )
    }

    /// Confirms whether a failed export was caused by an incompatible tracker schema.
    /// Runs only on the failure path, so the successful open still costs no extra subprocess.
    private func detectSchemaSkew(
        projectURL: URL,
        exportError: Error
    ) async throws -> BeadsSchemaSkew? {
        if let skew = BeadsSchemaSkew.detect(in: exportError) {
            return skew
        }
        try Task.checkCancellation()
        return await loadDefinitions(projectURL: projectURL).schemaSkew
    }

    /// Re-exports the readable JSONL snapshot before reading, then loads.
    ///
    /// Automatic JSONL export is optional and may be throttled, so `bd` writes are
    /// not guaranteed to appear immediately in the readable snapshot. Callers that must observe
    /// recent writes — post-mutation reloads and explicit user refreshes — go
    /// through here so the read reflects current state.
    ///
    /// The export is best-effort: if it fails (or `bd` is unavailable) we still
    /// load the existing snapshot rather than surfacing an error.
    func refreshSnapshotAndLoadProject(
        projectURL: URL,
        staleCutoffDays: Int = BeadProjectIndex.defaultStaleCutoffDays,
        hidesParentsWithOnlyBlockedChildrenInReady: Bool = true,
        cachedDefinitions: BeadSemanticDefinitions? = nil,
        cachedDefinitionsTrackerDirectoryURL: URL? = nil,
        cachedEnvironment: BeadsProjectEnvironment? = nil,
        loadsDefinitionsIfMissing: Bool = true,
        usesJournalRefresh: Bool = false,
        mayApplyJournal: Bool = false,
        journalBaseline: BeadsJournalBaseline? = nil,
        journalDiscoveryCache: BeadsJournalDiscoveryCache? = nil
    ) async throws -> LoadedProject {
        let configurationChanged = cachedEnvironment.map { environment in
            if let journalDiscoveryCache { return !journalDiscoveryCache.matches(environment) }
            if let journalBaseline { return !journalBaseline.configurationMatches(environment) }
            return false
        } ?? false
        let environment = try await resolveEnvironment(
            projectURL: projectURL,
            // A cursor belongs to a resolved tracker, not a project path. Re-check
            // routing before using it, including worktree and contributor redirects.
            cachedEnvironment: usesJournalRefresh && (mayApplyJournal || configurationChanged) ? nil : cachedEnvironment
        )
        if usesJournalRefresh, mayApplyJournal,
           let journalBaseline, journalBaseline.allowsIncrementalRefresh,
           environment.storageMode == .embedded, journalBaseline.matches(environment) {
            do {
                let observedFiles = ProjectSnapshotFreshnessFiles.load(
                    projectURL: projectURL, beadsDirectoryURL: environment.beadsDirectoryURL,
                    source: journalBaseline.source
                )
                guard case .records(let records) = try await commands.readEventsJournal(
                        projectURL: projectURL, since: max(0, journalBaseline.cursor - 1),
                        limit: BeadsJournalPage.recordLimit
                      ) else { throw BeadsJournalError.requiresSnapshot }
                let advanced = try journalBaseline.applying(records)
                guard advanced.matches(environment), observedFiles == ProjectSnapshotFreshnessFiles.load(
                    projectURL: projectURL, beadsDirectoryURL: environment.beadsDirectoryURL,
                    source: advanced.source
                ) else { throw BeadsJournalError.configurationChanged }
                var loaded = try await loadResolvedProject(
                    projectURL: projectURL, environment: environment,
                    staleCutoffDays: staleCutoffDays,
                    hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
                    cachedDefinitions: cachedDefinitions,
                    cachedDefinitionsTrackerDirectoryURL: cachedDefinitionsTrackerDirectoryURL,
                    loadsDefinitionsIfMissing: loadsDefinitionsIfMissing,
                    preparedSnapshot: LoadedBeadsSnapshot(source: advanced.source, snapshot: advanced.snapshot)
                )
                loaded.journalBaseline = advanced
                var cache = journalDiscoveryCache ?? BeadsJournalDiscoveryCache(
                    configuration: advanced.configuration, availability: .enabled
                )
                cache.position = BeadsJournalPosition(
                    cursor: advanced.cursor, anchor: advanced.anchor, configuration: advanced.configuration
                )
                loaded.journalDiscoveryCache = cache
                loaded.journalRefresh = .projected(observedFiles: observedFiles)
                return loaded
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // This is an optional optimization. Any uncertainty takes the normal
                // export path; partial records and cursors are never installed.
                BeadsJournalError.logFallback(error)
            }
        } else if usesJournalRefresh, mayApplyJournal, journalBaseline != nil {
            BeadsJournalError.logFallback(BeadsJournalError.configurationChanged)
        }
        let journalPosition: BeadsJournalPosition?
        var discoveryCache = journalDiscoveryCache
        if usesJournalRefresh {
            do {
                let discovery = try await BeadsJournalPosition.discover(
                    commands: commands, environment: environment,
                    baseline: journalBaseline, cache: journalDiscoveryCache
                )
                journalPosition = discovery.position
                discoveryCache = discovery.cache
            } catch is CancellationError { throw CancellationError() }
            catch {
                BeadsJournalError.logFallback(error)
                journalPosition = nil
                discoveryCache = nil
            }
        } else {
            journalPosition = nil
            discoveryCache = nil
        }
        var snapshotRefreshWarning: String?
        var preparedSnapshot: LoadedBeadsSnapshot?
        if Self.directoryExists(at: environment.beadsDirectoryURL) {
            do {
                let exportResult = try await commands.exportReadableSnapshotWithResult(
                    projectURL: projectURL,
                    beadsDirectoryURL: environment.beadsDirectoryURL
                )
                preparedSnapshot = exportResult.loadedSnapshot
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                snapshotRefreshWarning = error.localizedDescription
                // A failed verification must not roll a newer in-memory view back
                // to the older disk snapshot that the fast path deliberately left alone.
                if usesJournalRefresh, let journalBaseline, journalBaseline.hasProjectedChanges,
                   journalBaseline.matches(environment) {
                    preparedSnapshot = LoadedBeadsSnapshot(
                        source: journalBaseline.source, snapshot: journalBaseline.snapshot
                    )
                }
            }
        }
        var loadedProject = try await loadResolvedProject(
            projectURL: projectURL,
            environment: environment,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
            cachedDefinitions: cachedDefinitions,
            cachedDefinitionsTrackerDirectoryURL: cachedDefinitionsTrackerDirectoryURL,
            loadsDefinitionsIfMissing: loadsDefinitionsIfMissing,
            preparedSnapshot: preparedSnapshot
        )
        loadedProject.snapshotRefreshWarning = snapshotRefreshWarning
        loadedProject.journalDiscoveryCache = discoveryCache
        if let journalPosition, snapshotRefreshWarning == nil {
            do {
                loadedProject.journalBaseline = try await journalPosition.baseline(commands: commands, loaded: loadedProject)
            } catch is CancellationError { throw CancellationError() }
            catch {
                BeadsJournalError.logFallback(error)
                loadedProject.journalBaseline = nil
            }
        } else if usesJournalRefresh, snapshotRefreshWarning != nil, var journalBaseline,
                  journalBaseline.hasProjectedChanges, journalBaseline.matches(environment) {
            journalBaseline.allowsIncrementalRefresh = false
            loadedProject.journalBaseline = journalBaseline
            loadedProject.journalRefresh = .heldAfterFailedVerification
        }
        return loadedProject
    }

    /// Reads status/type definitions from `bd`. Returns `nil` definitions if the read
    /// fails, so the caller falls back to built-in definitions without caching the
    /// failure, and reports schema skew when that is what caused it.
    func loadDefinitions(projectURL: URL) async -> LoadedSemanticDefinitions {
        do {
            let statuses = try await commands.loadStatusDefinitions(projectURL: projectURL)
            let types = try await commands.loadTypeDefinitions(projectURL: projectURL)
            return LoadedSemanticDefinitions(
                definitions: BeadSemanticDefinitions(statuses: statuses, types: types),
                schemaSkew: nil
            )
        } catch {
            return LoadedSemanticDefinitions(
                definitions: nil,
                schemaSkew: BeadsSchemaSkew.detect(in: error)
            )
        }
    }

    private func resolveEnvironment(
        projectURL: URL,
        cachedEnvironment: BeadsProjectEnvironment?
    ) async throws -> BeadsProjectEnvironment {
        if let cachedEnvironment {
            return cachedEnvironment
        }
        do {
            let context = try await commands.loadProjectContext(projectURL: projectURL)
            return try BeadsProjectEnvironment(context: context, projectURL: projectURL)
        } catch {
            if let skew = BeadsSchemaSkew.detect(in: error) {
                throw BeadError.trackerSchemaIncompatible(skew)
            }
            throw error
        }
    }

    private static func directoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
