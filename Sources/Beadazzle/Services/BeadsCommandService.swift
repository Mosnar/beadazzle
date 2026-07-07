import Foundation

protocol BeadsCommanding: Sendable {
    func initialize(projectURL: URL, options: BeadsInitOptions) async throws
    func exportReadableSnapshot(projectURL: URL) async throws
    func create(projectURL: URL, draft: IssueDraft) async throws -> String
    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws
    func close(projectURL: URL, ids: [String], reason: String?) async throws
    func delete(projectURL: URL, ids: [String]) async throws
    func bulkUpdate(projectURL: URL, ids: [String], status: String?, type: String?, priority: Int?) async throws
    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws
    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws
    func addComment(projectURL: URL, issueID: String, text: String) async throws
    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition]
    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition]
    func loadCustomStatuses(projectURL: URL) async throws -> [BeadStatusDefinition]
    func loadCustomTypes(projectURL: URL) async throws -> [BeadTypeDefinition]
    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws
    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws

    func loadGateDetail(projectURL: URL, id: String) async throws -> BeadGate?
    func resolveGate(projectURL: URL, id: String, reason: String?) async throws
    func checkGates(projectURL: URL, type: String?, escalate: Bool, dryRun: Bool) async throws -> String
    func createGate(projectURL: URL, blocks: String, type: GateAwaitType, reason: String?, timeout: String?, awaitID: String?) async throws -> String
    func addGateWaiter(projectURL: URL, id: String, waiter: String) async throws
}

extension BeadsCommanding {
    func loadCustomStatuses(projectURL: URL) async throws -> [BeadStatusDefinition] {
        try await loadStatusDefinitions(projectURL: projectURL).filter(\.isCustom)
    }

    func loadCustomTypes(projectURL: URL) async throws -> [BeadTypeDefinition] {
        try await loadTypeDefinitions(projectURL: projectURL).filter(\.isCustom)
    }

    // Gate support is optional: conformers that don't shell out to `bd` (test doubles) get
    // safe no-op defaults so a `bd` without gate support degrades to an empty Gates section.
    func loadGateDetail(projectURL _: URL, id _: String) async throws -> BeadGate? { nil }
    func resolveGate(projectURL _: URL, id _: String, reason _: String?) async throws {}
    func checkGates(projectURL _: URL, type _: String?, escalate _: Bool, dryRun _: Bool) async throws -> String { "" }
    func createGate(projectURL _: URL, blocks _: String, type _: GateAwaitType, reason _: String?, timeout _: String?, awaitID _: String?) async throws -> String { "" }
    func addGateWaiter(projectURL _: URL, id _: String, waiter _: String) async throws {}
}

struct BeadsCommandService {
    typealias CommandExecutable = (url: URL, prefix: [String])

    private let readOnlyCommandTimeout: Duration
    private let snapshotExportTimeout: Duration
    private let executable: @Sendable () -> CommandExecutable

    init(
        readOnlyCommandTimeout: Duration = .seconds(10),
        snapshotExportTimeout: Duration = .seconds(60),
        executable: @escaping @Sendable () -> CommandExecutable = { BeadsCLI.executable() }
    ) {
        self.readOnlyCommandTimeout = readOnlyCommandTimeout
        self.snapshotExportTimeout = snapshotExportTimeout
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

    func close(projectURL: URL, ids: [String], reason: String? = "Closed in Beadazzle") async throws {
        guard !ids.isEmpty else { return }
        try await run(projectURL: projectURL, arguments: BeadsCommandArguments.close(ids: ids, reason: reason))
    }

    func delete(projectURL: URL, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await run(projectURL: projectURL, arguments: ["delete"] + ids + ["--force"])
    }

    func bulkUpdate(projectURL: URL, ids: [String], status: String? = nil, type: String? = nil, priority: Int? = nil) async throws {
        guard !ids.isEmpty else { return }
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
        try await run(projectURL: projectURL, arguments: arguments)
    }

    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {
        try await run(projectURL: projectURL, arguments: ["dep", "add", issueID, dependsOnID, "--type", type])
    }

    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {
        try await run(projectURL: projectURL, arguments: ["dep", "remove", issueID, dependsOnID])
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

    private func run(projectURL: URL, arguments: [String], standardInput: String? = nil) async throws {
        _ = try await runOutput(projectURL: projectURL, arguments: arguments, standardInput: standardInput)
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
        precondition(timeout == nil || terminatesOnCancel, "Timed commands must be cancellable.")
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
            try Self.runOutputSynchronously(projectURL: projectURL, arguments: arguments, standardInput: standardInput, executable: executable)
        }.value
    }

    private func configValue(projectURL: URL, key: String) async throws -> String? {
        let text = try await runOutput(
            projectURL: projectURL,
            arguments: ["--readonly", "config", "get", key],
            terminatesOnCancel: true,
            timeout: readOnlyCommandTimeout
        )
        guard !text.hasSuffix(" (not set)") else { return nil }
        return text.isEmpty ? nil : text
    }

    private static func runOutputSynchronously(
        projectURL: URL,
        arguments: [String],
        standardInput: String? = nil,
        executable: CommandExecutable
    ) throws -> String {
        let process = Process()
        process.executableURL = executable.url
        process.arguments = executable.prefix + arguments
        process.currentDirectoryURL = projectURL

        let output = Pipe()
        let input = standardInput.map { _ in Pipe() }
        if let input {
            process.standardInput = input
        }
        process.standardOutput = output
        process.standardError = output

        try process.run()
        if let standardInput, let input {
            input.fileHandleForWriting.write(Data(standardInput.utf8))
            input.fileHandleForWriting.closeFile()
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw BeadError.commandFailed(command: commandDescription(arguments), output: text)
        }
        return text
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
                        if let standardInput, let input {
                            input.fileHandleForWriting.write(Data(standardInput.utf8))
                            input.fileHandleForWriting.closeFile()
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
