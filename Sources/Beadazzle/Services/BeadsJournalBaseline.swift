import Foundation

struct BeadsJournalBaseline: Sendable {
    let environment: BeadsProjectEnvironment
    let source: BeadsDataSource
    var snapshot: BeadsSnapshot
    var cursor: Int64
    var anchor: BeadsJournalRecord?
    let configuration: [ProjectSnapshotFileFingerprint]
    var allowsIncrementalRefresh = true
    private(set) var hasProjectedChanges = false

    static func configurationFiles(_ environment: BeadsProjectEnvironment) -> [ProjectSnapshotFileFingerprint] {
        // Include the local redirect as well as the effective tracker. A redirect
        // edit must invalidate a cache even when the old tracker has not changed.
        let directories = [environment.projectURL.appendingPathComponent(".beads"), environment.beadsDirectoryURL]
        var seen: Set<URL> = []
        return directories.flatMap { directory in
            ["config.yaml", "metadata.json", "redirect", ".local_version"].compactMap { name in
                let url = directory.appendingPathComponent(name).standardizedFileURL
                return seen.insert(url).inserted ? .load(url) : nil
            }
        }
    }

    func configurationMatches(_ environment: BeadsProjectEnvironment) -> Bool {
        self.environment.context == environment.context
            && self.environment.projectURL == environment.projectURL
            && self.environment.beadsDirectoryURL == environment.beadsDirectoryURL
            && configuration == Self.configurationFiles(environment)
    }

    func matches(_ environment: BeadsProjectEnvironment) -> Bool {
        configurationMatches(environment)
            && ProjectSnapshotFileFingerprint.load(source.url) == .source(source)
    }

    func applying(_ records: [BeadsJournalRecord]) throws -> Self {
        guard records.count < BeadsJournalPage.recordLimit else {
            throw BeadsJournalError.pageFull
        }
        var remaining = records[...]
        if let anchor {
            // Re-read the last applied record. A reset, another journal or a cursor
            // above the head must not be mistaken for an empty, current feed.
            guard remaining.first == anchor else { throw BeadsJournalError.anchorChanged }
            remaining = remaining.dropFirst()
        } else if cursor != 0 {
            throw BeadsJournalError.anchorChanged
        }
        guard !remaining.isEmpty else { throw BeadsJournalError.emptyFeed }
        var copy = self
        var indices: [String: Int] = [:]
        for (index, issue) in snapshot.issues.enumerated() {
            guard indices.updateValue(index, forKey: issue.id) == nil else {
                throw BeadsJournalError.duplicateIssueID
            }
        }
        for record in remaining {
            guard copy.cursor < Int64.max, record.sequence == copy.cursor + 1,
                  let index = indices[record.issueID] else {
                throw BeadsJournalError.sequenceGap
            }
            copy.snapshot.issues[index] = try record.replacingFields(in: copy.snapshot.issues[index])
            copy.cursor = record.sequence
            copy.anchor = record
        }
        copy.hasProjectedChanges = true
        return copy
    }
}

struct BeadsJournalDiscoveryCache: Sendable {
    enum Availability: Equatable, Sendable {
        case enabled, disabled, historyTooLarge, backlogTooLarge
    }

    let configuration: [ProjectSnapshotFileFingerprint]
    var availability: Availability
    var position: BeadsJournalPosition? = nil

    func matches(_ environment: BeadsProjectEnvironment) -> Bool {
        configuration == BeadsJournalBaseline.configurationFiles(environment)
    }

    var inactiveReason: String? {
        switch availability {
        case .enabled: nil
        case .disabled: "The Beads journal is not enabled. Normal refresh remains in use."
        case .historyTooLarge: "Journal history exceeds the read limit. Normal refresh remains in use. Reopen the project or turn this option off and on to retry."
        case .backlogTooLarge: "Too many changes arrived since the saved journal position. Normal refresh remains in use. Reopen the project or turn this option off and on to retry."
        }
    }
}

struct BeadsJournalPosition: Sendable {
    let cursor: Int64
    let anchor: BeadsJournalRecord?
    let configuration: [ProjectSnapshotFileFingerprint]

    static func discover(
        commands: any BeadsCommanding, environment: BeadsProjectEnvironment,
        baseline: BeadsJournalBaseline?, cache: BeadsJournalDiscoveryCache?
    ) async throws -> (position: Self?, cache: BeadsJournalDiscoveryCache?) {
        guard environment.storageMode == .embedded else { return (nil, nil) }
        let configuration = BeadsJournalBaseline.configurationFiles(environment)
        var cache = cache.flatMap { $0.matches(environment) ? $0 : nil }
        let previous = baseline.flatMap {
            $0.configurationMatches(environment) ? Self(cursor: $0.cursor, anchor: $0.anchor, configuration: configuration) : nil
        } ?? cache?.position
        if cache == nil {
            let enabled: Bool
            if previous != nil { enabled = true }
            else { enabled = try await commands.isEventsJournalEnabled(projectURL: environment.projectURL) }
            cache = BeadsJournalDiscoveryCache(configuration: configuration, availability: enabled ? .enabled : .disabled)
        }
        guard cache?.availability == .enabled else { return (nil, cache) }
        do {
            let position = try await readPosition(commands: commands, environment: environment, previous: previous)
            cache?.position = position
            return (position, cache)
        } catch is CancellationError { throw CancellationError() }
        catch {
            BeadsJournalError.logFallback(error)
            if error as? BeadsJournalError == .pageFull {
                cache?.availability = previous == nil ? .historyTooLarge : .backlogTooLarge
            }
            // A changed anchor must not be retried forever from the old position.
            cache?.position = nil
            return (nil, cache)
        }
    }

    private static func readPosition(
        commands: any BeadsCommanding, environment: BeadsProjectEnvironment, previous: Self?
    ) async throws -> Self {
        let configuration = BeadsJournalBaseline.configurationFiles(environment)
        let page = try await commands.readEventsJournal(
            projectURL: environment.projectURL, since: max(0, (previous?.cursor ?? 0) - 1), limit: BeadsJournalPage.recordLimit
        )
        switch page {
        case .truncated(let head):
            guard case .records(let records) = try await commands.readEventsJournal(
                projectURL: environment.projectURL, since: max(0, head - 1), limit: 2
            ), head == 0 ? records.isEmpty : (records.count == 1 && records.first?.sequence == head) else {
                throw BeadsJournalError.anchorChanged
            }
            return Self(cursor: head, anchor: records.first, configuration: configuration)
        case .records(let records):
            guard records.count < BeadsJournalPage.recordLimit else { throw BeadsJournalError.pageFull }
            var remaining = records[...]
            var cursor = previous?.cursor ?? 0
            if let anchor = previous?.anchor {
                guard remaining.first == anchor else { throw BeadsJournalError.anchorChanged }
                remaining = remaining.dropFirst()
            } else if cursor != 0 {
                throw BeadsJournalError.anchorChanged
            }
            for record in remaining {
                guard cursor < Int64.max, record.sequence == cursor + 1 else { throw BeadsJournalError.sequenceGap }
                cursor = record.sequence
            }
            return Self(cursor: cursor, anchor: records.last ?? previous?.anchor, configuration: configuration)
        }
    }

    func baseline(
        commands: any BeadsCommanding, loaded: LoadedProject
    ) async throws -> BeadsJournalBaseline? {
        guard loaded.snapshotRefreshWarning == nil,
              configuration == BeadsJournalBaseline.configurationFiles(loaded.environment) else {
            throw BeadsJournalError.configurationChanged
        }
        guard case .records(let records) = try await commands.readEventsJournal(
                projectURL: loaded.environment.projectURL, since: max(0, cursor - 1), limit: 2
              ) else { throw BeadsJournalError.anchorChanged }
        // Only bind a snapshot and cursor across a quiet export. Replaying the
        // interval over a snapshot that already contains part of it is not safe.
        guard cursor == 0 ? records.isEmpty : (records.count == 1 && records.first == anchor) else {
            throw BeadsJournalError.busyBaseline
        }
        return BeadsJournalBaseline(
            environment: loaded.environment, source: loaded.source, snapshot: loaded.snapshot,
            cursor: cursor, anchor: records.first, configuration: configuration
        )
    }
}
