import Foundation

private struct PreparedBeadsSetup: Sendable {
    var report: BeadsSetupApplyReport
    var environment: BeadsProjectEnvironment
    var exportResult: ReadableSnapshotExportResult
}

private struct PreparedBeadsSetupReload: Sendable {
    var environment: BeadsProjectEnvironment
    var exportResult: ReadableSnapshotExportResult
}

extension BeadStore {
    var showsBeadsSetupAdvisory: Bool {
        guard projectURL != nil,
              beadsSetupIntent != nil,
              let fingerprint = beadsSetupFindingsFingerprint else {
            return false
        }
        return beadsSetupDismissedFingerprint != fingerprint
    }

    func inspectBeadsSetup(
        projectURL: URL,
        candidateRemote: BeadsDoltRemote? = nil
    ) async throws -> BeadsSetupAssessment {
        try await beadsSetupService.inspect(
            projectURL: projectURL.standardizedFileURL,
            scope: .wizard,
            candidateRemote: candidateRemote,
            preloadedEnvironment: nil
        )
    }

    func refreshBeadsSetupAudit() {
        guard let projectURL, beadsSetupIntent != nil else { return }
        beadsSetupInspectionGeneration &+= 1
        let generation = beadsSetupInspectionGeneration
        beadsSetupInspectionTask?.cancel()
        _isInspectingBeadsSetup = true
        let setupService = beadsSetupService
        let intent = beadsSetupIntent

        beadsSetupInspectionTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.beadsSetupInspectionGeneration == generation {
                    self._isInspectingBeadsSetup = false
                    self.beadsSetupInspectionTask = nil
                }
            }
            do {
                let assessment = try await setupService.inspect(
                    projectURL: projectURL,
                    scope: .audit,
                    candidateRemote: nil,
                    preloadedEnvironment: self?.projectEnvironment
                )
                guard !Task.isCancelled,
                      let self,
                      self.projectURL == projectURL,
                      self.beadsSetupInspectionGeneration == generation else { return }
                self._beadsSetupAssessment = assessment
                self.project.cacheProjectConfigurationInspection(assessment.configurationInspection)
                self._beadsSetupFindings = intent.map {
                    BeadsSetupPlanner.audit(intent: $0, assessment: assessment)
                } ?? []
                if self.projectDoltRemotes == nil,
                   self.projectEnvironment?.storageMode == .embedded {
                    self._projectDoltRemotes = assessment.remotes.map(ProjectHealthValue.available)
                        ?? .unavailable("Dolt remotes could not be inspected.")
                    self.projectDoltRemotesDidLoad(previousRemote: nil)
                }
                if self.beadsSetupFindingsFingerprint == nil {
                    self.beadsSetupPreferenceRepository.saveDismissedFingerprint(
                        nil,
                        projectURL: projectURL
                    )
                    self.beadsSetupDismissedFingerprint = nil
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.projectURL == projectURL,
                      self.beadsSetupInspectionGeneration == generation else { return }
                self._beadsSetupFindings = [BeadsSetupFinding(
                    id: "audit-failed",
                    severity: .warning,
                    title: "Setup check could not finish",
                    detail: error.localizedDescription
                )]
                self.loadProjectDoltRemotesIfNeeded()
            }
        }
    }

    func dismissBeadsSetupAdvisory() {
        guard let projectURL else { return }
        let fingerprint = beadsSetupFindingsFingerprint
        beadsSetupPreferenceRepository.saveDismissedFingerprint(
            fingerprint,
            projectURL: projectURL
        )
        beadsSetupDismissedFingerprint = fingerprint
    }

    @discardableResult
    func applyBeadsSetup(
        draft: BeadsSetupDraft,
        assessment: BeadsSetupAssessment,
        progress: @escaping BeadsSetupApplyProgressHandler = { _ in }
    ) async throws -> BeadsSetupApplyReport {
        let projectURL = assessment.projectURL.standardizedFileURL
        guard self.projectURL?.standardizedFileURL == projectURL else {
            throw BeadError.commandFailed(
                command: "bd setup",
                output: "The active project changed before setup could begin."
            )
        }
        guard !isApplyingBeadsSetup else {
            throw BeadError.commandFailed(
                command: "bd setup",
                output: "Another setup operation is already running."
            )
        }

        let generation = project.beginSetupApplication()
        _isApplyingBeadsSetup = true
        defer {
            if project.ownsSetupApplication(projectURL: projectURL, generation: generation) {
                _isApplyingBeadsSetup = false
                project.finishSetupApplication(generation: generation)
            }
        }

        let metadataBaseline = mutations.reloadBaseline()
        let setupService = beadsSetupService
        let commands = commands
        let cancellationToken = BeadsSetupCancellationToken()
        let reviewedPlan = BeadsSetupPlanner.plan(draft: draft, assessment: assessment)
        guard reviewedPlan.canApply else {
            throw BeadError.commandFailed(
                command: "bd setup",
                output: reviewedPlan.blockingFindings.map(\.detail).joined(separator: "\n")
            )
        }
        do {
            await progress(.validating)
            let setupTask = Task {
                try await enqueueMutationWrite {
                    let candidateRemote = draft.remoteURL.nilIfBlank.map {
                        BeadsDoltRemote(
                            name: draft.remoteName,
                            url: $0,
                            sqlURL: nil,
                            status: nil
                        )
                    }
                    let freshAssessment = try await setupService.inspect(
                        projectURL: projectURL,
                        scope: .wizard,
                        candidateRemote: candidateRemote,
                        preloadedEnvironment: nil
                    )
                    try Task.checkCancellation()
                    try cancellationToken.checkCancellation()
                    let plan = BeadsSetupPlanner.plan(draft: draft, assessment: freshAssessment)
                    guard plan.steps == reviewedPlan.steps,
                          plan.blockingFindings == reviewedPlan.blockingFindings else {
                        throw BeadError.commandFailed(
                            command: "bd setup",
                            output: "The Beads setup changed after it was reviewed. Review the updated commands and findings before applying them."
                        )
                    }
                    let report = try await setupService.apply(
                        projectURL: projectURL,
                        plan: plan,
                        cancellationToken: cancellationToken,
                        progress: progress
                    )
                    try Task.checkCancellation()
                    try cancellationToken.checkCancellation()
                    await progress(.reloadingProject)
                    let context = try await commands.loadProjectContext(projectURL: projectURL)
                    let environment = try BeadsProjectEnvironment(
                        context: context,
                        projectURL: projectURL
                    )
                    let exportResult = try await commands.exportReadableSnapshotWithResult(
                        projectURL: projectURL,
                        beadsDirectoryURL: environment.beadsDirectoryURL
                    )
                    return PreparedBeadsSetup(
                        report: report,
                        environment: environment,
                        exportResult: exportResult
                    )
                }
            }
            setupApplicationCancellation = {
                cancellationToken.cancel()
                setupTask.cancel()
            }
            let preparedSetup = try await withTaskCancellationHandler {
                try await setupTask.value
            } onCancel: {
                setupTask.cancel()
            }
            try Task.checkCancellation()
            let loadedProject = try await projectLoader.loadProject(
                projectURL: projectURL,
                staleCutoffDays: staleCutoffDays,
                hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
                cachedDefinitions: cachedDefinitions,
                cachedDefinitionsTrackerDirectoryURL: cachedDefinitionsTrackerDirectoryURL,
                cachedEnvironment: preparedSetup.environment,
                preparedSnapshot: preparedSetup.exportResult.loadedSnapshot
            )
            guard project.ownsSetupApplication(projectURL: projectURL, generation: generation) else {
                throw CancellationError()
            }
            await progress(.savingIntent)
            let intent = draft.intent
            beadsSetupPreferenceRepository.saveIntent(intent, projectURL: projectURL)
            _beadsSetupIntent = intent
            beadsSetupDismissedFingerprint = nil
            applyLoadedProject(
                loadedProject,
                projectURL: projectURL,
                metadataBaseline: metadataBaseline,
                confirmsReadableSnapshotExport: true
            )
            refreshBeadsSetupAudit()
            refreshOwnerIdentityAfterSetup(projectURL: projectURL)
            await progress(.finished)
            return preparedSetup.report
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A failed later step may follow durable successful setup changes. Reconcile
            // anything exportable so the workspace reflects the actual on-disk state.
            await progress(.recoveringProject)
            if let loadedProject = try? await loadProjectAfterBeadsSetup(projectURL: projectURL),
               project.ownsSetupApplication(projectURL: projectURL, generation: generation) {
                applyLoadedProject(
                    loadedProject,
                    projectURL: projectURL,
                    metadataBaseline: metadataBaseline,
                    confirmsReadableSnapshotExport: true
                )
            }
            throw error
        }
    }

    private func loadProjectAfterBeadsSetup(projectURL: URL) async throws -> LoadedProject {
        let commands = commands
        let preparedReload = try await enqueueMutationWrite {
            let context = try await commands.loadProjectContext(projectURL: projectURL)
            let environment = try BeadsProjectEnvironment(context: context, projectURL: projectURL)
            let exportResult = try await commands.exportReadableSnapshotWithResult(
                projectURL: projectURL,
                beadsDirectoryURL: environment.beadsDirectoryURL
            )
            return PreparedBeadsSetupReload(
                environment: environment,
                exportResult: exportResult
            )
        }
        return try await projectLoader.loadProject(
            projectURL: projectURL,
            staleCutoffDays: staleCutoffDays,
            hidesParentsWithOnlyBlockedChildrenInReady: hidesParentsWithOnlyBlockedChildrenInReady,
            cachedDefinitions: cachedDefinitions,
            cachedDefinitionsTrackerDirectoryURL: cachedDefinitionsTrackerDirectoryURL,
            cachedEnvironment: preparedReload.environment,
            preparedSnapshot: preparedReload.exportResult.loadedSnapshot
        )
    }

    private func refreshOwnerIdentityAfterSetup(projectURL: URL) {
        let generation = project.beginOwnerIdentityLoad()
        _ownerIdentity = .resolving
        let resolver = ownerIdentityResolver
        ownerIdentityTask = Task { @MainActor [weak self] in
            let identity = await resolver.resolve(projectURL: projectURL)
            guard !Task.isCancelled,
                  let self,
                  self.project.ownsOwnerIdentityLoad(projectURL: projectURL, generation: generation) else { return }
            self._ownerIdentity = identity
            self.project.finishOwnerIdentityLoad(generation: generation)
        }
    }
}
