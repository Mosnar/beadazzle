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
        XCTAssertEqual(health.maintenance.compact.value?.totalCommits, 160)
        XCTAssertEqual(health.maintenance.flatten.value?.commitCount, 160)
        XCTAssertEqual(health.maintenance.embeddedDatabaseSize, 0)
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

    func testProjectLoadDiscoversDoltRemoteWithoutLoadingFullHealthSnapshot() async throws {
        let projectURL = try makeProject(named: "WorkspaceSyncProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()

        XCTAssertNil(store.projectHealthSnapshot)
        XCTAssertEqual(store.projectDoltRemotes?.value?.primaryRemote?.name, "origin")
        XCTAssertTrue(store.hasConfiguredProjectDoltRemote)
        XCTAssertTrue(store.canSynchronizeProjectIssues)
    }

    func testFullHealthRemoteResultRetiresOlderWorkspaceProbe() async throws {
        let projectURL = try makeProject(named: "RemoteProbeRaceProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(
            doltRemoteNames: ["stale", "fresh"],
            doltRemoteDelays: [.milliseconds(200), nil]
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        while await commands.doltRemoteCallCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()
        await store.waitForPendingProjectDoltRemotesLoad()

        XCTAssertEqual(store.projectHealthSnapshot?.doltRemotes.value?.primaryRemote?.name, "fresh")
        XCTAssertEqual(store.projectDoltRemotes?.value?.primaryRemote?.name, "fresh")
    }

    func testNewerWorkspaceRemoteProbeCannotBeOverwrittenByOlderHealthLoad() async throws {
        let projectURL = try makeProject(named: "NewerRemoteProbeRaceProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(
            doltRemoteNames: ["initial", "stale-health", "fresh-probe"],
            doltRemoteDelays: [nil, .milliseconds(200), nil]
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()

        store.loadProjectHealthStatus()
        while await commands.doltRemoteCallCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        store.loadProjectDoltRemotesIfNeeded(force: true)
        await store.waitForPendingProjectDoltRemotesLoad()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertEqual(store.projectHealthSnapshot?.doltRemotes.value?.primaryRemote?.name, "fresh-probe")
        XCTAssertEqual(store.projectDoltRemotes?.value?.primaryRemote?.name, "fresh-probe")
    }

    func testWorkspaceSyncStaysUnavailableWhenProjectHasNoDoltRemote() async throws {
        let projectURL = try makeProject(named: "LocalOnlyWorkspaceProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(hasDoltRemote: false)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()

        XCTAssertEqual(store.projectDoltRemotes?.value?.remotes, [])
        XCTAssertFalse(store.hasConfiguredProjectDoltRemote)
        XCTAssertFalse(store.canSynchronizeProjectIssues)
        XCTAssertEqual(store.doltRemoteFreshness.result, .notConfigured)
        let remoteGenerationCallCount = await commands.doltRemoteGenerationCallCount
        XCTAssertEqual(remoteGenerationCallCount, 0)
    }

    func testAutomaticRemoteCheckIsQuietUntilSyncEstablishesBaseline() async throws {
        let projectURL = try makeProject(named: "RemoteFreshnessProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()
        await store.waitForPendingDoltRemoteFreshnessCheck()

        XCTAssertEqual(store.doltRemoteFreshness.result, .unknown)
        let initialCallCount = await commands.doltRemoteGenerationCallCount
        XCTAssertEqual(initialCallCount, 0)

        store.checkProjectDoltRemoteFreshness(
            .automatic,
            now: Date().addingTimeInterval(60)
        )
        let cachedCallCount = await commands.doltRemoteGenerationCallCount
        XCTAssertEqual(cachedCallCount, 0)

        let didSync = await store.synchronizeProjectIssues()
        XCTAssertTrue(didSync)
        await store.waitForPendingDoltRemoteFreshnessCheck()
        guard case .unchangedSinceSync = store.doltRemoteFreshness.result else {
            return XCTFail("A successful sync should establish the remote checkpoint")
        }

        await commands.setDoltRemoteGeneration(String(repeating: "b", count: 40))
        store.checkProjectDoltRemoteFreshness(.manual)
        await store.waitForPendingDoltRemoteFreshnessCheck()

        guard case .remoteChanged = store.doltRemoteFreshness.result else {
            return XCTFail("A different remote generation should be reported as available")
        }
    }

    func testAutomaticRemoteCheckPreservesTransientFailureDuringBackoff() async throws {
        let projectURL = try makeProject(named: "RemoteFreshnessFailureProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()
        await store.waitForPendingDoltRemoteFreshnessCheck()

        await commands.setDoltRemoteGenerationError(ProjectHealthTestError.failedRemoteCheck)
        let failureTime = Date()
        store.checkProjectDoltRemoteFreshness(.manual, now: failureTime)
        await store.waitForPendingDoltRemoteFreshnessCheck()
        guard case .unavailable = store.doltRemoteFreshness.result else {
            return XCTFail("The failed remote check should remain visible")
        }

        store.checkProjectDoltRemoteFreshness(
            .automatic,
            now: failureTime.addingTimeInterval(60)
        )

        guard case .unavailable = store.doltRemoteFreshness.result else {
            return XCTFail("Backoff should not replace the transient failure with stale cached state")
        }
        let callCount = await commands.doltRemoteGenerationCallCount
        XCTAssertEqual(callCount, 1)
    }

    func testAutomaticRemoteChecksCanBeDisabledWithoutDisablingManualChecks() async throws {
        let projectURL = try makeProject(named: "ManualRemoteFreshnessProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let defaults = makeUserDefaults()
        defaults.set(
            false,
            forKey: BeadazzleAppBoolPreferences.automaticallyChecksDoltRemotes.key
        )
        let store = BeadStore(userDefaults: defaults, commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()

        XCTAssertFalse(store.automaticallyChecksDoltRemotes)
        let automaticCallCount = await commands.doltRemoteGenerationCallCount
        XCTAssertEqual(automaticCallCount, 0)

        store.checkProjectDoltRemoteFreshness(.manual)
        await store.waitForPendingDoltRemoteFreshnessCheck()
        let manualCallCount = await commands.doltRemoteGenerationCallCount
        XCTAssertEqual(manualCallCount, 1)
        XCTAssertEqual(store.doltRemoteFreshness.result, .unknown)
    }

    func testContributorProjectsGracefullySkipChecksUntilSyncCheckpointExists() async throws {
        let projectURL = try makeProject(named: "ContributorFreshnessProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(role: "contributor")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()
        await store.waitForPendingDoltRemoteFreshnessCheck()

        XCTAssertEqual(store.projectEnvironment?.role, .contributor)
        let automaticCallCount = await commands.doltRemoteGenerationCallCount
        XCTAssertEqual(automaticCallCount, 0)
        XCTAssertEqual(store.doltRemoteFreshness.result, .unknown)
    }

    func testActiveProjectPeriodicallyChecksRemoteAfterSyncCheckpoint() async throws {
        let projectURL = try makeProject(named: "PeriodicRemoteFreshnessProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(
            userDefaults: makeUserDefaults(),
            commands: commands,
            doltRemoteFreshnessCheckInterval: 0.05
        )
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()
        let sceneID = UUID()
        store.setDoltRemoteFreshnessSceneActive(true, sceneID: sceneID)

        let didSync = await store.synchronizeProjectIssues()
        XCTAssertTrue(didSync)
        await store.waitForPendingDoltRemoteFreshnessCheck()
        guard case .unchangedSinceSync = store.doltRemoteFreshness.result else {
            store.setDoltRemoteFreshnessSceneActive(false, sceneID: sceneID)
            return XCTFail("Sync should establish the periodic check checkpoint")
        }

        await commands.setDoltRemoteGeneration(String(repeating: "b", count: 40))
        try await waitUntil(timeout: 1) {
            store.doltRemoteFreshness.result.hasRemoteChanges
        }
        store.setDoltRemoteFreshnessSceneActive(false, sceneID: sceneID)

        let periodicCallCount = await commands.doltRemoteGenerationCallCount
        XCTAssertGreaterThanOrEqual(periodicCallCount, 2)
    }

    func testClosingOneOfTwoActiveScenesKeepsRemoteMonitoringAlive() async throws {
        let projectURL = try makeProject(named: "MultiSceneRemoteProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()

        let firstSceneID = UUID()
        let secondSceneID = UUID()
        store.setDoltRemoteFreshnessSceneActive(true, sceneID: firstSceneID)
        store.setDoltRemoteFreshnessSceneActive(true, sceneID: secondSceneID)
        let didSync = await store.synchronizeProjectIssues()
        XCTAssertTrue(didSync)
        await store.waitForPendingDoltRemoteFreshnessCheck()
        XCTAssertNotNil(store.doltRemoteFreshnessMonitorTask)

        store.setDoltRemoteFreshnessSceneActive(false, sceneID: firstSceneID)

        XCTAssertTrue(store.isDoltRemoteFreshnessSceneActive)
        XCTAssertNotNil(store.doltRemoteFreshnessMonitorTask)

        store.setDoltRemoteFreshnessSceneActive(false, sceneID: secondSceneID)

        XCTAssertFalse(store.isDoltRemoteFreshnessSceneActive)
        XCTAssertNil(store.doltRemoteFreshnessMonitorTask)
    }

    func testMonitorStopsWhenCurrentRemoteNoLongerHasCheckpoint() async throws {
        let originalRemote = BeadsDoltRemote(
            name: "origin",
            url: "git+ssh://git@github.com/example/original.git",
            sqlURL: nil,
            status: "ok"
        )
        let projectURL = try makeProject(named: "ChangedRemoteMonitorProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(configuredDoltRemotes: [originalRemote])
        let store = BeadStore(
            userDefaults: makeUserDefaults(),
            commands: commands,
            doltRemoteFreshnessCheckInterval: 5
        )
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()
        let sceneID = UUID()
        store.setDoltRemoteFreshnessSceneActive(true, sceneID: sceneID)
        let didSync = await store.synchronizeProjectIssues()
        XCTAssertTrue(didSync)
        await store.waitForPendingDoltRemoteFreshnessCheck()
        XCTAssertNotNil(store.doltRemoteFreshnessMonitorTask)

        await commands.setDoltRemoteGenerationDelay(.milliseconds(300))
        store.checkProjectDoltRemoteFreshness(.manual)
        while await commands.doltRemoteGenerationCallCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(store.doltRemoteFreshness.isChecking)

        await commands.setConfiguredDoltRemotes([
            BeadsDoltRemote(
                name: "origin",
                url: "git+ssh://git@github.com/example/replacement.git",
                sqlURL: nil,
                status: "ok"
            )
        ])
        store.loadProjectDoltRemotesIfNeeded(force: true)
        await store.waitForPendingProjectDoltRemotesLoad()
        try await waitUntil(timeout: 1) {
            store.doltRemoteFreshnessMonitorTask == nil
        }

        XCTAssertEqual(store.doltRemoteFreshness.result, .unknown)
        XCTAssertFalse(store.doltRemoteFreshness.isChecking)
        let callCountAfterRemoteChange = await commands.doltRemoteGenerationCallCount
        try await Task.sleep(for: .milliseconds(100))
        let finalCallCount = await commands.doltRemoteGenerationCallCount
        XCTAssertEqual(finalCallCount, callCountAfterRemoteChange)
        store.setDoltRemoteFreshnessSceneActive(false, sceneID: sceneID)
    }

    func testRemoteCheckpointPersistsAcrossWorktreesForSameTracker() async throws {
        let firstProjectURL = try makeProject(named: "FirstTrackerWorktree", issueID: "bd-1")
        let secondProjectURL = try makeProject(named: "SecondTrackerWorktree", issueID: "bd-2")
        let defaults = makeUserDefaults()
        defaults.set(
            false,
            forKey: BeadazzleAppBoolPreferences.automaticallyChecksDoltRemotes.key
        )

        let firstCommands = ProjectHealthTestCommands(projectID: "shared-tracker-id")
        let firstStore = BeadStore(userDefaults: defaults, commands: firstCommands)
        firstStore.openProject(firstProjectURL)
        try await waitUntil { !firstStore.isLoading && firstStore.issue(with: "bd-1") != nil }
        await firstStore.waitForPendingProjectDoltRemotesLoad()
        let didSync = await firstStore.synchronizeProjectIssues()
        XCTAssertTrue(didSync)
        await firstStore.waitForPendingDoltRemoteFreshnessCheck()
        guard case .unchangedSinceSync = firstStore.doltRemoteFreshness.result else {
            return XCTFail("The first worktree should save a sync checkpoint")
        }

        let secondCommands = ProjectHealthTestCommands(projectID: "shared-tracker-id")
        let secondStore = BeadStore(userDefaults: defaults, commands: secondCommands)
        secondStore.openProject(secondProjectURL)
        try await waitUntil { !secondStore.isLoading && secondStore.issue(with: "bd-2") != nil }
        await secondStore.waitForPendingProjectDoltRemotesLoad()

        guard case .unchangedSinceSync = secondStore.doltRemoteFreshness.result else {
            return XCTFail("A second worktree should load the tracker checkpoint")
        }
        let secondCallCount = await secondCommands.doltRemoteGenerationCallCount
        XCTAssertEqual(secondCallCount, 0)
    }

    func testRemoteCheckUsesConfiguredSyncRemoteInMultiRemoteProject() async throws {
        let projectURL = try makeProject(named: "ConfiguredSyncRemoteProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(
            configuredDoltRemotes: [
                BeadsDoltRemote(
                    name: "origin",
                    url: "git+ssh://git@github.com/example/origin.git",
                    sqlURL: nil,
                    status: "ok"
                ),
                BeadsDoltRemote(
                    name: "team",
                    url: "git+ssh://git@github.com/example/team.git",
                    sqlURL: nil,
                    status: "ok"
                )
            ]
        )
        await commands.setContextSyncRemote("team")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()

        let didSync = await store.synchronizeProjectIssues()
        XCTAssertTrue(didSync)
        await store.waitForPendingDoltRemoteFreshnessCheck()

        let checkedRemoteName = await commands.lastDoltRemoteGenerationRemoteName
        XCTAssertEqual(checkedRemoteName, "team")
    }

    func testProjectSwitchCancelsInFlightRemoteFreshnessCheck() async throws {
        let firstProjectURL = try makeProject(named: "SlowRemoteProject", issueID: "bd-1")
        let secondProjectURL = try makeProject(named: "ReplacementRemoteProject", issueID: "bd-2")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()
        let didSync = await store.synchronizeProjectIssues()
        XCTAssertTrue(didSync)
        await store.waitForPendingDoltRemoteFreshnessCheck()

        await commands.setDoltRemoteGenerationDelay(.milliseconds(300))
        store.checkProjectDoltRemoteFreshness(.manual)
        while await commands.doltRemoteGenerationCallCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        store.openProject(secondProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(store.projectURL, secondProjectURL)
        XCTAssertEqual(store.doltRemoteFreshness.result, .unknown)
        XCTAssertFalse(store.doltRemoteFreshness.isChecking)
    }

    func testSyncIssuesPullsPushesExportsAndReloadsBeforeReturning() async throws {
        let projectURL = try makeProject(named: "CombinedSyncProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(exportedIssueTitle: "Synced from remote")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()
        XCTAssertNil(store.projectHealthSnapshot)
        let contextCallsBeforeSync = await commands.contextCallCount

        let didSync = await store.synchronizeProjectIssues()
        await store.waitForPendingProjectHealthLoad()

        XCTAssertTrue(didSync)
        let commandEvents = await commands.commandEvents
        let pullCallCount = await commands.pullCallCount
        let exportCallCount = await commands.exportCallCount
        let pushCallCount = await commands.pushCallCount
        XCTAssertEqual(Array(commandEvents.suffix(3)), ["pull", "push", "export"])
        XCTAssertEqual(pullCallCount, 1)
        XCTAssertEqual(exportCallCount, 1)
        XCTAssertEqual(pushCallCount, 1)
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Synced from remote")
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.projectHealthAction)
        XCTAssertNil(store.projectHealthActionError)
        XCTAssertNil(store.projectHealthSnapshot)
        let contextCallsAfterSync = await commands.contextCallCount
        XCTAssertEqual(contextCallsAfterSync, contextCallsBeforeSync)
    }

    func testSyncReusesDefinitionsAndRefreshesThemWithoutBlockingCompletion() async throws {
        let projectURL = try makeProject(named: "SlowSyncReloadProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(exportedIssueTitle: "Reloaded after sync")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()
        if let semanticDefinitionsRefreshTask = store.semanticDefinitionsRefreshTask {
            await semanticDefinitionsRefreshTask.value
        }
        await commands.setStatusDefinitionsDelay(.seconds(5))

        let didSync = await store.synchronizeProjectIssues()
        while await commands.statusDefinitionsLoadStarted == false {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(didSync)
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Reloaded after sync")
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.projectHealthAction)
        let semanticDefinitionsRefreshTask = store.semanticDefinitionsRefreshTask
        XCTAssertNotNil(semanticDefinitionsRefreshTask)
        store.cancelSemanticDefinitionsRefresh()
        if let semanticDefinitionsRefreshTask {
            await semanticDefinitionsRefreshTask.value
        }
    }

    func testSyncWaitsForMutationThatStartsDuringRemoteWriteThenReexports() async throws {
        let projectURL = try makeProject(named: "SyncConcurrentMutationProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(
            pullDelay: .milliseconds(150),
            exportedIssueTitle: "Synced after edit"
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()

        let syncTask = Task { await store.synchronizeProjectIssues() }
        try await waitUntil { store.activeMutationCount == 1 }
        let editGeneration = store.beginMutation()
        while await commands.exportCallCount < 1 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await waitUntil { store.activeMutationCount == 1 }

        XCTAssertEqual(store.projectHealthAction, .synchronizingIssues)
        XCTAssertEqual(store.activeMutationCount, 1)
        store.endMutation(generation: editGeneration)

        let didSync = await syncTask.value

        XCTAssertTrue(didSync)
        let exportCallCount = await commands.exportCallCount
        XCTAssertEqual(exportCallCount, 2)
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Synced after edit")
        XCTAssertNil(store.projectHealthActionError)
    }

    func testSyncRetriesWhenMutationCancelsItsFirstSnapshotReload() async throws {
        let projectURL = try makeProject(named: "SyncReloadMutationProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(exportedIssueTitle: "Synced after reload retry")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()
        if let semanticDefinitionsRefreshTask = store.semanticDefinitionsRefreshTask {
            await semanticDefinitionsRefreshTask.value
        }
        store.invalidateSemanticDefinitionsCache()
        await commands.setStatusDefinitionsDelay(.milliseconds(300))

        let syncTask = Task { await store.synchronizeProjectIssues() }
        while await commands.statusDefinitionsLoadStarted == false {
            try await Task.sleep(for: .milliseconds(5))
        }
        let editGeneration = store.beginMutation()
        store.endMutation(generation: editGeneration)

        let didSync = await syncTask.value

        XCTAssertTrue(didSync)
        let exportCallCount = await commands.exportCallCount
        XCTAssertEqual(exportCallCount, 2)
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Synced after reload retry")
        XCTAssertNil(store.projectHealthActionError)
    }

    func testSettingsSyncCanRequestFullHealthRefresh() async throws {
        let projectURL = try makeProject(named: "SettingsSyncHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(exportedIssueTitle: "Synced from Settings")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()
        XCTAssertNil(store.projectHealthSnapshot)
        await commands.setDoltRemoteGenerationDelay(.milliseconds(100))

        let didSync = await store.synchronizeProjectIssues(completionRefresh: .fullHealth)
        await store.waitForPendingProjectHealthLoad()
        await store.waitForPendingDoltRemoteFreshnessCheck()

        XCTAssertTrue(didSync)
        XCTAssertNotNil(store.projectHealthSnapshot)
        guard case .unchangedSinceSync = store.doltRemoteFreshness.result else {
            return XCTFail("Refreshing health for the same remote should preserve checkpoint setup")
        }
    }

    func testSyncReloadOwnsQueuedExternalReconcileFromSnapshotExport() async throws {
        let projectURL = try makeProject(named: "SyncExportMonitorRaceProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(
            pullDelay: .milliseconds(100),
            exportedIssueTitle: "Reloaded without a competing reconcile"
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()
        let syncTask = Task { await store.synchronizeProjectIssues() }
        try await waitUntil { store.activeMutationCount == 1 }

        // An atomic snapshot export produces this monitor request while Sync still owns
        // the mutation. On a large tracker, its delayed reconcile used to cancel the
        // authoritative reload that Sync was awaiting 600 ms later.
        store.requestReconcile(trigger: .externalMarker)

        let didSync = await syncTask.value

        XCTAssertTrue(didSync)
        XCTAssertEqual(
            store.issue(with: "bd-1")?.title,
            "Reloaded without a competing reconcile"
        )
        XCTAssertFalse(store.reconcileState.hasPendingRequest)
        XCTAssertFalse(store.reconcileState.isInFlight)
        XCTAssertNil(store.projectHealthActionError)
    }

    func testSyncReportsRefreshFailureAfterRemotePushCompletes() async throws {
        let projectURL = try makeProject(named: "SyncReloadFailureProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(removesSnapshotOnExport: true)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()

        let didSync = await store.synchronizeProjectIssues(reportsFailureInWorkspace: true)
        await store.waitForPendingProjectHealthLoad()

        XCTAssertFalse(didSync)
        let pushCallCount = await commands.pushCallCount
        XCTAssertEqual(pushCallCount, 1)
        XCTAssertEqual(store.projectHealthActionError?.title, "Sync completed, but refresh failed")
        XCTAssertEqual(store.currentFailure?.title, "Sync completed, but refresh failed")
        XCTAssertNil(store.projectHealthAction)
    }

    func testSyncPullFailureReconcilesLocalSnapshotWithoutPushing() async throws {
        let projectURL = try makeProject(named: "CombinedSyncPullFailureProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(
            pullError: BeadError.commandFailed(
                command: "bd dolt pull",
                output: "merge conflict"
            ),
            exportedIssueTitle: "Partially pulled change"
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()

        let didSync = await store.synchronizeProjectIssues(reportsFailureInWorkspace: true)
        await store.waitForPendingProjectHealthLoad()

        XCTAssertFalse(didSync)
        let pullCallCount = await commands.pullCallCount
        let exportCallCount = await commands.exportCallCount
        let pushCallCount = await commands.pushCallCount
        let commandEvents = await commands.commandEvents
        XCTAssertEqual(pullCallCount, 1)
        XCTAssertEqual(exportCallCount, 1)
        XCTAssertEqual(pushCallCount, 0)
        XCTAssertEqual(Array(commandEvents.suffix(2)), ["pull", "export"])
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Partially pulled change")
        let failure = try XCTUnwrap(store.currentFailure)
        XCTAssertEqual(failure.title, "Couldn't sync beads with remote")
        XCTAssertEqual(failure.command, "bd dolt pull")
        XCTAssertEqual(failure.output, "merge conflict")
        XCTAssertTrue(failure.isRetryable)
    }

    func testSyncExportFailureStillPushesAndMarksSnapshotStale() async throws {
        let projectURL = try makeProject(named: "CombinedSyncExportFailureProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(exportError: ProjectHealthTestError.failedExport)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()

        let didSync = await store.synchronizeProjectIssues(reportsFailureInWorkspace: true)
        await store.waitForPendingProjectHealthLoad()

        XCTAssertFalse(didSync)
        let commandEvents = await commands.commandEvents
        let pushCallCount = await commands.pushCallCount
        XCTAssertEqual(Array(commandEvents.suffix(3)), ["pull", "push", "export"])
        XCTAssertEqual(pushCallCount, 1)
        XCTAssertEqual(store.snapshotFreshness.state, .possiblyStale)
        XCTAssertEqual(store.projectHealthActionError?.title, "Sync completed, but refresh failed")
        XCTAssertEqual(store.currentFailure?.title, "Sync completed, but refresh failed")

        await commands.setExportError(nil)
        store.retryCurrentFailure()
        try await waitUntil {
            !store.isLoading
                && store.currentFailure == nil
                && store.projectHealthActionError == nil
        }

        let retryPushCallCount = await commands.pushCallCount
        let retryExportCallCount = await commands.exportCallCount
        XCTAssertEqual(retryPushCallCount, 1)
        XCTAssertEqual(retryExportCallCount, 2)
    }

    func testSyncPushFailureReloadsPulledSnapshotAndReportsPartialSuccess() async throws {
        let projectURL = try makeProject(named: "CombinedSyncPushFailureProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(
            pushError: BeadError.commandFailed(
                command: "bd dolt push",
                output: "remote contains changes"
            ),
            exportedIssueTitle: "Pulled from remote"
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()

        let didSync = await store.synchronizeProjectIssues(reportsFailureInWorkspace: true)
        await store.waitForPendingProjectHealthLoad()

        XCTAssertFalse(didSync)
        let commandEvents = await commands.commandEvents
        XCTAssertEqual(Array(commandEvents.suffix(3)), ["pull", "push", "export"])
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Pulled from remote")
        let failure = try XCTUnwrap(store.currentFailure)
        XCTAssertEqual(failure.title, "Pulled beads, but couldn't push")
        XCTAssertEqual(failure.command, "bd dolt push")
        XCTAssertEqual(failure.output, "remote contains changes")
        XCTAssertTrue(failure.isRetryable)
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
        await store.waitForPendingProjectDoltRemotesLoad()
        XCTAssertNil(store.projectHealthSnapshot)

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
        XCTAssertFalse(store.reconcileState.hasPendingRequest)
        XCTAssertFalse(store.reconcileState.isInFlight)
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
        await store.waitForPendingProjectDoltRemotesLoad()
        XCTAssertNil(store.projectHealthSnapshot)

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

    func testWorkspacePushFailureUsesUnifiedRetryableFailureDialog() async throws {
        let projectURL = try makeProject(named: "WorkspacePushFailureProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(
            pushError: BeadError.commandFailed(
                command: "bd dolt push",
                output: "remote contains changes"
            )
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await store.waitForPendingProjectDoltRemotesLoad()

        let didPush = await store.pushProjectIssues(reportsFailureInWorkspace: true)
        await store.waitForPendingProjectHealthLoad()

        XCTAssertFalse(didPush)
        let failure = try XCTUnwrap(store.currentFailure)
        XCTAssertEqual(failure.title, "Couldn't push beads to remote")
        XCTAssertEqual(failure.command, "bd dolt push")
        XCTAssertEqual(failure.output, "remote contains changes")
        XCTAssertTrue(failure.isRetryable)
    }

    func testPullFailureReconcilesPossiblyChangedSnapshotAndPreservesPullError() async throws {
        let projectURL = try makeProject(named: "FailedPullHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(
            pullError: ProjectHealthTestError.failedPull,
            exportedIssueTitle: "Recovered after failed pull"
        )
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
        XCTAssertEqual(exportCallCount, 1)
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Recovered after failed pull")
        XCTAssertEqual(store.projectHealthActionError?.title, "Couldn't pull beads from remote")
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

    func testCompactMaintenanceSyncsBackupThenCompactsAndExports() async throws {
        let projectURL = try makeProject(named: "CompactHealthProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let succeeded = await store.performDoltMaintenance(
            .compact,
            allowsProceedingWithoutBackup: false
        )
        try await waitUntil { !store.isLoading }
        await store.waitForPendingProjectHealthLoad()

        XCTAssertTrue(succeeded)
        let syncBackupCallCount = await commands.syncBackupCallCount
        let compactCallCount = await commands.compactCallCount
        let exportCallCount = await commands.exportCallCount
        XCTAssertEqual(syncBackupCallCount, 1)
        XCTAssertEqual(compactCallCount, 1)
        XCTAssertEqual(exportCallCount, 1)
        let events = await commands.commandEvents
        guard let backupIndex = events.firstIndex(of: "backup"),
              let compactIndex = events.firstIndex(of: "compact"),
              let exportIndex = events.firstIndex(of: "export") else {
            return XCTFail("Expected backup, compact, and export events: \(events)")
        }
        XCTAssertLessThan(backupIndex, compactIndex)
        XCTAssertLessThan(compactIndex, exportIndex)
    }

    func testMaintenanceRequiresExplicitOverrideWhenBackupIsNotConfigured() async throws {
        let projectURL = try makeProject(named: "NoBackupMaintenanceProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(backupConfigured: false)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let rejected = await store.performDoltMaintenance(
            .flatten,
            allowsProceedingWithoutBackup: false
        )
        await store.waitForPendingProjectHealthLoad()

        XCTAssertFalse(rejected)
        let rejectedFlattenCallCount = await commands.flattenCallCount
        let rejectedExportCallCount = await commands.exportCallCount
        XCTAssertEqual(rejectedFlattenCallCount, 0)
        XCTAssertEqual(rejectedExportCallCount, 0)
        XCTAssertTrue(store.projectHealthActionError?.message.contains("explicitly allow") == true)

        let succeeded = await store.performDoltMaintenance(
            .flatten,
            allowsProceedingWithoutBackup: true
        )
        try await waitUntil { !store.isLoading }

        XCTAssertTrue(succeeded)
        let flattenCallCount = await commands.flattenCallCount
        let syncBackupCallCount = await commands.syncBackupCallCount
        let exportCallCount = await commands.exportCallCount
        XCTAssertEqual(flattenCallCount, 1)
        XCTAssertEqual(syncBackupCallCount, 0)
        XCTAssertEqual(exportCallCount, 1)
    }

    func testMaintenanceStopsAfterBackupFailureUntilOverrideIsExplicit() async throws {
        let projectURL = try makeProject(named: "FailedBackupMaintenanceProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(backupError: ProjectHealthTestError.failedBackup)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let rejected = await store.performDoltMaintenance(
            .compact,
            allowsProceedingWithoutBackup: false
        )
        await store.waitForPendingProjectHealthLoad()
        XCTAssertFalse(rejected)
        let rejectedCounts = await commands.counts()
        XCTAssertEqual(rejectedCounts.compact, 0)

        let succeeded = await store.performDoltMaintenance(
            .compact,
            allowsProceedingWithoutBackup: true
        )
        try await waitUntil { !store.isLoading }

        XCTAssertTrue(succeeded)
        let counts = await commands.counts()
        XCTAssertEqual(counts.backup, 2)
        XCTAssertEqual(counts.compact, 1)
        XCTAssertEqual(counts.export, 1)
    }

    func testFreshNoOpMaintenancePreviewStopsBeforeBackupOrWrite() async throws {
        let projectURL = try makeProject(named: "NoOpMaintenanceProject", issueID: "bd-1")
        let commands = ProjectHealthTestCommands(
            compactPreview: BeadsDoltCompactPreview(
                totalCommits: 2,
                oldCommits: 1,
                recentCommits: 1,
                cutoffDays: 30
            ),
            flattenPreview: BeadsDoltFlattenPreview(commitCount: 1, wouldFlatten: false)
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let compacted = await store.performDoltMaintenance(
            .compact,
            allowsProceedingWithoutBackup: false
        )
        await store.waitForPendingProjectHealthLoad()
        XCTAssertFalse(compacted)
        XCTAssertTrue(store.projectHealthActionError?.message.contains("fewer than two commits") == true)

        let flattened = await store.performDoltMaintenance(
            .flatten,
            allowsProceedingWithoutBackup: false
        )
        await store.waitForPendingProjectHealthLoad()
        XCTAssertFalse(flattened)
        XCTAssertTrue(store.projectHealthActionError?.message.contains("already flat") == true)

        let counts = await commands.counts()
        XCTAssertEqual(counts.backup, 0)
        XCTAssertEqual(counts.compact, 0)
        XCTAssertEqual(counts.flatten, 0)
        XCTAssertEqual(counts.export, 0)
    }

    func testQueuedMaintenanceDoesNotStartAfterProjectSwitch() async throws {
        let firstProjectURL = try makeProject(named: "QueuedMaintenanceProject", issueID: "bd-1")
        let secondProjectURL = try makeProject(named: "MaintenanceNextProject", issueID: "bd-2")
        let commands = ProjectHealthTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.loadProjectHealthStatus()
        await store.waitForPendingProjectHealthLoad()

        let blockingWrite = Task {
            try await store.enqueueMutationWrite {
                await commands.runSyntheticWrite(delay: .milliseconds(250))
            }
        }
        while await commands.syntheticWriteStarted == false {
            try await Task.sleep(for: .milliseconds(5))
        }
        let maintenance = Task {
            await store.performDoltMaintenance(.compact, allowsProceedingWithoutBackup: false)
        }
        try await waitUntil { store.projectHealthAction == .compactingDatabase }

        store.openProject(secondProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }
        try await blockingWrite.value
        let maintenanceSucceeded = await maintenance.value
        XCTAssertFalse(maintenanceSucceeded)

        let counts = await commands.counts()
        XCTAssertEqual(counts.backup, 0)
        XCTAssertEqual(counts.compact, 0)
        XCTAssertEqual(counts.export, 0)
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
    private var exportError: Error?
    private let contextDelay: Duration?
    private let backupConfigured: Bool
    private let backupError: Error?
    private let noGitOperations: Bool
    private let hasDoltRemote: Bool
    private let pullDelay: Duration?
    private let pullError: Error?
    private let pushError: Error?
    private let exportedIssueTitle: String?
    private let removesSnapshotOnExport: Bool
    private let doltRemoteNames: [String]
    private let doltRemoteDelays: [Duration?]
    private var configuredDoltRemotes: [BeadsDoltRemote]?
    private let role: String
    private let projectID: String?
    private var doltRemoteGeneration = String(repeating: "a", count: 40)
    private var doltRemoteGenerationError: Error?
    private var doltRemoteGenerationDelay: Duration?
    private let compactPreview: BeadsDoltCompactPreview
    private let flattenPreview: BeadsDoltFlattenPreview
    private var contextSyncRemote: String?
    private var statusDefinitionsDelay: Duration?
    private(set) var exportCallCount = 0
    private(set) var contextCallCount = 0
    private(set) var installHooksCallCount = 0
    private(set) var pullCallCount = 0
    private(set) var pushCallCount = 0
    private(set) var syncBackupCallCount = 0
    private(set) var compactCallCount = 0
    private(set) var flattenCallCount = 0
    private(set) var doltRemoteCallCount = 0
    private(set) var doltRemoteGenerationCallCount = 0
    private(set) var lastDoltRemoteGenerationRemoteName: String?
    private(set) var statusDefinitionsLoadStarted = false
    private(set) var commandEvents: [String] = []
    private(set) var syntheticWriteStarted = false

    init(
        storageError: Error? = nil,
        exportError: Error? = nil,
        contextDelay: Duration? = nil,
        backupConfigured: Bool = true,
        backupError: Error? = nil,
        noGitOperations: Bool = false,
        hasDoltRemote: Bool = true,
        pullDelay: Duration? = nil,
        pullError: Error? = nil,
        pushError: Error? = nil,
        exportedIssueTitle: String? = nil,
        removesSnapshotOnExport: Bool = false,
        doltRemoteNames: [String] = ["origin"],
        doltRemoteDelays: [Duration?] = [],
        configuredDoltRemotes: [BeadsDoltRemote]? = nil,
        role: String = "maintainer",
        projectID: String? = nil,
        compactPreview: BeadsDoltCompactPreview = BeadsDoltCompactPreview(
            totalCommits: 160,
            oldCommits: 40,
            recentCommits: 120,
            cutoffDays: 30
        ),
        flattenPreview: BeadsDoltFlattenPreview = BeadsDoltFlattenPreview(
            commitCount: 160,
            wouldFlatten: true
        )
    ) {
        self.storageError = storageError
        self.exportError = exportError
        self.contextDelay = contextDelay
        self.backupConfigured = backupConfigured
        self.backupError = backupError
        self.noGitOperations = noGitOperations
        self.hasDoltRemote = hasDoltRemote
        self.pullDelay = pullDelay
        self.pullError = pullError
        self.pushError = pushError
        self.exportedIssueTitle = exportedIssueTitle
        self.removesSnapshotOnExport = removesSnapshotOnExport
        self.doltRemoteNames = doltRemoteNames
        self.doltRemoteDelays = doltRemoteDelays
        self.configuredDoltRemotes = configuredDoltRemotes
        self.role = role
        self.projectID = projectID
        self.compactPreview = compactPreview
        self.flattenPreview = flattenPreview
    }


    func exportReadableSnapshot(projectURL: URL) async throws {
        exportCallCount += 1
        commandEvents.append("export")
        if let exportError {
            throw exportError
        }
        if removesSnapshotOnExport {
            try? FileManager.default.removeItem(
                at: projectURL.appendingPathComponent(".beads/issues.jsonl")
            )
            return
        }
        if let exportedIssueTitle {
            try """
            {"_type":"issue","id":"bd-1","title":"\(exportedIssueTitle)","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-08T12:00:00Z"}
            """.write(
                to: projectURL.appendingPathComponent(".beads/issues.jsonl"),
                atomically: true,
                encoding: .utf8
            )
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
        statusDefinitionsLoadStarted = true
        if let statusDefinitionsDelay {
            try await Task.sleep(for: statusDefinitionsDelay)
        }
        return [
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
            projectID: projectID ?? "project-\(projectURL.lastPathComponent)",
            repoRoot: projectURL.path,
            role: role,
            schemaVersion: 1,
            syncRemote: contextSyncRemote
        )
    }

    func setContextSyncRemote(_ value: String?) {
        contextSyncRemote = value
    }

    func setConfiguredDoltRemotes(_ remotes: [BeadsDoltRemote]?) {
        configuredDoltRemotes = remotes
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
        guard hasDoltRemote else { return BeadsDoltRemotes(remotes: []) }
        let callIndex = doltRemoteCallCount
        doltRemoteCallCount += 1
        if doltRemoteDelays.indices.contains(callIndex),
           let delay = doltRemoteDelays[callIndex] {
            try await Task.sleep(for: delay)
        }
        if let configuredDoltRemotes {
            return BeadsDoltRemotes(remotes: configuredDoltRemotes)
        }
        let remoteName = doltRemoteNames.indices.contains(callIndex)
            ? doltRemoteNames[callIndex]
            : doltRemoteNames.last ?? "origin"
        return BeadsDoltRemotes(remotes: [
            BeadsDoltRemote(
                name: remoteName,
                url: "git+ssh://git@github.com/example/project.git",
                sqlURL: "git+ssh://git@github.com/example/project.git",
                status: "ok"
            )
        ])
    }

    func loadDoltRemoteGeneration(
        projectURL: URL,
        remote: BeadsDoltRemote
    ) async throws -> String {
        doltRemoteGenerationCallCount += 1
        lastDoltRemoteGenerationRemoteName = remote.name
        if let doltRemoteGenerationDelay {
            try await Task.sleep(for: doltRemoteGenerationDelay)
        }
        if let doltRemoteGenerationError {
            throw doltRemoteGenerationError
        }
        return doltRemoteGeneration
    }

    func setDoltRemoteGeneration(_ generation: String) {
        doltRemoteGeneration = generation
    }

    func setDoltRemoteGenerationError(_ error: Error?) {
        doltRemoteGenerationError = error
    }

    func setDoltRemoteGenerationDelay(_ delay: Duration?) {
        doltRemoteGenerationDelay = delay
    }

    func setStatusDefinitionsDelay(_ delay: Duration?) {
        statusDefinitionsDelay = delay
        statusDefinitionsLoadStarted = false
    }

    func setExportError(_ error: Error?) {
        exportError = error
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
        commandEvents.append("backup")
        if let backupError {
            throw backupError
        }
    }

    func loadDoltMaintenancePreview(projectURL: URL) async -> BeadsDoltMaintenancePreview {
        return BeadsDoltMaintenancePreview(
            compact: .available(compactPreview),
            flatten: .available(flattenPreview),
            embeddedDatabaseSize: nil
        )
    }

    func compactDoltDatabase(projectURL: URL, retainingDays: Int) async throws {
        compactCallCount += 1
        commandEvents.append("compact")
    }

    func flattenDoltDatabase(projectURL: URL) async throws {
        flattenCallCount += 1
        commandEvents.append("flatten")
    }

    func counts() -> (backup: Int, compact: Int, flatten: Int, export: Int) {
        (syncBackupCallCount, compactCallCount, flattenCallCount, exportCallCount)
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
    case failedBackup
    case failedRemoteCheck
}
