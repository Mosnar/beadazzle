import Foundation

protocol BeadsCommanding: Sendable {
    func initialize(projectURL: URL, options: BeadsInitOptions) async throws
    func exportReadableSnapshot(projectURL: URL) async throws
    func create(projectURL: URL, draft: IssueDraft) async throws -> String
    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws
    func updateMetadata(
        projectURL: URL,
        issueID: String,
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
    func setParent(projectURL: URL, issueID: String, parentID: String?) async throws
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
    func loadProjectContext(projectURL: URL) async throws -> BeadsProjectContext
    func loadProjectStorageConfig(projectURL: URL) async throws -> ProjectStorageConfig
    func loadHooksStatus(projectURL: URL) async throws -> BeadsHooksStatus
    func loadBackupStatus(projectURL: URL) async throws -> BeadsBackupStatus
    func installHooks(projectURL: URL) async throws
    func syncBackup(projectURL: URL) async throws

    func loadGateDetail(projectURL: URL, id: String) async throws -> BeadGate?
    func resolveGate(projectURL: URL, id: String, reason: String?) async throws
    func checkGates(projectURL: URL, type: String?, escalate: Bool, dryRun: Bool) async throws -> String
    func createGate(projectURL: URL, blocks: String, type: GateAwaitType, reason: String?, timeout: String?, awaitID: String?) async throws -> String
    func addGateWaiter(projectURL: URL, id: String, waiter: String) async throws
}

extension BeadsCommanding {
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

struct BeadsCommandService {
    typealias CommandExecutable = (url: URL, prefix: [String])

    private let readOnlyCommandTimeout: Duration
    private let snapshotExportTimeout: Duration
    private let writeCommandTimeout: Duration
    private let executable: @Sendable () -> CommandExecutable

    init(
        readOnlyCommandTimeout: Duration = .seconds(10),
        snapshotExportTimeout: Duration = .seconds(60),
        writeCommandTimeout: Duration = .seconds(120),
        executable: @escaping @Sendable () -> CommandExecutable = { BeadsCLI.executable() }
    ) {
        self.readOnlyCommandTimeout = readOnlyCommandTimeout
        self.snapshotExportTimeout = snapshotExportTimeout
        self.writeCommandTimeout = writeCommandTimeout
        self.executable = executable
    }

    func initialize(projectURL: URL, options: BeadsInitOptions) async throws {
        try await run(projectURL: projectURL, arguments: BeadsCommandArguments.initialize(options: options))
        try await exportReadableSnapshot(projectURL: projectURL)
    }

    func exportReadableSnapshot(projectURL: URL) async throws {
        let tempPath = Self.temporaryExportedIssuesJSONLPath()
        let tempURL = projectURL.appendingPathComponent(tempPath)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = try await runOutput(
            projectURL: projectURL,
            arguments: BeadsCommandArguments.exportJSONL(outputPath: tempPath),
            terminatesOnCancel: true,
            timeout: snapshotExportTimeout
        )
        try Self.validateExportedIssuesJSONL(at: tempURL)
        try Self.installExportedIssuesJSONL(tempURL: tempURL, projectURL: projectURL)
    }

    func create(projectURL: URL, draft: IssueDraft) async throws -> String {
        let output = try await runOutput(projectURL: projectURL, arguments: BeadsCommandArguments.create(draft: draft, silent: true))
        return try Self.createdIssueID(from: output)
    }

    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue? = nil) async throws {
        guard let arguments = BeadsCommandArguments.update(draft: draft, originalLabels: originalIssue?.labels) else { return }
        try await run(projectURL: projectURL, arguments: arguments)
    }

    func updateMetadata(
        projectURL: URL,
        issueID: String,
        labels: [String]? = nil,
        originalLabels: [String]? = nil,
        dueAt: IssueMetadataDateUpdate = .unchanged,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) async throws {
        guard let arguments = BeadsCommandArguments.updateMetadata(
            issueID: issueID,
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

    func setParent(projectURL: URL, issueID: String, parentID: String?) async throws {
        try await run(
            projectURL: projectURL,
            arguments: BeadsCommandArguments.setParent(issueID: issueID, parentID: parentID)
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
            terminatesOnCancel: true,
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
            terminatesOnCancel: true,
            timeout: readOnlyCommandTimeout
        )
        return try BeadsMetadataService.decodeStatuses(from: Data(text.utf8))
    }

    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "types", "--json"],
            terminatesOnCancel: true,
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

    func loadProjectContext(projectURL: URL) async throws -> BeadsProjectContext {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "context", "--json"],
            terminatesOnCancel: true,
            timeout: readOnlyCommandTimeout
        )
        return try BeadsProjectContext.decode(from: text)
    }

    func loadProjectStorageConfig(projectURL: URL) async throws -> ProjectStorageConfig {
        async let exportAuto = configBoolSetting(projectURL: projectURL, key: "export.auto")
        async let exportPath = configSetting(projectURL: projectURL, key: "export.path")
        async let exportInterval = configSetting(projectURL: projectURL, key: "export.interval")
        async let exportGitAdd = configBoolSetting(projectURL: projectURL, key: "export.git-add")
        async let importAuto = configBoolSetting(projectURL: projectURL, key: "import.auto")
        async let federationRemote = configSetting(projectURL: projectURL, key: "federation.remote")

        return ProjectStorageConfig(
            exportAutoStatus: await exportAuto,
            exportPathStatus: await exportPath,
            exportIntervalStatus: await exportInterval,
            exportGitAddStatus: await exportGitAdd,
            importAutoStatus: await importAuto,
            federationRemoteStatus: await federationRemote
        )
    }

    func loadHooksStatus(projectURL: URL) async throws -> BeadsHooksStatus {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "hooks", "list"],
            terminatesOnCancel: true,
            timeout: readOnlyCommandTimeout
        )
        return BeadsHooksStatus.parse(from: text)
    }

    func loadBackupStatus(projectURL: URL) async throws -> BeadsBackupStatus {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "backup", "status", "--json"],
            terminatesOnCancel: true,
            timeout: readOnlyCommandTimeout
        )
        return try BeadsBackupStatus.decode(from: text)
    }

    func installHooks(projectURL: URL) async throws {
        try await run(projectURL: projectURL, arguments: ["hooks", "install"])
    }

    func syncBackup(projectURL: URL) async throws {
        try await run(projectURL: projectURL, arguments: ["backup", "sync"])
    }

    private func run(projectURL: URL, arguments: [String], standardInput: String? = nil) async throws {
        _ = try await runOutput(
            projectURL: projectURL,
            arguments: arguments,
            standardInput: standardInput,
            timeout: writeCommandTimeout
        )
    }

    /// - Parameter terminatesOnCancel: when `true`, cancelling the surrounding task kills
    ///   the `bd` subprocess instead of letting `readDataToEndOfFile` block until it exits
    ///   on its own. Only safe for read-only reads — never for writes, which must not be
    ///   interrupted mid-flight. Defaults to `false`.
    private func runOutput(
        projectURL: URL,
        arguments: [String],
        standardInput: String? = nil,
        terminatesOnCancel: Bool = false,
        timeout: Duration? = nil
    ) async throws -> String {
        let executable = executable()
        if terminatesOnCancel {
            guard let timeout else {
                return try await Self.runOutputTerminatingOnCancel(
                    projectURL: projectURL,
                    arguments: arguments,
                    standardInput: standardInput,
                    executable: executable
                )
            }
            return try await Self.runOutputTerminatingOnCancel(
                projectURL: projectURL,
                arguments: arguments,
                standardInput: standardInput,
                executable: executable,
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

    private func configValue(projectURL: URL, key: String) async throws -> String? {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "config", "get", key],
            terminatesOnCancel: true,
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
        timeout: Duration? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = executable.url
        process.arguments = executable.prefix + arguments
        process.currentDirectoryURL = projectURL
        process.environment = BeadsCLI.subprocessEnvironment(executableURL: executable.url)

        let output = Pipe()
        let input = standardInput.map { _ in Pipe() }
        if let input {
            process.standardInput = input
        }
        process.standardOutput = output
        process.standardError = output

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

        var standardInputDelivered = true
        if let standardInput, let input {
            standardInputDelivered = writeStandardInput(standardInput, to: input)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            if watchdog?.state.didFire == true {
                throw BeadError.commandFailed(
                    command: commandDescription(arguments),
                    output: "Timed out waiting for `bd` to finish."
                )
            }
            throw BeadError.commandFailed(command: commandDescription(arguments), output: text)
        }
        guard standardInputDelivered else {
            throw BeadError.commandFailed(
                command: commandDescription(arguments),
                output: "`bd` stopped reading its input before it was fully delivered."
            )
        }
        return text
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
        standardInput: String?,
        executable: CommandExecutable,
        timeout: Duration
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await runOutputTerminatingOnCancel(
                    projectURL: projectURL,
                    arguments: arguments,
                    standardInput: standardInput,
                    executable: executable
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BeadError.commandFailed(
                    command: commandDescription(arguments),
                    output: "Timed out waiting for `bd` to finish."
                )
            }
            do {
                guard let result = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private static func runOutputTerminatingOnCancel(
        projectURL: URL,
        arguments: [String],
        standardInput: String?,
        executable: CommandExecutable
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable.url
        process.arguments = executable.prefix + arguments
        process.currentDirectoryURL = projectURL

        process.environment = BeadsCLI.subprocessEnvironment(executableURL: executable.url)

        let output = Pipe()
        let input = standardInput.map { _ in Pipe() }
        if let input {
            process.standardInput = input
        }
        process.standardOutput = output
        process.standardError = output

        // `launched` gates `terminate()`: `Process.terminate()` raises if the process was
        // never launched, and `onCancel` can fire before (or racing) `process.run()` — most
        // obviously when the task is already cancelled on entry, where the handler runs
        // immediately. `cancelled` lets the worker bail before launching and distinguishes a
        // termination we caused from a genuine `bd` failure.
        let state = SubprocessRunState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        guard !state.isCancelled else {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        try process.run()
                        if state.markLaunchedAndShouldTerminate() {
                            process.terminate()
                        }
                        if state.isCancelled {
                            process.waitUntilExit()
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        var standardInputDelivered = true
                        if let standardInput, let input {
                            standardInputDelivered = writeStandardInput(standardInput, to: input)
                        }
                        let data = output.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        if state.isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard process.terminationStatus == 0 else {
                            continuation.resume(throwing: BeadError.commandFailed(command: commandDescription(arguments), output: text))
                            return
                        }
                        guard standardInputDelivered else {
                            continuation.resume(throwing: BeadError.commandFailed(
                                command: commandDescription(arguments),
                                output: "`bd` stopped reading its input before it was fully delivered."
                            ))
                            return
                        }
                        continuation.resume(returning: text)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            if state.markCancelledAndShouldTerminate() {
                process.terminate()
            }
        }
    }

    private static func commandDescription(_ arguments: [String]) -> String {
        (["bd"] + arguments).joined(separator: " ")
    }

    static func exportedIssuesJSONLURL(projectURL: URL) -> URL {
        projectURL
            .appendingPathComponent(".beads", isDirectory: true)
            .appendingPathComponent("issues.jsonl")
    }

    private static func temporaryExportedIssuesJSONLPath() -> String {
        ".beads/issues.jsonl.tmp.\(UUID().uuidString)"
    }

    static func installExportedIssuesJSONL(tempURL: URL, projectURL: URL, fileManager: FileManager = .default) throws {
        let destinationURL = exportedIssuesJSONLURL(projectURL: projectURL)
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
            throw BeadError.commandFailed(command: "bd create --silent", output: "Expected created bead ID but bd returned no output.")
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

extension BeadsCommandService: BeadsCommanding {}

struct BeadsInitOptions: Equatable, Sendable {
    var prefix = ""
    var usesStealthMode = false
    var skipsAgents = false
    var skipsHooks = false

    var commandPreview: String {
        (["bd"] + BeadsCommandArguments.initialize(options: self))
            .map(Self.shellEscaped)
            .joined(separator: " ")
    }

    private static func shellEscaped(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:-")
        if argument.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum BeadsCommandArguments {
    static let exportedIssuesJSONLPath = ".beads/issues.jsonl"

    static func initialize(options: BeadsInitOptions) -> [String] {
        var arguments = ["init", "--non-interactive", "--role", "maintainer"]
        appendNonEmpty(&arguments, flag: "--prefix", value: options.prefix)
        if options.usesStealthMode {
            arguments.append("--stealth")
        }
        if options.skipsAgents {
            arguments.append("--skip-agents")
        }
        if options.skipsHooks {
            arguments.append("--skip-hooks")
        }
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
        appendNonEmpty(&arguments, flag: "--description", value: draft.description)
        appendNonEmpty(&arguments, flag: "--design", value: draft.design)
        appendNonEmpty(&arguments, flag: "--acceptance", value: draft.acceptanceCriteria)
        appendNonEmpty(&arguments, flag: "--notes", value: draft.notes)
        appendNonEmpty(&arguments, flag: "--assignee", value: draft.assignee)
        appendNonEmpty(&arguments, flag: "--due", value: BeadFormatters.commandDate(draft.dueAt))
        appendNonEmpty(&arguments, flag: "--defer", value: BeadFormatters.commandDate(draft.deferUntil))
        appendNonEmpty(&arguments, flag: "--labels", value: normalizedLabelArgument(draft.labelsText))
        appendNonEmpty(&arguments, flag: "--parent", value: draft.parentID)
        if silent {
            arguments.append("--silent")
        }
        return arguments
    }

    static func update(draft: IssueDraft, originalLabels: [String]? = nil) -> [String]? {
        guard let id = draft.id else { return nil }
        var arguments = [
            "update",
            id,
            "--title",
            draft.title,
            "--type",
            draft.issueType,
            "--priority",
            "P\(draft.priority)",
            "--status",
            draft.status,
            "--description",
            draft.description,
            "--allow-empty-description",
            "--design",
            draft.design,
            "--acceptance",
            draft.acceptanceCriteria,
            "--notes",
            draft.notes
        ]
        appendNonEmpty(&arguments, flag: "--assignee", value: draft.assignee)
        arguments += ["--due", dateUpdateArgument(draft.dueAt)]
        arguments += ["--defer", dateUpdateArgument(draft.deferUntil)]
        appendLabelUpdate(&arguments, draftLabelsText: draft.labelsText, originalLabels: originalLabels)
        return arguments
    }

    static func updateMetadata(
        issueID: String,
        labels: [String]? = nil,
        originalLabels: [String]? = nil,
        dueAt: IssueMetadataDateUpdate = .unchanged,
        deferUntil: IssueMetadataDateUpdate = .unchanged
    ) -> [String]? {
        var arguments = ["update", issueID]
        var didAppendUpdate = false

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
                draftLabelsText: IssueDraft.normalizedLabelText(labels),
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

    static func setParent(issueID: String, parentID: String?) -> [String] {
        ["update", issueID, "--parent", parentID?.nilIfBlank ?? ""]
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
        return labels.isEmpty ? nil : labels.joined(separator: ",")
    }

    private static func appendLabelUpdate(_ arguments: inout [String], draftLabelsText: String, originalLabels: [String]?) {
        if let labels = normalizedLabelArgument(draftLabelsText) {
            arguments += ["--set-labels", labels]
            return
        }

        guard let originalLabels else { return }
        for label in IssueDraft.normalizedLabels(originalLabels.joined(separator: ",")) {
            arguments += ["--remove-label", label]
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

private final class SubprocessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var launched = false
    private var cancelled = false

    /// Records launch and reports whether cancellation already happened before the launch
    /// was visible to the cancellation handler.
    func markLaunchedAndShouldTerminate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        launched = true
        return cancelled
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Records cancellation and reports whether the caller should terminate the process —
    /// true only if it has already been launched, so `terminate()` is always safe to call.
    func markCancelledAndShouldTerminate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        return launched
    }
}
