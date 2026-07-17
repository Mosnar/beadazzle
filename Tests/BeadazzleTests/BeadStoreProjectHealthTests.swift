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
    private let contextDelay: Duration?
    private let backupConfigured: Bool
    private let noGitOperations: Bool
    private(set) var exportCallCount = 0
    private(set) var installHooksCallCount = 0
    private(set) var syncBackupCallCount = 0

    init(
        storageError: Error? = nil,
        contextDelay: Duration? = nil,
        backupConfigured: Bool = true,
        noGitOperations: Bool = false
    ) {
        self.storageError = storageError
        self.contextDelay = contextDelay
        self.backupConfigured = backupConfigured
        self.noGitOperations = noGitOperations
    }

    func initialize(projectURL: URL, options: BeadsInitOptions) async throws {}

    func exportReadableSnapshot(projectURL: URL) async throws {
        exportCallCount += 1
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
            schemaVersion: 1
        )
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

    func syncBackup(projectURL: URL) async throws {
        syncBackupCallCount += 1
    }
}

private enum ProjectHealthTestError: Error {
    case failedStorage
}
