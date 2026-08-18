import CryptoKit
import Foundation

struct BeadsTrackerRecoveryCommand: Equatable, Sendable {
    enum Purpose: Hashable, Sendable {
        case bdVersion
        case context
        case doltVersion
        case backup
        case schemaPreflight
        case schemaCursorRepair
        case eventsTrackingRepair
        case schemaValidation
        case ignoreValidation
        case workingStateValidation
        case tableValidation
        case bdContextValidation
        case bdListValidation
    }

    let purpose: Purpose
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryURL: URL
    let environment: [String: String]
    let timeout: Duration
}

protocol BeadsTrackerRecoveryProcessRunning: Sendable {
    func run(_ command: BeadsTrackerRecoveryCommand) async throws -> CancellableProcessResult
}

struct LiveBeadsTrackerRecoveryProcessRunner: BeadsTrackerRecoveryProcessRunning {
    func run(_ command: BeadsTrackerRecoveryCommand) async throws -> CancellableProcessResult {
        try await CancellableProcessRunner.run(
            executableURL: command.executableURL,
            arguments: command.arguments,
            currentDirectoryURL: command.currentDirectoryURL,
            environment: command.environment,
            outputLimit: 64 * 1_024,
            timeout: command.timeout,
            cancellationMode: .waitForProcessExit
        )
    }
}

struct BeadsTrackerBackupInspection: Equatable, Sendable {
    let sourceFileBytes: Int64
}

protocol BeadsTrackerRecoveryFileSystem: Sendable {
    func inspectBackup(
        sourceURL: URL,
        databaseDirectoryURL: URL,
        projectURL: URL,
        backupURL: URL
    ) async throws -> BeadsTrackerBackupInspection
    func fingerprintTracker(
        sourceURL: URL,
        databaseDirectoryURL: URL,
        projectURL: URL
    ) async throws -> BeadsTrackerBackupFingerprint
    func prepareBackupParent(for backupURL: URL) async throws
    func validateBackup(
        sourceURL: URL,
        backupURL: URL,
        databaseName: String,
        expectedFingerprint: BeadsTrackerBackupFingerprint
    ) async throws
}

struct SystemBeadsTrackerRecoveryFileSystem: BeadsTrackerRecoveryFileSystem {
    func inspectBackup(
        sourceURL: URL,
        databaseDirectoryURL: URL,
        projectURL: URL,
        backupURL: URL
    ) async throws -> BeadsTrackerBackupInspection {
        try await Self.runDetached {
            let fileManager = FileManager.default
            try Self.requireSafeTrackerSource(
                sourceURL: sourceURL,
                databaseDirectoryURL: databaseDirectoryURL,
                projectURL: projectURL
            )
            let resolvedBackupURL = backupURL.resolvingSymlinksInPath()
            let resolvedProjectURL = projectURL.resolvingSymlinksInPath()
            guard !Self.isDescendant(backupURL, of: projectURL),
                  !Self.isDescendant(projectURL, of: backupURL),
                  !Self.isDescendant(resolvedBackupURL, of: resolvedProjectURL),
                  !Self.isDescendant(resolvedProjectURL, of: resolvedBackupURL) else {
                throw BeadsTrackerRecoveryFailure(
                    message: "The recovery backup must be stored outside the project repository.",
                    backupURL: nil,
                    log: []
                )
            }
            guard !fileManager.fileExists(atPath: backupURL.path) else {
                throw BeadsTrackerRecoveryFailure(
                    message: "The planned recovery backup path already exists.",
                    backupURL: backupURL,
                    log: []
                )
            }

            let source = try Self.measureRegularFiles(in: sourceURL)
            guard source.count > 0, source.bytes > 0 else {
                throw BeadsTrackerRecoveryFailure(
                    message: "The effective tracker directory does not contain a recoverable database backup source.",
                    backupURL: nil,
                    log: []
                )
            }
            let capacityURL = try Self.existingAncestor(
                of: backupURL.deletingLastPathComponent()
            )
            let attributes = try fileManager.attributesOfFileSystem(forPath: capacityURL.path)
            let availableBytes = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            let margin = max(Int64(64 * 1_024 * 1_024), source.bytes / 10)
            guard availableBytes >= source.bytes + margin else {
                throw BeadsTrackerRecoveryFailure(
                    message: "Not enough free space for a verified recovery backup. Free at least \(ByteCountFormatter.string(fromByteCount: source.bytes + margin, countStyle: .file)).",
                    backupURL: nil,
                    log: []
                )
            }
            return BeadsTrackerBackupInspection(
                sourceFileBytes: source.bytes
            )
        }
    }

    func fingerprintTracker(
        sourceURL: URL,
        databaseDirectoryURL: URL,
        projectURL: URL
    ) async throws -> BeadsTrackerBackupFingerprint {
        try await Self.runDetached {
            try Self.requireSafeTrackerSource(
                sourceURL: sourceURL,
                databaseDirectoryURL: databaseDirectoryURL,
                projectURL: projectURL
            )
            return try Self.fingerprint(of: sourceURL)
        }
    }

    func prepareBackupParent(for backupURL: URL) async throws {
        try await Self.runDetached {
            let fileManager = FileManager.default
            guard !fileManager.fileExists(atPath: backupURL.path) else {
                throw BeadsTrackerRecoveryFailure(
                    message: "The recovery backup path already exists; no tracker changes were made.",
                    backupURL: backupURL,
                    log: []
                )
            }
            try fileManager.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
    }

    func validateBackup(
        sourceURL: URL,
        backupURL: URL,
        databaseName: String,
        expectedFingerprint: BeadsTrackerBackupFingerprint
    ) async throws {
        try await Self.runDetached {
            try Self.requireDirectory(backupURL, named: "recovery backup")
            try Self.requireNotSymbolicLink(backupURL, named: "recovery backup")
            let databaseURL = backupURL
                .appendingPathComponent("embeddeddolt", isDirectory: true)
                .appendingPathComponent(databaseName, isDirectory: true)
            try Self.requireDirectory(databaseURL, named: "backed-up Dolt database")
            let sourceFingerprint = try Self.fingerprint(of: sourceURL)
            let backupFingerprint = try Self.fingerprint(of: backupURL)
            guard sourceFingerprint == expectedFingerprint,
                  backupFingerprint == expectedFingerprint else {
                throw BeadsTrackerRecoveryFailure(
                    message: "The copied recovery backup did not match the source tracker. No tracker repair was attempted.",
                    backupURL: backupURL,
                    log: []
                )
            }
        }
    }

    private static func requireSafeTrackerSource(
        sourceURL: URL,
        databaseDirectoryURL: URL,
        projectURL: URL
    ) throws {
        try requireConservativeTrackerRoot(sourceURL, projectURL: projectURL)
        try requireDirectory(sourceURL, named: "effective tracker directory")
        try requireDirectory(databaseDirectoryURL, named: "embedded Dolt database")
        try requireNotSymbolicLink(sourceURL, named: "effective tracker directory")
        try requireNotSymbolicLink(databaseDirectoryURL, named: "embedded Dolt database")
        guard isDescendant(databaseDirectoryURL, of: sourceURL) else {
            throw BeadsTrackerRecoveryFailure(
                message: "The resolved Dolt database is outside the effective tracker directory.",
                backupURL: nil,
                log: []
            )
        }
        try requireNoSymbolicLinkComponents(
            from: sourceURL,
            through: databaseDirectoryURL,
            named: "embedded Dolt database path"
        )
    }

    private static func requireDirectory(_ url: URL, named name: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BeadsTrackerRecoveryFailure(
                message: "The \(name) could not be verified at \(url.path).",
                backupURL: nil,
                log: []
            )
        }
    }

    private static func requireConservativeTrackerRoot(_ url: URL, projectURL: URL) throws {
        let normalizedURL = url.standardizedFileURL
        let path = normalizedURL.path
        let forbiddenPaths = [
            "/",
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
            projectURL.standardizedFileURL.path
        ]
        guard !forbiddenPaths.contains(path),
              normalizedURL.lastPathComponent == ".beads",
              normalizedURL.pathComponents.count >= 3 else {
            throw BeadsTrackerRecoveryFailure(
                message: "bd context did not resolve a conservatively scoped .beads tracker directory.",
                backupURL: nil,
                log: []
            )
        }
    }

    private static func requireNotSymbolicLink(_ url: URL, named name: String) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw BeadsTrackerRecoveryFailure(
                message: "The \(name) is a symbolic link, so Beadazzle will not run a low-level recovery there.",
                backupURL: nil,
                log: []
            )
        }
    }

    private static func requireNoSymbolicLinkComponents(
        from ancestorURL: URL,
        through descendantURL: URL,
        named name: String
    ) throws {
        let ancestor = ancestorURL.standardizedFileURL
        var current = descendantURL.standardizedFileURL
        while current.path != ancestor.path {
            try requireNotSymbolicLink(current, named: name)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                throw BeadsTrackerRecoveryFailure(
                    message: "The \(name) could not be proven to stay inside the effective tracker directory.",
                    backupURL: nil,
                    log: []
                )
            }
            current = parent
        }
    }

    private static func existingAncestor(of url: URL) throws -> URL {
        let fileManager = FileManager.default
        var current = url.standardizedFileURL
        while !fileManager.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else {
                throw BeadsTrackerRecoveryFailure(
                    message: "The backup destination filesystem could not be inspected.",
                    backupURL: nil,
                    log: []
                )
            }
            current = parent
        }
        return current
    }

    private static func measureRegularFiles(in rootURL: URL) throws -> (count: Int, bytes: Int64) {
        try Task.checkCancellation()
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw BeadsTrackerRecoveryFailure(
                message: "The tracker could not be enumerated for backup sizing.",
                backupURL: nil,
                log: []
            )
        }
        var count = 0
        var bytes: Int64 = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        if let enumerationError {
            throw BeadsTrackerRecoveryFailure(
                message: "The tracker could not be fully enumerated for backup sizing: \(enumerationError.localizedDescription)",
                backupURL: nil,
                log: []
            )
        }
        return (count, bytes)
    }

    private static func fingerprint(of rootURL: URL) throws -> BeadsTrackerBackupFingerprint {
        try Task.checkCancellation()
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw BeadsTrackerRecoveryFailure(
                message: "The tracker could not be enumerated for backup verification.",
                backupURL: nil,
                log: []
            )
        }
        var regularFileCount = 0
        var directoryCount = 0
        var symbolicLinkCount = 0
        var regularFileBytes: Int64 = 0
        var entries: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            entries.append(url)
        }
        if let enumerationError {
            throw BeadsTrackerRecoveryFailure(
                message: "The tracker could not be fully enumerated for backup verification: \(enumerationError.localizedDescription)",
                backupURL: nil,
                log: []
            )
        }

        entries.sort { lhs, rhs in
            relativePath(of: lhs, under: rootURL) < relativePath(of: rhs, under: rootURL)
        }
        var hasher = SHA256()
        for url in entries {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            let relativePath = relativePath(of: url, under: rootURL)
            hasher.update(data: Data(relativePath.utf8))
            if values.isSymbolicLink == true {
                symbolicLinkCount += 1
                hasher.update(data: Data("\0link\0".utf8))
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                hasher.update(data: Data(destination.utf8))
            } else if values.isDirectory == true {
                directoryCount += 1
                hasher.update(data: Data("\0directory\0".utf8))
            } else if values.isRegularFile == true {
                regularFileCount += 1
                regularFileBytes += Int64(values.fileSize ?? 0)
                hasher.update(data: Data("\0file\0".utf8))
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
                    try Task.checkCancellation()
                    hasher.update(data: data)
                }
            }
            hasher.update(data: Data("\0entry-end\0".utf8))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return BeadsTrackerBackupFingerprint(
            regularFileCount: regularFileCount,
            directoryCount: directoryCount,
            symbolicLinkCount: symbolicLinkCount,
            regularFileBytes: regularFileBytes,
            digest: digest
        )
    }

    private static func relativePath(of url: URL, under rootURL: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(rootURL.standardizedFileURL.path.count + 1))
    }

    private static func isDescendant(_ candidateURL: URL, of parentURL: URL) -> Bool {
        let candidate = candidateURL.standardizedFileURL.path
        let parent = parentURL.standardizedFileURL.path
        return candidate == parent || candidate.hasPrefix(parent + "/")
    }

    private static func runDetached<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .utility) {
            try operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

protocol BeadsTrackerRecovering: Sendable {
    func diagnose(
        projectURL: URL,
        skew: BeadsSchemaSkew,
        activity: BeadsTrackerRecoveryActivity
    ) async -> BeadsTrackerRecoveryAssessment

    func recover(
        assessment: BeadsTrackerRecoveryAssessment,
        activity: BeadsTrackerRecoveryActivity,
        progress: @escaping @Sendable (BeadsTrackerRecoveryProgress) -> Void
    ) async throws -> BeadsTrackerRecoveryResult
}

struct BeadsTrackerRecoveryService: BeadsTrackerRecovering {
    static let supportedBDVersion = "1.2.2"

    /// Fixed statements from the pinned bd 1.2.2 guide. The events repair also stages
    /// `dolt_ignore` explicitly because Dolt 2.3 can otherwise leave that deletion
    /// unstaged while committing the re-tracked `events` table.
    static let schemaCursorRepairSQL = """
    DELETE FROM schema_migrations WHERE version > 53; CALL DOLT_ADD('schema_migrations'); CALL DOLT_COMMIT('-m', 'recovery: roll schema cursor back to v53 (accidental v1.2.1)', '--author', 'bd recovery <recovery@beads.invalid>')
    """
    static let eventsTrackingRepairSQL = """
    DELETE FROM dolt_ignore WHERE pattern = 'events'; CALL DOLT_ADD('dolt_ignore'); CALL DOLT_ADD('-f', 'events'); CALL DOLT_COMMIT('-m', 'recovery: re-track events table', '--author', 'bd recovery <recovery@beads.invalid>')
    """

    private let processRunner: any BeadsTrackerRecoveryProcessRunning
    private let fileSystem: any BeadsTrackerRecoveryFileSystem
    private let bdExecutable: @Sendable () -> BeadsCommandService.CommandExecutable
    private let backupRoot: @Sendable () throws -> URL
    private let now: @Sendable () -> Date
    private let uniqueID: @Sendable () -> UUID

    init(
        processRunner: any BeadsTrackerRecoveryProcessRunning = LiveBeadsTrackerRecoveryProcessRunner(),
        fileSystem: any BeadsTrackerRecoveryFileSystem = SystemBeadsTrackerRecoveryFileSystem(),
        bdExecutable: @escaping @Sendable () -> BeadsCommandService.CommandExecutable = {
            BeadsCLI.executable()
        },
        backupRoot: @escaping @Sendable () throws -> URL = {
            try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            .appendingPathComponent("Beadazzle", isDirectory: true)
            .appendingPathComponent("Recovery Backups", isDirectory: true)
        },
        now: @escaping @Sendable () -> Date = { .now },
        uniqueID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.bdExecutable = bdExecutable
        self.backupRoot = backupRoot
        self.now = now
        self.uniqueID = uniqueID
    }

    func diagnose(
        projectURL: URL,
        skew: BeadsSchemaSkew,
        activity: BeadsTrackerRecoveryActivity
    ) async -> BeadsTrackerRecoveryAssessment {
        var checks: [BeadsTrackerRecoveryCheck] = []
        guard skew.supportsPinnedV65ToV53Recovery else {
            return blockedAssessment(
                skew: skew,
                checks: checks,
                message: Self.unsupportedSkewGuidance(for: skew)
            )
        }
        checks.append(passedCheck(
            id: .incident,
            title: "Pinned recovery incident",
            detail: "Database v65 with a bd binary that supports schema v53 matches the bd 1.2.2 recovery guide."
        ))
        if let blocker = activity.blocker {
            checks.append(blockedCheck(id: .activity, title: "App activity", detail: blocker))
            return blockedAssessment(skew: skew, checks: checks, message: blocker)
        }
        checks.append(passedCheck(
            id: .activity,
            title: "App activity",
            detail: "No Beadazzle mutation, database action, or competing project window is active."
        ))

        let executable = bdExecutable()
        let environment = BeadsCLI.subprocessEnvironment(executableURL: executable.url)
        let bdVersion: String
        do {
            bdVersion = try await validatedBDVersion(
                executable: executable,
                projectURL: projectURL,
                environment: environment
            )
            checks.append(passedCheck(
                id: .bdVersion,
                title: "Supported bd release",
                detail: "bd \(bdVersion) is the tested recovery binary. The accidental 1.2.0/1.2.1 release should not be reinstalled."
            ))
        } catch {
            let message = error.localizedDescription
            checks.append(blockedCheck(id: .bdVersion, title: "Supported bd release", detail: message))
            return blockedAssessment(skew: skew, checks: checks, message: message)
        }

        let context: BeadsProjectContext
        let environmentModel: BeadsProjectEnvironment
        let databaseName: String
        do {
            context = try await loadRecoveryContext(
                executable: executable,
                projectURL: projectURL,
                environment: environment
            )
            environmentModel = try BeadsProjectEnvironment(context: context, projectURL: projectURL)
            guard environmentModel.storageMode == .embedded else {
                throw recoveryFailure("Automatic recovery is limited to a local embedded Dolt tracker.")
            }
            databaseName = try Self.validatedDatabaseName(context.database)
            guard context.bdVersion?.split(separator: " ").first.map(String.init)
                    == Self.supportedBDVersion else {
                throw recoveryFailure("The effective tracker context does not report bd \(Self.supportedBDVersion).")
            }
            checks.append(passedCheck(
                id: .context,
                title: "Effective local tracker",
                detail: "Embedded database \(databaseName) in \(environmentModel.beadsDirectoryURL.path)."
            ))
        } catch {
            let message = error.localizedDescription
            checks.append(blockedCheck(id: .context, title: "Effective local tracker", detail: message))
            return blockedAssessment(skew: skew, checks: checks, message: message)
        }

        let doltVersion: String
        do {
            doltVersion = try await validatedDoltVersion(
                projectURL: projectURL,
                environment: environment
            )
            checks.append(passedCheck(
                id: .doltVersion,
                title: "Dolt CLI",
                detail: "dolt \(doltVersion) is available for the guide's low-level repair."
            ))
        } catch {
            let message = error.localizedDescription
            checks.append(blockedCheck(id: .doltVersion, title: "Dolt CLI", detail: message))
            return blockedAssessment(skew: skew, checks: checks, message: message)
        }

        let databaseDirectoryURL = environmentModel.beadsDirectoryURL
            .appendingPathComponent("embeddeddolt", isDirectory: true)
            .appendingPathComponent(databaseName, isDirectory: true)
            .standardizedFileURL
        let backupURL: URL
        do {
            backupURL = try makeBackupURL(projectURL: projectURL)
        } catch {
            let message = "A backup destination could not be prepared: \(error.localizedDescription)"
            checks.append(blockedCheck(id: .backup, title: "Recovery backup", detail: message))
            return blockedAssessment(skew: skew, checks: checks, message: message)
        }

        do {
            let currentCursor = try await schemaCursor(
                purpose: .schemaPreflight,
                databaseDirectoryURL: databaseDirectoryURL,
                environment: environment
            )
            guard currentCursor == 65 else {
                throw recoveryFailure(
                    "The effective database currently reports schema cursor v\(currentCursor), not the pinned v65 incident."
                )
            }
            checks.append(passedCheck(
                id: .schemaCursor,
                title: "Current schema cursor",
                detail: "The effective embedded database independently confirms schema cursor v65."
            ))
        } catch {
            let message = error.localizedDescription
            checks.append(blockedCheck(
                id: .schemaCursor,
                title: "Current schema cursor",
                detail: message
            ))
            return blockedAssessment(skew: skew, checks: checks, message: message)
        }

        do {
            let inspection = try await fileSystem.inspectBackup(
                sourceURL: environmentModel.beadsDirectoryURL,
                databaseDirectoryURL: databaseDirectoryURL,
                projectURL: projectURL,
                backupURL: backupURL
            )
            checks.append(passedCheck(
                id: .backup,
                title: "Recovery backup",
                detail: "A \(ByteCountFormatter.string(fromByteCount: inspection.sourceFileBytes, countStyle: .file)) copy can be written outside the repository at \(backupURL.path)."
            ))
        } catch {
            let message = error.localizedDescription
            checks.append(blockedCheck(id: .backup, title: "Recovery backup", detail: message))
            return blockedAssessment(skew: skew, checks: checks, message: message)
        }

        return BeadsTrackerRecoveryAssessment(
            skew: skew,
            checks: checks,
            plan: BeadsTrackerRecoveryPlan(
                projectURL: projectURL.standardizedFileURL,
                beadsDirectoryURL: environmentModel.beadsDirectoryURL.standardizedFileURL,
                databaseDirectoryURL: databaseDirectoryURL,
                databaseName: databaseName,
                backupURL: backupURL,
                bdExecutableURL: executable.url,
                bdArgumentsPrefix: executable.prefix,
                subprocessEnvironment: environment,
                bdVersion: bdVersion,
                doltVersion: doltVersion
            ),
            blockingMessage: nil
        )
    }

    func recover(
        assessment: BeadsTrackerRecoveryAssessment,
        activity: BeadsTrackerRecoveryActivity,
        progress: @escaping @Sendable (BeadsTrackerRecoveryProgress) -> Void
    ) async throws -> BeadsTrackerRecoveryResult {
        var log: [String] = []
        var createdBackupURL: URL?
        do {
            guard assessment.skew.supportsPinnedV65ToV53Recovery,
                  assessment.canRecover,
                  let plan = assessment.plan else {
                throw recoveryFailure("This assessment does not authorize automatic recovery.")
            }
            if let blocker = activity.blocker {
                throw recoveryFailure(blocker)
            }

            append("Rechecking bd, Dolt, tracker context, and backup capacity.", phase: .checkingPrerequisites, log: &log, progress: progress)
            try await revalidate(plan: plan)

            append("Fingerprinting the effective tracker before backup.", phase: .creatingBackup, log: &log, progress: progress)
            try await fileSystem.prepareBackupParent(for: plan.backupURL)
            createdBackupURL = plan.backupURL
            let backupFingerprint = try await fileSystem.fingerprintTracker(
                sourceURL: plan.beadsDirectoryURL,
                databaseDirectoryURL: plan.databaseDirectoryURL,
                projectURL: plan.projectURL
            )
            append("Copying the complete effective tracker outside the repository.", phase: .creatingBackup, log: &log, progress: progress)
            let backupResult = try await processRunner.run(BeadsTrackerRecoveryCommand(
                purpose: .backup,
                executableURL: URL(fileURLWithPath: "/bin/cp"),
                arguments: ["-a", plan.beadsDirectoryURL.path, plan.backupURL.path],
                currentDirectoryURL: plan.projectURL,
                environment: plan.subprocessEnvironment,
                timeout: .seconds(1_800)
            ))
            try Self.requireSuccess(backupResult, command: "backup copy")
            try await fileSystem.validateBackup(
                sourceURL: plan.beadsDirectoryURL,
                backupURL: plan.backupURL,
                databaseName: plan.databaseName,
                expectedFingerprint: backupFingerprint
            )
            append("Verified recovery backup: \(plan.backupURL.path)", phase: .creatingBackup, log: &log, progress: progress)

            append("Applying the pinned schema-cursor rollback.", phase: .repairingSchemaCursor, log: &log, progress: progress)
            try await runDoltRepair(
                purpose: .schemaCursorRepair,
                sql: Self.schemaCursorRepairSQL,
                plan: plan
            )

            append("Re-tracking events and explicitly staging dolt_ignore.", phase: .restoringEventsTracking, log: &log, progress: progress)
            try await runDoltRepair(
                purpose: .eventsTrackingRepair,
                sql: Self.eventsTrackingRepairSQL,
                plan: plan
            )

            append("Checking schema v53, events tracking, a clean Dolt state, and normal bd access.", phase: .validating, log: &log, progress: progress)
            try await validateRecoveredTracker(plan: plan)
            append("Local recovery completed. No pull or push was run.", phase: .validating, log: &log, progress: progress)
            return BeadsTrackerRecoveryResult(backupURL: plan.backupURL, log: log)
        } catch let failure as BeadsTrackerRecoveryFailure {
            throw BeadsTrackerRecoveryFailure(
                message: failure.message,
                backupURL: failure.backupURL ?? createdBackupURL,
                log: log + failure.log
            )
        } catch is CancellationError {
            throw BeadsTrackerRecoveryFailure(
                message: "Recovery was stopped. The tracker will remain read-only until validation succeeds.",
                backupURL: createdBackupURL,
                log: log
            )
        } catch {
            throw BeadsTrackerRecoveryFailure(
                message: error.localizedDescription,
                backupURL: createdBackupURL,
                log: log
            )
        }
    }

    static func unsupportedSkewGuidance(for skew: BeadsSchemaSkew) -> String {
        skew.resolution.guidance
    }

    private func revalidate(plan: BeadsTrackerRecoveryPlan) async throws {
        let executable = (
            url: plan.bdExecutableURL,
            prefix: plan.bdArgumentsPrefix
        )
        let bdVersion = try await validatedBDVersion(
            executable: executable,
            projectURL: plan.projectURL,
            environment: plan.subprocessEnvironment
        )
        guard bdVersion == plan.bdVersion else {
            throw recoveryFailure("The resolved bd executable changed after review.")
        }
        let context = try await loadRecoveryContext(
            executable: executable,
            projectURL: plan.projectURL,
            environment: plan.subprocessEnvironment
        )
        let environment = try BeadsProjectEnvironment(context: context, projectURL: plan.projectURL)
        guard environment.storageMode == .embedded,
              environment.beadsDirectoryURL.standardizedFileURL == plan.beadsDirectoryURL,
              try Self.validatedDatabaseName(context.database) == plan.databaseName else {
            throw recoveryFailure("The effective tracker changed after review; no recovery was attempted.")
        }
        let doltVersion = try await validatedDoltVersion(
            projectURL: plan.projectURL,
            environment: plan.subprocessEnvironment
        )
        guard doltVersion == plan.doltVersion else {
            throw recoveryFailure("The resolved Dolt executable changed after review.")
        }
        let currentCursor = try await schemaCursor(
            purpose: .schemaPreflight,
            databaseDirectoryURL: plan.databaseDirectoryURL,
            environment: plan.subprocessEnvironment
        )
        guard currentCursor == 65 else {
            throw recoveryFailure(
                "The schema cursor changed after review; automatic recovery requires v65 exactly."
            )
        }
        _ = try await fileSystem.inspectBackup(
            sourceURL: plan.beadsDirectoryURL,
            databaseDirectoryURL: plan.databaseDirectoryURL,
            projectURL: plan.projectURL,
            backupURL: plan.backupURL
        )
    }

    private func validatedBDVersion(
        executable: BeadsCommandService.CommandExecutable,
        projectURL: URL,
        environment: [String: String]
    ) async throws -> String {
        let result = try await processRunner.run(BeadsTrackerRecoveryCommand(
            purpose: .bdVersion,
            executableURL: executable.url,
            arguments: executable.prefix + ["version"],
            currentDirectoryURL: projectURL,
            environment: environment,
            timeout: .seconds(15)
        ))
        try Self.requireSuccess(result, command: "bd version")
        guard let reported = BeadsCLIVersionProbe.version(from: result.output),
              let version = reported.split(separator: " ").first.map(String.init),
              version == Self.supportedBDVersion else {
            throw recoveryFailure("Automatic recovery requires the tested bd \(Self.supportedBDVersion) release.")
        }
        return version
    }

    private func loadRecoveryContext(
        executable: BeadsCommandService.CommandExecutable,
        projectURL: URL,
        environment: [String: String]
    ) async throws -> BeadsProjectContext {
        let result = try await processRunner.run(BeadsTrackerRecoveryCommand(
            purpose: .context,
            executableURL: executable.url,
            arguments: executable.prefix + ["--ignore-schema-skew", "context", "--json"],
            currentDirectoryURL: projectURL,
            environment: environment,
            timeout: .seconds(15)
        ))
        try Self.requireSuccess(result, command: "bd context --json")
        return try BeadsJSONCommandOutput.decodeObject(
            BeadsProjectContext.self,
            from: result.output,
            command: "bd context --json"
        )
    }

    private func validatedDoltVersion(
        projectURL: URL,
        environment: [String: String]
    ) async throws -> String {
        let result = try await processRunner.run(BeadsTrackerRecoveryCommand(
            purpose: .doltVersion,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["dolt", "version"],
            currentDirectoryURL: projectURL,
            environment: environment,
            timeout: .seconds(15)
        ))
        try Self.requireSuccess(result, command: "dolt version")
        guard let line = result.output.split(whereSeparator: \Character.isNewline).first else {
            throw recoveryFailure("Dolt did not report a version.")
        }
        let prefix = "dolt version "
        let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix(prefix),
              let version = text.dropFirst(prefix.count).split(separator: " ").first,
              version.split(separator: ".").allSatisfy({ Int($0) != nil }) else {
            throw recoveryFailure("The resolved `dolt` executable did not report a supported version banner.")
        }
        return String(version)
    }

    private func runDoltRepair(
        purpose: BeadsTrackerRecoveryCommand.Purpose,
        sql: String,
        plan: BeadsTrackerRecoveryPlan
    ) async throws {
        let command = doltCommand(
            purpose: purpose,
            arguments: ["sql", "-q", sql],
            plan: plan,
            timeout: .seconds(300)
        )
        let runner = processRunner
        let result = try await Task.detached {
            try await runner.run(command)
        }.value
        try Task.checkCancellation()
        if result.terminationStatus == 0 { return }
        guard result.output.localizedCaseInsensitiveContains("nothing to commit") else {
            throw recoveryFailure("The Dolt recovery step failed: \(result.output.nilIfBlank ?? "no command output")")
        }
    }

    private func schemaCursor(
        purpose: BeadsTrackerRecoveryCommand.Purpose,
        databaseDirectoryURL: URL,
        environment: [String: String]
    ) async throws -> Int {
        let result = try await processRunner.run(BeadsTrackerRecoveryCommand(
            purpose: purpose,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "dolt", "sql", "-r", "json", "-q",
                "SELECT MAX(version) AS version FROM schema_migrations;"
            ],
            currentDirectoryURL: databaseDirectoryURL,
            environment: environment,
            timeout: .seconds(30)
        ))
        try Self.requireSuccess(result, command: "dolt schema cursor check")
        guard let cursor = Self.integer(named: "version", in: result.output) else {
            throw recoveryFailure("Dolt did not return a parseable schema cursor.")
        }
        return cursor
    }

    private func validateRecoveredTracker(plan: BeadsTrackerRecoveryPlan) async throws {
        let schema = try await requiredDoltOutput(
            purpose: .schemaValidation,
            arguments: ["sql", "-r", "json", "-q", "SELECT MAX(version) AS version FROM schema_migrations;"],
            plan: plan
        )
        guard Self.integer(named: "version", in: schema) == 53 else {
            throw recoveryFailure("Post-recovery validation did not find schema cursor v53.")
        }

        let ignored = try await requiredDoltOutput(
            purpose: .ignoreValidation,
            arguments: ["sql", "-r", "json", "-q", "SELECT COUNT(*) AS ignored FROM dolt_ignore WHERE pattern = 'events';"],
            plan: plan
        )
        guard Self.integer(named: "ignored", in: ignored) == 0 else {
            throw recoveryFailure("The events table is still ignored after recovery.")
        }

        let changes = try await requiredDoltOutput(
            purpose: .workingStateValidation,
            arguments: ["sql", "-r", "json", "-q", "SELECT COUNT(*) AS changes FROM dolt_status;"],
            plan: plan
        )
        guard Self.integer(named: "changes", in: changes) == 0 else {
            throw recoveryFailure("Dolt still has uncommitted recovery changes, including a possible dolt_ignore deletion.")
        }

        let tables = try await requiredDoltOutput(
            purpose: .tableValidation,
            arguments: ["ls"],
            plan: plan
        )
        let tableNames = Set(tables.split(whereSeparator: \Character.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        guard tableNames.contains("events") else {
            throw recoveryFailure("The events table is not tracked after recovery.")
        }

        let context = try await processRunner.run(BeadsTrackerRecoveryCommand(
            purpose: .bdContextValidation,
            executableURL: plan.bdExecutableURL,
            arguments: plan.bdArgumentsPrefix + ["context", "--json"],
            currentDirectoryURL: plan.projectURL,
            environment: plan.subprocessEnvironment,
            timeout: .seconds(30)
        ))
        try Self.requireSuccess(context, command: "bd context --json")
        _ = try BeadsJSONCommandOutput.decodeObject(
            BeadsProjectContext.self,
            from: context.output,
            command: "bd context --json"
        )

        let list = try await processRunner.run(BeadsTrackerRecoveryCommand(
            purpose: .bdListValidation,
            executableURL: plan.bdExecutableURL,
            arguments: plan.bdArgumentsPrefix + ["--readonly", "list", "--limit", "1", "--json"],
            currentDirectoryURL: plan.projectURL,
            environment: plan.subprocessEnvironment,
            timeout: .seconds(30)
        ))
        try Self.requireSuccess(list, command: "bd --readonly list --limit 1 --json")
        try BeadsJSONCommandOutput.requireArray(
            in: list.output,
            command: "bd --readonly list --limit 1 --json"
        )
    }

    private func requiredDoltOutput(
        purpose: BeadsTrackerRecoveryCommand.Purpose,
        arguments: [String],
        plan: BeadsTrackerRecoveryPlan
    ) async throws -> String {
        let result = try await processRunner.run(doltCommand(
            purpose: purpose,
            arguments: arguments,
            plan: plan,
            timeout: .seconds(30)
        ))
        try Self.requireSuccess(result, command: "dolt \(arguments.first ?? "command")")
        return result.output
    }

    private func doltCommand(
        purpose: BeadsTrackerRecoveryCommand.Purpose,
        arguments: [String],
        plan: BeadsTrackerRecoveryPlan,
        timeout: Duration
    ) -> BeadsTrackerRecoveryCommand {
        BeadsTrackerRecoveryCommand(
            purpose: purpose,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["dolt"] + arguments,
            currentDirectoryURL: plan.databaseDirectoryURL,
            environment: plan.subprocessEnvironment,
            timeout: timeout
        )
    }

    private func makeBackupURL(projectURL: URL) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: now())
            .replacingOccurrences(of: ":", with: "-")
        let projectName = projectURL.lastPathComponent
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }
        let safeProjectName = String(projectName).nilIfBlank ?? "project"
        return try backupRoot().appendingPathComponent(
            "\(safeProjectName)-\(timestamp)-\(uniqueID().uuidString).beads-backup",
            isDirectory: true
        )
    }

    private func append(
        _ message: String,
        phase: BeadsTrackerRecoveryPhase,
        log: inout [String],
        progress: @escaping @Sendable (BeadsTrackerRecoveryProgress) -> Void
    ) {
        log.append(message)
        progress(BeadsTrackerRecoveryProgress(phase: phase, log: log))
    }

    private func blockedAssessment(
        skew: BeadsSchemaSkew,
        checks: [BeadsTrackerRecoveryCheck],
        message: String
    ) -> BeadsTrackerRecoveryAssessment {
        BeadsTrackerRecoveryAssessment(
            skew: skew,
            checks: checks,
            plan: nil,
            blockingMessage: message
        )
    }

    private func passedCheck(
        id: BeadsTrackerRecoveryCheckID,
        title: String,
        detail: String
    ) -> BeadsTrackerRecoveryCheck {
        BeadsTrackerRecoveryCheck(id: id, title: title, detail: detail, status: .passed)
    }

    private func blockedCheck(
        id: BeadsTrackerRecoveryCheckID,
        title: String,
        detail: String
    ) -> BeadsTrackerRecoveryCheck {
        BeadsTrackerRecoveryCheck(id: id, title: title, detail: detail, status: .blocked)
    }

    private func recoveryFailure(_ message: String) -> BeadsTrackerRecoveryFailure {
        BeadsTrackerRecoveryFailure(message: message, backupURL: nil, log: [])
    }

    private static func requireSuccess(_ result: CancellableProcessResult, command: String) throws {
        guard result.terminationStatus == 0 else {
            throw BeadsTrackerRecoveryFailure(
                message: "`\(command)` failed: \(result.output.nilIfBlank ?? "no command output")",
                backupURL: nil,
                log: []
            )
        }
    }

    private static func validatedDatabaseName(_ value: String?) throws -> String {
        guard let value = value?.nilIfBlank,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0") else {
            throw BeadsTrackerRecoveryFailure(
                message: "bd context did not report a safe embedded database name.",
                backupURL: nil,
                log: []
            )
        }
        return value
    }

    private static func integer(named key: String, in json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["rows"] as? [[String: Any]],
              let value = rows.first?[key] else { return nil }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
