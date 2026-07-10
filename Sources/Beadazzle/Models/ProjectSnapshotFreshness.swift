import Foundation

struct ProjectSnapshotFileFingerprint: Equatable, Sendable {
    var path: String
    var exists: Bool
    var size: Int64?
    var modifiedAt: Date?

    static func load(_ url: URL, fileManager: FileManager = .default) -> ProjectSnapshotFileFingerprint {
        let standardizedURL = url.standardizedFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: standardizedURL.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return ProjectSnapshotFileFingerprint(
                path: standardizedURL.path,
                exists: false,
                size: nil,
                modifiedAt: nil
            )
        }

        return ProjectSnapshotFileFingerprint(
            path: standardizedURL.path,
            exists: true,
            size: attributes[.size] as? Int64 ?? (attributes[.size] as? NSNumber)?.int64Value,
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }

    static func source(_ source: BeadsDataSource) -> ProjectSnapshotFileFingerprint {
        ProjectSnapshotFileFingerprint(
            path: source.url.standardizedFileURL.path,
            exists: true,
            size: source.size,
            modifiedAt: source.modifiedAt
        )
    }
}

struct ProjectSnapshotFreshnessFiles: Equatable, Sendable {
    var activeSource: ProjectSnapshotFileFingerprint
    var legacySQLite: ProjectSnapshotFileFingerprint
    var exportState: ProjectSnapshotFileFingerprint
    var lastTouched: ProjectSnapshotFileFingerprint

    static func load(projectURL: URL, source: BeadsDataSource) -> ProjectSnapshotFreshnessFiles {
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        return ProjectSnapshotFreshnessFiles(
            activeSource: .load(source.url),
            legacySQLite: .load(beadsURL.appendingPathComponent("beads.db")),
            exportState: .load(beadsURL.appendingPathComponent("export-state.json")),
            lastTouched: .load(beadsURL.appendingPathComponent("last-touched"))
        )
    }

    static func loaded(projectURL: URL, source: BeadsDataSource) -> ProjectSnapshotFreshnessFiles {
        var files = load(projectURL: projectURL, source: source)
        files.activeSource = .source(source)
        return files
    }

    func requiresReload(comparedTo loadedFiles: ProjectSnapshotFreshnessFiles) -> Bool {
        activeSource != loadedFiles.activeSource || legacySQLite != loadedFiles.legacySQLite
    }

    func markerChanged(comparedTo loadedFiles: ProjectSnapshotFreshnessFiles) -> Bool {
        exportState != loadedFiles.exportState || lastTouched != loadedFiles.lastTouched
    }
}

struct ProjectSnapshotFreshness: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case unknown
        case current
        case refreshing
        case possiblyStale
    }

    struct Evaluation: Equatable, Sendable {
        var freshness: ProjectSnapshotFreshness
        var requiresReload: Bool
    }

    var state: State
    var message: String
    var detail: String?
    var evaluatedAt: Date
    var loadedFiles: ProjectSnapshotFreshnessFiles?
    var observedFiles: ProjectSnapshotFreshnessFiles?

    static var unknown: ProjectSnapshotFreshness {
        ProjectSnapshotFreshness(
            state: .unknown,
            message: "Freshness unknown",
            detail: nil,
            evaluatedAt: Date(),
            loadedFiles: nil,
            observedFiles: nil
        )
    }

    static func loaded(projectURL: URL, source: BeadsDataSource) -> ProjectSnapshotFreshness {
        let files = ProjectSnapshotFreshnessFiles.loaded(projectURL: projectURL, source: source)
        return ProjectSnapshotFreshness(
            state: .current,
            message: source.kind == .jsonl ? "Snapshot current" : "Data source current",
            detail: nil,
            evaluatedAt: Date(),
            loadedFiles: files,
            observedFiles: files
        )
    }

    func evaluatingCurrentFiles(projectURL: URL, source: BeadsDataSource) -> Evaluation {
        let observedFiles = ProjectSnapshotFreshnessFiles.load(projectURL: projectURL, source: source)
        guard let loadedFiles else {
            return Evaluation(
                freshness: ProjectSnapshotFreshness(
                    state: .refreshing,
                    message: "Refreshing snapshot",
                    detail: "Loaded snapshot baseline is unavailable.",
                    evaluatedAt: Date(),
                    loadedFiles: nil,
                    observedFiles: observedFiles
                ),
                requiresReload: true
            )
        }

        guard !observedFiles.requiresReload(comparedTo: loadedFiles) else {
            return Evaluation(
                freshness: ProjectSnapshotFreshness(
                    state: .refreshing,
                    message: "Refreshing snapshot",
                    detail: "The active snapshot changed on disk.",
                    evaluatedAt: Date(),
                    loadedFiles: loadedFiles,
                    observedFiles: observedFiles
                ),
                requiresReload: true
            )
        }

        guard !observedFiles.markerChanged(comparedTo: loadedFiles) else {
            return Evaluation(
                freshness: ProjectSnapshotFreshness(
                    state: .possiblyStale,
                    message: "Snapshot may be stale",
                    detail: "A Beads export marker changed before the readable snapshot changed.",
                    evaluatedAt: Date(),
                    loadedFiles: loadedFiles,
                    observedFiles: observedFiles
                ),
                requiresReload: false
            )
        }

        return Evaluation(
            freshness: ProjectSnapshotFreshness(
                state: .current,
                message: source.kind == .jsonl ? "Snapshot current" : "Data source current",
                detail: nil,
                evaluatedAt: Date(),
                loadedFiles: loadedFiles,
                observedFiles: observedFiles
            ),
            requiresReload: false
        )
    }

    func refreshing(projectURL: URL, source: BeadsDataSource) -> ProjectSnapshotFreshness {
        ProjectSnapshotFreshness(
            state: .refreshing,
            message: "Refreshing snapshot",
            detail: nil,
            evaluatedAt: Date(),
            loadedFiles: loadedFiles,
            observedFiles: ProjectSnapshotFreshnessFiles.load(projectURL: projectURL, source: source)
        )
    }

    func failed(_ message: String) -> ProjectSnapshotFreshness {
        ProjectSnapshotFreshness(
            state: .unknown,
            message: "Freshness unknown",
            detail: message,
            evaluatedAt: Date(),
            loadedFiles: loadedFiles,
            observedFiles: observedFiles
        )
    }

    func possiblyStale(afterFailedRefresh message: String) -> ProjectSnapshotFreshness {
        ProjectSnapshotFreshness(
            state: .possiblyStale,
            message: "Snapshot may be stale",
            detail: "Could not export the latest Beads data. \(message)",
            evaluatedAt: Date(),
            loadedFiles: loadedFiles,
            observedFiles: observedFiles
        )
    }
}
