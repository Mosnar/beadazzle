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
    var exportState: ProjectSnapshotFileFingerprint
    var lastTouched: ProjectSnapshotFileFingerprint

    static func load(
        projectURL: URL,
        beadsDirectoryURL: URL? = nil,
        source: BeadsDataSource
    ) -> ProjectSnapshotFreshnessFiles {
        let beadsURL = beadsDirectoryURL
            ?? projectURL.appendingPathComponent(".beads", isDirectory: true)
        return ProjectSnapshotFreshnessFiles(
            activeSource: .load(source.url),
            exportState: .load(beadsURL.appendingPathComponent("export-state.json")),
            lastTouched: .load(beadsURL.appendingPathComponent("last-touched"))
        )
    }

    static func loaded(
        projectURL: URL,
        beadsDirectoryURL: URL? = nil,
        source: BeadsDataSource
    ) -> ProjectSnapshotFreshnessFiles {
        var files = load(
            projectURL: projectURL,
            beadsDirectoryURL: beadsDirectoryURL,
            source: source
        )
        files.activeSource = .source(source)
        return files
    }

    func requiresReload(comparedTo loadedFiles: ProjectSnapshotFreshnessFiles) -> Bool {
        activeSource != loadedFiles.activeSource
    }

    func markerChanged(comparedTo loadedFiles: ProjectSnapshotFreshnessFiles) -> Bool {
        exportState != loadedFiles.exportState || lastTouched != loadedFiles.lastTouched
    }

    /// `bd export` rewrites the readable snapshot and then updates its marker files
    /// (`export-state.json` / `last-touched`) a few milliseconds later, so a strict
    /// comparison flags the snapshot we just exported as stale — which re-arms the
    /// warning indefinitely because the reconcile meant to clear it is what bumped
    /// the marker. Only treat a marker as newer when it leads the snapshot by more
    /// than this margin. Genuine external staleness clears it comfortably: embedded
    /// (Dolt-backed) projects only re-export on a multi-minute timer, so a real
    /// out-of-band `bd` write leaves the marker seconds-to-minutes ahead.
    static let markerFreshnessTolerance: TimeInterval = 5

    var hasMarkerNewerThanActiveSource: Bool {
        guard let sourceModifiedAt = activeSource.modifiedAt else { return false }
        return [exportState, lastTouched].contains { marker in
            guard marker.exists, let markerModifiedAt = marker.modifiedAt else { return false }
            return markerModifiedAt.timeIntervalSince(sourceModifiedAt) > Self.markerFreshnessTolerance
        }
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
    var isJournalProjection = false
    private var unresolvedWarning: String?

    var requiresSnapshotVerification: Bool {
        isJournalProjection || unresolvedWarning != nil
    }

    static func loadedFromJournal(files: ProjectSnapshotFreshnessFiles) -> ProjectSnapshotFreshness {
        ProjectSnapshotFreshness(
            state: .current,
            message: "Updated from change feed",
            detail: "A full snapshot check is pending.",
            evaluatedAt: Date(), loadedFiles: files, observedFiles: files,
            isJournalProjection: true
        )
    }

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

    static func loaded(
        projectURL: URL,
        beadsDirectoryURL: URL? = nil,
        source: BeadsDataSource
    ) -> ProjectSnapshotFreshness {
        let files = ProjectSnapshotFreshnessFiles.loaded(
            projectURL: projectURL,
            beadsDirectoryURL: beadsDirectoryURL,
            source: source
        )
        let isPossiblyStale = source.kind == .jsonl && files.hasMarkerNewerThanActiveSource
        return ProjectSnapshotFreshness(
            state: isPossiblyStale ? .possiblyStale : .current,
            message: isPossiblyStale
                ? "Snapshot may be stale"
                : (source.kind == .jsonl ? "Snapshot current" : "Data source current"),
            detail: isPossiblyStale
                ? "A Beads marker is newer than the readable snapshot."
                : nil,
            evaluatedAt: Date(),
            loadedFiles: files,
            observedFiles: files
        )
    }

    func evaluatingCurrentFiles(
        projectURL: URL,
        beadsDirectoryURL: URL? = nil,
        source: BeadsDataSource
    ) -> Evaluation {
        let observedFiles = ProjectSnapshotFreshnessFiles.load(
            projectURL: projectURL,
            beadsDirectoryURL: beadsDirectoryURL,
            source: source
        )
        var copy = self
        copy.observedFiles = observedFiles
        guard let loadedFiles else {
            return Evaluation(freshness: copy.updating(
                state: .refreshing, message: "Refreshing snapshot", detail: "Loaded snapshot baseline is unavailable."
            ), requiresReload: true)
        }
        guard !observedFiles.requiresReload(comparedTo: loadedFiles) else {
            return Evaluation(freshness: copy.updating(
                state: .refreshing, message: "Refreshing snapshot", detail: "The active snapshot changed on disk."
            ), requiresReload: true)
        }
        // An unrelated file event is not proof that an export failure was repaired.
        if let unresolvedWarning {
            return Evaluation(freshness: copy.updating(
                state: .possiblyStale, message: "Snapshot may be stale", detail: unresolvedWarning
            ), requiresReload: false)
        }
        if source.kind == .jsonl, observedFiles.markerChanged(comparedTo: loadedFiles) {
            return Evaluation(freshness: copy.updating(
                state: .possiblyStale, message: "Snapshot may be stale",
                detail: "A Beads export marker changed before the readable snapshot changed."
            ), requiresReload: false)
        }
        let current = isJournalProjection ? Self.loadedFromJournal(files: observedFiles) : copy.updating(
            state: .current, message: source.kind == .jsonl ? "Snapshot current" : "Data source current", detail: nil
        )
        return Evaluation(freshness: current, requiresReload: false)
    }

    func refreshing(
        projectURL: URL,
        beadsDirectoryURL: URL? = nil,
        source: BeadsDataSource
    ) -> ProjectSnapshotFreshness {
        var copy = updating(state: .refreshing, message: "Refreshing snapshot", detail: nil)
        copy.observedFiles = ProjectSnapshotFreshnessFiles.load(
            projectURL: projectURL, beadsDirectoryURL: beadsDirectoryURL, source: source
        )
        return copy
    }

    func failed(_ message: String) -> ProjectSnapshotFreshness {
        var copy = updating(state: .unknown, message: "Freshness unknown", detail: message)
        copy.unresolvedWarning = message
        return copy
    }

    func possiblyStale(afterFailedRefresh message: String) -> ProjectSnapshotFreshness {
        let warning = "Could not export the latest Beads data. \(message)"
        var copy = updating(state: .possiblyStale, message: "Snapshot may be stale", detail: warning)
        copy.unresolvedWarning = warning
        return copy
    }

    func stoppingJournalRefresh() -> Self {
        guard isJournalProjection else { return self }
        var copy = updating(state: .possiblyStale, message: "Snapshot may be stale",
                            detail: "The change feed is off. A full snapshot refresh is still needed.")
        copy.isJournalProjection = false
        copy.unresolvedWarning = unresolvedWarning ?? copy.detail
        return copy
    }

    private func updating(state: State, message: String, detail: String?) -> Self {
        var copy = self
        copy.state = state
        copy.message = message
        copy.detail = detail
        copy.evaluatedAt = Date()
        return copy
    }
}
