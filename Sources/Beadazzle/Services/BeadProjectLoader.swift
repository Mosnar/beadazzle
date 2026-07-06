import Foundation

struct LoadedProject: Sendable {
    var source: BeadsDataSource
    var snapshot: BeadsSnapshot
    var index: BeadProjectIndex
}

struct BeadProjectLoader: Sendable {
    private let commands: any BeadsCommanding

    init(commands: any BeadsCommanding) {
        self.commands = commands
    }

    func loadProject(
        projectURL: URL,
        staleCutoffDays: Int = BeadProjectIndex.defaultStaleCutoffDays
    ) async throws -> LoadedProject {
        let loadedSnapshot = try await Task.detached(priority: .userInitiated) {
            try PerformanceSignposts.load.withIntervalSignpost("SnapshotRead") {
                try BeadsSnapshotReader().loadProject(projectURL: projectURL)
            }
        }.value
        let semantics = await loadSemantics(projectURL: projectURL, issues: loadedSnapshot.snapshot.issues)

        return await Task.detached(priority: .userInitiated) {
            let index = PerformanceSignposts.load.withIntervalSignpost("IndexBuild") {
                BeadProjectIndex(
                    issues: loadedSnapshot.snapshot.issues,
                    dependencies: loadedSnapshot.snapshot.dependencies,
                    semantics: semantics,
                    staleCutoffDays: staleCutoffDays
                )
            }
            return LoadedProject(source: loadedSnapshot.source, snapshot: loadedSnapshot.snapshot, index: index)
        }.value
    }

    func initializeAndLoadProject(
        projectURL: URL,
        options: BeadsInitOptions,
        staleCutoffDays: Int = BeadProjectIndex.defaultStaleCutoffDays
    ) async throws -> LoadedProject {
        try await commands.initialize(projectURL: projectURL, options: options)
        return try await loadProject(projectURL: projectURL, staleCutoffDays: staleCutoffDays)
    }

    func exportAndLoadProject(
        projectURL: URL,
        staleCutoffDays: Int = BeadProjectIndex.defaultStaleCutoffDays
    ) async throws -> LoadedProject {
        guard Self.beadsDirectoryExists(at: projectURL) else {
            throw BeadError.projectMissingDataSource(projectURL)
        }
        try await commands.exportReadableSnapshot(projectURL: projectURL)
        return try await loadProject(projectURL: projectURL, staleCutoffDays: staleCutoffDays)
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
        staleCutoffDays: Int = BeadProjectIndex.defaultStaleCutoffDays
    ) async throws -> LoadedProject {
        if Self.beadsDirectoryExists(at: projectURL) {
            try? await commands.exportReadableSnapshot(projectURL: projectURL)
        }
        return try await loadProject(projectURL: projectURL, staleCutoffDays: staleCutoffDays)
    }

    private func loadSemantics(projectURL: URL, issues: [BeadIssue]) async -> BeadProjectSemantics {
        let metadata = BeadsMetadataService()
        do {
            async let statuses = commands.loadStatusDefinitions(projectURL: projectURL)
            async let types = commands.loadTypeDefinitions(projectURL: projectURL)
            let statusDefinitions = try await statuses
            let typeDefinitions = try await types
            return metadata.loadSemantics(
                projectURL: projectURL,
                issues: issues,
                statusDefinitions: statusDefinitions,
                typeDefinitions: typeDefinitions
            )
        } catch {
            return metadata.loadSemantics(projectURL: projectURL, issues: issues)
        }
    }

    private static func beadsDirectoryExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let beadsURL = url.appendingPathComponent(".beads", isDirectory: true)
        return FileManager.default.fileExists(atPath: beadsURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
