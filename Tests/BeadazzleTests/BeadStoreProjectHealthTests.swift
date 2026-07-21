import XCTest
@testable import Beadazzle

@MainActor
final class BeadStoreProjectHealthTests: XCTestCase {
    func testProjectHealthLoadCollectsEmbeddedStorageSnapshotHooksAndBackup() async throws {
        let projectURL = try makeProject(named: "HealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertNil(store.projectHealthTask)
        let health = try XCTUnwrap(store.projectHealthSnapshot)
        XCTAssertTrue(health.context.value?.usesCurrentEmbeddedDolt == true)
        XCTAssertEqual(health.storageConfig.value?.exportAuto, true)
        XCTAssertEqual(health.storageConfig.value?.importAuto, false)
        XCTAssertNil(health.storageConfig.value?.federationRemote)
        XCTAssertEqual(health.doltRemotes.value?.primaryRemote?.name, "origin")
        XCTAssertTrue(health.hooks.value?.hasMissingHooks == true)
        XCTAssertTrue(health.backup.value?.isConfigured == true)
        XCTAssertTrue(health.snapshotFile.exists)
        XCTAssertEqual(health.snapshotFile.activeDataSource?.kind, .jsonl)
    }

    func testProjectHealthLoadKeepsPartialResultsWhenOneDiagnosticFails() async throws {
        let projectURL = try makeProject(named: "PartialHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(storageError: ProjectHealthTestError.failedStorage)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let health = try XCTUnwrap(store.projectHealthSnapshot)
        XCTAssertNotNil(health.context.value)
        XCTAssertNil(health.storageConfig.value)
        XCTAssertNotNil(health.storageConfig.errorMessage)
        XCTAssertEqual(health.doltRemotes.value?.primaryRemote?.name, "origin")
        XCTAssertTrue(health.hooks.value?.hasMissingHooks == true)
        XCTAssertTrue(health.backup.value?.isConfigured == true)
    }

    func testExportSnapshotActionRunsExportAndReloadsHealth() async throws {
        let projectURL = try makeProject(named: "ExportHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let didExport = await store.exportProjectSnapshotNow()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertTrue(didExport)
        let exportCallCount = await commands.exportCallCount
        XCTAssertEqual(exportCallCount, 1)
        XCTAssertNil(store.projectHealthAction)
        XCTAssertNil(store.projectHealthActionError)
    }

    func testInstallHooksActionRunsOnlyWhenHooksAreMissing() async throws {
        let projectURL = try makeProject(named: "HooksHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let didInstall = await store.installProjectHooks()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertTrue(didInstall)
        let installHooksCallCount = await commands.installHooksCallCount
        XCTAssertEqual(installHooksCallCount, 1)
        XCTAssertNil(store.projectHealthAction)
        XCTAssertNil(store.projectHealthActionError)
    }

    func testPullIssuesRunsDoltPullThenExportsAndReloadsProject() async throws {
        let projectURL = try makeProject(named: "PullHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let didPull = await store.pullProjectIssues()
        try await waitUntil { !store.isLoading }
        await store.waitForPendingProjectHealthLoad()

        XCTAssertTrue(didPull)
        let pullCallCount = await commands.pullCallCount
        let exportCallCount = await commands.exportCallCount
        let commandEvents = await commands.commandEvents
        XCTAssertEqual(pullCallCount, 1)
        XCTAssertEqual(exportCallCount, 1)
        XCTAssertEqual(Array(commandEvents.suffix(2)), ["pull", "export"])
        XCTAssertNil(store.projectHealthAction)
        XCTAssertNil(store.projectHealthActionError)
    }

    func testPullSnapshotExportFailureMarksSnapshotStaleAndReportsPartialSuccess() async throws {
        let projectURL = try makeProject(named: "PartialPullHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(exportError: ProjectHealthTestError.failedExport)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let didPull = await store.pullProjectIssues()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertFalse(didPull)
        let commandEvents = await commands.commandEvents
        XCTAssertEqual(Array(commandEvents.suffix(2)), ["pull", "export"])
        XCTAssertEqual(store.snapshotFreshness.state, .possiblyStale)
        XCTAssertEqual(store.projectHealthActionError?.title, "Pull completed, but refresh failed")
        XCTAssertTrue(store.projectHealthActionError?.message.contains("Dolt database was updated") == true)
    }

    func testPushWaitsForEarlierSerializedWrite() async throws {
        let projectURL = try makeProject(named: "QueuedPushHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let blockingWrite = Task {
            try await store.enqueueMutationWrite {
                await commands.runSyntheticWrite(delay: .milliseconds(150))
            }
        }
        while await commands.syntheticWriteStarted == false {
            try await Task.sleep(for: .milliseconds(5))
        }

        let push = Task { await store.pushProjectIssues() }
        try await Task.sleep(for: .milliseconds(30))
        let pushCallCountWhileBlocked = await commands.pushCallCount
        XCTAssertEqual(pushCallCountWhileBlocked, 0)

        try await blockingWrite.value
        let didPush = await push.value
        let commandEvents = await commands.commandEvents
        XCTAssertTrue(didPush)
        XCTAssertEqual(Array(commandEvents.suffix(3)), ["write-start", "write-end", "push"])
    }

    func testPushIssuesRunsDoltPushWithoutReloadingSnapshot() async throws {
        let projectURL = try makeProject(named: "PushHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let didPush = await store.pushProjectIssues()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertTrue(didPush)
        let pushCallCount = await commands.pushCallCount
        let exportCallCount = await commands.exportCallCount
        XCTAssertEqual(pushCallCount, 1)
        XCTAssertEqual(exportCallCount, 0)
        XCTAssertNil(store.projectHealthAction)
        XCTAssertNil(store.projectHealthActionError)
    }

    func testPushFailureSurfacesActionError() async throws {
        let projectURL = try makeProject(named: "FailedPushHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(pushError: ProjectHealthTestError.failedPush)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let didPush = await store.pushProjectIssues()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertFalse(didPush)
        let pushCallCount = await commands.pushCallCount
        XCTAssertEqual(pushCallCount, 1)
        XCTAssertNotNil(store.projectHealthActionError)
    }

    func testPullFailurePreservesCurrentSnapshotAndSurfacesActionError() async throws {
        let projectURL = try makeProject(named: "FailedPullHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(pullError: ProjectHealthTestError.failedPull)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let didPull = await store.pullProjectIssues()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertFalse(didPull)
        let pullCallCount = await commands.pullCallCount
        let exportCallCount = await commands.exportCallCount
        XCTAssertEqual(pullCallCount, 1)
        XCTAssertEqual(exportCallCount, 0)
        XCTAssertNotNil(store.issue(with: "bd-1"))
        XCTAssertNotNil(store.projectHealthActionError)
    }

    func testPullResultIsIgnoredAfterProjectSwitch() async throws {
        let firstProjectURL = try makeProject(named: "SlowPullHealthProject", issueID: "bd-1")
        let secondProjectURL = try makeProject(named: "NextPullHealthProject", issueID: "bd-2")
        let commands = ProjectHealthTestCommands(pullDelay: .milliseconds(150))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let pullTask = Task { await store.pullProjectIssues() }
        try await Task.sleep(for: .milliseconds(30))
        store.openProject(secondProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }

        let pullResult = await pullTask.value
        XCTAssertFalse(pullResult)
        XCTAssertEqual(store.projectURL, secondProjectURL)
        XCTAssertNotNil(store.issue(with: "bd-2"))
        XCTAssertNil(store.issue(with: "bd-1"))
    }

    func testInstallHooksActionDoesNotRunInStealthMode() async throws {
        let projectURL = try makeProject(named: "StealthHooksHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(noGitOperations: true)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let didInstall = await store.installProjectHooks()

        XCTAssertFalse(didInstall)
        let installHooksCallCount = await commands.installHooksCallCount
        XCTAssertEqual(installHooksCallCount, 0)
        XCTAssertEqual(store.projectEnvironment?.gitIntegration, .disabled)
    }

    func testInstallHooksActionDoesNotRunWhenGitIntegrationIsUnknown() async throws {
        let projectURL = try makeProject(named: "UnknownHooksHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(storageError: ProjectHealthTestError.failedStorage)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let didInstall = await store.installProjectHooks()

        XCTAssertFalse(didInstall)
        let installHooksCallCount = await commands.installHooksCallCount
        XCTAssertEqual(installHooksCallCount, 0)
        XCTAssertEqual(store.projectEnvironment?.gitIntegration, .unknown)
    }

    func testBackupActionRunsOnlyWhenBackupIsConfigured() async throws {
        let projectURL = try makeProject(named: "BackupHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let didSync = await store.syncProjectBackup()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertTrue(didSync)
        let syncBackupCallCount = await commands.syncBackupCallCount
        XCTAssertEqual(syncBackupCallCount, 1)
        XCTAssertNil(store.projectHealthAction)
        XCTAssertNil(store.projectHealthActionError)
    }

    func testBackupActionDoesNotRunForHistoricalUnconfiguredBackup() async throws {
        let projectURL = try makeProject(named: "UnconfiguredBackupHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(backupConfigured: false)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertEqual(store.projectHealthSnapshot?.backup.value?.hasBackupHistory, true)
        XCTAssertEqual(store.projectHealthSnapshot?.backup.value?.isConfigured, false)

        let didSync = await store.syncProjectBackup()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertFalse(didSync)
        let syncBackupCallCount = await commands.syncBackupCallCount
        XCTAssertEqual(syncBackupCallCount, 0)
        XCTAssertNil(store.projectHealthAction)
        XCTAssertNil(store.projectHealthActionError)
    }

    func testProjectHealthLoadIgnoresStaleResultAfterProjectSwitch() async throws {
        let firstProjectURL = try makeProject(named: "FirstHealthProject", issueID: "bd-1")
        let secondProjectURL = try makeProject(named: "SecondHealthProject", issueID: "bd-2")
        let commands = ProjectHealthTestCommands(contextDelay: .milliseconds(150))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)

        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        store.openProject(secondProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertEqual(store.projectHealthSnapshot?.context.value?.database, "SecondHealthProject")
    }

    func testProjectHealthRefreshReloadsContextInsteadOfReusingOpenProjectContext() async throws {
        let projectURL = try makeProject(named: "FreshContextHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        await commands.setContextSyncRemote("git+ssh://git@github.com/example/project.git")
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertEqual(
            store.projectHealthSnapshot?.context.value?.syncRemote,
            "git+ssh://git@github.com/example/project.git"
        )
        let contextCallCount = await commands.contextCallCount
        XCTAssertGreaterThanOrEqual(contextCallCount, 2)
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "BeadStoreProjectHealthTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeProject(named name: String, issueID: String) throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        try """
        {"_type":"issue","id":"\(issueID)","title":"Health","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-08T12:00:00Z"}
        """.write(
            to: beadsURL.appendingPathComponent("issues.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL)
        }
        return projectURL
    }

    private func waitUntil(
        timeout: TimeInterval = 3.0,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private actor ProjectHealthTestCommands: BeadsCommanding {
    private let storageError: Error?
    private let exportError: Error?
    private let contextDelay: Duration?
    private let backupConfigured: Bool
    private let noGitOperations: Bool
    private let pullDelay: Duration?
    private let pullError: Error?
    private let pushError: Error?
    private var contextSyncRemote: String?
    private(set) var exportCallCount = 0
    private(set) var contextCallCount = 0
    private(set) var installHooksCallCount = 0
    private(set) var pullCallCount = 0
    private(set) var pushCallCount = 0
    private(set) var syncBackupCallCount = 0
    private(set) var commandEvents: [String] = []
    private(set) var syntheticWriteStarted = false

    init(
        storageError: Error? = nil,
        exportError: Error? = nil,
        contextDelay: Duration? = nil,
        backupConfigured: Bool = true,
        noGitOperations: Bool = false,
        pullDelay: Duration? = nil,
        pullError: Error? = nil,
        pushError: Error? = nil
    ) {
        self.storageError = storageError
        self.exportError = exportError
        self.contextDelay = contextDelay
        self.backupConfigured = backupConfigured
        self.noGitOperations = noGitOperations
        self.pullDelay = pullDelay
        self.pullError = pullError
        self.pushError = pushError
    }

    func initialize(projectURL: URL, options: BeadsInitOptions) async throws {}

    func exportReadableSnapshot(projectURL: URL) async throws {
        exportCallCount += 1
        commandEvents.append("export")
        if let exportError {
            throw exportError
        }
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

    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition] {
        [
            BeadStatusDefinition(name: "open", category: .active, icon: nil, description: nil, isBuiltIn: true, source: .builtIn)
        ]
    }

    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] {
        [
            BeadTypeDefinition(name: "task", description: nil, source: .core)
        ]
    }

    func loadCustomStatuses(projectURL: URL) async throws -> [BeadStatusDefinition] { [] }

    func loadCustomTypes(projectURL: URL) async throws -> [BeadTypeDefinition] { [] }

    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws {}

    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws {}

    func loadProjectContext(projectURL: URL) async throws -> BeadsProjectContext {
        contextCallCount += 1
        if let contextDelay {
            try await Task.sleep(for: contextDelay)
        }
        return BeadsProjectContext(
            backend: "dolt",
            bdVersion: "1.0.4",
            beadsDirectory: projectURL.appendingPathComponent(".beads", isDirectory: true).path,
            cwdRepoRoot: projectURL.path,
            database: projectURL.lastPathComponent.components(separatedBy: "-").first,
            doltMode: "embedded",
            isRedirected: false,
            isWorktree: false,
            projectID: "project-id",
            repoRoot: projectURL.path,
            role: "maintainer",
            schemaVersion: 1,
            syncRemote: contextSyncRemote
        )
    }

    func setContextSyncRemote(_ value: String?) {
        contextSyncRemote = value
    }

    func loadProjectStorageConfig(projectURL: URL) async throws -> ProjectStorageConfig {
        if let storageError {
            throw storageError
        }
        return ProjectStorageConfig(
            exportAuto: true,
            exportPath: "issues.jsonl",
            exportInterval: "60s",
            exportGitAdd: true,
            importAuto: false,
            federationRemote: nil,
            noGitOperations: noGitOperations
        )
    }

    func loadHooksStatus(projectURL: URL) async throws -> BeadsHooksStatus {
        BeadsHooksStatus.parse(from: """
        Git hooks status:
          ✗ pre-commit: not installed
          ✓ pre-push: installed
        """)
    }

    func loadDoltRemotes(projectURL: URL) async throws -> BeadsDoltRemotes {
        BeadsDoltRemotes(remotes: [
            BeadsDoltRemote(
                name: "origin",
                url: "git+ssh://git@github.com/example/project.git",
                sqlURL: "git+ssh://git@github.com/example/project.git",
                status: "ok"
            )
        ])
    }

    func loadBackupStatus(projectURL: URL) async throws -> BeadsBackupStatus {
        try BeadsBackupStatus.decode(from: """
        {
          "backup": {
            "last_dolt_commit": "commit",
            "timestamp": "2026-07-08T13:35:44.99568Z"
          },
          "database_size": {
            "bytes": 10,
            "human": "10 B"
          },
          "dolt": {
            "configured": \(backupConfigured)
          }
        }
        """)
    }

    func installHooks(projectURL: URL) async throws {
        installHooksCallCount += 1
    }

    func pullDoltRemote(projectURL: URL) async throws {
        pullCallCount += 1
        commandEvents.append("pull")
        if let pullDelay {
            try await Task.sleep(for: pullDelay)
        }
        if let pullError {
            throw pullError
        }
    }

    func pushDoltRemote(projectURL: URL) async throws {
        pushCallCount += 1
        commandEvents.append("push")
        if let pushError {
            throw pushError
        }
    }

    func syncBackup(projectURL: URL) async throws {
        syncBackupCallCount += 1
    }

    func runSyntheticWrite(delay: Duration) async {
        syntheticWriteStarted = true
        commandEvents.append("write-start")
        try? await Task.sleep(for: delay)
        commandEvents.append("write-end")
    }
}

private enum ProjectHealthTestError: Error {
    case failedStorage
    case failedExport
    case failedPull
    case failedPush
}
