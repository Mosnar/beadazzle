import Foundation

struct BeadsAddLabelsBatch: Equatable, Sendable {
    let issueIDs: [String]
    let labels: [String]

    var arguments: [String] {
        BeadsCommandArguments.addLabels(ids: issueIDs, labels: labels)
    }
}

struct BeadsLabelMutationBatch: Equatable, Sendable {
    let issueIDs: [String]
    let labelsToAdd: [String]
    let labelsToRemove: [String]

    var arguments: [String] {
        BeadsCommandArguments.updateLabels(
            ids: issueIDs,
            adding: labelsToAdd,
            removing: labelsToRemove
        )
    }
}

private struct BeadsCommandOutput: Sendable {
    let standardOutput: String
    let standardError: String

    var combined: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private enum ConcurrentProcessOutputReader {
    static func read(
        standardOutput: Pipe,
        standardError: Pipe,
        outputLimitPerStream: Int? = nil
    ) -> () -> BeadsCommandOutput {
        let outputData = LockedProcessData(limit: outputLimitPerStream)
        let errorData = LockedProcessData(limit: outputLimitPerStream)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        group.enter()
        queue.async {
            outputData.readToEnd(from: standardOutput.fileHandleForReading)
            group.leave()
        }
        group.enter()
        queue.async {
            errorData.readToEnd(from: standardError.fileHandleForReading)
            group.leave()
        }

        return {
            group.wait()
            return BeadsCommandOutput(
                standardOutput: outputData.text,
                standardError: errorData.text
            )
        }
    }
}

private final class LockedProcessData: @unchecked Sendable {
    private static let chunkSize = 16 * 1_024
    private static let truncatedPrefix = "[Earlier command output omitted]\n"

    private let lock = NSLock()
    private let limit: Int?
    private var data = Data()
    private var wasTruncated = false

    init(limit: Int?) {
        self.limit = limit
    }

    var text: String {
        lock.withLock {
            let retainedData = limit.map { Data(data.suffix($0)) } ?? data
            let decoded = String(decoding: retainedData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard wasTruncated, !decoded.isEmpty else { return decoded }
            return Self.truncatedPrefix + decoded
        }
    }

    func readToEnd(from handle: FileHandle) {
        while true {
            do {
                guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                    return
                }
                append(chunk)
            } catch {
                return
            }
        }
    }

    private func append(_ value: Data) {
        lock.withLock {
            data.append(value)
            guard let limit, data.count > limit else { return }
            wasTruncated = true
            guard data.count > limit * 2 else { return }
            data.removeFirst(data.count - limit)
        }
    }
}

protocol BeadsCommanding: BeadsSetupServicing, Sendable {
    func exportReadableSnapshot(projectURL: URL) async throws
    func exportReadableSnapshot(projectURL: URL, beadsDirectoryURL: URL) async throws
    func exportReadableSnapshotWithResult(
        projectURL: URL,
        beadsDirectoryURL: URL
    ) async throws -> ReadableSnapshotExportResult
    func create(projectURL: URL, draft: IssueDraft) async throws -> String
    func createWithFeedback(projectURL: URL, draft: IssueDraft) async throws -> BeadsCreateResult
    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws
    func updateMetadata(
        projectURL: URL,
        issueID: String,
        assignee: String?,
        labels: [String]?,
        originalLabels: [String]?,
        dueAt: IssueMetadataDateUpdate,
        deferUntil: IssueMetadataDateUpdate
    ) async throws
    func close(projectURL: URL, ids: [String], reason: String?) async throws
    func delete(projectURL: URL, ids: [String]) async throws
    func bulkUpdate(
        projectURL: URL,
        ids: [String],
        status: String?,
        type: String?,
        priority: Int?,
        deferUntil: IssueMetadataDateUpdate
    ) async throws
    func addLabels(projectURL: URL, ids: [String], labels: [String]) async throws
    func addLabelsBatch(projectURL: URL, ids: [String], labels: [String]) async throws
    func updateLabelsBatch(
        projectURL: URL,
        ids: [String],
        adding labelsToAdd: [String],
        removing labelsToRemove: [String]
    ) async throws
    func setParent(projectURL: URL, issueID: String, parentID: String?) async throws
    func setState(projectURL: URL, issueID: String, dimension: String, value: String, reason: String?) async throws
    func clearState(projectURL: URL, issueID: String, dimension: String, currentValue: String, reason: String?) async throws
    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws
    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws
    func loadComments(projectURL: URL, issueID: String) async throws -> [BeadComment]
    func addComment(projectURL: URL, issueID: String, text: String) async throws
    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition]
    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition]
    func loadCustomStatuses(projectURL: URL) async throws -> [BeadStatusDefinition]
    func loadCustomTypes(projectURL: URL) async throws -> [BeadTypeDefinition]
    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws
    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws
    func loadCreationValidationSettings(projectURL: URL) async throws -> BeadsCreationValidationSettings
    func saveCreationValidationSettings(
        projectURL: URL,
        settings: BeadsCreationValidationSettings
    ) async throws
    func loadProjectContext(projectURL: URL) async throws -> BeadsProjectContext
    func loadProjectStorageConfig(projectURL: URL) async throws -> ProjectStorageConfig
    func loadDoltRemotes(projectURL: URL) async throws -> BeadsDoltRemotes
    func loadDoltRemoteGeneration(projectURL: URL, remote: BeadsDoltRemote) async throws -> String
    func verifyDoltRemoteAccess(projectURL: URL, remote: BeadsDoltRemote) async throws
    func loadHooksStatus(projectURL: URL) async throws -> BeadsHooksStatus
    func loadBackupStatus(projectURL: URL) async throws -> BeadsBackupStatus
    func installHooks(projectURL: URL) async throws
    func pullDoltRemote(projectURL: URL, remote: BeadsDoltRemote?) async throws
    func pushDoltRemote(projectURL: URL, remote: BeadsDoltRemote?) async throws
    func syncBackup(projectURL: URL) async throws
    func loadDoltMaintenancePreview(projectURL: URL) async -> BeadsDoltMaintenancePreview
    func compactDoltDatabase(projectURL: URL, retainingDays: Int) async throws
    func flattenDoltDatabase(projectURL: URL) async throws

    func loadGateDetail(projectURL: URL, id: String) async throws -> BeadGate?
    func resolveGate(projectURL: URL, id: String, reason: String?) async throws
    func checkGates(projectURL: URL, type: String?, escalate: Bool, dryRun: Bool) async throws -> String
    func createGate(projectURL: URL, blocks: String, type: GateAwaitType, reason: String?, timeout: String?, awaitID: String?) async throws -> String
    func addGateWaiter(projectURL: URL, id: String, waiter: String) async throws
}

extension BeadsCommanding {
    func verifyDoltRemoteAccess(projectURL _: URL, remote _: BeadsDoltRemote) async throws {
        throw BeadError.commandFailed(
            command: "git ls-remote",
            output: "Dolt remote access verification is not supported by this command service."
        )
    }

    func pullDoltRemote(projectURL _: URL, remote _: BeadsDoltRemote?) async throws {
        throw BeadError.commandFailed(
            command: "bd dolt pull",
            output: "Dolt pull is not supported by this command service."
        )
    }

    func pushDoltRemote(projectURL _: URL, remote _: BeadsDoltRemote?) async throws {
        throw BeadError.commandFailed(
            command: "bd dolt push",
            output: "Dolt push is not supported by this command service."
        )
    }

    func inspect(
        projectURL _: URL,
        scope _: BeadsSetupInspectionScope,
        candidateRemote _: BeadsDoltRemote?,
        preloadedEnvironment _: BeadsProjectEnvironment?
    ) async throws -> BeadsSetupAssessment {
        throw BeadError.commandFailed(
            command: "bd setup inspect",
            output: "Setup inspection is not supported by this command service."
        )
    }

    func apply(
        projectURL _: URL,
        plan _: BeadsSetupPlan,
        cancellationToken _: BeadsSetupCancellationToken,
        progress _: @escaping BeadsSetupApplyProgressHandler
    ) async throws -> BeadsSetupApplyReport {
        throw BeadError.commandFailed(
            command: "bd setup",
            output: "Setup changes are not supported by this command service."
        )
    }

    func createWithFeedback(projectURL: URL, draft: IssueDraft) async throws -> BeadsCreateResult {
        BeadsCreateResult(
            issueID: try await create(projectURL: projectURL, draft: draft),
            warning: nil
        )
    }

    func loadCreationValidationSettings(projectURL _: URL) async throws -> BeadsCreationValidationSettings {
        .beadsDefault
    }

    func saveCreationValidationSettings(
        projectURL _: URL,
        settings _: BeadsCreationValidationSettings
    ) async throws {}

    func loadDoltRemoteGeneration(
        projectURL _: URL,
        remote _: BeadsDoltRemote
    ) async throws -> String {
        throw DoltRemoteGenerationProbeError.unsupportedRemote
    }

    func exportReadableSnapshot(projectURL: URL, beadsDirectoryURL _: URL) async throws {
        try await exportReadableSnapshot(projectURL: projectURL)
    }

    func exportReadableSnapshotWithResult(
        projectURL: URL,
        beadsDirectoryURL: URL
    ) async throws -> ReadableSnapshotExportResult {
        try await exportReadableSnapshot(
            projectURL: projectURL,
            beadsDirectoryURL: beadsDirectoryURL
        )
        return .unprepared
    }

    func loadComments(projectURL _: URL, issueID _: String) async throws -> [BeadComment] { [] }

    func loadCustomStatuses(projectURL: URL) async throws -> [BeadStatusDefinition] {
        try await loadStatusDefinitions(projectURL: projectURL).filter(\.isCustom)
    }

    func loadCustomTypes(projectURL: URL) async throws -> [BeadTypeDefinition] {
        try await loadTypeDefinitions(projectURL: projectURL).filter(\.isCustom)
    }

    func loadProjectContext(projectURL _: URL) async throws -> BeadsProjectContext {
        throw BeadError.commandFailed(command: "bd context --json", output: "Project context is not supported by this command service.")
    }

    func loadProjectStorageConfig(projectURL _: URL) async throws -> ProjectStorageConfig {
        throw BeadError.commandFailed(command: "bd config get", output: "Project storage config is not supported by this command service.")
    }

    func loadDoltRemotes(projectURL _: URL) async throws -> BeadsDoltRemotes {
        throw BeadError.commandFailed(command: "bd dolt remote list --json", output: "Dolt remote status is not supported by this command service.")
    }

    func loadHooksStatus(projectURL _: URL) async throws -> BeadsHooksStatus {
        throw BeadError.commandFailed(command: "bd hooks list", output: "Hook status is not supported by this command service.")
    }

    func loadBackupStatus(projectURL _: URL) async throws -> BeadsBackupStatus {
        throw BeadError.commandFailed(command: "bd backup status --json", output: "Backup status is not supported by this command service.")
    }

    func installHooks(projectURL _: URL) async throws {
        throw BeadError.commandFailed(command: "bd hooks install", output: "Hook installation is not supported by this command service.")
    }

    func syncBackup(projectURL _: URL) async throws {
        throw BeadError.commandFailed(command: "bd backup sync", output: "Backup sync is not supported by this command service.")
    }

    func loadDoltMaintenancePreview(projectURL _: URL) async -> BeadsDoltMaintenancePreview {
        .unavailable
    }

    func compactDoltDatabase(projectURL _: URL, retainingDays _: Int) async throws {
        throw BeadError.commandFailed(
            command: "bd compact",
            output: "Database compaction is not supported by this command service."
        )
    }

    func flattenDoltDatabase(projectURL _: URL) async throws {
        throw BeadError.commandFailed(
            command: "bd flatten",
            output: "Database flattening is not supported by this command service."
        )
    }

    // Gate support is optional: conformers that don't shell out to `bd` (test doubles) get
    // safe no-op defaults so a `bd` without gate support degrades to an empty Gates section.
    func loadGateDetail(projectURL _: URL, id _: String) async throws -> BeadGate? { nil }
    func resolveGate(projectURL _: URL, id _: String, reason _: String?) async throws {}
    func checkGates(projectURL _: URL, type _: String?, escalate _: Bool, dryRun _: Bool) async throws -> String { "" }
    func createGate(projectURL _: URL, blocks _: String, type _: GateAwaitType, reason _: String?, timeout _: String?, awaitID _: String?) async throws -> String { "" }
    func addGateWaiter(projectURL _: URL, id _: String, waiter _: String) async throws {}
    func setParent(projectURL _: URL, issueID _: String, parentID _: String?) async throws {
        throw BeadError.commandFailed(
            command: "bd update --parent",
            output: "Parent updates are not supported by this command service."
        )
    }

    func setState(projectURL _: URL, issueID _: String, dimension _: String, value _: String, reason _: String?) async throws {
        throw BeadError.commandFailed(
            command: "bd set-state",
            output: "State changes are not supported by this command service."
        )
    }

    func clearState(projectURL _: URL, issueID _: String, dimension _: String, currentValue _: String, reason _: String?) async throws {
        throw BeadError.commandFailed(
            command: "bd update --remove-label",
            output: "Clearing state is not supported by this command service."
        )
    }

    func addLabels(projectURL _: URL, ids _: [String], labels _: [String]) async throws {
        throw BeadError.commandFailed(
            command: "bd update --add-label",
            output: "Bulk label updates are not supported by this command service."
        )
    }

    /// Single-command primitive used by the bulk coordinator. Existing command
    /// doubles only need to implement `addLabels`; the production service overrides
    /// this to ensure one call represents exactly one process invocation.
    func addLabelsBatch(projectURL: URL, ids: [String], labels: [String]) async throws {
        try await addLabels(projectURL: projectURL, ids: ids, labels: labels)
    }

    func updateLabelsBatch(
        projectURL: URL,
        ids: [String],
        adding labelsToAdd: [String],
        removing labelsToRemove: [String]
    ) async throws {
        guard labelsToRemove.isEmpty else {
            throw BeadError.commandFailed(
                command: "bd update --remove-label",
                output: "Bulk label removal is not supported by this command service."
            )
        }
        try await addLabelsBatch(projectURL: projectURL, ids: ids, labels: labelsToAdd)
    }

    func bulkUpdate(projectURL: URL, ids: [String], status: String?, type: String?, priority: Int?) async throws {
        try await bulkUpdate(
            projectURL: projectURL,
            ids: ids,
            status: status,
            type: type,
            priority: priority,
            deferUntil: .unchanged
        )
    }
}

private struct BeadsProjectLocation: Decodable {
    var prefix: String?
}

private struct BeadsSetupBootstrapInspection: Sendable {
    var preview: BeadsSetupBootstrapPreview
    var warning: String?
}

private enum BeadsCommandCancellationBehavior {
    case keepRunning
    case terminate
    case terminateAndWait

    var processCancellationMode: CancellableProcessRunner.CancellationMode? {
        switch self {
        case .keepRunning: nil
        case .terminate: .returnImmediately
        case .terminateAndWait: .waitForProcessExit
        }
    }
}

struct BeadsCommandService {
    typealias CommandExecutable = (url: URL, prefix: [String])

    // Leave a wide margin beyond the normal export timeout so a second app
    // process cannot prune another export that is still in flight.
    private static let staleTemporaryExportArtifactAge: TimeInterval = 5 * 60
    private static let temporaryExportFilenamePrefix = "issues.jsonl.tmp."
    private static let atomicTemporaryExportFilenamePrefix = ".~issues.jsonl.tmp."
    private static let atomicInstalledSnapshotFilenamePrefix = ".~issues.jsonl."

    private let readOnlyCommandTimeout: Duration
    private let snapshotExportTimeout: Duration
    private let writeCommandTimeout: Duration
    private let remoteSyncCommandTimeout: Duration
    private let executable: @Sendable () -> CommandExecutable

    init(
        readOnlyCommandTimeout: Duration = .seconds(10),
        snapshotExportTimeout: Duration = .seconds(60),
        writeCommandTimeout: Duration = .seconds(120),
        remoteSyncCommandTimeout: Duration = .seconds(1_800),
        executable: @escaping @Sendable () -> CommandExecutable = { BeadsCLI.executable() }
    ) {
        self.readOnlyCommandTimeout = readOnlyCommandTimeout
        self.snapshotExportTimeout = snapshotExportTimeout
        self.writeCommandTimeout = writeCommandTimeout
        self.remoteSyncCommandTimeout = remoteSyncCommandTimeout
        self.executable = executable
    }

    func inspectSetup(
        projectURL: URL,
        scope: BeadsSetupInspectionScope,
        candidateRemote: BeadsDoltRemote?,
        preloadedEnvironment: BeadsProjectEnvironment? = nil
    ) async throws -> BeadsSetupAssessment {
        let isWizardInspection = scope == .wizard
        async let bootstrapResult = inspectBootstrap(
            projectURL: projectURL,
            isRequired: isWizardInspection
        )
        async let gitOrigin = isWizardInspection
            ? gitRemoteURL(named: "origin", projectURL: projectURL)
            : nil
        async let gitUpstream = isWizardInspection
            ? gitRemoteURL(named: "upstream", projectURL: projectURL)
            : nil
        async let contextResult: ProjectHealthValue<BeadsProjectContext> = {
            if let preloadedEnvironment {
                return .available(preloadedEnvironment.context)
            }
            return await ProjectHealthValue.capture {
                try await loadProjectContext(projectURL: projectURL)
            }
        }()

        let bootstrapInspection = try await bootstrapResult
        let bootstrap = bootstrapInspection.preview
        let gitOriginURL = await gitOrigin
        let gitUpstreamURL = await gitUpstream
        let context = await contextResult
        var warnings: [String] = []
        if let warning = bootstrapInspection.warning {
            warnings.append(warning)
        }
        var environment = preloadedEnvironment
        if environment == nil, let contextValue = context.value {
            do {
                environment = try BeadsProjectEnvironment(
                    context: contextValue,
                    projectURL: projectURL
                )
            } catch {
                warnings.append(error.localizedDescription)
            }
        } else if bootstrap.hasExisting == true, let message = context.errorMessage {
            warnings.append(message)
        }

        let resolvedEnvironment = environment
        async let localDatabaseReadability = inspectLocalDatabaseReadability(
            projectURL: projectURL,
            environment: resolvedEnvironment,
            bootstrap: bootstrap
        )
        let candidateFingerprint = candidateRemote?.url.nilIfBlank.map(BeadsSetupPlanner.configurationFingerprint)
        let candidateMatchesOrigin = candidateFingerprint != nil
            && candidateFingerprint == gitOriginURL.map(BeadsSetupPlanner.configurationFingerprint)
        let candidateMatchesUpstream = candidateFingerprint != nil
            && candidateFingerprint == gitUpstreamURL.map(BeadsSetupPlanner.configurationFingerprint)
        async let gitOriginProbe = probeDoltData(
            remoteName: "origin",
            remoteURL: isWizardInspection ? gitOriginURL : nil,
            projectURL: projectURL
        )
        async let gitUpstreamProbe = probeDoltData(
            remoteName: "upstream",
            remoteURL: isWizardInspection ? gitUpstreamURL : nil,
            projectURL: projectURL
        )
        async let candidateRemoteProbe = probeDoltData(
            remoteName: candidateRemote?.name ?? "candidate",
            remoteURL: isWizardInspection && !candidateMatchesOrigin && !candidateMatchesUpstream
                ? candidateRemote?.url
                : nil,
            projectURL: projectURL
        )
        let gitOriginHasDoltData = await gitOriginProbe
        let gitUpstreamHasDoltData = await gitUpstreamProbe
        let independentCandidateRemoteHasDoltData = await candidateRemoteProbe
        let localDatabase = await localDatabaseReadability
        let candidateRemoteHasDoltData: Bool?
        if candidateMatchesOrigin {
            candidateRemoteHasDoltData = gitOriginHasDoltData
        } else if candidateMatchesUpstream {
            candidateRemoteHasDoltData = gitUpstreamHasDoltData
        } else {
            candidateRemoteHasDoltData = independentCandidateRemoteHasDoltData
        }

        if let message = localDatabase.errorMessage {
            warnings.append(message)
        }

        let hasInspectableTracker = bootstrap.hasExisting == true
            || localDatabase.value == true
            || environment.map { $0.storageMode != .embedded } == true
        guard hasInspectableTracker else {
            return BeadsSetupAssessment(
                projectURL: projectURL,
                inspectedAt: Date(),
                bootstrap: bootstrap,
                environment: environment,
                localDatabaseReadability: localDatabase,
                config: .unavailable("Project configuration was not inspected."),
                remotes: nil,
                hooks: nil,
                backup: nil,
                configurationInspection: nil,
                gitOriginURL: gitOriginURL,
                gitUpstreamURL: gitUpstreamURL,
                gitOriginHasDoltData: gitOriginHasDoltData,
                gitUpstreamHasDoltData: gitUpstreamHasDoltData,
                candidateRemoteURL: candidateRemote?.url,
                candidateRemoteHasDoltData: candidateRemoteHasDoltData,
                warnings: warnings
            )
        }

        let shouldLoadEmbeddedRemotes = environment?.storageMode == .embedded || environment == nil

        async let configResult = ProjectHealthValue<[BeadsSetupConfigEntry]>.capture {
            try await loadSetupConfig(projectURL: projectURL)
        }
        async let configuration = BeadsProjectConfigurationInspection.load(
            projectURL: projectURL,
            commands: self,
            context: context,
            loadsDoltRemotes: shouldLoadEmbeddedRemotes
        )

        let config = await configResult
        let configurationResult = await configuration
        for message in [
            config.errorMessage,
            configurationResult.doltRemotes.errorMessage,
            configurationResult.hooks.errorMessage,
            configurationResult.backup.errorMessage
        ].compactMap({ $0 }) {
            warnings.append(message)
        }

        return BeadsSetupAssessment(
            projectURL: projectURL,
            inspectedAt: Date(),
            bootstrap: bootstrap,
            environment: environment,
            localDatabaseReadability: localDatabase,
            config: config,
            remotes: configurationResult.doltRemotes.value,
            hooks: configurationResult.hooks.value,
            backup: configurationResult.backup.value,
            configurationInspection: configurationResult,
            gitOriginURL: gitOriginURL,
            gitUpstreamURL: gitUpstreamURL,
            gitOriginHasDoltData: gitOriginHasDoltData,
            gitUpstreamHasDoltData: gitUpstreamHasDoltData,
            candidateRemoteURL: candidateRemote?.url,
            candidateRemoteHasDoltData: candidateRemoteHasDoltData,
            warnings: warnings
        )
    }

    func applySetup(
        projectURL: URL,
        plan: BeadsSetupPlan,
        cancellationToken: BeadsSetupCancellationToken,
        progress: @escaping BeadsSetupApplyProgressHandler = { _ in }
    ) async throws -> BeadsSetupApplyReport {
        guard plan.canApply else {
            throw BeadError.commandFailed(
                command: "bd setup",
                output: plan.blockingFindings.map(\.detail).joined(separator: "\n")
            )
        }
        var completed: [String] = []
        for step in plan.steps {
            try Task.checkCancellation()
            try cancellationToken.checkCancellation()
            await progress(.stepStarted(step.id))
            do {
                try await run(
                    projectURL: projectURL,
                    arguments: step.operation.arguments,
                    timeout: step.operation.usesRemoteTimeout ? remoteSyncCommandTimeout : nil
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await progress(.stepFailed(step.id))
                throw BeadsSetupApplyFailure(
                    report: BeadsSetupApplyReport(completedStepIDs: completed),
                    failedStepTitle: step.title,
                    underlyingError: error
                )
            }
            completed.append(step.id)
            await progress(.stepCompleted(step.id))
        }
        try cancellationToken.checkCancellation()
        return BeadsSetupApplyReport(completedStepIDs: completed)
    }

    private func loadSetupConfig(projectURL: URL) async throws -> [BeadsSetupConfigEntry] {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "config", "show", "--json"],
            cancellationBehavior: .terminate,
            timeout: readOnlyCommandTimeout
        )
        return try JSONDecoder().decode([BeadsSetupConfigEntry].self, from: Data(text.utf8))
    }

    private func inspectBootstrap(
        projectURL: URL,
        isRequired: Bool
    ) async throws -> BeadsSetupBootstrapInspection {
        guard isRequired else {
            return BeadsSetupBootstrapInspection(
                preview: BeadsSetupBootstrapPreview(
                    action: "none",
                    beadsDirectory: nil,
                    database: nil,
                    hasExisting: true,
                    reason: nil,
                    suggestion: nil
                ),
                warning: nil
            )
        }
        do {
            let output = try await runOutput(
                projectURL: projectURL,
                arguments: ["--readonly", "bootstrap", "--dry-run", "--json"],
                cancellationBehavior: .terminate,
                timeout: readOnlyCommandTimeout
            )
            return BeadsSetupBootstrapInspection(
                preview: try decodeBootstrapPreview(output),
                warning: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch BeadError.commandFailed(_, let output) {
            if let preview = try? decodeBootstrapPreview(output) {
                return BeadsSetupBootstrapInspection(preview: preview, warning: nil)
            }
            return BeadsSetupBootstrapInspection(
                preview: BeadsSetupBootstrapPreview(),
                warning: "Bootstrap guidance could not be inspected: \(output.nilIfBlank ?? "bd returned no details.")"
            )
        } catch {
            return BeadsSetupBootstrapInspection(
                preview: BeadsSetupBootstrapPreview(),
                warning: "Bootstrap guidance could not be inspected: \(error.localizedDescription)"
            )
        }
    }

    private func decodeBootstrapPreview(_ output: String) throws -> BeadsSetupBootstrapPreview {
        try JSONDecoder().decode(
            BeadsSetupBootstrapPreview.self,
            from: Data(output.utf8)
        )
    }

    private func inspectLocalDatabaseReadability(
        projectURL: URL,
        environment: BeadsProjectEnvironment?,
        bootstrap: BeadsSetupBootstrapPreview
    ) async -> ProjectHealthValue<Bool> {
        guard environment?.storageMode == .embedded else {
            return .available(bootstrap.hasExisting == true)
        }
        guard bootstrap.hasExisting != true else {
            return .available(true)
        }
        do {
            _ = try await runOutput(
                projectURL: projectURL,
                arguments: ["--readonly", "count", "--json"],
                cancellationBehavior: .terminate,
                timeout: readOnlyCommandTimeout
            )
            return .available(true)
        } catch BeadError.commandFailed(_, let output)
            where output.localizedCaseInsensitiveContains("no beads database found") {
            return .available(false)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func gitRemoteURL(named name: String, projectURL: URL) async -> String? {
        do {
            let executableURL = URL(fileURLWithPath: "/usr/bin/env")
            // Git is launched through `/usr/bin/env`, but its PATH should still
            // prefer the directory of the resolved `bd` executable. This keeps
            // setup inspection consistent with regular `bd` subprocesses without
            // relying on a login shell to reconstruct the user's environment.
            let bdExecutableURL = executable().url
            let result = try await CancellableProcessRunner.run(
                executableURL: executableURL,
                arguments: ["git", "remote", "get-url", name],
                currentDirectoryURL: projectURL,
                environment: BeadsCLI.subprocessEnvironment(executableURL: bdExecutableURL),
                outputLimit: 16 * 1_024,
                timeout: .seconds(10)
            )
            guard result.terminationStatus == 0 else { return nil }
            return result.output.nilIfBlank
        } catch {
            return nil
        }
    }

    private func probeDoltData(
        remoteName: String,
        remoteURL: String?,
        projectURL: URL
    ) async -> Bool? {
        guard let remoteURL else { return nil }
        do {
            _ = try await GitDoltRemoteGenerationProbe.generation(
                remote: BeadsDoltRemote(
                    name: remoteName,
                    url: remoteURL,
                    sqlURL: nil,
                    status: nil
                ),
                projectURL: projectURL,
                toolchainExecutableURL: executable().url
            )
            return true
        } catch DoltRemoteGenerationProbeError.missingDoltReference {
            return false
        } catch DoltRemoteGenerationProbeError.unsupportedRemote {
            return nil
        } catch {
            return nil
        }
    }

    func exportReadableSnapshot(projectURL: URL) async throws {
        try await exportReadableSnapshot(
            projectURL: projectURL,
            beadsDirectoryURL: projectURL.appendingPathComponent(".beads", isDirectory: true)
        )
    }

    func exportReadableSnapshot(projectURL: URL, beadsDirectoryURL: URL) async throws {
        _ = try await exportReadableSnapshotWithResult(
            projectURL: projectURL,
            beadsDirectoryURL: beadsDirectoryURL
        )
    }

    func exportReadableSnapshotWithResult(
        projectURL: URL,
        beadsDirectoryURL: URL
    ) async throws -> ReadableSnapshotExportResult {
        Self.removeStaleTemporaryExportArtifacts(in: beadsDirectoryURL)
        let tempURL = Self.temporaryExportedIssuesJSONLURL(beadsDirectoryURL: beadsDirectoryURL)
        defer { Self.removeTemporaryExportArtifacts(for: tempURL) }

        _ = try await runOutput(
            projectURL: projectURL,
            arguments: BeadsCommandArguments.exportJSONL(outputPath: tempURL.path),
            cancellationBehavior: .terminateAndWait,
            timeout: snapshotExportTimeout
        )
        let preparationTask = Task.detached(priority: .userInitiated) {
            try Self.prepareExportedIssuesJSONL(
                tempURL: tempURL,
                beadsDirectoryURL: beadsDirectoryURL
            )
        }
        return try await withTaskCancellationHandler {
            try await preparationTask.value
        } onCancel: {
            preparationTask.cancel()
        }
    }

    func create(projectURL: URL, draft: IssueDraft) async throws -> String {
        try await createWithFeedback(projectURL: projectURL, draft: draft).issueID
    }

    func createWithFeedback(projectURL: URL, draft: IssueDraft) async throws -> BeadsCreateResult {
        let output = try await runCommandOutput(
            projectURL: projectURL,
            arguments: BeadsCommandArguments.create(draft: draft, silent: true),
            timeout: writeCommandTimeout
        )
        return BeadsCreateResult(
            issueID: try Self.createdIssueID(from: output.standardOutput),
            warning: output.standardError.nilIfBlank
        )
    }

    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue? = nil) async throws {
        guard let arguments = BeadsCommandArguments.update(
            draft: draft,
            originalIssue: originalIssue
        ) else { return }
        try await run(projectURL: projectURL, arguments: arguments)
    }

    func updateMetadata(
        projectURL: URL,
        issueID: String,
        assignee: String? = nil,
        labels: [String]? = nil,
        originalLabels: [String]? = nil,
        dueAt: IssueMetadataDateUpdate = .unchanged,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) async throws {
        guard let arguments = BeadsCommandArguments.updateMetadata(
            issueID: issueID,
            assignee: assignee,
            labels: labels,
            originalLabels: originalLabels,
            dueAt: dueAt,
            deferUntil: deferUntil
        ) else { return }
        try await run(projectURL: projectURL, arguments: arguments)
    }

    func close(projectURL: URL, ids: [String], reason: String? = "Closed in Beadazzle") async throws {
        guard !ids.isEmpty else { return }
        try await run(projectURL: projectURL, arguments: BeadsCommandArguments.close(ids: ids, reason: reason))
    }

    func delete(projectURL: URL, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await run(projectURL: projectURL, arguments: ["delete"] + ids + ["--force"])
    }

    func bulkUpdate(
        projectURL: URL,
        ids: [String],
        status: String? = nil,
        type: String? = nil,
        priority: Int? = nil,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) async throws {
        guard !ids.isEmpty else { return }
        let arguments = BeadsCommandArguments.bulkUpdate(
            ids: ids,
            status: status,
            type: type,
            priority: priority,
            deferUntil: deferUntil
        )
        try await run(projectURL: projectURL, arguments: arguments)
    }

    func addLabels(projectURL: URL, ids: [String], labels: [String]) async throws {
        for batch in BeadsCommandArguments.addLabelBatchPlans(ids: ids, labels: labels) {
            try await addLabelsBatch(
                projectURL: projectURL,
                ids: batch.issueIDs,
                labels: batch.labels
            )
        }
    }

    func addLabelsBatch(projectURL: URL, ids: [String], labels: [String]) async throws {
        guard !ids.isEmpty, !labels.isEmpty else { return }
        try await run(
            projectURL: projectURL,
            arguments: BeadsCommandArguments.addLabels(ids: ids, labels: labels)
        )
    }

    func updateLabelsBatch(
        projectURL: URL,
        ids: [String],
        adding labelsToAdd: [String],
        removing labelsToRemove: [String]
    ) async throws {
        guard !ids.isEmpty, !labelsToAdd.isEmpty || !labelsToRemove.isEmpty else { return }
        try await run(
            projectURL: projectURL,
            arguments: BeadsCommandArguments.updateLabels(
                ids: ids,
                adding: labelsToAdd,
                removing: labelsToRemove
            )
        )
    }

    func setParent(projectURL: URL, issueID: String, parentID: String?) async throws {
        try await run(
            projectURL: projectURL,
            arguments: BeadsCommandArguments.setParent(issueID: issueID, parentID: parentID)
        )
    }

    func setState(projectURL: URL, issueID: String, dimension: String, value: String, reason: String?) async throws {
        try await run(
            projectURL: projectURL,
            arguments: BeadsCommandArguments.setState(issueID: issueID, dimension: dimension, value: value, reason: reason)
        )
    }

    func clearState(
        projectURL: URL,
        issueID: String,
        dimension: String,
        currentValue: String,
        reason: String?
    ) async throws {
        try await run(
            projectURL: projectURL,
            arguments: BeadsCommandArguments.removeStateLabel(
                issueID: issueID,
                dimension: dimension,
                value: currentValue
            )
        )
        let output = try await runOutput(
            projectURL: projectURL,
            arguments: BeadsCommandArguments.createStateClearEvent(
                issueID: issueID,
                dimension: dimension,
                reason: reason
            )
        )
        let eventID = try Self.createdIssueID(from: output)
        try await run(
            projectURL: projectURL,
            arguments: BeadsCommandArguments.close(ids: [eventID], reason: nil)
        )
    }

    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {
        try await run(projectURL: projectURL, arguments: ["dep", "add", issueID, dependsOnID, "--type", type])
    }

    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {
        try await run(projectURL: projectURL, arguments: ["dep", "remove", issueID, dependsOnID])
    }

    func loadComments(projectURL: URL, issueID: String) async throws -> [BeadComment] {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "comments", issueID, "--json"],
            cancellationBehavior: .terminate,
            timeout: readOnlyCommandTimeout
        )
        return try Self.decodeComments(from: Data(text.utf8), issueID: issueID)
    }

    func addComment(projectURL: URL, issueID: String, text: String) async throws {
        try await run(projectURL: projectURL, arguments: BeadsCommandArguments.addComment(issueID: issueID), standardInput: text)
    }

    func loadGateDetail(projectURL: URL, id: String) async throws -> BeadGate? {
        let text = try await runOutput(projectURL: projectURL, arguments: BeadsCommandArguments.gateShow(id: id))
        guard !text.isEmpty else { return nil }
        return try BeadGate.decodeOne(from: Data(text.utf8))
    }

    func resolveGate(projectURL: URL, id: String, reason: String?) async throws {
        try await run(projectURL: projectURL, arguments: BeadsCommandArguments.gateResolve(id: id, reason: reason))
    }

    func checkGates(projectURL: URL, type: String?, escalate: Bool, dryRun: Bool) async throws -> String {
        try await runOutput(projectURL: projectURL, arguments: BeadsCommandArguments.gateCheck(type: type, escalate: escalate, dryRun: dryRun))
    }

    func createGate(projectURL: URL, blocks: String, type: GateAwaitType, reason: String?, timeout: String?, awaitID: String?) async throws -> String {
        try await runOutput(projectURL: projectURL, arguments: BeadsCommandArguments.gateCreate(blocks: blocks, type: type, reason: reason, timeout: timeout, awaitID: awaitID))
    }

    func addGateWaiter(projectURL: URL, id: String, waiter: String) async throws {
        try await run(projectURL: projectURL, arguments: BeadsCommandArguments.gateAddWaiter(id: id, waiter: waiter))
    }

    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition] {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "statuses", "--json"],
            cancellationBehavior: .terminate,
            timeout: readOnlyCommandTimeout
        )
        return try BeadsMetadataService.decodeStatuses(from: Data(text.utf8))
    }

    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "types", "--json"],
            cancellationBehavior: .terminate,
            timeout: readOnlyCommandTimeout
        )
        return try BeadsMetadataService.decodeTypes(from: Data(text.utf8))
    }

    func loadCustomStatuses(projectURL: URL) async throws -> [BeadStatusDefinition] {
        guard let value = try await configValue(projectURL: projectURL, key: "status.custom") else { return [] }
        return try Self.decodeCustomStatuses(from: value)
    }

    func loadCustomTypes(projectURL: URL) async throws -> [BeadTypeDefinition] {
        guard let value = try await configValue(projectURL: projectURL, key: "types.custom") else { return [] }
        return try Self.decodeCustomTypes(from: value)
    }

    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws {
        try await run(projectURL: projectURL, arguments: BeadsCommandArguments.saveCustomStatuses(statuses))
    }

    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws {
        try await run(projectURL: projectURL, arguments: BeadsCommandArguments.saveCustomTypes(types))
    }

    func loadCreationValidationSettings(projectURL: URL) async throws -> BeadsCreationValidationSettings {
        async let requiresDescription = configValue(
            projectURL: projectURL,
            key: "create.require-description"
        )
        async let mode = configValue(
            projectURL: projectURL,
            key: "validation.on-create"
        )
        let (descriptionValue, modeValue) = try await (requiresDescription, mode)
        return BeadsCreationValidationSettings(
            requiresDescription: ProjectStorageConfig.bool(from: descriptionValue) ?? false,
            mode: modeValue.flatMap(BeadsCreationValidationMode.init(rawValue:)) ?? .none
        )
    }

    func saveCreationValidationSettings(
        projectURL: URL,
        settings: BeadsCreationValidationSettings
    ) async throws {
        let original = try await loadCreationValidationSettings(projectURL: projectURL)
        if original.requiresDescription != settings.requiresDescription {
            try await run(
                projectURL: projectURL,
                arguments: [
                    "config",
                    "set",
                    "create.require-description",
                    settings.requiresDescription ? "true" : "false"
                ]
            )
        }
        if original.mode != settings.mode {
            try await run(
                projectURL: projectURL,
                arguments: ["config", "set", "validation.on-create", settings.mode.rawValue]
            )
        }
    }

    func loadProjectContext(projectURL: URL) async throws -> BeadsProjectContext {
        do {
            async let locationText: String? = try? await runOutput(
                projectURL: projectURL,
                arguments: ["--readonly", "where", "--json"],
                cancellationBehavior: .terminate,
                timeout: readOnlyCommandTimeout
            )
            let text = try await runOutput(
                projectURL: projectURL,
                arguments: ["--readonly", "context", "--json"],
                cancellationBehavior: .terminate,
                timeout: readOnlyCommandTimeout
            )
            var context = try BeadsProjectContext.decode(from: text)
            if let locationText = await locationText,
               let location = try? JSONDecoder().decode(
                BeadsProjectLocation.self,
                from: Data(locationText.utf8)
               ) {
                context.issuePrefix = location.prefix?.nilIfBlank
            }
            return context
        } catch {
            if case BeadError.commandFailed(_, let output) = error,
               Self.contextReportsMissingBeadsDirectory(output) {
                throw BeadError.projectMissingDataSource(projectURL)
            }
            throw error
        }
    }

    static func contextReportsMissingBeadsDirectory(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("no .beads directory found")
    }

    func loadProjectStorageConfig(projectURL: URL) async throws -> ProjectStorageConfig {
        async let exportAuto = configBoolSetting(projectURL: projectURL, key: "export.auto")
        async let exportPath = configSetting(projectURL: projectURL, key: "export.path")
        async let exportInterval = configSetting(projectURL: projectURL, key: "export.interval")
        async let exportGitAdd = configBoolSetting(projectURL: projectURL, key: "export.git-add")
        async let importAuto = configBoolSetting(projectURL: projectURL, key: "import.auto")
        async let federationRemote = configSetting(projectURL: projectURL, key: "federation.remote")
        async let noGitOperations = configBoolSetting(projectURL: projectURL, key: "no-git-ops")
        async let doltAutoPush = configBoolSetting(projectURL: projectURL, key: "dolt.auto-push")
        async let doltAutoPushInterval = configSetting(projectURL: projectURL, key: "dolt.auto-push-interval")
        async let doltAutoPushTimeout = configSetting(projectURL: projectURL, key: "dolt.auto-push-timeout")

        return ProjectStorageConfig(
            exportAutoStatus: await exportAuto,
            exportPathStatus: await exportPath,
            exportIntervalStatus: await exportInterval,
            exportGitAddStatus: await exportGitAdd,
            importAutoStatus: await importAuto,
            federationRemoteStatus: await federationRemote,
            noGitOperationsStatus: await noGitOperations,
            doltAutoPushStatus: await doltAutoPush,
            doltAutoPushIntervalStatus: await doltAutoPushInterval,
            doltAutoPushTimeoutStatus: await doltAutoPushTimeout
        )
    }

    func loadDoltRemotes(projectURL: URL) async throws -> BeadsDoltRemotes {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "dolt", "remote", "list", "--json"],
            cancellationBehavior: .terminate,
            timeout: readOnlyCommandTimeout
        )
        return try BeadsDoltRemotes.decode(from: text)
    }

    func loadDoltRemoteGeneration(
        projectURL: URL,
        remote: BeadsDoltRemote
    ) async throws -> String {
        try await GitDoltRemoteGenerationProbe.generation(
            remote: remote,
            projectURL: projectURL,
            toolchainExecutableURL: executable().url
        )
    }

    func verifyDoltRemoteAccess(
        projectURL: URL,
        remote: BeadsDoltRemote
    ) async throws {
        try await GitDoltRemoteGenerationProbe.verifyAccess(
            remote: remote,
            projectURL: projectURL,
            toolchainExecutableURL: executable().url
        )
    }

    func loadHooksStatus(projectURL: URL) async throws -> BeadsHooksStatus {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "hooks", "list"],
            cancellationBehavior: .terminate,
            timeout: readOnlyCommandTimeout
        )
        return BeadsHooksStatus.parse(from: text)
    }

    func loadBackupStatus(projectURL: URL) async throws -> BeadsBackupStatus {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "backup", "status", "--json"],
            cancellationBehavior: .terminate,
            timeout: readOnlyCommandTimeout
        )
        return try BeadsBackupStatus.decode(from: text)
    }

    func installHooks(projectURL: URL) async throws {
        try await run(projectURL: projectURL, arguments: ["hooks", "install"])
    }

    func pullDoltRemote(projectURL: URL, remote: BeadsDoltRemote?) async throws {
        try await runDoltRemoteCommand(
            projectURL: projectURL,
            arguments: ["dolt", "pull"],
            remote: remote,
            timeout: remoteSyncCommandTimeout
        )
    }

    func pushDoltRemote(projectURL: URL, remote: BeadsDoltRemote?) async throws {
        try await runDoltRemoteCommand(
            projectURL: projectURL,
            arguments: ["dolt", "push"],
            remote: remote,
            timeout: remoteSyncCommandTimeout
        )
    }

    private func runDoltRemoteCommand(
        projectURL: URL,
        arguments: [String],
        remote: BeadsDoltRemote?,
        timeout: Duration
    ) async throws {
        let executable = executable()
        var environment = BeadsCLI.subprocessEnvironment(executableURL: executable.url)
        if let remote {
            environment = await SSHAgentSocketResolver.environment(
                base: environment,
                remoteURL: remote.url,
                projectURL: projectURL
            )
        }
        _ = try await Task.detached(priority: .userInitiated) {
            try Self.runOutputSynchronously(
                projectURL: projectURL,
                arguments: arguments,
                executable: executable,
                timeout: timeout,
                environment: environment,
                outputLimitPerStream: 512 * 1_024
            )
        }.value
    }

    func syncBackup(projectURL: URL) async throws {
        try await run(projectURL: projectURL, arguments: ["backup", "sync"])
    }

    func loadDoltMaintenancePreview(projectURL: URL) async -> BeadsDoltMaintenancePreview {
        async let compact = ProjectHealthValue.capture {
            let text = try await runOutput(
                projectURL: projectURL,
                arguments: ["--readonly", "compact", "--dry-run", "--json"],
                cancellationBehavior: .terminate,
                timeout: readOnlyCommandTimeout
            )
            return try BeadsDoltCompactPreview.decode(from: text)
        }
        async let flatten = ProjectHealthValue.capture {
            let text = try await runOutput(
                projectURL: projectURL,
                arguments: ["--readonly", "flatten", "--dry-run", "--json"],
                cancellationBehavior: .terminate,
                timeout: readOnlyCommandTimeout
            )
            return try BeadsDoltFlattenPreview.decode(from: text)
        }
        return BeadsDoltMaintenancePreview(
            compact: await compact,
            flatten: await flatten,
            embeddedDatabaseSize: nil
        )
    }

    func compactDoltDatabase(projectURL: URL, retainingDays: Int = 30) async throws {
        try await run(
            projectURL: projectURL,
            arguments: ["--sandbox", "compact", "--days", String(max(1, retainingDays)), "--force", "--json"],
            timeout: remoteSyncCommandTimeout
        )
    }

    func flattenDoltDatabase(projectURL: URL) async throws {
        try await run(
            projectURL: projectURL,
            arguments: ["--sandbox", "flatten", "--force", "--json"],
            timeout: remoteSyncCommandTimeout
        )
    }

    private func run(
        projectURL: URL,
        arguments: [String],
        standardInput: String? = nil,
        timeout: Duration? = nil
    ) async throws {
        _ = try await runOutput(
            projectURL: projectURL,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout ?? writeCommandTimeout
        )
    }

    /// - Parameter cancellationBehavior: controls whether cancellation leaves the
    ///   subprocess running, terminates it and returns immediately, or waits for it
    ///   to exit. Termination is only safe for read-only commands. Commands with stdin
    ///   retain the non-cancellable write path so broken-pipe errors can be reconciled
    ///   with the child's exit status.
    private func runOutput(
        projectURL: URL,
        arguments: [String],
        standardInput: String? = nil,
        cancellationBehavior: BeadsCommandCancellationBehavior = .keepRunning,
        timeout: Duration? = nil
    ) async throws -> String {
        let executable = executable()
        if let cancellationMode = cancellationBehavior.processCancellationMode,
           standardInput == nil {
            guard let timeout else {
                return try await Self.runOutputTerminatingOnCancel(
                    projectURL: projectURL,
                    arguments: arguments,
                    executable: executable,
                    cancellationMode: cancellationMode
                )
            }
            return try await Self.runOutputTerminatingOnCancel(
                projectURL: projectURL,
                arguments: arguments,
                executable: executable,
                cancellationMode: cancellationMode,
                timeout: timeout
            )
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.runOutputSynchronously(
                projectURL: projectURL,
                arguments: arguments,
                standardInput: standardInput,
                executable: executable,
                timeout: timeout
            )
        }.value
    }

    private func runCommandOutput(
        projectURL: URL,
        arguments: [String],
        standardInput: String? = nil,
        timeout: Duration? = nil
    ) async throws -> BeadsCommandOutput {
        let executable = executable()
        return try await Task.detached(priority: .userInitiated) {
            try Self.runCommandOutputSynchronously(
                projectURL: projectURL,
                arguments: arguments,
                standardInput: standardInput,
                executable: executable,
                timeout: timeout
            )
        }.value
    }

    private func configValue(projectURL: URL, key: String) async throws -> String? {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "config", "get", key],
            cancellationBehavior: .terminate,
            timeout: readOnlyCommandTimeout
        )
        return ProjectStorageConfig.configValue(from: text, key: key)
    }

    private func configSetting(projectURL: URL, key: String) async -> ProjectStorageConfigValue<String> {
        do {
            return .available(try await configValue(projectURL: projectURL, key: key))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    private func configBoolSetting(projectURL: URL, key: String) async -> ProjectStorageConfigValue<Bool> {
        let setting = await configSetting(projectURL: projectURL, key: key)
        guard setting.errorMessage == nil else {
            return .unavailable(setting.errorMessage ?? "Unavailable")
        }
        return .available(ProjectStorageConfig.bool(from: setting.value))
    }

    private static func runOutputSynchronously(
        projectURL: URL,
        arguments: [String],
        standardInput: String? = nil,
        executable: CommandExecutable,
        timeout: Duration? = nil,
        environment: [String: String]? = nil,
        outputLimitPerStream: Int? = nil
    ) throws -> String {
        try runCommandOutputSynchronously(
            projectURL: projectURL,
            arguments: arguments,
            standardInput: standardInput,
            executable: executable,
            timeout: timeout,
            environment: environment,
            outputLimitPerStream: outputLimitPerStream
        ).combined
    }

    private static func runCommandOutputSynchronously(
        projectURL: URL,
        arguments: [String],
        standardInput: String? = nil,
        executable: CommandExecutable,
        timeout: Duration? = nil,
        environment: [String: String]? = nil,
        outputLimitPerStream: Int? = nil
    ) throws -> BeadsCommandOutput {
        let process = Process()
        process.executableURL = executable.url
        process.arguments = executable.prefix + arguments
        process.currentDirectoryURL = projectURL
        process.environment = environment
            ?? BeadsCLI.subprocessEnvironment(executableURL: executable.url)

        let standardOutput = Pipe()
        let standardError = Pipe()
        let input = standardInput.map { _ in Pipe() }
        if let input {
            process.standardInput = input
        }
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()

        // A watchdog rather than task cancellation: writes must never be interrupted
        // by a superseded task, but with no ceiling at all a hung `bd` (e.g. a stuck
        // Dolt lock) stalls the serialized mutation queue forever while optimistic
        // edits stay applied and never error.
        var watchdog: (item: DispatchWorkItem, state: SubprocessWatchdogState)?
        if let timeout {
            let state = SubprocessWatchdogState()
            let item = DispatchWorkItem {
                state.markFired()
                process.terminate()
            }
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + timeout.timeInterval, execute: item)
            watchdog = (item, state)
        }
        defer { watchdog?.item.cancel() }

        let output = ConcurrentProcessOutputReader.read(
            standardOutput: standardOutput,
            standardError: standardError,
            outputLimitPerStream: outputLimitPerStream
        )
        var standardInputDelivered = true
        if let standardInput, let input {
            standardInputDelivered = writeStandardInput(standardInput, to: input)
        }

        process.waitUntilExit()
        let result = output()

        guard process.terminationStatus == 0 else {
            if watchdog?.state.didFire == true {
                throw BeadError.commandFailed(
                    command: commandDescription(arguments),
                    output: "Timed out waiting for `bd` to finish."
                )
            }
            throw BeadError.commandFailed(command: commandDescription(arguments), output: result.combined)
        }
        guard standardInputDelivered else {
            throw BeadError.commandFailed(
                command: commandDescription(arguments),
                output: "`bd` stopped reading its input before it was fully delivered."
            )
        }
        return result
    }

    /// Writes `bd`'s stdin without crashing on a broken pipe. The non-throwing
    /// `FileHandle.write(_:)` raises an uncatchable ObjC exception if `bd` exits
    /// before draining stdin; the throwing variant surfaces that as an error we
    /// defer to the process's own exit status.
    private static func writeStandardInput(_ text: String, to pipe: Pipe) -> Bool {
        let handle = pipe.fileHandleForWriting
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: Data(text.utf8))
            return true
        } catch {
            return false
        }
    }

    /// Runs `bd` off the cooperative pool and terminates the subprocess if the surrounding
    /// task is cancelled. `readDataToEndOfFile` is not cancellation-aware, so without this
    /// a superseded read would keep an entire `bd`/Dolt process running to completion —
    /// overlapping reads would pile up instead of the newest winning.
    private static func runOutputTerminatingOnCancel(
        projectURL: URL,
        arguments: [String],
        executable: CommandExecutable,
        cancellationMode: CancellableProcessRunner.CancellationMode,
        timeout: Duration
    ) async throws -> String {
        do {
            return try await runOutputTerminatingOnCancel(
                projectURL: projectURL,
                arguments: arguments,
                executable: executable,
                cancellationMode: cancellationMode,
                runnerTimeout: timeout
            )
        } catch CancellableProcessRunnerError.timedOut {
            throw BeadError.commandFailed(
                command: commandDescription(arguments),
                output: "Timed out waiting for `bd` to finish."
            )
        }
    }

    private static func runOutputTerminatingOnCancel(
        projectURL: URL,
        arguments: [String],
        executable: CommandExecutable,
        cancellationMode: CancellableProcessRunner.CancellationMode = .returnImmediately,
        runnerTimeout: Duration? = nil
    ) async throws -> String {
        let result = try await CancellableProcessRunner.run(
            executableURL: executable.url,
            arguments: executable.prefix + arguments,
            currentDirectoryURL: projectURL,
            environment: BeadsCLI.subprocessEnvironment(executableURL: executable.url),
            timeout: runnerTimeout,
            cancellationMode: cancellationMode
        )
        guard result.terminationStatus == 0 else {
            throw BeadError.commandFailed(
                command: commandDescription(arguments),
                output: result.output
            )
        }
        return result.output
    }

    private static func commandDescription(_ arguments: [String]) -> String {
        (["bd"] + arguments).joined(separator: " ")
    }

    static func exportedIssuesJSONLURL(projectURL: URL) -> URL {
        exportedIssuesJSONLURL(
            beadsDirectoryURL: projectURL.appendingPathComponent(".beads", isDirectory: true)
        )
    }

    static func exportedIssuesJSONLURL(beadsDirectoryURL: URL) -> URL {
        beadsDirectoryURL
            .appendingPathComponent("issues.jsonl")
    }

    private static func temporaryExportedIssuesJSONLURL(beadsDirectoryURL: URL) -> URL {
        beadsDirectoryURL.appendingPathComponent("\(temporaryExportFilenamePrefix)\(UUID().uuidString)")
    }

    private static func removeTemporaryExportArtifacts(
        for tempURL: URL,
        fileManager: FileManager = .default
    ) {
        removeRegularFileIfPresent(at: tempURL, fileManager: fileManager)

        let nestedPrefix = ".~\(tempURL.lastPathComponent)."
        guard let contents = try? fileManager.contentsOfDirectory(
            at: tempURL.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return }
        for candidateURL in contents where candidateURL.lastPathComponent.hasPrefix(nestedPrefix) {
            removeRegularFileIfPresent(at: candidateURL, fileManager: fileManager)
        }
    }

    private static func removeStaleTemporaryExportArtifacts(
        in beadsDirectoryURL: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: beadsDirectoryURL,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ]
        ) else { return }

        for candidateURL in contents where isTemporarySnapshotArtifactName(candidateURL.lastPathComponent) {
            guard
                let values = try? candidateURL.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]),
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let modificationDate = values.contentModificationDate,
                now.timeIntervalSince(modificationDate) >= staleTemporaryExportArtifactAge
            else { continue }
            try? fileManager.removeItem(at: candidateURL)
        }
    }

    private static func isTemporarySnapshotArtifactName(_ name: String) -> Bool {
        if name.hasPrefix(temporaryExportFilenamePrefix) {
            return UUID(uuidString: String(name.dropFirst(temporaryExportFilenamePrefix.count))) != nil
        }

        if name.hasPrefix(atomicTemporaryExportFilenamePrefix) {
            let remainder = name.dropFirst(atomicTemporaryExportFilenamePrefix.count)
            let components = remainder.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            return components.count == 2
                && UUID(uuidString: String(components[0])) != nil
                && !components[1].isEmpty
        }

        guard name.hasPrefix(atomicInstalledSnapshotFilenamePrefix) else { return false }
        let suffix = name.dropFirst(atomicInstalledSnapshotFilenamePrefix.count)
        return !suffix.isEmpty && suffix.utf8.allSatisfy { byte in byte >= 48 && byte <= 57 }
    }

    private static func removeRegularFileIfPresent(at url: URL, fileManager: FileManager) {
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else { return }
        try? fileManager.removeItem(at: url)
    }

    static func installExportedIssuesJSONL(tempURL: URL, projectURL: URL, fileManager: FileManager = .default) throws {
        try installExportedIssuesJSONL(
            tempURL: tempURL,
            beadsDirectoryURL: projectURL.appendingPathComponent(".beads", isDirectory: true),
            fileManager: fileManager
        )
    }

    static func installExportedIssuesJSONL(
        tempURL: URL,
        beadsDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let destinationURL = exportedIssuesJSONLURL(beadsDirectoryURL: beadsDirectoryURL)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destinationURL.path])
            }
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }
    }

    private static func prepareExportedIssuesJSONL(
        tempURL: URL,
        beadsDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> ReadableSnapshotExportResult {
        try Task.checkCancellation()
        let attributes = try fileManager.attributesOfItem(atPath: tempURL.path)
        let temporarySource = BeadsDataSource(
            kind: .jsonl,
            url: tempURL,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast
        )
        let snapshot: BeadsSnapshot
        do {
            snapshot = try BeadsJSONLSnapshotReader().loadSnapshot(from: temporarySource)
        } catch BeadError.invalidSnapshot(_, let line, let message) {
            throw BeadError.commandFailed(
                command: "bd export --output \(BeadsCommandArguments.exportedIssuesJSONLPath)",
                output: "Export produced invalid JSONL at line \(line): \(message)"
            )
        }
        try Task.checkCancellation()

        let destinationURL = exportedIssuesJSONLURL(beadsDirectoryURL: beadsDirectoryURL)
        let matchesInstalledSnapshot = try filesHaveEqualContents(
            tempURL,
            destinationURL,
            fileManager: fileManager
        )
        if !matchesInstalledSnapshot {
            try installExportedIssuesJSONL(
                tempURL: tempURL,
                beadsDirectoryURL: beadsDirectoryURL,
                fileManager: fileManager
            )
        }
        // Once the validated snapshot has been installed, finish describing that committed
        // result even if cancellation arrives. Reporting cancellation after replacement
        // would leave callers believing the readable snapshot was not updated.
        let installedSource = try BeadsDataSourceDiscovery(fileManager: fileManager).discover(
            projectURL: beadsDirectoryURL.deletingLastPathComponent(),
            beadsDirectoryURL: beadsDirectoryURL
        )
        return ReadableSnapshotExportResult(
            loadedSnapshot: LoadedBeadsSnapshot(
                source: installedSource,
                snapshot: snapshot
            ),
            didReplaceSnapshot: !matchesInstalledSnapshot
        )
    }

    private static func filesHaveEqualContents(
        _ lhsURL: URL,
        _ rhsURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rhsURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        let lhsAttributes = try fileManager.attributesOfItem(atPath: lhsURL.path)
        let rhsAttributes = try fileManager.attributesOfItem(atPath: rhsURL.path)
        guard (lhsAttributes[.size] as? NSNumber)?.int64Value
                == (rhsAttributes[.size] as? NSNumber)?.int64Value else {
            return false
        }

        let lhs = try FileHandle(forReadingFrom: lhsURL)
        let rhs = try FileHandle(forReadingFrom: rhsURL)
        defer {
            try? lhs.close()
            try? rhs.close()
        }
        while true {
            try Task.checkCancellation()
            let lhsData = try lhs.read(upToCount: 64 * 1024) ?? Data()
            let rhsData = try rhs.read(upToCount: 64 * 1024) ?? Data()
            guard lhsData == rhsData else { return false }
            if lhsData.isEmpty {
                return true
            }
        }
    }

    static func validateExportedIssuesJSONL(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var lineNumber = 0
        var lineBuffer = Data()
        lineBuffer.reserveCapacity(64 * 1024)

        while true {
            guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                break
            }

            var start = chunk.startIndex
            while let newlineIndex = chunk[start...].firstIndex(of: 10) {
                lineBuffer.append(contentsOf: chunk[start..<newlineIndex])
                lineNumber += 1
                try validateJSONLRecord(lineBuffer, lineNumber: lineNumber)
                lineBuffer.removeAll(keepingCapacity: true)
                start = chunk.index(after: newlineIndex)
            }

            if start < chunk.endIndex {
                lineBuffer.append(contentsOf: chunk[start..<chunk.endIndex])
            }
        }

        if !lineBuffer.isEmpty {
            lineNumber += 1
            try validateJSONLRecord(lineBuffer, lineNumber: lineNumber)
        }
    }

    private static func validateJSONLRecord(_ rawLineData: Data, lineNumber: Int) throws {
        var lineData = rawLineData
        if lineData.last == 13 {
            lineData.removeLast()
        }
        guard !lineData.isEmpty else { return }
        guard (try? JSONSerialization.jsonObject(with: lineData)) is [String: Any] else {
            throw BeadError.commandFailed(
                command: "bd export --output \(BeadsCommandArguments.exportedIssuesJSONLPath)",
                output: "Export produced invalid JSONL at line \(lineNumber)."
            )
        }
    }

    static func ensureExportedIssuesJSONLExists(projectURL: URL, fileManager: FileManager = .default) throws {
        let url = exportedIssuesJSONLURL(projectURL: projectURL)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
            return
        }

        try Data().write(to: url, options: .atomic)
    }

    static func decodeCustomStatuses(from value: String) throws -> [BeadStatusDefinition] {
        try commaSeparatedValues(value).map { entry in
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            let name = try WorkflowValueValidator.normalizedIdentifier(parts[0])
            let category: BeadStatusCategory
            if parts.count == 2 {
                guard let parsedCategory = BeadStatusCategory(rawValue: parts[1]) else {
                    throw BeadError.commandFailed(
                        command: "bd config get status.custom",
                        output: "\(parts[1]) is not a valid status category."
                    )
                }
                category = parsedCategory
            } else {
                category = .uncategorized
            }
            return BeadStatusDefinition(
                name: name,
                category: category,
                icon: nil,
                description: nil,
                isBuiltIn: false,
                source: .custom
            )
        }
    }

    static func decodeCustomTypes(from value: String) throws -> [BeadTypeDefinition] {
        try commaSeparatedValues(value).map { entry in
            BeadTypeDefinition(
                name: try WorkflowValueValidator.normalizedIdentifier(entry),
                description: nil,
                source: .custom
            )
        }
    }

    private static func commaSeparatedValues(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func createdIssueID(from output: String) throws -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let issueID = lines.last else {
            throw BeadError.createOutcomeUncertain(
                command: "bd create --silent",
                output: "Expected created bead ID but bd returned no output."
            )
        }
        return issueID
    }

    static func decodeComments(from data: Data, issueID: String) throws -> [BeadComment] {
        let value = try JSONSerialization.jsonObject(with: data)
        let records: [[String: Any]]
        if let array = value as? [[String: Any]] {
            records = array
        } else if let object = value as? [String: Any], let comments = object["comments"] as? [[String: Any]] {
            records = comments
        } else {
            throw BeadError.commandFailed(
                command: "bd comments \(issueID) --json",
                output: "Expected a JSON array of comments."
            )
        }

        return records.enumerated().map { offset, record in
            let resolvedIssueID = stringValue(record["issue_id"])
                ?? stringValue(record["issueId"])
                ?? issueID
            return BeadComment(
                id: stringValue(record["id"]) ?? "\(resolvedIssueID)-comment-\(offset)",
                issueID: resolvedIssueID,
                author: stringValue(record["author"]),
                text: stringValue(record["text"])
                    ?? stringValue(record["body"])
                    ?? stringValue(record["content"])
                    ?? "",
                createdAt: BeadFormatters.parseDate(
                    stringValue(record["created_at"]) ?? stringValue(record["createdAt"])
                ),
                updatedAt: BeadFormatters.parseDate(
                    stringValue(record["updated_at"]) ?? stringValue(record["updatedAt"])
                )
            )
        }
        .sorted { lhs, rhs in
            (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast)
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String {
            return string.nilIfBlank
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}

extension BeadsCommandService: BeadsCommanding {
    func inspect(
        projectURL: URL,
        scope: BeadsSetupInspectionScope,
        candidateRemote: BeadsDoltRemote?,
        preloadedEnvironment: BeadsProjectEnvironment?
    ) async throws -> BeadsSetupAssessment {
        try await inspectSetup(
            projectURL: projectURL,
            scope: scope,
            candidateRemote: candidateRemote,
            preloadedEnvironment: preloadedEnvironment
        )
    }

    func apply(
        projectURL: URL,
        plan: BeadsSetupPlan,
        cancellationToken: BeadsSetupCancellationToken,
        progress: @escaping BeadsSetupApplyProgressHandler
    ) async throws -> BeadsSetupApplyReport {
        try await applySetup(
            projectURL: projectURL,
            plan: plan,
            cancellationToken: cancellationToken,
            progress: progress
        )
    }
}

struct BeadsInitOptions: Equatable, Sendable {
    var prefix = ""
    var usesStealthMode = false
    var skipsAgents = false
    var skipsHooks = false
    var remoteURL = ""
}

enum BeadsCommandArguments {
    static let exportedIssuesJSONLPath = ".beads/issues.jsonl"
    /// Leaves ample room for the executable path and inherited environment beneath
    /// macOS's process argument limit while keeping normal bulk edits to one command.
    static let safeBulkArgumentByteLimit = 64 * 1_024

    static func initializeOptionArguments(options: BeadsInitOptions) -> [String] {
        var arguments: [String] = []
        appendNonEmpty(&arguments, flag: "--prefix", value: options.prefix)
        if options.usesStealthMode {
            arguments.append("--stealth")
        }
        if options.skipsAgents {
            arguments.append("--skip-agents")
        }
        if options.skipsHooks && !options.usesStealthMode {
            arguments.append("--skip-hooks")
        }
        appendNonEmpty(&arguments, flag: "--remote", value: options.remoteURL)
        return arguments
    }

    static func exportJSONL(outputPath: String = exportedIssuesJSONLPath) -> [String] {
        ["export", "--output", outputPath]
    }

    static func close(ids: [String], reason: String?) -> [String] {
        var arguments = ["close"] + ids
        appendNonEmpty(&arguments, flag: "--reason", value: reason)
        return arguments
    }

    static func addComment(issueID: String) -> [String] {
        ["comment", issueID, "--stdin"]
    }

    static func create(draft: IssueDraft, silent: Bool = false) -> [String] {
        var arguments = ["create", draft.title, "--type", draft.issueType, "--priority", "P\(draft.priority)"]
        appendNonEmpty(&arguments, flag: "--id", value: draft.id)
        appendNonEmpty(&arguments, flag: "--description", value: draft.description)
        appendNonEmpty(&arguments, flag: "--design", value: draft.design)
        appendNonEmpty(&arguments, flag: "--acceptance", value: draft.acceptanceCriteria)
        appendNonEmpty(&arguments, flag: "--notes", value: draft.notes)
        appendNonEmpty(&arguments, flag: "--assignee", value: draft.assignee)
        appendNonEmpty(&arguments, flag: "--due", value: BeadFormatters.commandDate(draft.dueAt))
        appendNonEmpty(&arguments, flag: "--defer", value: BeadFormatters.commandDate(draft.deferUntil))
        appendNonEmpty(&arguments, flag: "--labels", value: normalizedLabelArgument(draft.labelsText))
        if draft.id != nil, let parentID = draft.parentID?.nilIfBlank {
            // bd rejects --id together with --parent. The equivalent parent-child
            // dependency preserves hierarchy while allowing a client-assigned id.
            arguments += ["--deps", "parent-child:\(parentID)"]
        } else {
            appendNonEmpty(&arguments, flag: "--parent", value: draft.parentID)
        }
        if silent {
            arguments.append("--silent")
        }
        return arguments
    }

    static func update(
        draft: IssueDraft,
        originalLabels: [String]? = nil,
        originalIssue: BeadIssue? = nil
    ) -> [String]? {
        guard let id = draft.id else { return nil }
        var arguments = ["update", id]
        if originalIssue == nil || draft.title != originalIssue?.title {
            arguments += ["--title", draft.title]
        }
        if originalIssue == nil || draft.issueType != originalIssue?.issueType {
            arguments += ["--type", draft.issueType]
        }
        if originalIssue == nil || draft.priority != originalIssue?.priority {
            arguments += ["--priority", "P\(draft.priority)"]
        }
        if originalIssue == nil || draft.status != originalIssue?.status {
            arguments += ["--status", draft.status]
        }
        if originalIssue == nil || draft.description != originalIssue?.description {
            arguments += ["--description", draft.description, "--allow-empty-description"]
        }
        if originalIssue == nil || draft.design != originalIssue?.design {
            arguments += ["--design", draft.design]
        }
        if originalIssue == nil || draft.acceptanceCriteria != originalIssue?.acceptanceCriteria {
            arguments += ["--acceptance", draft.acceptanceCriteria]
        }
        if originalIssue == nil || draft.notes != originalIssue?.notes {
            arguments += ["--notes", draft.notes]
        }
        if originalIssue == nil || draft.dueAt != originalIssue?.dueAt {
            arguments += ["--due", dateUpdateArgument(draft.dueAt)]
        }
        if originalIssue == nil || draft.deferUntil != originalIssue?.deferUntil {
            arguments += ["--defer", dateUpdateArgument(draft.deferUntil)]
        }
        let labelsBeforeUpdate = originalLabels ?? originalIssue?.labels
        let labelsMatch = labelsBeforeUpdate.map { Set(draft.labels) == Set($0) } ?? false
        if originalIssue == nil || !labelsMatch {
            appendLabelUpdate(
                &arguments,
                labels: draft.labels,
                originalLabels: labelsBeforeUpdate
            )
        }
        return arguments.count > 2 ? arguments : nil
    }

    static func updateMetadata(
        issueID: String,
        assignee: String? = nil,
        labels: [String]? = nil,
        originalLabels: [String]? = nil,
        dueAt: IssueMetadataDateUpdate = .unchanged,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) -> [String]? {
        var arguments = ["update", issueID]
        var didAppendUpdate = false

        if let assignee {
            arguments += ["--assignee", assignee.trimmingCharacters(in: .whitespacesAndNewlines)]
            didAppendUpdate = true
        }

        switch dueAt {
        case .unchanged:
            break
        case .set(let date):
            arguments += ["--due", dateUpdateArgument(date)]
            didAppendUpdate = true
        }

        switch deferUntil {
        case .unchanged:
            break
        case .set(let date):
            arguments += ["--defer", dateUpdateArgument(date)]
            didAppendUpdate = true
        }

        if let labels {
            let countBeforeLabels = arguments.count
            appendLabelUpdate(
                &arguments,
                labels: labels,
                originalLabels: originalLabels
            )
            didAppendUpdate = didAppendUpdate || arguments.count > countBeforeLabels
        }

        return didAppendUpdate ? arguments : nil
    }

    static func bulkUpdate(
        ids: [String],
        status: String? = nil,
        type: String? = nil,
        priority: Int? = nil,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) -> [String] {
        var arguments = ["update"] + ids
        if let status {
            arguments += ["--status", status]
        }
        if let type {
            arguments += ["--type", type]
        }
        if let priority {
            arguments += ["--priority", "P\(priority)"]
        }
        switch deferUntil {
        case .unchanged:
            break
        case .set(let date):
            arguments += ["--defer", dateUpdateArgument(date)]
        }
        return arguments
    }

    static func addLabels(ids: [String], labels: [String]) -> [String] {
        ["update"] + Array(Set(ids)).sorted() + addLabelArguments(labels)
    }

    static func updateLabels(
        ids: [String],
        adding labelsToAdd: [String],
        removing labelsToRemove: [String]
    ) -> [String] {
        let additions = normalizedUniqueLabels(labelsToAdd)
        let additionSet = Set(additions)
        let removals = normalizedUniqueLabels(labelsToRemove).filter {
            !additionSet.contains($0)
        }
        return ["update"] + Array(Set(ids)).sorted()
            + labelMutationArguments(adding: additions, removing: removals)
    }

    static func labelMutationBatchPlans(
        ids: [String],
        adding labelsToAdd: [String],
        removing labelsToRemove: [String],
        maximumArgumentBytes: Int = safeBulkArgumentByteLimit
    ) -> [BeadsLabelMutationBatch] {
        let ids = Array(Set(ids)).sorted()
        let additions = normalizedUniqueLabels(labelsToAdd)
        let additionSet = Set(additions)
        let removals = normalizedUniqueLabels(labelsToRemove).filter {
            !additionSet.contains($0)
        }
        let operations = additions.map { LabelMutationArgument(kind: .add, label: $0) }
            + removals.map { LabelMutationArgument(kind: .remove, label: $0) }
        guard !ids.isEmpty, !operations.isEmpty else { return [] }

        let unchunkedArguments = ["update"] + ids + operations.flatMap(\.arguments)
        if estimatedArgumentBytes(unchunkedArguments) <= maximumArgumentBytes {
            return [BeadsLabelMutationBatch(
                issueIDs: ids,
                labelsToAdd: additions,
                labelsToRemove: removals
            )]
        }

        let commandByteCount = estimatedArgumentBytes(["update"])
        let longestIDByteCount = ids.map { estimatedArgumentBytes([$0]) }.max() ?? 0
        let largestOperationByteCount = operations
            .map(\.arguments)
            .map(estimatedArgumentBytes)
            .max() ?? 0
        let availableOperationByteCount = max(
            1,
            maximumArgumentBytes - commandByteCount - longestIDByteCount
        )
        let balancedOperationByteCount = max(
            1,
            (maximumArgumentBytes - commandByteCount) / 2
        )
        let operationBatchByteLimit = min(
            availableOperationByteCount,
            max(balancedOperationByteCount, largestOperationByteCount)
        )
        let operationBatches = chunkLabelMutationArguments(
            operations,
            maximumArgumentBytes: operationBatchByteLimit
        )

        let largestOperationBatchByteCount = operationBatches.map {
            estimatedArgumentBytes($0.flatMap(\.arguments))
        }.max() ?? 0
        let fixedByteCount = commandByteCount + largestOperationBatchByteCount
        var idBatches: [[String]] = []
        var batchIDs: [String] = []
        var batchByteCount = fixedByteCount
        for id in ids {
            let idByteCount = estimatedArgumentBytes([id])
            if !batchIDs.isEmpty, batchByteCount + idByteCount > maximumArgumentBytes {
                idBatches.append(batchIDs)
                batchIDs = []
                batchByteCount = fixedByteCount
            }
            batchIDs.append(id)
            batchByteCount += idByteCount
        }
        if !batchIDs.isEmpty {
            idBatches.append(batchIDs)
        }

        return idBatches.flatMap { idBatch in
            operationBatches.map { operationBatch in
                BeadsLabelMutationBatch(
                    issueIDs: idBatch,
                    labelsToAdd: operationBatch.compactMap {
                        $0.kind == .add ? $0.label : nil
                    },
                    labelsToRemove: operationBatch.compactMap {
                        $0.kind == .remove ? $0.label : nil
                    }
                )
            }
        }
    }

    static func addLabelBatches(
        ids: [String],
        labels: [String],
        maximumArgumentBytes: Int = safeBulkArgumentByteLimit
    ) -> [[String]] {
        addLabelBatchPlans(
            ids: ids,
            labels: labels,
            maximumArgumentBytes: maximumArgumentBytes
        ).map(\.arguments)
    }

    static func addLabelBatchPlans(
        ids: [String],
        labels: [String],
        maximumArgumentBytes: Int = safeBulkArgumentByteLimit
    ) -> [BeadsAddLabelsBatch] {
        let ids = Array(Set(ids)).sorted()
        let labels = normalizedUniqueLabels(labels)
        let labelArgumentPairs = labels.map { label in
            ["--add-label", IssueDraft.normalizedLabelText([label])]
        }
        guard !ids.isEmpty, !labels.isEmpty else { return [] }

        let unchunkedArguments = ["update"] + ids + labelArgumentPairs.flatMap { $0 }
        if estimatedArgumentBytes(unchunkedArguments) <= maximumArgumentBytes {
            return [BeadsAddLabelsBatch(
                issueIDs: ids,
                labels: labels
            )]
        }

        let commandByteCount = estimatedArgumentBytes(["update"])
        let longestIDByteCount = ids.map { estimatedArgumentBytes([$0]) }.max() ?? 0
        let largestLabelPairByteCount = labelArgumentPairs
            .map(estimatedArgumentBytes)
            .max() ?? 0
        // Giving labels at most roughly half of a large command avoids an
        // inefficient one-ID-per-command cross product when both axes are huge.
        // A single indivisible ID or label can still exceed a caller-supplied
        // synthetic limit; the production limit is intentionally far larger than
        // Beads' valid identifiers and labels.
        let availableLabelByteCount = max(
            1,
            maximumArgumentBytes - commandByteCount - longestIDByteCount
        )
        let balancedLabelByteCount = max(
            1,
            (maximumArgumentBytes - commandByteCount) / 2
        )
        let labelBatchByteLimit = min(
            availableLabelByteCount,
            max(balancedLabelByteCount, largestLabelPairByteCount)
        )
        let labelBatches = chunkLabels(
            labels,
            maximumArgumentBytes: labelBatchByteLimit
        )

        // Use the largest label group to size ID groups, then run ID groups on the
        // outside. Every bead's label commands are therefore adjacent and progress
        // can finish that bead before advancing to the next group.
        let largestLabelByteCount = labelBatches.map {
            estimatedArgumentBytes(addLabelArgumentPairs($0).flatMap { $0 })
        }.max() ?? 0
        let fixedByteCount = commandByteCount + largestLabelByteCount
        var idBatches: [[String]] = []
        var batchIDs: [String] = []
        var batchByteCount = fixedByteCount
        for id in ids {
            let idByteCount = estimatedArgumentBytes([id])
            if !batchIDs.isEmpty, batchByteCount + idByteCount > maximumArgumentBytes {
                idBatches.append(batchIDs)
                batchIDs = []
                batchByteCount = fixedByteCount
            }
            batchIDs.append(id)
            batchByteCount += idByteCount
        }
        if !batchIDs.isEmpty {
            idBatches.append(batchIDs)
        }

        var batches: [BeadsAddLabelsBatch] = []
        batches.reserveCapacity(idBatches.count * labelBatches.count)
        for idBatch in idBatches {
            for labelBatch in labelBatches {
                batches.append(BeadsAddLabelsBatch(
                    issueIDs: idBatch,
                    labels: labelBatch
                ))
            }
        }
        return batches
    }

    private static func addLabelArguments(_ labels: [String]) -> [String] {
        addLabelArgumentPairs(labels).flatMap { $0 }
    }

    private static func addLabelArgumentPairs(_ labels: [String]) -> [[String]] {
        normalizedUniqueLabels(labels).map {
            ["--add-label", IssueDraft.normalizedLabelText([$0])]
        }
    }

    private static func normalizedUniqueLabels(_ labels: [String]) -> [String] {
        let normalizedLabels = IssueDraft.normalizedLabels(IssueDraft.normalizedLabelText(labels))
        var seen: Set<String> = []
        return normalizedLabels.filter { seen.insert($0).inserted }
    }

    private static func labelMutationArguments(
        adding labelsToAdd: [String],
        removing labelsToRemove: [String]
    ) -> [String] {
        labelsToAdd.flatMap {
            ["--add-label", IssueDraft.normalizedLabelText([$0])]
        } + labelsToRemove.flatMap {
            ["--remove-label", IssueDraft.normalizedLabelText([$0])]
        }
    }

    private static func chunkLabelMutationArguments(
        _ operations: [LabelMutationArgument],
        maximumArgumentBytes: Int
    ) -> [[LabelMutationArgument]] {
        var batches: [[LabelMutationArgument]] = []
        var batch: [LabelMutationArgument] = []
        var batchByteCount = 0
        for operation in operations {
            let operationByteCount = estimatedArgumentBytes(operation.arguments)
            if !batch.isEmpty,
               batchByteCount + operationByteCount > maximumArgumentBytes {
                batches.append(batch)
                batch = []
                batchByteCount = 0
            }
            batch.append(operation)
            batchByteCount += operationByteCount
        }
        if !batch.isEmpty {
            batches.append(batch)
        }
        return batches
    }

    private static func chunkLabels(
        _ labels: [String],
        maximumArgumentBytes: Int
    ) -> [[String]] {
        var batches: [[String]] = []
        var batch: [String] = []
        var batchByteCount = 0
        for label in labels {
            let pair = ["--add-label", IssueDraft.normalizedLabelText([label])]
            let pairByteCount = estimatedArgumentBytes(pair)
            if !batch.isEmpty, batchByteCount + pairByteCount > maximumArgumentBytes {
                batches.append(batch)
                batch = []
                batchByteCount = 0
            }
            batch.append(label)
            batchByteCount += pairByteCount
        }
        if !batch.isEmpty {
            batches.append(batch)
        }
        return batches
    }

    private static func estimatedArgumentBytes(_ arguments: [String]) -> Int {
        arguments.reduce(0) { $0 + $1.utf8.count + 1 }
    }

    private struct LabelMutationArgument {
        enum Kind: Equatable {
            case add
            case remove
        }

        let kind: Kind
        let label: String

        var arguments: [String] {
            [
                kind == .add ? "--add-label" : "--remove-label",
                IssueDraft.normalizedLabelText([label])
            ]
        }
    }

    static func setParent(issueID: String, parentID: String?) -> [String] {
        ["update", issueID, "--parent", parentID?.nilIfBlank ?? ""]
    }

    /// `set-state` atomically records an event bead and swaps the `dimension:value`
    /// label, so state changes must never be rewritten as plain label updates.
    static func setState(issueID: String, dimension: String, value: String, reason: String?) -> [String] {
        var arguments = ["set-state", issueID, "\(dimension)=\(value)"]
        appendNonEmpty(&arguments, flag: "--reason", value: reason)
        return arguments
    }

    static func removeStateLabel(issueID: String, dimension: String, value: String) -> [String] {
        let label = BeadStateLabel.label(dimension: dimension, value: value)
        return [
            "update",
            issueID,
            "--remove-label",
            IssueDraft.normalizedLabelText([label])
        ]
    }

    static func createStateClearEvent(issueID: String, dimension: String, reason: String?) -> [String] {
        var description = "Cleared \(dimension)"
        if let reason = reason?.nilIfBlank {
            description += "\n\nReason: \(reason)"
        }
        return [
            "create",
            BeadStateLabel.clearEventTitle(dimension: dimension),
            "--type",
            "event",
            "--priority",
            "P4",
            "--description",
            description,
            "--parent",
            issueID,
            "--silent"
        ]
    }

    static func saveCustomStatuses(_ statuses: [BeadStatusDefinition]) -> [String] {
        let value = statuses
            .map { "\($0.name):\($0.category.rawValue)" }
            .joined(separator: ",")
        return configSetOrUnset(key: "status.custom", value: value)
    }

    static func saveCustomTypes(_ types: [BeadTypeDefinition]) -> [String] {
        let value = types
            .map(\.name)
            .joined(separator: ",")
        return configSetOrUnset(key: "types.custom", value: value)
    }

    static func gateShow(id: String) -> [String] {
        ["--readonly", "gate", "show", id, "--json"]
    }

    static func gateResolve(id: String, reason: String?) -> [String] {
        var arguments = ["gate", "resolve", id]
        appendNonEmpty(&arguments, flag: "--reason", value: reason)
        return arguments
    }

    static func gateCheck(type: String?, escalate: Bool, dryRun: Bool) -> [String] {
        var arguments = ["gate", "check"]
        appendNonEmpty(&arguments, flag: "--type", value: type)
        if escalate {
            arguments.append("--escalate")
        }
        if dryRun {
            arguments.append("--dry-run")
        }
        return arguments
    }

    static func gateCreate(blocks: String, type: GateAwaitType, reason: String?, timeout: String?, awaitID: String?) -> [String] {
        var arguments = ["gate", "create", "--blocks", blocks, "--type", type.commandValue]
        appendNonEmpty(&arguments, flag: "--reason", value: reason)
        appendNonEmpty(&arguments, flag: "--timeout", value: timeout)
        appendNonEmpty(&arguments, flag: "--await-id", value: awaitID)
        return arguments
    }

    static func gateAddWaiter(id: String, waiter: String) -> [String] {
        ["gate", "add-waiter", id, waiter]
    }

    private static func configSetOrUnset(key: String, value: String) -> [String] {
        guard !value.isEmpty else {
            return ["config", "unset", key]
        }
        return ["config", "set", key, value]
    }

    private static func appendNonEmpty(_ arguments: inout [String], flag: String, value: String?) {
        guard let value = value?.nilIfBlank else { return }
        arguments += [flag, value]
    }

    private static func dateUpdateArgument(_ date: Date?) -> String {
        BeadFormatters.commandDate(date) ?? ""
    }

    private static func normalizedLabelArgument(_ labelsText: String) -> String? {
        let labels = IssueDraft.normalizedLabels(labelsText)
        return normalizedLabelArgument(labels)
    }

    private static func normalizedLabelArgument(_ labels: [String]) -> String? {
        guard !labels.isEmpty else { return nil }
        return labels
            .map { IssueDraft.normalizedLabelText([$0]) }
            .joined(separator: ",")
    }

    private static func appendLabelUpdate(
        _ arguments: inout [String],
        labels: [String],
        originalLabels: [String]?
    ) {
        let normalizedLabels = IssueDraft.normalizedLabels(IssueDraft.normalizedLabelText(labels))
        guard let originalLabels else {
            if let labelArgument = normalizedLabelArgument(normalizedLabels) {
                arguments += ["--set-labels", labelArgument]
            }
            return
        }

        let normalizedOriginalLabels = IssueDraft.normalizedLabels(
            IssueDraft.losslessLabelText(originalLabels)
        )
        let targetSet = Set(normalizedLabels)
        let originalSet = Set(normalizedOriginalLabels)

        // Incremental label writes do not retransmit unrelated labels. In
        // particular, a concurrent `bd set-state` label remains owned by that
        // command and cannot be replaced by a stale full-label snapshot.
        for label in normalizedLabels where !originalSet.contains(label) {
            arguments += ["--add-label", IssueDraft.normalizedLabelText([label])]
        }
        for label in normalizedOriginalLabels where !targetSet.contains(label) {
            arguments += ["--remove-label", IssueDraft.normalizedLabelText([label])]
        }
    }
}

/// Shared, thread-safe state coordinating a `bd` subprocess with its task-cancellation
/// handler. Guards two hazards under one lock: (1) `Process.terminate()` raises if the
/// process was never launched, so cancellation must only terminate a launched process; and
/// (2) the worker must be able to tell a termination we caused from a genuine `bd` failure.
private final class SubprocessWatchdogState: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func markFired() {
        lock.lock()
        fired = true
        lock.unlock()
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
    }
}
