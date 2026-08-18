import XCTest
@testable import Beadazzle

final class BeadsTrackerRecoveryServiceTests: XCTestCase {
    func testSuccessfulRecoveryStagesDoltIgnoreAndNeverPullsOrPushes() async throws {
        let runner = RecoveryTestProcessRunner()
        let fileSystem = RecoveryTestFileSystem()
        let service = makeService(runner: runner, fileSystem: fileSystem)
        let assessment = await service.diagnose(
            projectURL: Self.projectURL,
            skew: Self.pinnedSkew,
            activity: .idle
        )

        XCTAssertTrue(assessment.canRecover)
        let result = try await service.recover(
            assessment: assessment,
            activity: .idle,
            progress: { _ in }
        )

        let commands = await runner.recordedCommands()
        let eventsRepair = try XCTUnwrap(commands.first { $0.purpose == .eventsTrackingRepair })
        XCTAssertTrue(eventsRepair.arguments.joined(separator: " ").contains("DOLT_ADD('dolt_ignore')"))
        XCTAssertFalse(commands.flatMap(\.arguments).contains("pull"))
        XCTAssertFalse(commands.flatMap(\.arguments).contains("push"))
        XCTAssertTrue(BeadsTrackerRecoveryResult.publicationGuidance.contains("Do not pull first"))
        XCTAssertEqual(result.backupURL, assessment.plan?.backupURL)
        let backupValidationCount = await fileSystem.backupValidationCount()
        XCTAssertEqual(backupValidationCount, 1)
    }

    func testBackupFailureStopsBeforeAnyTrackerRepair() async throws {
        let runner = RecoveryTestProcessRunner(failingStatusPurpose: .backup)
        let fileSystem = RecoveryTestFileSystem()
        let service = makeService(runner: runner, fileSystem: fileSystem)
        let assessment = await service.diagnose(
            projectURL: Self.projectURL,
            skew: Self.pinnedSkew,
            activity: .idle
        )

        do {
            _ = try await service.recover(
                assessment: assessment,
                activity: .idle,
                progress: { _ in }
            )
            XCTFail("Expected the failed backup to stop recovery")
        } catch let failure as BeadsTrackerRecoveryFailure {
            XCTAssertTrue(failure.message.contains("backup copy"))
        }

        let purposes = await runner.recordedCommands().map(\.purpose)
        XCTAssertFalse(purposes.contains(.schemaCursorRepair))
        XCTAssertFalse(purposes.contains(.eventsTrackingRepair))
        let backupValidationCount = await fileSystem.backupValidationCount()
        XCTAssertEqual(backupValidationCount, 0)
    }

    func testPreflightFailureDoesNotCreateBackupOrRunRepair() async {
        let runner = RecoveryTestProcessRunner()
        let fileSystem = RecoveryTestFileSystem(inspectError: RecoveryTestError.noSpace)
        let service = makeService(runner: runner, fileSystem: fileSystem)

        let assessment = await service.diagnose(
            projectURL: Self.projectURL,
            skew: Self.pinnedSkew,
            activity: .idle
        )

        XCTAssertFalse(assessment.canRecover)
        XCTAssertNil(assessment.plan)
        XCTAssertEqual(assessment.blockingMessage, RecoveryTestError.noSpace.localizedDescription)
        let purposes = await runner.recordedCommands().map(\.purpose)
        XCTAssertEqual(purposes, [.bdVersion, .context, .doltVersion, .schemaPreflight])
        let preparedBackupCount = await fileSystem.preparedBackupCount()
        XCTAssertEqual(preparedBackupCount, 0)
    }

    func testPostconditionFailureKeepsTrackerInRecoveryFailure() async throws {
        let runner = RecoveryTestProcessRunner(ignoredEventCount: 1)
        let fileSystem = RecoveryTestFileSystem()
        let service = makeService(runner: runner, fileSystem: fileSystem)
        let assessment = await service.diagnose(
            projectURL: Self.projectURL,
            skew: Self.pinnedSkew,
            activity: .idle
        )

        do {
            _ = try await service.recover(
                assessment: assessment,
                activity: .idle,
                progress: { _ in }
            )
            XCTFail("Expected post-recovery validation to fail")
        } catch let failure as BeadsTrackerRecoveryFailure {
            XCTAssertTrue(failure.message.contains("events table is still ignored"))
            XCTAssertNotNil(failure.backupURL)
        }

        let purposes = await runner.recordedCommands().map(\.purpose)
        XCTAssertFalse(purposes.contains(.bdContextValidation))
        XCTAssertFalse(purposes.contains(.bdListValidation))
    }

    func testInterruptedRepairStopsBeforeLaterWrites() async throws {
        let runner = RecoveryTestProcessRunner(cancellingPurpose: .schemaCursorRepair)
        let fileSystem = RecoveryTestFileSystem()
        let service = makeService(runner: runner, fileSystem: fileSystem)
        let assessment = await service.diagnose(
            projectURL: Self.projectURL,
            skew: Self.pinnedSkew,
            activity: .idle
        )

        do {
            _ = try await service.recover(
                assessment: assessment,
                activity: .idle,
                progress: { _ in }
            )
            XCTFail("Expected interruption to stop recovery")
        } catch let failure as BeadsTrackerRecoveryFailure {
            XCTAssertTrue(failure.message.contains("was stopped"))
            XCTAssertNotNil(failure.backupURL)
        }

        let purposes = await runner.recordedCommands().map(\.purpose)
        XCTAssertFalse(purposes.contains(.eventsTrackingRepair))
        XCTAssertFalse(purposes.contains(.schemaValidation))
    }

    func testUserCancellationLetsCurrentDoltRepairFinishBeforeStopping() async throws {
        let runner = PausingRecoveryTestProcessRunner()
        let fileSystem = RecoveryTestFileSystem()
        let service = makeService(runner: runner, fileSystem: fileSystem)
        let assessment = await service.diagnose(
            projectURL: Self.projectURL,
            skew: Self.pinnedSkew,
            activity: .idle
        )
        let recovery = Task {
            try await service.recover(
                assessment: assessment,
                activity: .idle,
                progress: { _ in }
            )
        }

        await runner.waitUntilSchemaRepairStarts()
        recovery.cancel()
        try await Task.sleep(for: .milliseconds(50))
        let repairObservedCancellation = await runner.schemaRepairObservedCancellation()
        XCTAssertFalse(repairObservedCancellation)
        await runner.finishSchemaRepair()

        do {
            _ = try await recovery.value
            XCTFail("Expected recovery to stop between repair phases")
        } catch let failure as BeadsTrackerRecoveryFailure {
            XCTAssertTrue(failure.message.contains("was stopped"))
            XCTAssertNotNil(failure.backupURL)
        }
        let purposes = await runner.recordedCommands().map(\.purpose)
        XCTAssertTrue(purposes.contains(.schemaCursorRepair))
        XCTAssertFalse(purposes.contains(.eventsTrackingRepair))
    }

    func testZeroExitContextErrorEnvelopeFailsPostRecoveryValidation() async throws {
        try await assertZeroExitErrorEnvelopeFailsPostValidation(at: .bdContextValidation)
    }

    func testZeroExitListErrorEnvelopeFailsPostRecoveryValidation() async throws {
        try await assertZeroExitErrorEnvelopeFailsPostValidation(at: .bdListValidation)
    }

    func testUnsupportedForwardSkewPerformsNoCommandOrFileSystemWork() async {
        let runner = RecoveryTestProcessRunner()
        let fileSystem = RecoveryTestFileSystem()
        let service = makeService(runner: runner, fileSystem: fileSystem)

        let assessment = await service.diagnose(
            projectURL: Self.projectURL,
            skew: BeadsSchemaSkew(databaseVersion: 66, binaryVersion: 53),
            activity: .idle
        )

        XCTAssertFalse(assessment.canRecover)
        let commands = await runner.recordedCommands()
        let inspectionCount = await fileSystem.inspectionCount()
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(inspectionCount, 0)
    }

    func testDatabaseThatNoLongerHasCursor65IsBlockedBeforeBackupOrRepair() async {
        let runner = RecoveryTestProcessRunner(preflightCursor: 66)
        let fileSystem = RecoveryTestFileSystem()
        let service = makeService(runner: runner, fileSystem: fileSystem)

        let assessment = await service.diagnose(
            projectURL: Self.projectURL,
            skew: Self.pinnedSkew,
            activity: .idle
        )

        XCTAssertFalse(assessment.canRecover)
        XCTAssertTrue(assessment.blockingMessage?.contains("schema cursor v66") == true)
        let purposes = await runner.recordedCommands().map(\.purpose)
        XCTAssertFalse(purposes.contains(.backup))
        XCTAssertFalse(purposes.contains(.schemaCursorRepair))
        XCTAssertFalse(purposes.contains(.eventsTrackingRepair))
        let preparedBackupCount = await fileSystem.preparedBackupCount()
        XCTAssertEqual(preparedBackupCount, 0)
    }

    func testSystemBackupValidationDetectsSameSizeContentCorruption() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BeadsTrackerRecoveryFileSystemTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let projectURL = rootURL.appendingPathComponent("project", isDirectory: true)
        let sourceURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        let databaseURL = sourceURL
            .appendingPathComponent("embeddeddolt", isDirectory: true)
            .appendingPathComponent("beadazzle", isDirectory: true)
        let backupURL = rootURL
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: sourceURL.appendingPathComponent("config.yaml"))
        try Data("database".utf8).write(to: databaseURL.appendingPathComponent("manifest"))
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileSystem = SystemBeadsTrackerRecoveryFileSystem()
        _ = try await fileSystem.inspectBackup(
            sourceURL: sourceURL,
            databaseDirectoryURL: databaseURL,
            projectURL: projectURL,
            backupURL: backupURL
        )
        let fingerprint = try await fileSystem.fingerprintTracker(
            sourceURL: sourceURL,
            databaseDirectoryURL: databaseURL,
            projectURL: projectURL
        )
        try await fileSystem.prepareBackupParent(for: backupURL)
        try FileManager.default.copyItem(at: sourceURL, to: backupURL)
        try await fileSystem.validateBackup(
            sourceURL: sourceURL,
            backupURL: backupURL,
            databaseName: "beadazzle",
            expectedFingerprint: fingerprint
        )

        // Preserve the count and byte length so only the content digest catches this.
        try Data("omega".utf8).write(to: backupURL.appendingPathComponent("config.yaml"))
        do {
            try await fileSystem.validateBackup(
                sourceURL: sourceURL,
                backupURL: backupURL,
                databaseName: "beadazzle",
                expectedFingerprint: fingerprint
            )
            XCTFail("Expected corrupt backup contents to fail verification")
        } catch let failure as BeadsTrackerRecoveryFailure {
            XCTAssertTrue(failure.message.contains("did not match"))
        }
    }

    func testSystemBackupInspectionRejectsDestinationInsideProject() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BeadsTrackerRecoveryLocationTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let projectURL = rootURL.appendingPathComponent("project", isDirectory: true)
        let sourceURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        let databaseURL = sourceURL
            .appendingPathComponent("embeddeddolt", isDirectory: true)
            .appendingPathComponent("beadazzle", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        try Data("database".utf8).write(to: databaseURL.appendingPathComponent("manifest"))
        defer { try? FileManager.default.removeItem(at: rootURL) }

        do {
            _ = try await SystemBeadsTrackerRecoveryFileSystem().inspectBackup(
                sourceURL: sourceURL,
                databaseDirectoryURL: databaseURL,
                projectURL: projectURL,
                backupURL: projectURL.appendingPathComponent("unsafe-backup", isDirectory: true)
            )
            XCTFail("Expected an in-repository backup path to be rejected")
        } catch let failure as BeadsTrackerRecoveryFailure {
            XCTAssertTrue(failure.message.contains("outside the project repository"))
        }
    }

    private static let projectURL = URL(fileURLWithPath: "/tmp/BeadsTrackerRecoveryTests/project")
    private static let pinnedSkew = BeadsSchemaSkew(databaseVersion: 65, binaryVersion: 53)

    private func assertZeroExitErrorEnvelopeFailsPostValidation(
        at purpose: BeadsTrackerRecoveryCommand.Purpose
    ) async throws {
        let runner = RecoveryTestProcessRunner(errorEnvelopePurpose: purpose)
        let fileSystem = RecoveryTestFileSystem()
        let service = makeService(runner: runner, fileSystem: fileSystem)
        let assessment = await service.diagnose(
            projectURL: Self.projectURL,
            skew: Self.pinnedSkew,
            activity: .idle
        )

        do {
            _ = try await service.recover(
                assessment: assessment,
                activity: .idle,
                progress: { _ in }
            )
            XCTFail("Expected the zero-exit JSON error envelope to fail validation")
        } catch let failure as BeadsTrackerRecoveryFailure {
            XCTAssertTrue(failure.message.contains("schema version mismatch"))
            XCTAssertNotNil(failure.backupURL)
        }
    }

    private func makeService(
        runner: any BeadsTrackerRecoveryProcessRunning,
        fileSystem: any BeadsTrackerRecoveryFileSystem
    ) -> BeadsTrackerRecoveryService {
        BeadsTrackerRecoveryService(
            processRunner: runner,
            fileSystem: fileSystem,
            bdExecutable: {
                (url: URL(fileURLWithPath: "/opt/homebrew/bin/bd"), prefix: [])
            },
            backupRoot: {
                URL(fileURLWithPath: "/tmp/BeadsTrackerRecoveryTests/backups", isDirectory: true)
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            uniqueID: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
        )
    }
}

private enum RecoveryTestError: LocalizedError {
    case noSpace

    var errorDescription: String? { "Not enough test backup space." }
}

private actor RecoveryTestProcessRunner: BeadsTrackerRecoveryProcessRunning {
    private var commands: [BeadsTrackerRecoveryCommand] = []
    private let failingStatusPurpose: BeadsTrackerRecoveryCommand.Purpose?
    private let cancellingPurpose: BeadsTrackerRecoveryCommand.Purpose?
    private let errorEnvelopePurpose: BeadsTrackerRecoveryCommand.Purpose?
    private let ignoredEventCount: Int
    private let preflightCursor: Int

    init(
        failingStatusPurpose: BeadsTrackerRecoveryCommand.Purpose? = nil,
        cancellingPurpose: BeadsTrackerRecoveryCommand.Purpose? = nil,
        errorEnvelopePurpose: BeadsTrackerRecoveryCommand.Purpose? = nil,
        ignoredEventCount: Int = 0,
        preflightCursor: Int = 65
    ) {
        self.failingStatusPurpose = failingStatusPurpose
        self.cancellingPurpose = cancellingPurpose
        self.errorEnvelopePurpose = errorEnvelopePurpose
        self.ignoredEventCount = ignoredEventCount
        self.preflightCursor = preflightCursor
    }

    func recordedCommands() -> [BeadsTrackerRecoveryCommand] { commands }

    func run(_ command: BeadsTrackerRecoveryCommand) async throws -> CancellableProcessResult {
        commands.append(command)
        if command.purpose == cancellingPurpose { throw CancellationError() }
        if command.purpose == errorEnvelopePurpose {
            return result(output: #"{"error":"schema version mismatch after recovery"}"#)
        }
        if command.purpose == failingStatusPurpose {
            return result(status: 1, output: "simulated failure")
        }
        switch command.purpose {
        case .bdVersion:
            return result(output: "bd version 1.2.2\n")
        case .context, .bdContextValidation:
            return result(output: Self.contextJSON)
        case .doltVersion:
            return result(output: "dolt version 2.3.0\n")
        case .schemaPreflight:
            return result(output: "{\"rows\":[{\"version\":\(preflightCursor)}]}")
        case .schemaValidation:
            return result(output: #"{"rows":[{"version":53}]}"#)
        case .ignoreValidation:
            return result(output: "{\"rows\":[{\"ignored\":\(ignoredEventCount)}]}")
        case .workingStateValidation:
            return result(output: #"{"rows":[{"changes":0}]}"#)
        case .tableValidation:
            return result(output: "Tables in working set:\n\tevents\n")
        case .bdListValidation:
            return result(output: "[]")
        case .backup, .schemaCursorRepair, .eventsTrackingRepair:
            return result()
        }
    }

    private func result(status: Int32 = 0, output: String = "") -> CancellableProcessResult {
        CancellableProcessResult(
            terminationStatus: status,
            output: output,
            outputWasTruncated: false
        )
    }

    private static let contextJSON = #"{"backend":"dolt","bd_version":"1.2.2","beads_dir":"/tmp/BeadsTrackerRecoveryTests/project/.beads","cwd_repo_root":"/tmp/BeadsTrackerRecoveryTests/project","database":"beadazzle","dolt_mode":"embedded","is_redirected":false,"is_worktree":false,"project_id":"test","repo_root":"/tmp/BeadsTrackerRecoveryTests/project","role":"maintainer","schema_version":65}"#
}

private actor PausingRecoveryTestProcessRunner: BeadsTrackerRecoveryProcessRunning {
    private var commands: [BeadsTrackerRecoveryCommand] = []
    private var schemaRepairContinuation: CheckedContinuation<Void, Never>?
    private var schemaRepairStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var schemaRepairStarted = false
    private var schemaRepairWasCancelled = false

    func recordedCommands() -> [BeadsTrackerRecoveryCommand] { commands }

    func waitUntilSchemaRepairStarts() async {
        guard !schemaRepairStarted else { return }
        await withCheckedContinuation { continuation in
            schemaRepairStartWaiters.append(continuation)
        }
    }

    func finishSchemaRepair() {
        schemaRepairContinuation?.resume()
        schemaRepairContinuation = nil
    }

    func schemaRepairObservedCancellation() -> Bool { schemaRepairWasCancelled }

    func run(_ command: BeadsTrackerRecoveryCommand) async throws -> CancellableProcessResult {
        commands.append(command)
        if command.purpose == .schemaCursorRepair {
            schemaRepairStarted = true
            let waiters = schemaRepairStartWaiters
            schemaRepairStartWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    schemaRepairContinuation = continuation
                }
            } onCancel: {
                Task { await self.cancelSchemaRepair() }
            }
            if schemaRepairWasCancelled { throw CancellationError() }
        }
        return result(for: command.purpose)
    }

    private func cancelSchemaRepair() {
        schemaRepairWasCancelled = true
        finishSchemaRepair()
    }

    private func result(
        for purpose: BeadsTrackerRecoveryCommand.Purpose
    ) -> CancellableProcessResult {
        let output: String
        switch purpose {
        case .bdVersion:
            output = "bd version 1.2.2\n"
        case .context, .bdContextValidation:
            output = Self.contextJSON
        case .doltVersion:
            output = "dolt version 2.3.0\n"
        case .schemaPreflight:
            output = #"{"rows":[{"version":65}]}"#
        case .schemaValidation:
            output = #"{"rows":[{"version":53}]}"#
        case .ignoreValidation:
            output = #"{"rows":[{"ignored":0}]}"#
        case .workingStateValidation:
            output = #"{"rows":[{"changes":0}]}"#
        case .tableValidation:
            output = "Tables in working set:\n\tevents\n"
        case .bdListValidation:
            output = "[]"
        case .backup, .schemaCursorRepair, .eventsTrackingRepair:
            output = ""
        }
        return CancellableProcessResult(
            terminationStatus: 0,
            output: output,
            outputWasTruncated: false
        )
    }

    private static let contextJSON = #"{"backend":"dolt","bd_version":"1.2.2","beads_dir":"/tmp/BeadsTrackerRecoveryTests/project/.beads","cwd_repo_root":"/tmp/BeadsTrackerRecoveryTests/project","database":"beadazzle","dolt_mode":"embedded","is_redirected":false,"is_worktree":false,"project_id":"test","repo_root":"/tmp/BeadsTrackerRecoveryTests/project","role":"maintainer","schema_version":65}"#
}

private actor RecoveryTestFileSystem: BeadsTrackerRecoveryFileSystem {
    private let inspectError: Error?
    private var inspections = 0
    private var preparedBackups = 0
    private var backupValidations = 0

    init(inspectError: Error? = nil) {
        self.inspectError = inspectError
    }

    func inspectionCount() -> Int { inspections }
    func preparedBackupCount() -> Int { preparedBackups }
    func backupValidationCount() -> Int { backupValidations }

    func inspectBackup(
        sourceURL: URL,
        databaseDirectoryURL: URL,
        projectURL: URL,
        backupURL: URL
    ) async throws -> BeadsTrackerBackupInspection {
        inspections += 1
        if let inspectError { throw inspectError }
        return BeadsTrackerBackupInspection(sourceFileBytes: 4_096)
    }

    func fingerprintTracker(
        sourceURL: URL,
        databaseDirectoryURL: URL,
        projectURL: URL
    ) async throws -> BeadsTrackerBackupFingerprint {
        BeadsTrackerBackupFingerprint(
            regularFileCount: 8,
            directoryCount: 4,
            symbolicLinkCount: 0,
            regularFileBytes: 4_096,
            digest: "test-fingerprint"
        )
    }

    func prepareBackupParent(for backupURL: URL) async throws {
        preparedBackups += 1
    }

    func validateBackup(
        sourceURL: URL,
        backupURL: URL,
        databaseName: String,
        expectedFingerprint: BeadsTrackerBackupFingerprint
    ) async throws {
        backupValidations += 1
    }
}
