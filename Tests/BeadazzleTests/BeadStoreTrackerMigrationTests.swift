import XCTest
@testable import Beadazzle

/// The verbatim refusal `bd` 1.2.1 emits when a read-only open finds an out-of-date
/// database. Parsing is driven off the real text so a wording change fails loudly here
/// rather than silently degrading into the old "cannot find the binary" behavior.
private let realSchemaMismatchOutput = """
Error: failed to open database: schema version mismatch: database is at v53, binary \
expects v65, and the read-only open cannot migrate it; run any bd write command in that \
workspace to migrate, or set BD_IGNORE_SCHEMA_SKEW=1 to read anyway (queries touching \
newer schema may fail)
"""

private let realForwardSchemaMismatchOutput = """
Error: schema version mismatch: database is at v65, binary knows up to v53 \
(12 migrations ahead)
"""

private let testSnapshotLine = """
{"id":"bd-1","title":"One","status":"open","priority":2,"issue_type":"task","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
"""

final class BeadsSchemaSkewTests: XCTestCase {
    func testKnownForwardSkewAutomaticallyRequestsRecoveryReview() throws {
        let projectURL = URL(fileURLWithPath: "/tmp/ForwardSkewProject")
        let skew = BeadsSchemaSkew(databaseVersion: 65, binaryVersion: 53)

        let request = try XCTUnwrap(
            TrackerRecoveryRequest.automatic(
                projectURL: projectURL,
                migrationState: .recoveryAvailable(skew)
            )
        )

        XCTAssertEqual(request.projectURL, projectURL)
    }

    func testRecoveryReviewDoesNotAutomaticallyOpenForUnsafeOrUpwardSkew() {
        let projectURL = URL(fileURLWithPath: "/tmp/OtherSkewProject")

        XCTAssertNil(
            TrackerRecoveryRequest.automatic(
                projectURL: projectURL,
                migrationState: .recoveryBlocked(
                    BeadsSchemaSkew(databaseVersion: 66, binaryVersion: 53),
                    guidance: "Use a compatible binary."
                )
            )
        )
        XCTAssertNil(
            TrackerRecoveryRequest.automatic(
                projectURL: projectURL,
                migrationState: .ready(
                    BeadsSchemaSkew(databaseVersion: 53, binaryVersion: 65)
                )
            )
        )
        XCTAssertNil(
            TrackerRecoveryRequest.automatic(
                projectURL: nil,
                migrationState: .recoveryAvailable(
                    BeadsSchemaSkew(databaseVersion: 65, binaryVersion: 53)
                )
            )
        )
    }

    func testDetectsVersionsFromRealBdReadOnlyRefusal() throws {
        let skew = try XCTUnwrap(BeadsSchemaSkew.detect(in: realSchemaMismatchOutput))
        XCTAssertEqual(skew.databaseVersion, 53)
        XCTAssertEqual(skew.binaryVersion, 65)
        XCTAssertEqual(skew.versionSummary, "Database is at v53; bd expects v65.")
    }

    func testDetectsSkewIgnoredWarning() throws {
        let warning = """
        Warning: schema skew ignored — database (v53) is behind binary (v65) and was \
        opened read-only; some queries may fail
        """
        XCTAssertNotNil(BeadsSchemaSkew.detect(in: warning))
    }

    func testDetectsPinnedForwardSkewWithoutTreatingItAsMigration() throws {
        let skew = try XCTUnwrap(BeadsSchemaSkew.detect(in: realForwardSchemaMismatchOutput))
        XCTAssertEqual(skew.databaseVersion, 65)
        XCTAssertEqual(skew.binaryVersion, 53)
        XCTAssertEqual(skew.direction, .databaseAhead)
        XCTAssertTrue(skew.supportsPinnedV65ToV53Recovery)
        XCTAssertEqual(skew.versionSummary, "Database is at v65; bd supports up to v53.")
    }

    func testDetectsReportedDirectionWhenVersionsAreNotParseable() throws {
        let skew = try XCTUnwrap(BeadsSchemaSkew.detect(
            in: "Warning: database is ahead of binary"
        ))
        XCTAssertEqual(skew.direction, .databaseAhead)
        XCTAssertFalse(skew.supportsPinnedV65ToV53Recovery)
    }

    func testDetectsMismatchWithoutParseableVersions() throws {
        let skew = try XCTUnwrap(BeadsSchemaSkew.detect(in: "Error: schema version mismatch"))
        XCTAssertNil(skew.databaseVersion)
        XCTAssertNil(skew.binaryVersion)
        XCTAssertNil(skew.versionSummary)
    }

    func testIgnoresUnrelatedFailures() {
        XCTAssertNil(BeadsSchemaSkew.detect(in: "Error: executable file not found in $PATH"))
        XCTAssertNil(BeadsSchemaSkew.detect(in: "Timed out waiting for `bd` to finish."))
        XCTAssertNil(BeadsSchemaSkew.detect(in: ""))
    }

    func testClassifiesCommandFailureAndWrappedErrors() throws {
        let failure = BeadError.commandFailed(
            command: "bd --readonly statuses --json",
            output: realSchemaMismatchOutput
        )
        XCTAssertEqual(failure.schemaSkew?.databaseVersion, 53)
        XCTAssertEqual(BeadsSchemaSkew.detect(in: failure as Error)?.binaryVersion, 65)
        XCTAssertNil(BeadError.projectMissingDataSource(URL(fileURLWithPath: "/tmp")).schemaSkew)
        XCTAssertNil(BeadError.trackerSchemaIncompatible(nil).schemaSkew)
        XCTAssertEqual(
            BeadError.trackerSchemaIncompatible(
                BeadsSchemaSkew(databaseVersion: 53, binaryVersion: 65)
            ).schemaSkew?.binaryVersion,
            65
        )
    }

    func testProcessTimeoutCarriesItsOwnDescription() {
        let description = CancellableProcessRunnerError.timedOut.localizedDescription
        XCTAssertEqual(description, "Timed out waiting for the command to finish.")
        XCTAssertFalse(description.contains("error 0"))
    }
}

final class TrackerMigrationHealthCheckTests: XCTestCase {
    func testSchemaSkewDoesNotBlameTheBdExecutable() throws {
        let check = try bdCLICheck(contextError: realSchemaMismatchOutput)
        XCTAssertEqual(check.summary, "This tracker needs a one-time upgrade")
        XCTAssertEqual(check.actionHint, "Upgrade the tracker to continue.")
        XCTAssertEqual(check.detail?.contains("Database is at v53; bd expects v65."), true)
    }

    func testPinnedForwardSkewPointsAtGuidedRecovery() throws {
        let check = try bdCLICheck(contextError: realForwardSchemaMismatchOutput)
        XCTAssertEqual(check.summary, "This tracker needs guided recovery")
        XCTAssertEqual(check.actionHint, "Review the backup-first v65-to-v53 recovery.")
        XCTAssertEqual(check.detail?.contains("Database is at v65; bd supports up to v53."), true)
    }

    func testTimeoutDoesNotSendUserToTheExecutablePicker() throws {
        let check = try bdCLICheck(contextError: "`bd context` failed: Timed out waiting for `bd` to finish.")
        XCTAssertEqual(check.summary, "Cannot run bd for this project")
        XCTAssertEqual(check.actionHint?.contains("Choose a bd executable"), false)
    }

    func testGenuineExecutableFailureStillPointsAtSettings() throws {
        let check = try bdCLICheck(contextError: "executable file not found in $PATH")
        XCTAssertEqual(check.actionHint, "Choose a bd executable in Settings.")
    }

    private func bdCLICheck(contextError: String) throws -> ProjectPreflightHealth.Check {
        let health = ProjectHealthSnapshot(
            loadedAt: Date(),
            context: .unavailable(contextError),
            storageConfig: .unavailable(contextError),
            hooks: .unavailable(contextError),
            backup: .unavailable(contextError),
            snapshotFile: ProjectSnapshotFileStatus.load(
                projectURL: URL(fileURLWithPath: "/tmp/project"),
                beadsDirectoryURL: nil,
                activeDataSource: nil
            )
        )
        let preflight = ProjectPreflightHealth.evaluate(
            projectURL: URL(fileURLWithPath: "/tmp/project"),
            missingDataSourceURL: nil,
            activeDataSource: nil,
            snapshotFreshness: .unknown,
            health: health,
            automaticallyRefreshesExternalChanges: true,
            isLoading: false
        )
        return try XCTUnwrap(preflight.checks.first { $0.id == .bdCLI })
    }
}

@MainActor
final class BeadStoreTrackerMigrationTests: XCTestCase {
    func testRunningRecoveryKeepsTheStoreBoundToItsTracker() throws {
        let originalProjectURL = try makeProject(named: "RecoveryOriginal")
        let replacementProjectURL = try makeProject(named: "RecoveryReplacement")
        let store = BeadStore(userDefaults: makeUserDefaults())
        store.openProject(originalProjectURL)
        store._trackerRecovery = .running(BeadsTrackerRecoveryProgress(
            phase: .repairingSchemaCursor,
            log: ["Repairing"]
        ))

        store.openProject(replacementProjectURL)
        XCTAssertEqual(store.projectURL, originalProjectURL.standardizedFileURL)

        store.closeProject()
        XCTAssertEqual(store.projectURL, originalProjectURL.standardizedFileURL)
    }

    func testOptInLiveForwardSkewProjectKeepsRecoveryStateAfterCachedFirstPaint() async throws {
        guard let path = ProcessInfo.processInfo.environment["BEADAZZLE_LIVE_SCHEMA_SKEW_PROJECT"] else {
            throw XCTSkip("Set BEADAZZLE_LIVE_SCHEMA_SKEW_PROJECT to exercise a real skewed tracker.")
        }
        let projectURL = URL(fileURLWithPath: path).standardizedFileURL
        let isolatedDefaults = makeUserDefaults()
        let standardRepository = BeadSemanticDefinitionsRepository(userDefaults: .standard)
        if let cached = standardRepository.load(projectURL: projectURL) {
            BeadSemanticDefinitionsRepository(userDefaults: isolatedDefaults).save(
                cached.entry.definitions,
                projectURL: projectURL,
                trackerDirectoryURL: cached.trackerDirectoryURL,
                refreshedAt: cached.entry.refreshedAt
            )
        }
        let store = BeadStore(
            userDefaults: isolatedDefaults,
            commands: BeadsCommandService()
        )

        store.openProject(projectURL)
        try await waitUntil(timeout: .seconds(15)) {
            !store.isLoading && store.hasReadableProject
        }
        try await waitUntil(timeout: .seconds(15)) {
            if case .recoveryAvailable = store.trackerMigration { return true }
            return false
        }

        XCTAssertTrue(store.hasReadableProject)
        XCTAssertTrue(store.trackerMigration.canReviewRecovery)
    }

    func testReadableSnapshotForwardSkewOffersRecoveryAndNeverRunsBdMigrate() async throws {
        let projectURL = try makeProject(named: "ReadableForwardSkew")
        let commands = SchemaSkewTestCommands(
            schemaMismatchOutput: realForwardSchemaMismatchOutput
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)

        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        try await waitUntil {
            if case .recoveryAvailable = store.trackerMigration { return true }
            return false
        }

        XCTAssertTrue(store.projectReadiness.isReady)
        XCTAssertNotNil(store.issue(with: "bd-1"))
        XCTAssertTrue(store.trackerMigration.isPending)
        let migrateCalls = await commands.migrateCallCount()
        XCTAssertEqual(migrateCalls, 0)
    }

    func testInitialForwardSkewRoutesToRecoveryAndNeverRunsBdMigrate() async throws {
        let projectURL = try makeProject(named: "ForwardSkew")
        let commands = SchemaSkewTestCommands(
            contextError: BeadError.commandFailed(
                command: "bd context --json",
                output: realForwardSchemaMismatchOutput
            )
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)

        store.openProject(projectURL)
        try await waitUntil {
            if case .recoveryAvailable = store.trackerMigration { return true }
            return false
        }

        guard case .recoveryAvailable(let skew) = store.trackerMigration else {
            return XCTFail("Expected pinned recovery instead of an upward migration")
        }
        XCTAssertEqual(skew.direction, .databaseAhead)
        XCTAssertEqual(store.projectReadiness.unavailableProject?.url, projectURL.standardizedFileURL)
        store.startTrackerMigration(confirmedByUser: true)
        try await Task.sleep(for: .milliseconds(50))
        let migrateCalls = await commands.migrateCallCount()
        XCTAssertEqual(migrateCalls, 0)
    }

    func testUnrecognizedForwardSkewStaysReadOnlyWithoutMigration() async throws {
        let commands = SchemaSkewTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        let skew = BeadsSchemaSkew(databaseVersion: 66, binaryVersion: 53)

        store.noteTrackerSchemaSkew(skew)
        guard case .recoveryBlocked(let blockedSkew, let guidance) = store.trackerMigration else {
            return XCTFail("Expected unsupported forward skew to remain blocked")
        }
        XCTAssertEqual(blockedSkew, skew)
        XCTAssertTrue(guidance.contains("compatible tested bd binary"))
        store.startTrackerMigration(confirmedByUser: true)
        try await Task.sleep(for: .milliseconds(50))
        let migrateCalls = await commands.migrateCallCount()
        XCTAssertEqual(migrateCalls, 0)
    }

    func testUnparseableSkewStaysReadOnlyWithoutMigration() async throws {
        let commands = SchemaSkewTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)

        store.noteTrackerSchemaSkew(BeadsSchemaSkew())
        guard case .recoveryBlocked(let skew, let guidance) = store.trackerMigration else {
            return XCTFail("Expected unparseable skew to remain blocked")
        }
        XCTAssertEqual(skew.direction, .unknown)
        XCTAssertTrue(guidance.contains("could not prove the mismatch direction"))
        store.startTrackerMigration(confirmedByUser: true)
        try await Task.sleep(for: .milliseconds(50))
        let migrateCalls = await commands.migrateCallCount()
        XCTAssertEqual(migrateCalls, 0)
    }

    func testLocalTrackerWithoutRemoteMigratesWithoutAsking() async throws {
        let projectURL = try makeProject(named: "LocalSkew")
        let commands = SchemaSkewTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)

        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        try await waitUntil { await commands.migrateCallCount() == 1 }

        // Nothing is shared, so upgrading cannot fork a schema out from under anyone.
        let allowedRemote = await commands.lastMigrateAllowedRemote()
        XCTAssertEqual(allowedRemote, false)
        try await waitUntil { store.trackerMigration == .notNeeded }
    }

    func testRemoteBackedTrackerWaitsForConfirmationBeforeMigrating() async throws {
        let projectURL = try makeProject(named: "RemoteSkew")
        let commands = SchemaSkewTestCommands(remoteNames: ["origin"])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)

        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        // The hold arrives before the remote list does, so it is first recorded against an
        // unknown remote state. Wait for the settled reason rather than the first hold, or
        // this races the remote load and reads whichever won on the day.
        try await waitUntil {
            if case .awaitingConfirmation(_, .remoteBackedTracker) = store.trackerMigration {
                return true
            }
            return false
        }

        // bd refuses remote-backed migrations in place, so Beadazzle must not start one.
        let callsBeforeConfirmation = await commands.migrateCallCount()
        XCTAssertEqual(callsBeforeConfirmation, 0)
        guard case .awaitingConfirmation(let skew, let reason) = store.trackerMigration else {
            return XCTFail("Expected the upgrade to await confirmation")
        }
        XCTAssertEqual(skew.databaseVersion, 53)
        XCTAssertEqual(reason, .remoteBackedTracker)

        store.startTrackerMigration(confirmedByUser: true)
        try await waitUntil { await commands.migrateCallCount() == 1 }
        // Confirmation is what unlocks `--force`.
        let allowedRemote = await commands.lastMigrateAllowedRemote()
        XCTAssertEqual(allowedRemote, true)
    }

    /// A slow remote list is the ordinary case, and it decides which explanation the user
    /// reads. Holding under "could not check" is right until the list answers; leaving that
    /// there afterwards would tell someone with a remote-backed tracker to continue if it
    /// is local, which is the one mistake `bd` cannot undo.
    func testHoldRecordedBeforeRemotesLoadNamesTheRealReasonOnceTheyDo() async throws {
        let projectURL = try makeProject(named: "LateRemotes")
        let commands = SchemaSkewTestCommands(
            remoteNames: ["origin"],
            remoteLoadDelay: .milliseconds(250)
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)

        store.openProject(projectURL)
        try await waitUntil {
            if case .awaitingConfirmation(_, .unverifiedRemoteState) = store.trackerMigration {
                return true
            }
            return false
        }
        try await waitUntil {
            if case .awaitingConfirmation(_, .remoteBackedTracker) = store.trackerMigration {
                return true
            }
            return false
        }

        // Refining the explanation must not quietly start the upgrade it is still holding.
        let migrateCalls = await commands.migrateCallCount()
        XCTAssertEqual(migrateCalls, 0)
    }

    /// The remote list is normally still loading when the first failing read reports the
    /// skew. Migrating on that unknown would be the one unrecoverable mistake here, so
    /// an unknown remote list must hold the upgrade rather than start it.
    func testUnknownRemoteListNeverMigratesWithoutAsking() async throws {
        let projectURL = try makeProject(named: "UnknownRemotes")
        let commands = SchemaSkewTestCommands(remoteLoadDelay: .seconds(30))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)

        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        try await waitUntil { store.trackerMigration.isPending }

        guard case .awaitingConfirmation(_, let reason) = store.trackerMigration else {
            return XCTFail("Expected the upgrade to wait while the remote list is unknown")
        }
        // Reported as unverified rather than remote-backed: claiming a remote exists when
        // that was never checked would be wrong, and both hold the upgrade either way.
        XCTAssertEqual(reason, .unverifiedRemoteState)
        let migrateCalls = await commands.migrateCallCount()
        XCTAssertEqual(migrateCalls, 0)
    }

    func testPendingMigrationBlocksWritesAndStillShowsSnapshot() async throws {
        let projectURL = try makeProject(named: "BlockedWrites")
        let commands = SchemaSkewTestCommands(remoteNames: ["origin"])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)

        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        try await waitUntil { store.trackerMigration.isPending }

        // The snapshot is a plain file, so the project stays browsable meanwhile.
        XCTAssertNotNil(store.issue(with: "bd-1"))
        XCTAssertTrue(store.trackerMigration.blocksWrites)

        do {
            _ = try await store.enqueueMutationWrite { "unexpected" }
            XCTFail("Expected the write to be refused while the upgrade is pending")
        } catch BeadError.trackerSchemaIncompatible {
            // Refused before any `bd` subprocess ran.
        }
    }

    func testMigrationFailureIsReportedAndRetryable() async throws {
        let projectURL = try makeProject(named: "FailedMigration")
        let commands = SchemaSkewTestCommands(
            migrateError: BeadError.commandFailed(
                command: "bd migrate",
                output: "Error: refusing to migrate remote-backed database; use --force if you are the single designated migrator"
            )
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)

        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        try await waitUntil {
            if case .failed = store.trackerMigration { return true }
            return false
        }

        guard case .failed(_, let requiresDesignatedMigrator) = store.trackerMigration else {
            return XCTFail("Expected a failed upgrade")
        }
        XCTAssertTrue(requiresDesignatedMigrator)
        // A repeated failing read must not clobber the failure the user has not seen yet.
        store.noteTrackerSchemaSkew(BeadsSchemaSkew(databaseVersion: 53, binaryVersion: 65))
        if case .failed = store.trackerMigration {} else {
            XCTFail("Expected the failure to persist")
        }
    }

    /// A tracker with no snapshot cannot fall back to stale data, so the failing export
    /// is all there is to go on. The blocked project must still name the upgrade as the
    /// cause and offer it, rather than reporting the raw export timeout.
    func testProjectWithNoSnapshotReportsTheUpgradeInsteadOfTheExportFailure() async throws {
        let projectURL = try makeProject(named: "NoSnapshot", writesSnapshot: false)
        let commands = SchemaSkewTestCommands(
            exportError: BeadError.commandFailed(
                command: "bd export",
                output: "Timed out waiting for `bd` to finish."
            )
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)

        store.openProject(projectURL)
        try await waitUntil { store.trackerMigration.isPending }

        let unavailable = try XCTUnwrap(store.projectReadiness.unavailableProject)
        XCTAssertTrue(unavailable.detail.contains("one-time upgrade"))
        XCTAssertTrue(unavailable.detail.contains("Database is at v53"))
        // Nothing confirmed the remote state, so this stays an explicit choice.
        guard case .awaitingConfirmation(_, let reason) = store.trackerMigration else {
            return XCTFail("Expected the blocked project to offer an explicit upgrade")
        }
        XCTAssertEqual(reason, .unverifiedRemoteState)
        let migrateCalls = await commands.migrateCallCount()
        XCTAssertEqual(migrateCalls, 0)
    }

    func testConfirmingUpgradeOnBlockedProjectMigratesAndReopensIt() async throws {
        let projectURL = try makeProject(named: "NoSnapshotRecovery", writesSnapshot: false)
        let commands = SchemaSkewTestCommands(
            exportError: BeadError.commandFailed(
                command: "bd export",
                output: "Timed out waiting for `bd` to finish."
            ),
            writesSnapshotOnExportAfterMigration: true
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)

        store.openProject(projectURL)
        try await waitUntil { store.trackerMigration.isPending }

        store.startTrackerMigration(confirmedByUser: true)
        try await waitUntil { await commands.migrateCallCount() == 1 }
        // The upgrade retries the open, so the project recovers without user action.
        try await waitUntil { store.issue(with: "bd-1") != nil }
        XCTAssertEqual(store.trackerMigration, .notNeeded)
    }

    private func makeProject(named name: String, writesSnapshot: Bool = true) throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadStoreTrackerMigrationTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        if writesSnapshot {
            try testSnapshotLine.write(
                to: beadsURL.appendingPathComponent("issues.jsonl"),
                atomically: true,
                encoding: .utf8
            )
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: projectURL) }
        return projectURL
    }


    private func makeUserDefaults() -> UserDefaults {
        makeIsolatedUserDefaults()
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition")
    }
}

/// Reproduces an unmigrated tracker: every `bd --readonly` read fails with the schema
/// mismatch, exactly as `bd` 1.2.1 behaves against a v53 database.
private actor SchemaSkewTestCommands: BeadsCommanding {
    private let remoteNames: [String]
    private let migrateError: Error?
    private let remoteLoadDelay: Duration?
    private let exportError: Error?
    private let writesSnapshotOnExportAfterMigration: Bool
    private let contextError: Error?
    private let schemaMismatchOutput: String
    private var migrateCalls = 0
    private var lastAllowedRemoteMigration: Bool?
    private var hasMigrated = false

    init(
        remoteNames: [String] = [],
        migrateError: Error? = nil,
        remoteLoadDelay: Duration? = nil,
        exportError: Error? = nil,
        writesSnapshotOnExportAfterMigration: Bool = false,
        contextError: Error? = nil,
        schemaMismatchOutput: String = realSchemaMismatchOutput
    ) {
        self.remoteNames = remoteNames
        self.migrateError = migrateError
        self.remoteLoadDelay = remoteLoadDelay
        self.exportError = exportError
        self.writesSnapshotOnExportAfterMigration = writesSnapshotOnExportAfterMigration
        self.contextError = contextError
        self.schemaMismatchOutput = schemaMismatchOutput
    }

    func migrateCallCount() -> Int { migrateCalls }
    func lastMigrateAllowedRemote() -> Bool? { lastAllowedRemoteMigration }

    private var schemaMismatch: Error {
        BeadError.commandFailed(
            command: "bd --readonly statuses --json",
            output: schemaMismatchOutput
        )
    }

    func migrateTrackerSchema(projectURL: URL, allowsRemoteMigration: Bool) async throws {
        migrateCalls += 1
        lastAllowedRemoteMigration = allowsRemoteMigration
        if let migrateError { throw migrateError }
        hasMigrated = true
    }

    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition] {
        guard hasMigrated else { throw schemaMismatch }
        return []
    }

    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] {
        guard hasMigrated else { throw schemaMismatch }
        return []
    }

    func loadDoltRemotes(projectURL: URL) async throws -> BeadsDoltRemotes {
        if let remoteLoadDelay {
            try await Task.sleep(for: remoteLoadDelay)
        }
        return BeadsDoltRemotes(remotes: remoteNames.map {
            BeadsDoltRemote(name: $0, url: "https://example.com/team/beads.git")
        })
    }

    func loadProjectContext(projectURL: URL) async throws -> BeadsProjectContext {
        if let contextError { throw contextError }
        return .testContext(projectURL: projectURL)
    }

    /// Mirrors `bd export`: it opens the database for writing, so once the tracker has
    /// been migrated it succeeds and produces the snapshot.
    func exportReadableSnapshot(projectURL: URL) async throws {
        if let exportError, !hasMigrated {
            throw exportError
        }
        guard writesSnapshotOnExportAfterMigration, hasMigrated else { return }
        try testSnapshotLine.write(
            to: projectURL
                .appendingPathComponent(".beads", isDirectory: true)
                .appendingPathComponent("issues.jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }
    func create(projectURL: URL, draft: IssueDraft) async throws -> String { "bd-created" }
    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws {}
    func updateMetadata(
        projectURL: URL,
        issueID: String,
        assignee: String?,
        labels: [String]?,
        originalLabels: [String]?,
        dueAt: IssueMetadataDateUpdate,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {}
    func close(projectURL: URL, ids: [String], reason: String?) async throws {}
    func delete(projectURL: URL, ids: [String]) async throws {}
    func bulkUpdate(
        projectURL: URL,
        ids: [String],
        status: String?,
        type: String?,
        priority: Int?,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {}
    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {}
    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {}
    func addComment(projectURL: URL, issueID: String, text: String) async throws {}
    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws {}
    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws {}
}
