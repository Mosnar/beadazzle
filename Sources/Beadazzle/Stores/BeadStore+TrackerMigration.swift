import Foundation

/// Handling for the one-time `bd` schema migration a tracker needs after a `bd` upgrade.
///
/// `bd` migrates on the first *write*-mode open, but Beadazzle reads through
/// `bd --readonly`, which cannot migrate. Without this, every read failed and the
/// project looked broken in ways that pointed at the `bd` binary rather than at the
/// tracker. The JSONL snapshot is a plain file and still loads, so the project stays
/// browsable with stale data while the upgrade is offered.
extension BeadStore {
    /// Records a schema mismatch reported by a failing `bd` read. Only a database that is
    /// provably behind the binary may enter the upward migration path. Forward and unknown
    /// skew stay read-only and are routed to recovery or compatible-binary guidance.
    ///
    /// Safe means an embedded tracker with no Dolt remote: nobody else shares the
    /// database, so upgrading it cannot fork a schema out from under a teammate.
    internal func noteTrackerSchemaSkew(_ skew: BeadsSchemaSkew) {
        // A migration already under way, or a failure the user has not seen yet, must not
        // be overwritten by the next failing read reporting the same skew.
        switch trackerMigration {
        case .migrating, .failed:
            return
        case .notNeeded, .awaitingConfirmation, .ready,
             .recoveryAvailable, .recoveryBlocked:
            break
        }

        guard skew.direction == .databaseBehind else {
            if skew.supportsPinnedV65ToV53Recovery {
                _trackerMigration = .recoveryAvailable(skew)
            } else {
                _trackerMigration = .recoveryBlocked(
                    skew,
                    guidance: BeadsTrackerRecoveryService.unsupportedSkewGuidance(for: skew)
                )
            }
            return
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
        let skew: BeadsSchemaSkew
        switch trackerMigration {
        case .ready(let pendingSkew):
            skew = pendingSkew
        case .awaitingConfirmation(let pendingSkew, _):
            guard confirmedByUser else { return }
            skew = pendingSkew
        case .notNeeded, .migrating, .failed, .recoveryAvailable, .recoveryBlocked:
            return
        }
        guard skew.direction == .databaseBehind else { return }

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

    /// Runs the read-only recovery diagnosis shown in the full review sheet.
    func prepareTrackerRecovery(competingWindowBlocker: String?) {
        guard case .recoveryAvailable(let skew) = trackerMigration,
              _trackerRecoveryTask == nil else { return }
        let activity = trackerRecoveryActivity(competingWindowBlocker: competingWindowBlocker)
        let projectURL = projectURL
        guard let projectURL else { return }
        _trackerRecovery = .diagnosing
        let service = trackerRecoveryService
        _trackerRecoveryTask = Task { @MainActor [weak self] in
            defer { self?._trackerRecoveryTask = nil }
            let assessment = await service.diagnose(
                projectURL: projectURL,
                skew: skew,
                activity: activity
            )
            guard !Task.isCancelled,
                  let self,
                  self.projectURL == projectURL,
                  self.trackerMigration.skew == skew else { return }
            self._trackerRecovery = .review(assessment)
        }
    }

    /// Performs the exact reviewed v65-to-v53 repair. The app's normal write queue is
    /// used directly because ordinary mutations are deliberately blocked while skewed.
    func startTrackerRecovery(
        acknowledgesOtherClones: Bool,
        acknowledgesRemoteAuthority: Bool,
        competingWindowBlocker: String?
    ) {
        guard acknowledgesOtherClones, acknowledgesRemoteAuthority else { return }
        guard case .review(let assessment) = trackerRecovery,
              assessment.canRecover,
              let plan = assessment.plan,
              let projectURL,
              _trackerRecoveryTask == nil else { return }

        let trackerIdentityPath = plan.beadsDirectoryURL
            .standardizedFileURL
            .path
        let recoveryReservationOwner = appStateBroadcaster
        if let blocker = recoveryReservationOwner?.reserveTrackerRecovery(
            for: self,
            trackerIdentityPath: trackerIdentityPath
        ) {
            _trackerRecovery = .failed(BeadsTrackerRecoveryFailure(
                message: blocker,
                backupURL: nil,
                log: []
            ))
            return
        }

        let activity = trackerRecoveryActivity(competingWindowBlocker: competingWindowBlocker)
        guard activity.blocker == nil else {
            recoveryReservationOwner?.releaseTrackerRecovery(
                for: self,
                trackerIdentityPath: trackerIdentityPath
            )
            _trackerRecovery = .failed(BeadsTrackerRecoveryFailure(
                message: activity.blocker ?? "Recovery is blocked by app activity.",
                backupURL: nil,
                log: []
            ))
            return
        }

        let service = trackerRecoveryService
        let mutationGeneration = beginMutation()
        pauseDataSourceMonitoringForTrackerRecovery()
        _trackerRecovery = .running(BeadsTrackerRecoveryProgress(
            phase: .checkingPrerequisites,
            log: ["Starting guarded local recovery."]
        ))
        _trackerRecoveryTask = Task { @MainActor [weak self] in
            defer {
                if let self {
                    recoveryReservationOwner?.releaseTrackerRecovery(
                        for: self,
                        trackerIdentityPath: trackerIdentityPath
                    )
                    self._trackerRecoveryTask = nil
                    self.endMutation(generation: mutationGeneration)
                    self.resumeDataSourceMonitoringAfterTrackerRecovery()
                }
            }
            guard let self else { return }
            let progress: @Sendable (BeadsTrackerRecoveryProgress) -> Void = { [weak self] update in
                Task { @MainActor [weak self] in
                    guard let self, self.projectURL == projectURL else { return }
                    self._trackerRecovery = .running(update)
                }
            }
            do {
                let result = try await self.mutations.writeQueue.enqueueCancellable {
                    try await service.recover(
                        assessment: assessment,
                        activity: activity,
                        progress: progress
                    )
                }
                guard self.projectURL == projectURL else { return }
                self._trackerRecovery = .succeeded(result)
                self._trackerMigration = .notNeeded
                self.invalidateSemanticDefinitionsCache()
                self.refresh(reason: .manual, showsLoadingIndicator: true)
            } catch let failure as BeadsTrackerRecoveryFailure {
                guard self.projectURL == projectURL else { return }
                self._trackerRecovery = .failed(failure)
            } catch {
                guard self.projectURL == projectURL else { return }
                self._trackerRecovery = .failed(BeadsTrackerRecoveryFailure(
                    message: error.localizedDescription,
                    backupURL: nil,
                    log: []
                ))
            }
        }
    }

    func cancelTrackerRecovery() {
        guard trackerRecovery.isRunning else { return }
        _trackerRecoveryTask?.cancel()
        if case .diagnosing = trackerRecovery {
            _trackerRecovery = .idle
        }
    }

    func dismissTrackerRecoveryResult() {
        guard !trackerRecovery.isRunning else { return }
        _trackerRecovery = .idle
    }

    private func trackerRecoveryActivity(
        competingWindowBlocker: String?
    ) -> BeadsTrackerRecoveryActivity {
        if let competingWindowBlocker {
            return BeadsTrackerRecoveryActivity(blocker: competingWindowBlocker)
        }
        if activeMutationCount > 0 || mutations.writeQueue.hasPendingOperations {
            return BeadsTrackerRecoveryActivity(
                blocker: "Wait for the current Beadazzle mutation to finish before recovery."
            )
        }
        if let projectHealthAction {
            return BeadsTrackerRecoveryActivity(
                blocker: "Wait for \(projectHealthAction.title.lowercased()) to finish before recovery."
            )
        }
        if isLoading || isApplyingBeadsSetup {
            return BeadsTrackerRecoveryActivity(
                blocker: "Wait for the current project operation to finish before recovery."
            )
        }
        return .idle
    }
}
