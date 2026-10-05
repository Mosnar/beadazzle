import Foundation

extension BeadStore {
    internal var usesJournalRefresh: Bool {
        usesExperimentalJournalRefresh && automaticallyRefreshesExternalChanges
            && projectEnvironment?.storageMode == .embedded
    }

    internal func journalRefreshPreferenceDidChange() {
        project.resetJournalState()
        _snapshotFreshness = snapshotFreshness.stoppingJournalRefresh()
        guard projectReadiness.isReady else { return }
        if !usesExperimentalJournalRefresh {
            // Retire any displayed feed data with one normal export, after local
            // writes settle. This request does not arm a retry timer.
            if automaticallyRefreshesExternalChanges { requestReconcile(trigger: .externalMarker) }
            return
        }
        guard usesJournalRefresh else { return }
        // Keep definitions and the resolved environment. This is not a manual
        // refresh of all project metadata.
        if beginImmediateReconcile(trigger: .journalConfiguration) {
            refresh(reason: .reconcile, showsLoadingIndicator: false)
        } else {
            scheduleReconcileIfIdle()
        }
    }

    internal func journalRefreshDidApply(_ loaded: LoadedProject) {
        guard usesJournalRefresh else { project.resetJournalState(); return }
        project.acceptJournalState(from: loaded, verificationDelay: journalVerificationDelay)
        scheduleJournalVerificationIfNeeded()
    }

    /// Verify after the first accelerated update. A failed export retries after
    /// the same delay; successful verification stops the timer. More journal
    /// batches do not postpone it. Inactive windows defer it until activation.
    internal func scheduleJournalVerificationIfNeeded() {
        guard usesJournalRefresh,
              isWorkspaceSceneActive, !isRetiredAfterWindowClose,
              project.journalVerificationTask == nil,
              !reconcileState.pendingTriggers.contains(.journalVerification),
              !reconcileState.inFlightTriggers.contains(.journalVerification),
              let deadline = project.journalVerificationDeadline,
              let expectedProjectURL = projectURL else { return }
        project.startJournalVerification { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard let self, !Task.isCancelled, self.projectURL == expectedProjectURL,
                  self.usesJournalRefresh,
                  self.isWorkspaceSceneActive, !self.isRetiredAfterWindowClose else { return }
            self.requestReconcile(trigger: .journalVerification)
        }
    }
}
