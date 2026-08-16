import Foundation

/// Handling for the one-time `bd` schema migration a tracker needs after a `bd` upgrade.
///
/// `bd` migrates on the first *write*-mode open, but Beadazzle reads through
/// `bd --readonly`, which cannot migrate. Without this, every read failed and the
/// project looked broken in ways that pointed at the `bd` binary rather than at the
/// tracker. The JSONL snapshot is a plain file and still loads, so the project stays
/// browsable with stale data while the upgrade is offered.
extension BeadStore {
    /// Records a pending migration reported by a failing `bd` read and, when it is safe
    /// to do so, starts it without asking.
    ///
    /// Safe means an embedded tracker with no Dolt remote: nobody else shares the
    /// database, so upgrading it cannot fork a schema out from under a teammate.
    internal func noteTrackerSchemaSkew(_ skew: BeadsSchemaSkew) {
        // A migration already under way, or a failure the user has not seen yet, must not
        // be overwritten by the next failing read reporting the same skew.
        switch trackerMigration {
        case .migrating, .failed:
            return
        case .notNeeded, .awaitingConfirmation, .ready:
            break
        }

        if let reason = trackerMigrationConfirmationReason() {
            _trackerMigration = .awaitingConfirmation(skew, reason: reason)
            return
        }
        _trackerMigration = .ready(skew)
        startTrackerMigration(confirmedByUser: false)
    }

    /// Clears migration state once `bd` reads succeed again, so a tracker migrated
    /// elsewhere (by `bd` on the command line, or in another window) stops being reported.
    internal func clearTrackerMigrationStateAfterSuccessfulRead() {
        guard trackerMigration != .notNeeded else { return }
        // Leave a running migration alone; its own completion clears it.
        guard !trackerMigration.isMigrating else { return }
        _trackerMigration = .notNeeded
    }

    /// Why this tracker must not be migrated without explicit confirmation, or `nil`
    /// when Beadazzle can safely upgrade it on its own.
    ///
    /// `bd` refuses to migrate a remote-backed database in place because migrating two
    /// clones independently forks the schema so `bd dolt pull` can no longer merge them.
    private func trackerMigrationConfirmationReason() -> BeadsTrackerMigrationConfirmationReason? {
        switch projectEnvironment?.storageMode {
        case .server, .sharedServer:
            return .sharedDatabaseMode
        case .embedded, .none:
            break
        }
        // The remote list loads asynchronously and is usually still in flight when the
        // first failing read reports the skew. Treat unknown as needing confirmation:
        // asking needlessly is recoverable, silently forking a shared schema is not.
        // `reevaluateTrackerMigrationAfterRemotesLoaded` relaxes this to an automatic
        // upgrade once the list confirms there is no remote.
        guard let remotes = projectDoltRemotes?.value else {
            return .unverifiedRemoteState
        }
        return remotes.remotes.isEmpty ? nil : .remoteBackedTracker
    }

    /// Settles a hold taken while the Dolt remote list was still loading, now that it has
    /// answered: the upgrade starts if the tracker turns out to be local-only, and stays
    /// held under the real reason if it does not.
    ///
    /// Naming the real reason matters as much as starting the upgrade. A hold recorded
    /// against an unknown remote state tells the user to continue if the tracker is local;
    /// leaving that on screen after the list has proven there *is* a remote would advise
    /// exactly the migration `bd` refuses, in the case where getting it wrong is silent
    /// and unrecoverable.
    internal func reevaluateTrackerMigrationAfterRemotesLoaded() {
        guard case .awaitingConfirmation(let skew, let heldReason) = trackerMigration else {
            return
        }
        guard let reason = trackerMigrationConfirmationReason() else {
            _trackerMigration = .ready(skew)
            startTrackerMigration(confirmedByUser: false)
            return
        }
        guard reason != heldReason else { return }
        _trackerMigration = .awaitingConfirmation(skew, reason: reason)
    }

    /// True when the tracker needs upgrading before Beadazzle can write to it.
    var isTrackerMigrationPending: Bool {
        trackerMigration.isPending
    }

    /// Runs `bd migrate` for the open project, then reloads from the upgraded database.
    ///
    /// - Parameter confirmedByUser: passes `--force`, which `bd` requires before
    ///   migrating a remote-backed database. Only ever set from an explicit user action.
    func startTrackerMigration(confirmedByUser: Bool) {
        guard let projectURL else { return }
        guard !trackerMigration.isMigrating, _trackerMigrationTask == nil else { return }

        let allowsRemoteMigration = confirmedByUser
            && trackerMigrationConfirmationReason() != nil
        _trackerMigration = .migrating
        let commands = commands
        _trackerMigrationTask = Task { @MainActor [weak self] in
            defer { self?._trackerMigrationTask = nil }
            do {
                try await commands.migrateTrackerSchema(
                    projectURL: projectURL,
                    allowsRemoteMigration: allowsRemoteMigration
                )
            } catch {
                guard let self, self.projectURL == projectURL else { return }
                self._trackerMigration = .failed(
                    message: error.localizedDescription,
                    requiresDesignatedMigrator: Self.requiresDesignatedMigrator(error)
                )
                return
            }
            guard let self, self.projectURL == projectURL else { return }
            self._trackerMigration = .notNeeded
            // Definitions were read from built-in fallbacks while the schema was skewed,
            // so force a fresh read rather than trusting the cache from that window.
            self.invalidateSemanticDefinitionsCache()
            self.refresh(reason: .manual, showsLoadingIndicator: true)
        }
    }

    /// Detects `bd`'s refusal to migrate a remote-backed database in place, so the UI can
    /// explain the designated-migrator requirement instead of just repeating the error.
    private static func requiresDesignatedMigrator(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        guard text.contains("remote") else { return false }
        return text.contains("--force")
            || text.contains("bd_allow_remote_migrate")
            || text.contains("designated migrator")
    }

    /// Dismisses a failed migration so the banner returns to offering the upgrade.
    func retryTrackerMigrationAfterFailure() {
        guard case .failed = trackerMigration else { return }
        _trackerMigration = .notNeeded
        // The next failing `bd` read re-detects the skew; probing again here would add a
        // subprocess to a path that is about to run one anyway.
        refresh(reason: .manual, showsLoadingIndicator: true)
    }
}
