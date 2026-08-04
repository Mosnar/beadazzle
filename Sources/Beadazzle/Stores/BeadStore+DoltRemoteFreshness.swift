import Foundation

enum ProjectDoltRemoteFreshnessCheckKind: Equatable, Sendable {
    case automatic
    case manual
    case establishSyncCheckpoint
}

enum ProjectDoltRemoteFreshnessCheckDecision: Equatable, Sendable {
    case probe
    case showCached(preservesUnavailable: Bool)
    case skip
}

enum ProjectDoltRemoteFreshnessCheckPolicy {
    static func decision(
        kind: ProjectDoltRemoteFreshnessCheckKind,
        record: ProjectDoltRemoteFreshnessRecord,
        automaticallyChecks: Bool,
        hasActiveScene: Bool,
        isChecking: Bool,
        now: Date,
        checkInterval: TimeInterval
    ) -> ProjectDoltRemoteFreshnessCheckDecision {
        guard kind == .automatic else { return .probe }
        guard !isChecking else { return .skip }
        guard record.syncCheckpointGeneration != nil else {
            return .showCached(preservesUnavailable: record.lastAttemptedAt != nil)
        }
        if let lastAttemptedAt = record.lastAttemptedAt ?? record.lastCheckedAt,
           now.timeIntervalSince(lastAttemptedAt) >= 0,
           now.timeIntervalSince(lastAttemptedAt) < checkInterval {
            return .showCached(preservesUnavailable: true)
        }
        guard automaticallyChecks, hasActiveScene else {
            return .showCached(preservesUnavailable: false)
        }
        return .probe
    }
}

private struct DoltRemoteFreshnessMonitoringContext {
    let record: ProjectDoltRemoteFreshnessRecord
}

extension BeadStore {
    func checkProjectDoltRemoteFreshness(
        _ kind: ProjectDoltRemoteFreshnessCheckKind = .manual,
        now: Date = Date()
    ) {
        guard let projectURL,
              projectEnvironment?.storageMode == .embedded,
              let trackerIdentity = doltRemoteFreshnessTrackerIdentity else {
            project.cancelDoltRemoteFreshnessCheck()
            project.cancelDoltRemoteFreshnessMonitoring()
            _doltRemoteFreshness = ProjectDoltRemoteFreshnessState(result: .notApplicable)
            return
        }

        guard let remotesValue = projectDoltRemotes else {
            if !isLoadingProjectDoltRemotes {
                loadProjectDoltRemotesIfNeeded()
            }
            return
        }
        guard let remotes = remotesValue.value else {
            project.cancelDoltRemoteFreshnessCheck()
            project.cancelDoltRemoteFreshnessMonitoring()
            _doltRemoteFreshness = ProjectDoltRemoteFreshnessState(
                result: .unavailable(
                    checkedAt: nil,
                    message: remotesValue.errorMessage ?? "Dolt remotes could not be loaded."
                )
            )
            return
        }
        guard let remote = doltRemoteFreshnessRemote(in: remotes) else {
            project.cancelDoltRemoteFreshnessCheck()
            project.cancelDoltRemoteFreshnessMonitoring()
            _doltRemoteFreshness = ProjectDoltRemoteFreshnessState(result: .notConfigured)
            return
        }
        guard GitDoltRemoteGenerationProbe.normalizedGitRemoteURL(remote.url) != nil else {
            project.cancelDoltRemoteFreshnessCheck()
            project.cancelDoltRemoteFreshnessMonitoring()
            _doltRemoteFreshness = ProjectDoltRemoteFreshnessState(result: .unsupported)
            return
        }

        let initialRecord = loadDoltRemoteFreshnessRecord(
            trackerIdentity: trackerIdentity,
            remote: remote
        )
        let cachedResult = Self.doltRemoteFreshnessResult(from: initialRecord)
        switch ProjectDoltRemoteFreshnessCheckPolicy.decision(
            kind: kind,
            record: initialRecord,
            automaticallyChecks: automaticallyChecksDoltRemotes,
            hasActiveScene: isDoltRemoteFreshnessSceneActive,
            isChecking: doltRemoteFreshness.isChecking,
            now: now,
            checkInterval: doltRemoteFreshnessCheckInterval
        ) {
        case .probe:
            break
        case .showCached(let preservesUnavailable):
            showCachedDoltRemoteFreshness(
                cachedResult,
                preservesUnavailable: preservesUnavailable
            )
            return
        case .skip:
            return
        }

        let generation = project.beginDoltRemoteFreshnessCheck()
        _doltRemoteFreshness = ProjectDoltRemoteFreshnessState(
            result: cachedResult,
            isChecking: true
        )
        let commands = commands
        doltRemoteFreshnessTask = Task { @MainActor [weak self] in
            var shouldStartMonitoring = false
            defer {
                self?.project.finishDoltRemoteFreshnessCheck(generation: generation)
                if shouldStartMonitoring {
                    self?.restartDoltRemoteFreshnessMonitoring()
                }
            }
            do {
                let observedGeneration = try await commands.loadDoltRemoteGeneration(
                    projectURL: projectURL,
                    remote: remote
                )
                guard !Task.isCancelled,
                      let self,
                      self.project.ownsDoltRemoteFreshnessCheck(
                        projectURL: projectURL,
                        generation: generation
                      ),
                      self.matchesCurrentDoltRemoteFreshnessContext(
                        projectURL: projectURL,
                        trackerIdentity: trackerIdentity,
                        remote: remote
                      ) else {
                    return
                }

                var record = initialRecord
                record.observedGeneration = observedGeneration
                record.lastCheckedAt = now
                record.lastAttemptedAt = now
                if kind == .establishSyncCheckpoint {
                    record.syncCheckpointGeneration = observedGeneration
                }
                self.saveDoltRemoteFreshnessRecord(record, trackerIdentity: trackerIdentity)
                self._doltRemoteFreshness = ProjectDoltRemoteFreshnessState(
                    result: Self.doltRemoteFreshnessResult(from: record)
                )
                if kind == .establishSyncCheckpoint {
                    shouldStartMonitoring = true
                }
            } catch is CancellationError {
                return
            } catch DoltRemoteGenerationProbeError.unsupportedRemote {
                guard let self,
                      self.project.ownsDoltRemoteFreshnessCheck(
                        projectURL: projectURL,
                        generation: generation
                      ),
                      self.matchesCurrentDoltRemoteFreshnessContext(
                        projectURL: projectURL,
                        trackerIdentity: trackerIdentity,
                        remote: remote
                      ) else {
                    return
                }
                self.project.cancelDoltRemoteFreshnessMonitoring()
                self._doltRemoteFreshness = ProjectDoltRemoteFreshnessState(result: .unsupported)
            } catch {
                guard let self,
                      self.project.ownsDoltRemoteFreshnessCheck(
                        projectURL: projectURL,
                        generation: generation
                      ),
                      self.matchesCurrentDoltRemoteFreshnessContext(
                        projectURL: projectURL,
                        trackerIdentity: trackerIdentity,
                        remote: remote
                      ) else {
                    return
                }
                var record = initialRecord
                record.lastAttemptedAt = now
                self.saveDoltRemoteFreshnessRecord(record, trackerIdentity: trackerIdentity)
                self._doltRemoteFreshness = ProjectDoltRemoteFreshnessState(
                    result: .unavailable(
                        checkedAt: now,
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    func waitForPendingDoltRemoteFreshnessCheck() async {
        while let task = doltRemoteFreshnessTask {
            await task.value
            if doltRemoteFreshnessTask == task { return }
        }
    }

    func establishProjectDoltRemoteFreshnessCheckpoint() async {
        checkProjectDoltRemoteFreshness(.establishSyncCheckpoint)
        await waitForPendingDoltRemoteFreshnessCheck()
    }

    func automaticDoltRemoteFreshnessPreferenceDidChange() {
        if automaticallyChecksDoltRemotes {
            restartDoltRemoteFreshnessMonitoring()
            checkProjectDoltRemoteFreshness(.automatic)
        } else {
            project.cancelDoltRemoteFreshnessMonitoring()
        }
    }

    private func showCachedDoltRemoteFreshness(
        _ cachedResult: ProjectDoltRemoteFreshnessResult,
        preservesUnavailable: Bool = false
    ) {
        // Do not erase a useful in-memory failure with an older persisted result.
        if preservesUnavailable, case .unavailable = doltRemoteFreshness.result {
            return
        }
        _doltRemoteFreshness = ProjectDoltRemoteFreshnessState(result: cachedResult)
    }

    private func loadDoltRemoteFreshnessRecord(
        trackerIdentity: String,
        remote: BeadsDoltRemote
    ) -> ProjectDoltRemoteFreshnessRecord {
        let key = BeadazzlePreferenceKeys.remoteFreshnessRecord(trackerIdentity: trackerIdentity)
        if let data = userDefaults.data(forKey: key),
           let record = try? JSONDecoder().decode(ProjectDoltRemoteFreshnessRecord.self, from: data),
           record.matches(remote) {
            return record
        }
        return ProjectDoltRemoteFreshnessRecord(
            remoteName: remote.name,
            remoteFingerprint: ProjectDoltRemoteFreshnessRecord.fingerprint(remote.url),
            syncCheckpointGeneration: nil,
            observedGeneration: nil,
            lastCheckedAt: nil,
            lastAttemptedAt: nil
        )
    }

    private func saveDoltRemoteFreshnessRecord(
        _ record: ProjectDoltRemoteFreshnessRecord,
        trackerIdentity: String
    ) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        userDefaults.set(
            data,
            forKey: BeadazzlePreferenceKeys.remoteFreshnessRecord(trackerIdentity: trackerIdentity)
        )
    }

    private static func doltRemoteFreshnessResult(
        from record: ProjectDoltRemoteFreshnessRecord
    ) -> ProjectDoltRemoteFreshnessResult {
        guard let syncCheckpointGeneration = record.syncCheckpointGeneration,
              let observedGeneration = record.observedGeneration,
              let lastCheckedAt = record.lastCheckedAt else {
            return .checkpointRequired(remoteName: record.remoteName)
        }
        return syncCheckpointGeneration == observedGeneration
            ? .unchangedSinceSync(checkedAt: lastCheckedAt)
            : .remoteChanged(checkedAt: lastCheckedAt)
    }

    private var doltRemoteFreshnessTrackerIdentity: String? {
        guard let environment = projectEnvironment else { return nil }
        if let projectID = environment.context.projectID?.nilIfBlank {
            return "project-id:\(projectID)"
        }
        return "tracker-directory:\(environment.beadsDirectoryURL.standardizedFileURL.path)"
    }

    func doltRemoteFreshnessRemote(
        in remotes: BeadsDoltRemotes
    ) -> BeadsDoltRemote? {
        if let syncRemote = projectEnvironment?.context.syncRemote?.nilIfBlank,
           let configuredRemote = remotes.remotes.first(where: { $0.name == syncRemote }) {
            return configuredRemote
        }
        return remotes.primaryRemote
    }

    func matchesDoltRemoteFreshnessRemote(
        _ lhs: BeadsDoltRemote?,
        _ rhs: BeadsDoltRemote?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case (.some(let lhs), .some(let rhs)):
            lhs.name == rhs.name
                && ProjectDoltRemoteFreshnessRecord.fingerprint(lhs.url)
                    == ProjectDoltRemoteFreshnessRecord.fingerprint(rhs.url)
        case (.some, nil), (nil, .some):
            false
        }
    }

    func projectDoltRemotesDidLoad(previousRemote: BeadsDoltRemote?) {
        let currentRemote = projectDoltRemotes?.value.flatMap {
            doltRemoteFreshnessRemote(in: $0)
        }
        let remoteChanged = !matchesDoltRemoteFreshnessRemote(
            previousRemote,
            currentRemote
        )
        if remoteChanged {
            project.cancelDoltRemoteFreshnessCheck()
        }
        checkProjectDoltRemoteFreshness(.automatic)
        if remoteChanged {
            restartDoltRemoteFreshnessMonitoring()
        } else {
            startDoltRemoteFreshnessMonitoringIfNeeded()
        }
    }

    func setDoltRemoteFreshnessSceneActive(_ isActive: Bool, sceneID: UUID) {
        let wasActive = isDoltRemoteFreshnessSceneActive
        if isActive {
            activeDoltRemoteFreshnessSceneIDs.insert(sceneID)
        } else {
            activeDoltRemoteFreshnessSceneIDs.remove(sceneID)
        }
        guard wasActive != isDoltRemoteFreshnessSceneActive else { return }
        if isDoltRemoteFreshnessSceneActive {
            restartDoltRemoteFreshnessMonitoring()
        } else {
            project.cancelDoltRemoteFreshnessMonitoring()
        }
    }

    func restartDoltRemoteFreshnessMonitoring() {
        project.cancelDoltRemoteFreshnessMonitoring()
        startDoltRemoteFreshnessMonitoringIfNeeded()
    }

    func startDoltRemoteFreshnessMonitoringIfNeeded() {
        guard doltRemoteFreshnessMonitorTask == nil,
              let projectURL,
              doltRemoteFreshnessMonitoringContext(projectURL: projectURL) != nil else {
            return
        }

        let generation = project.beginDoltRemoteFreshnessMonitoring()
        doltRemoteFreshnessMonitorTask = Task { @MainActor [weak self] in
            defer { self?.project.finishDoltRemoteFreshnessMonitoring(generation: generation) }
            while !Task.isCancelled {
                guard let self,
                      self.project.ownsDoltRemoteFreshnessMonitoring(
                        projectURL: projectURL,
                        generation: generation
                      ),
                      self.doltRemoteFreshnessMonitoringContext(
                        projectURL: projectURL
                      ) != nil else {
                    return
                }

                self.checkProjectDoltRemoteFreshness(.automatic)
                await self.waitForPendingDoltRemoteFreshnessCheck()
                guard !Task.isCancelled else { return }

                guard let context = self.doltRemoteFreshnessMonitoringContext(
                    projectURL: projectURL
                ) else {
                    return
                }
                let referenceDate = context.record.lastAttemptedAt
                    ?? context.record.lastCheckedAt
                    ?? .distantPast
                let elapsed = max(0, Date().timeIntervalSince(referenceDate))
                let delay = max(0.01, self.doltRemoteFreshnessCheckInterval - elapsed)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    private func doltRemoteFreshnessMonitoringContext(
        projectURL expectedProjectURL: URL
    ) -> DoltRemoteFreshnessMonitoringContext? {
        guard projectURL == expectedProjectURL,
              isDoltRemoteFreshnessSceneActive,
              automaticallyChecksDoltRemotes,
              projectEnvironment?.storageMode == .embedded,
              let trackerIdentity = doltRemoteFreshnessTrackerIdentity,
              let remotes = projectDoltRemotes?.value,
              let remote = doltRemoteFreshnessRemote(in: remotes),
              GitDoltRemoteGenerationProbe.normalizedGitRemoteURL(remote.url) != nil else {
            return nil
        }
        let record = loadDoltRemoteFreshnessRecord(
            trackerIdentity: trackerIdentity,
            remote: remote
        )
        guard record.syncCheckpointGeneration != nil else { return nil }
        return DoltRemoteFreshnessMonitoringContext(
            record: record
        )
    }

    private func matchesCurrentDoltRemoteFreshnessContext(
        projectURL expectedProjectURL: URL,
        trackerIdentity: String,
        remote: BeadsDoltRemote
    ) -> Bool {
        guard projectURL == expectedProjectURL,
              doltRemoteFreshnessTrackerIdentity == trackerIdentity,
              let remotes = projectDoltRemotes?.value,
              let currentRemote = doltRemoteFreshnessRemote(in: remotes) else {
            return false
        }
        return currentRemote.name == remote.name
            && ProjectDoltRemoteFreshnessRecord.fingerprint(currentRemote.url)
                == ProjectDoltRemoteFreshnessRecord.fingerprint(remote.url)
    }
}
