import XCTest
@testable import Beadazzle

final class BeadsJournalRefreshTests: XCTestCase {
    func testFieldRefreshPreservesRelationshipsAndCountsWithoutExport() async throws {
        let (url, commands) = try fixture()
        let loader = BeadProjectLoader(commands: commands)
        let initial = try await load(loader, url: url)
        let baseline = try XCTUnwrap(initial.journalBaseline)
        try await commands.change(title: "External edit", operation: "update")

        let refreshed = try await load(loader, url: url, baseline: baseline, fast: true)

        XCTAssertTrue(refreshed.journalRefresh.requiresVerification)
        XCTAssertEqual(refreshed.index.issue(with: "bd-one")?.title, "External edit")
        XCTAssertEqual(refreshed.index.issue(with: "bd-one")?.commentCount, 2)
        XCTAssertEqual(refreshed.snapshot.dependencies, initial.snapshot.dependencies)
        XCTAssertEqual(refreshed.source, initial.source, "The fast path must not rewrite the exported file")
        let exports = await commands.exports
        XCTAssertEqual(exports, 1)
        XCTAssertEqual(refreshed.journalBaseline?.cursor, 2)
    }

    func testStructuralAndUnknownRecordsUseFullExportWithoutPartialApply() async throws {
        for operation in ["create", "delete", "comment", "dep_add", "dep_remove", "future_operation"] {
            let (url, commands) = try fixture()
            let loader = BeadProjectLoader(commands: commands)
            let initial = try await load(loader, url: url)
            try await commands.change(title: "Intermediate", operation: "update")
            try await commands.change(title: "Authoritative", operation: operation, commentCount: 3)

            let refreshed = try await load(loader, url: url, baseline: initial.journalBaseline, fast: true)

            XCTAssertFalse(refreshed.journalRefresh.requiresVerification, operation)
            XCTAssertEqual(refreshed.snapshot.issues.first?.title, "Authoritative", operation)
            XCTAssertEqual(refreshed.snapshot.issues.first?.commentCount, 3, operation)
            let exports = await commands.exports
            XCTAssertEqual(exports, 2, operation)
            XCTAssertEqual(initial.journalBaseline?.cursor, 1, "Rejected work must not mutate the accepted checkpoint")
        }
    }

    func testDisabledJournalDoesNotEstablishCheckpointOrSkipExport() async throws {
        let (url, commands) = try fixture()
        await commands.setEnabled(false)
        let loaded = try await load(BeadProjectLoader(commands: commands), url: url)
        XCTAssertNil(loaded.journalBaseline)
        XCTAssertFalse(loaded.journalRefresh.requiresVerification)
        let reads = await commands.journalReads
        XCTAssertEqual(reads, 0)
        let exports = await commands.exports
        XCTAssertEqual(exports, 1)
    }

    func testEmptyFeedAfterMarkerStillExportsUnjournaledChanges() async throws {
        let (url, commands) = try fixture()
        let loader = BeadProjectLoader(commands: commands)
        let initial = try await load(loader, url: url)
        try await commands.changeWithoutJournal(title: "Unjournaled edit")
        let refreshed = try await load(loader, url: url, baseline: initial.journalBaseline, fast: true)
        XCTAssertFalse(refreshed.journalRefresh.requiresVerification)
        XCTAssertEqual(refreshed.snapshot.issues.first?.title, "Unjournaled edit")
    }

    func testGapAndChangedAnchorRecoverFromFullSnapshot() async throws {
        for reset in [false, true] {
            let (url, commands) = try fixture()
            let loader = BeadProjectLoader(commands: commands)
            let initial = try await load(loader, url: url)
            if reset {
                await commands.replaceJournal([try JournalRefreshFixture.record(sequence: 1, title: "Another journal")])
            } else {
                await commands.append(try JournalRefreshFixture.record(sequence: 3, title: "Gap"))
            }
            try await commands.changeWithoutJournal(title: "Recovered")
            let refreshed = try await load(loader, url: url, baseline: initial.journalBaseline, fast: true)
            XCTAssertFalse(refreshed.journalRefresh.requiresVerification)
            XCTAssertEqual(refreshed.snapshot.issues.first?.title, "Recovered")
        }
    }

    func testPrunedAnchorAndCursorAboveHeadCannotLookCurrent() async throws {
        for pruned in [false, true] {
            let (url, commands) = try fixture()
            let loader = BeadProjectLoader(commands: commands)
            let initial = try await load(loader, url: url)
            try await commands.changeWithoutJournal(title: "Restored data")
            if pruned {
                await commands.setTruncationHead(10)
            } else {
                await commands.replaceJournal([])
            }
            let refreshed = try await load(loader, url: url, baseline: initial.journalBaseline, fast: true)
            XCTAssertFalse(refreshed.journalRefresh.requiresVerification)
            XCTAssertEqual(refreshed.snapshot.issues.first?.title, "Restored data")
        }
    }

    func testBusyBaselineDoesNotBindAnUnsafeCheckpoint() async throws {
        let (url, commands) = try fixture()
        await commands.changeDuringNextExport()
        let loader = BeadProjectLoader(commands: commands)
        let first = try await load(loader, url: url)
        XCTAssertNil(first.journalBaseline)
        let next = try await load(loader, url: url, baseline: first.journalBaseline, fast: true)
        XCTAssertEqual(next.snapshot.issues.first?.title, "Changed during export")
        XCTAssertNotNil(next.journalBaseline)
        XCTAssertFalse(next.journalRefresh.requiresVerification)
    }

    func testJournalResetAtSameSequenceDuringExportCannotBindCheckpoint() async throws {
        let (url, commands) = try fixture()
        await commands.resetDuringNextExport()
        let loader = BeadProjectLoader(commands: commands)
        let first = try await load(loader, url: url)
        XCTAssertNil(first.journalBaseline)
        let next = try await load(loader, url: url, baseline: first.journalBaseline, fast: true)
        XCTAssertEqual(next.snapshot.issues.first?.title, "Reset during export")
        XCTAssertNotNil(next.journalBaseline)
    }

    func testFullPageDoesNotInstallAnIncompleteCheckpoint() async throws {
        let (url, commands) = try fixture()
        let records = try (1...BeadsJournalPage.recordLimit).map {
            try JournalRefreshFixture.record(sequence: Int64($0), title: "Before")
        }
        await commands.replaceJournal(records)
        let loaded = try await load(BeadProjectLoader(commands: commands), url: url)
        XCTAssertNil(loaded.journalBaseline)
        XCTAssertFalse(loaded.journalRefresh.requiresVerification)
        let reads = await commands.journalReads
        XCTAssertEqual(reads, 1, "Do not keep paging through a large retained history")
    }

    func testFullRefreshReusesCheckpointBeyondHistoryLimitAndCachesCapability() async throws {
        let (url, commands) = try fixture()
        let loader = BeadProjectLoader(commands: commands)
        let initial = try await load(loader, url: url)
        let records = try (1...2_000).map { try JournalRefreshFixture.record(sequence: Int64($0), title: "Before") }
        await commands.replaceJournal(records)
        let next = try await load(loader, url: url, previous: initial)
        XCTAssertEqual(next.journalBaseline?.cursor, 2_000)
        for sequence in 2_001...2_100 {
            await commands.append(try JournalRefreshFixture.record(sequence: Int64(sequence), title: "Before"))
        }
        let readsBefore = await commands.journalSince.count
        let refreshed = try await load(loader, url: url, previous: next)
        XCTAssertEqual(refreshed.journalBaseline?.cursor, 2_100)
        let since = await commands.journalSince
        XCTAssertEqual(Array(since.dropFirst(readsBefore)), [1_999, 2_099])
        let contextLoads = await commands.contextLoads
        let enabledChecks = await commands.enabledChecks
        XCTAssertEqual(contextLoads, 1, "Full refreshes reuse the resolved tracker")
        XCTAssertEqual(enabledChecks, 1, "Unchanged configuration reuses the capability check")
        try await commands.change(title: "Still accelerated", operation: "update")
        let fast = try await load(loader, url: url, previous: refreshed, fast: true)
        XCTAssertEqual(fast.snapshot.issues.first?.title, "Still accelerated")
        XCTAssertTrue(fast.journalRefresh.requiresVerification)
        let checksAfterFastRead = await commands.enabledChecks
        XCTAssertEqual(checksAfterFastRead, 1, "The fast path reads the journal directly")
    }

    func testLargeHistoryIsNotReadAgainUntilConfigurationChanges() async throws {
        let (url, commands) = try fixture()
        let records = try (1...BeadsJournalPage.recordLimit).map {
            try JournalRefreshFixture.record(sequence: Int64($0), title: "Before")
        }
        await commands.replaceJournal(records)
        let loader = BeadProjectLoader(commands: commands)
        let initial = try await load(loader, url: url)
        let refreshed = try await load(loader, url: url, previous: initial)
        XCTAssertNotNil(refreshed.journalDiscoveryCache?.inactiveReason)
        XCTAssertEqual(refreshed.journalDiscoveryCache?.availability, .historyTooLarge)
        XCTAssertNil(refreshed.journalBaseline)
        let reads = await commands.journalReads
        let checks = await commands.enabledChecks
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(checks, 1)
        try "events-journal: true\n".write(to: url.appendingPathComponent(".beads/config.yaml"), atomically: true, encoding: .utf8)
        await commands.replaceJournal([try JournalRefreshFixture.record(sequence: 1, title: "Before")])
        let recovered = try await load(loader, url: url, previous: refreshed)
        XCTAssertNotNil(recovered.journalBaseline)
        XCTAssertNil(recovered.journalDiscoveryCache?.inactiveReason)
    }

    func testLargeBacklogUsesFullSnapshotAndHasItsOwnInactiveState() async throws {
        let (url, commands) = try fixture()
        let loader = BeadProjectLoader(commands: commands)
        let initial = try await load(loader, url: url)
        for sequence in 2...(BeadsJournalPage.recordLimit + 1) {
            await commands.append(try JournalRefreshFixture.record(sequence: Int64(sequence), title: "Burst edit"))
        }
        try await commands.changeWithoutJournal(title: "Complete snapshot after burst")
        let refreshed = try await load(loader, url: url, previous: initial, fast: true)
        XCTAssertEqual(refreshed.snapshot.issues.first?.title, "Complete snapshot after burst")
        XCTAssertFalse(refreshed.journalRefresh.requiresVerification)
        XCTAssertNil(refreshed.journalBaseline)
        XCTAssertEqual(refreshed.journalDiscoveryCache?.availability, .backlogTooLarge)
        let readsBefore = await commands.journalReads
        let next = try await load(loader, url: url, previous: refreshed)
        let readsAfter = await commands.journalReads
        XCTAssertEqual(readsAfter, readsBefore, "Do not repeatedly drain the same oversized backlog")
        XCTAssertEqual(next.journalDiscoveryCache?.availability, .backlogTooLarge)
    }

    func testDisabledCapabilityIsCachedAndDisabledFeedCannotUseOldBaseline() async throws {
        let (url, commands) = try fixture()
        let loader = BeadProjectLoader(commands: commands)
        let enabled = try await load(loader, url: url)
        await commands.setEnabled(false)
        try await commands.changeWithoutJournal(title: "No journal")
        let fallback = try await load(loader, url: url, previous: enabled, fast: true)
        XCTAssertFalse(fallback.journalRefresh.requiresVerification)
        XCTAssertEqual(fallback.snapshot.issues.first?.title, "No journal")
        let disabled = try await load(loader, url: url)
        _ = try await load(loader, url: url, previous: disabled)
        let checks = await commands.enabledChecks
        XCTAssertEqual(checks, 2, "The disabled result is cached too")
    }

    func testDuplicateIssueIDsRejectOptionalProjectionWithoutCrashing() async throws {
        let (url, commands) = try fixture()
        let loaded = try await load(BeadProjectLoader(commands: commands), url: url)
        var baseline = try XCTUnwrap(loaded.journalBaseline)
        baseline.snapshot.issues.append(try XCTUnwrap(baseline.snapshot.issues.first))
        XCTAssertThrowsError(try baseline.applying([
            try XCTUnwrap(baseline.anchor), try JournalRefreshFixture.record(sequence: 2, title: "Rejected")
        ]))
    }

    func testRedirectOrConfigurationChangePreventsReuse() async throws {
        for redirect in [false, true] {
            let (url, commands) = try fixture()
            let loader = BeadProjectLoader(commands: commands)
            let initial = try await load(loader, url: url)
            try await commands.change(title: "Resolved data", operation: "update")
            if redirect {
                let tracker = url.appendingPathComponent("routed-tracker")
                try FileManager.default.createDirectory(at: tracker, withIntermediateDirectories: true)
                await commands.setTracker(tracker)
            } else {
                try "events-journal: true\nexport.exclude_owners: other\n".write(
                    to: url.appendingPathComponent(".beads/config.yaml"), atomically: true, encoding: .utf8
                )
            }
            let refreshed = try await load(loader, url: url, baseline: initial.journalBaseline, fast: true)
            XCTAssertFalse(refreshed.journalRefresh.requiresVerification)
            XCTAssertEqual(refreshed.snapshot.issues.first?.title, "Resolved data")
            if redirect { XCTAssertEqual(refreshed.environment.beadsDirectoryURL.lastPathComponent, "routed-tracker") }
        }
    }

    func testFailedVerificationKeepsNewerMemoryAndDisablesFurtherFastReads() async throws {
        let (url, commands) = try fixture()
        let loader = BeadProjectLoader(commands: commands)
        let initial = try await load(loader, url: url)
        try await commands.change(title: "Newer than disk", operation: "update")
        let fast = try await load(loader, url: url, baseline: initial.journalBaseline, fast: true)
        await commands.setExportFailure(true)
        let failed = try await load(loader, url: url, baseline: fast.journalBaseline)
        XCTAssertEqual(failed.snapshot.issues.first?.title, "Newer than disk")
        XCTAssertNotNil(failed.snapshotRefreshWarning)
        XCTAssertEqual(failed.journalBaseline?.allowsIncrementalRefresh, false)
        await commands.setExportFailure(false)
        let recovered = try await load(loader, url: url, baseline: failed.journalBaseline, fast: true)
        XCTAssertFalse(recovered.journalRefresh.requiresVerification)
        XCTAssertNil(recovered.snapshotRefreshWarning)
        XCTAssertEqual(recovered.journalBaseline?.allowsIncrementalRefresh, true)
        XCTAssertEqual(recovered.journalBaseline?.hasProjectedChanges, false)
        await commands.setExportFailure(true)
        let laterFailure = try await load(loader, url: url, previous: recovered)
        XCTAssertFalse(laterFailure.journalRefresh.requiresVerification, "A successful full export retires the projection")
    }

    @MainActor
    func testOrdinaryExportFailureWithJournalEnabledDoesNotScheduleVerification() async throws {
        let (url, commands) = try fixture()
        let defaults = makeIsolatedUserDefaults()
        defaults.set(true, forKey: BeadazzlePreferenceKeys.usesExperimentalJournalRefresh(projectURL: url))
        let store = BeadStore(userDefaults: defaults, commands: commands)
        defer { store.project.cancelLifecycleWork() }
        store.openProject(url)
        try await waitForStoreToLoad(store, requiresVisibleRows: false)
        store.pauseDataSourceMonitoringForTrackerRecovery()
        store.setWorkspaceSceneActive(true, sceneID: UUID())
        let baseline = try XCTUnwrap(store.project.journalBaseline)
        XCTAssertFalse(baseline.hasProjectedChanges)
        await commands.setExportFailure(true)
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .mutation))
        let failed = try await load(BeadProjectLoader(commands: commands), url: url, baseline: baseline)
        guard case .none = failed.journalRefresh else { return XCTFail("Expected a normal snapshot fallback") }
        XCTAssertNotNil(failed.snapshotRefreshWarning)
        store.applyLoadedProject(failed, projectURL: url)
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Before")
        XCTAssertEqual(store.snapshotFreshness.state, .possiblyStale)
        XCTAssertFalse(store.snapshotFreshness.isJournalProjection)
        XCTAssertNil(store.project.journalVerificationDeadline)
        XCTAssertNil(store.project.journalVerificationTask)
    }

    func testDisabledFeatureDoesNotHoldJournalDataAfterExportFailure() async throws {
        let (url, commands) = try fixture()
        let loader = BeadProjectLoader(commands: commands)
        let initial = try await load(loader, url: url)
        try await commands.change(title: "Journal data", operation: "update")
        let fast = try await load(loader, url: url, previous: initial, fast: true)
        await commands.setExportFailure(true)
        let disabled = try await loader.refreshSnapshotAndLoadProject(
            projectURL: url, loadsDefinitionsIfMissing: false,
            usesJournalRefresh: false, journalBaseline: fast.journalBaseline
        )
        XCTAssertFalse(disabled.journalRefresh.requiresVerification)
        XCTAssertNil(disabled.journalBaseline)
        XCTAssertEqual(disabled.snapshot.issues.first?.title, "Before")
    }

    func testServerModeUsesExistingSnapshotPath() async throws {
        let (url, commands) = try fixture()
        await commands.setMode("server")
        let loaded = try await load(BeadProjectLoader(commands: commands), url: url)
        XCTAssertNil(loaded.journalBaseline)
        XCTAssertFalse(loaded.journalRefresh.requiresVerification)
        let reads = await commands.journalReads
        XCTAssertEqual(reads, 0)
    }

    func testDecoderRefusesDisabledMalformedAndFractionalSequenceOutput() throws {
        for output in [
            "note: the events journal is disabled for this workspace",
            "{\"seq\":1.5,\"op\":\"update\",\"issue_id\":\"bd-one\"}",
            "{\"seq\":true,\"op\":\"update\",\"issue_id\":\"bd-one\"}",
            "{\"seq\":1,\"op\":\"update\",\"issue_id\":\"\"}",
            "{\"error\":\"context canceled\"}"
        ] {
            XCTAssertThrowsError(try BeadsJournalPage.decode(output, exitStatus: 0))
        }
        let page = try BeadsJournalPage.decode(
            "{\"schema_version\":1,\"data\":{\"code\":\"events_journal_truncated\",\"head\":42}}",
            exitStatus: 1
        )
        guard case .truncated(let head) = page else { return XCTFail("Expected recovery window") }
        XCTAssertEqual(head, 42)
    }

    func testMalformedOrExportFilteredPayloadDoesNotReplaceIssue() async throws {
        let (url, commands) = try fixture()
        let initial = try await load(BeadProjectLoader(commands: commands), url: url)
        let baseline = try XCTUnwrap(initial.journalBaseline)
        let original = try XCTUnwrap(initial.snapshot.issues.first)
        let changes: [[String: Any]] = [
            ["description": 123], ["labels": [42]], ["priority": true],
            ["ephemeral": true], ["is_template": true], ["no_history": true],
            ["issue_type": "gate"], ["owner": "excluded@example.invalid"], ["updated_at": "bad-date"]
        ]
        for changed in changes {
            let record = try JournalRefreshFixture.record(sequence: 2, title: "Bad", fields: changed)
            XCTAssertThrowsError(try record.replacingFields(in: original))
            XCTAssertThrowsError(try baseline.applying([try XCTUnwrap(baseline.anchor), record]))
        }
    }

    @MainActor
    func testStorePreservesSelectionDraftAndRunsFullVerification() async throws {
        let (url, commands) = try fixture()
        let defaults = makeIsolatedUserDefaults()
        defaults.set(true, forKey: BeadazzlePreferenceKeys.usesExperimentalJournalRefresh(projectURL: url))
        let store = BeadStore(userDefaults: defaults, commands: commands, journalVerificationDelay: .milliseconds(40))
        store.openProject(url)
        try await waitForStoreToLoad(store, requiresVisibleRows: false)
        store.applyBookmark(.all)
        await store.waitForPendingQueryRecompute()
        store.setWorkspaceSceneActive(true, sceneID: UUID())
        store.select(["bd-one"])
        let issue = try XCTUnwrap(store.index.issue(with: "bd-one"))
        var draft = IssueDraft(issue: issue)
        draft.title = "Unsaved draft"
        store.updateIssueEditDraft(draft, for: issue)
        try await commands.change(title: "External edit", operation: "update")
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .externalMarker))
        _ = await store.refresh(reason: .reconcile, showsLoadingIndicator: false)?.value
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "External edit")
        XCTAssertEqual(store.selectedIDs, ["bd-one"])
        XCTAssertTrue(store.snapshotFreshness.isJournalProjection)
        XCTAssertNotNil(store.project.journalVerificationDeadline)
        try await commands.changeWithoutJournal(title: "Missed by journal")
        try await waitUntil("full verification", timeout: .seconds(5)) {
            store.index.issue(with: "bd-one")?.title == "Missed by journal"
        }
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Missed by journal")
        XCTAssertFalse(store.snapshotFreshness.isJournalProjection)
        XCTAssertNil(store.project.journalVerificationDeadline)
        XCTAssertEqual(store.issueEditDraft(for: issue).title, "Unsaved draft")
        store.project.cancelLifecycleWork()
    }

    @MainActor
    func testOptInIsPrivatePerProjectAndInactiveWindowDefersVerification() async throws {
        let (url, commands) = try fixture()
        let defaults = makeIsolatedUserDefaults()
        let store = BeadStore(userDefaults: defaults, commands: commands, journalVerificationDelay: .milliseconds(20))
        store.openProject(url)
        try await waitForStoreToLoad(store, requiresVisibleRows: false)
        XCTAssertFalse(store.usesExperimentalJournalRefresh)
        store.usesExperimentalJournalRefresh = true
        _ = await store.refreshTask?.value
        XCTAssertTrue(defaults.bool(forKey: BeadazzlePreferenceKeys.usesExperimentalJournalRefresh(projectURL: url)))
        try await commands.change(title: "Background edit", operation: "update")
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .externalMarker))
        _ = await store.refresh(reason: .reconcile, showsLoadingIndicator: false)?.value
        XCTAssertNotNil(store.project.journalVerificationDeadline)
        XCTAssertNil(store.project.journalVerificationTask)
        try await commands.changeWithoutJournal(title: "Verified on activation")
        store.setWorkspaceSceneActive(true, sceneID: UUID())
        try await waitUntil("activation verification", timeout: .seconds(5)) {
            store.index.issue(with: "bd-one")?.title == "Verified on activation"
        }
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Verified on activation")
        let (other, _) = try fixture()
        store.openProject(other)
        try await waitForStoreToLoad(store, requiresVisibleRows: false)
        XCTAssertFalse(store.usesExperimentalJournalRefresh)
        XCTAssertNil(store.project.journalVerificationTask)
        store.project.cancelLifecycleWork()
    }

    @MainActor
    func testPreferenceChangesAvoidMetadataReadsAndDisablingQueuesOneFullRefresh() async throws {
        let (url, commands) = try fixture()
        let store = BeadStore(userDefaults: makeIsolatedUserDefaults(), commands: commands)
        defer { store.project.cancelLifecycleWork() }
        store.openProject(url)
        try await waitForStoreToLoad(store, requiresVisibleRows: false)
        await store.semanticDefinitionsRefreshTask?.value
        store.pauseDataSourceMonitoringForTrackerRecovery()
        let contextBefore = await commands.contextLoads
        let definitionsBefore = await commands.definitionReads
        store.usesExperimentalJournalRefresh = true
        _ = await store.refreshTask?.value
        let contextAfter = await commands.contextLoads
        let definitionsAfter = await commands.definitionReads
        XCTAssertEqual(contextAfter, contextBefore)
        XCTAssertEqual(definitionsAfter, definitionsBefore)
        try await commands.change(title: "Keep displayed data", operation: "update")
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .externalMarker))
        _ = await store.refresh(reason: .reconcile, showsLoadingIndicator: false)?.value
        store.setWorkspaceSceneActive(true, sceneID: UUID())
        XCTAssertNotNil(store.project.journalVerificationTask)
        try await commands.changeWithoutJournal(title: "Full refresh after disabling")
        let exportsBefore = await commands.exports
        let callsBefore = await commands.commandCount
        store.usesExperimentalJournalRefresh = false
        let callsAfter = await commands.commandCount
        XCTAssertEqual(callsAfter, callsBefore)
        XCTAssertNil(store.project.journalBaseline)
        XCTAssertNil(store.project.journalDiscoveryCache)
        XCTAssertNil(store.project.journalVerificationTask)
        XCTAssertNil(store.project.journalVerificationDeadline)
        XCTAssertFalse(store.snapshotFreshness.isJournalProjection)
        XCTAssertEqual(store.snapshotFreshness.state, .possiblyStale)
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Keep displayed data")
        XCTAssertFalse(store.completeClaimedReconcileWithoutReload(
            projectURL: url, source: try XCTUnwrap(store.currentDataSource)
        ), "An unchanged disk file cannot verify data kept after the option was disabled")
        try await waitUntil("one-off full refresh") {
            store.index.issue(with: "bd-one")?.title == "Full refresh after disabling"
                && store.snapshotFreshness.state == .current
        }
        let exportsAfter = await commands.exports
        XCTAssertEqual(exportsAfter, exportsBefore + 1)
        XCTAssertNil(store.project.journalBaseline)
        XCTAssertNil(store.project.journalVerificationDeadline)
        XCTAssertNil(store.project.journalVerificationTask)
        XCTAssertFalse(store.reconcileState.hasPendingRequest)
    }

    @MainActor
    func testDisablingWithAutomaticRefreshOffDoesNotQueueAnExport() async throws {
        let (url, commands) = try fixture()
        let defaults = makeIsolatedUserDefaults()
        defaults.set(true, forKey: BeadazzlePreferenceKeys.usesExperimentalJournalRefresh(projectURL: url))
        let store = BeadStore(userDefaults: defaults, commands: commands)
        defer { store.project.cancelLifecycleWork() }
        store.openProject(url)
        try await waitForStoreToLoad(store, requiresVisibleRows: false)
        store.pauseDataSourceMonitoringForTrackerRecovery()
        try await commands.change(title: "Keep until manual refresh", operation: "update")
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .externalMarker))
        _ = await store.refresh(reason: .reconcile, showsLoadingIndicator: false)?.value
        store.automaticallyRefreshesExternalChanges = false
        let callsBefore = await commands.commandCount
        store.usesExperimentalJournalRefresh = false
        let callsAfter = await commands.commandCount
        XCTAssertEqual(callsAfter, callsBefore)
        XCTAssertFalse(store.reconcileState.hasPendingRequest)
        XCTAssertNil(store.project.journalVerificationDeadline)
        XCTAssertNil(store.project.journalVerificationTask)
        XCTAssertEqual(store.snapshotFreshness.state, .possiblyStale)
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Keep until manual refresh")
    }

    @MainActor
    func testDisabledAutomaticRefreshDoesNotExportAtOpenAndServerModeSkipsJournalWork() async throws {
        for server in [false, true] {
            let (url, commands) = try fixture()
            if server { await commands.setMode("server") }
            let defaults = makeIsolatedUserDefaults()
            defaults.set(true, forKey: BeadazzlePreferenceKeys.usesExperimentalJournalRefresh(projectURL: url))
            defaults.set(server, forKey: BeadazzlePreferenceKeys.automaticallyRefreshesExternalChanges(projectURL: url))
            let store = BeadStore(userDefaults: defaults, commands: commands)
            store.openProject(url)
            try await waitForStoreToLoad(store, requiresVisibleRows: false)
            store.pauseDataSourceMonitoringForTrackerRecovery()
            let exports = await commands.exports
            XCTAssertEqual(exports, server ? 1 : 0)
            let contextBefore = await commands.contextLoads
            XCTAssertTrue(store.beginImmediateReconcile(trigger: .externalMarker))
            _ = await store.refresh(reason: .reconcile, showsLoadingIndicator: false)?.value
            let contextAfter = await commands.contextLoads
            let checks = await commands.enabledChecks
            let reads = await commands.journalReads
            XCTAssertEqual(contextAfter, contextBefore)
            XCTAssertEqual(checks, 0)
            XCTAssertEqual(reads, 0)
            store.project.cancelLifecycleWork()
        }
    }

    @MainActor
    func testDisablingDuringReadCannotReinstallJournalState() async throws {
        let (url, commands) = try fixture()
        let defaults = makeIsolatedUserDefaults()
        defaults.set(true, forKey: BeadazzlePreferenceKeys.usesExperimentalJournalRefresh(projectURL: url))
        let store = BeadStore(userDefaults: defaults, commands: commands)
        defer { store.project.cancelLifecycleWork() }
        store.openProject(url)
        try await waitForStoreToLoad(store, requiresVisibleRows: false)
        store.pauseDataSourceMonitoringForTrackerRecovery()
        try await commands.change(title: "In flight", operation: "update")
        await commands.pauseNextJournalRead()
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .externalMarker))
        let refresh = try XCTUnwrap(store.refresh(reason: .reconcile, showsLoadingIndicator: false))
        try await waitUntil { await commands.isJournalReadPaused }
        store.usesExperimentalJournalRefresh = false
        await commands.resumeJournalRead()
        let accepted = await refresh.value
        XCTAssertFalse(accepted)
        XCTAssertNil(store.project.journalBaseline)
        XCTAssertNil(store.project.journalVerificationDeadline)
        XCTAssertFalse(store.snapshotFreshness.isJournalProjection)
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Before")
        try await waitUntil("full refresh after disabling during a read") {
            store.index.issue(with: "bd-one")?.title == "In flight"
        }
        XCTAssertFalse(store.snapshotFreshness.isJournalProjection)
        XCTAssertNil(store.project.journalBaseline)
        XCTAssertNil(store.project.journalVerificationDeadline)
    }

    @MainActor
    func testInterruptedJournalReadDoesNotAdvanceCursorOrReplaceLocalWrite() async throws {
        let (url, commands) = try fixture()
        let defaults = makeIsolatedUserDefaults()
        defaults.set(true, forKey: BeadazzlePreferenceKeys.usesExperimentalJournalRefresh(projectURL: url))
        let store = BeadStore(userDefaults: defaults, commands: commands)
        defer { store.project.cancelLifecycleWork() }
        store.openProject(url)
        try await waitForStoreToLoad(store, requiresVisibleRows: false)
        store.pauseDataSourceMonitoringForTrackerRecovery()
        try await commands.change(title: "Interrupted external edit", operation: "update")
        await commands.pauseNextJournalRead()
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .externalMarker))
        let refresh = try XCTUnwrap(store.refresh(reason: .reconcile, showsLoadingIndicator: false))
        try await waitUntil("paused journal read", timeout: .seconds(5)) { await commands.isJournalReadPaused }
        let isPaused = await commands.isJournalReadPaused
        XCTAssertTrue(isPaused)
        let generation = store.beginMutation()
        await commands.resumeJournalRead()
        let accepted = await refresh.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(store.project.journalBaseline?.cursor, 1)
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Before")

        try await commands.change(title: "Local saved edit", operation: "update")
        store.requestReconcile(trigger: .mutation)
        store.endMutation(generation: generation)
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .mutation))
        _ = await store.refresh(reason: .reconcile, showsLoadingIndicator: false)?.value
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Local saved edit")
        XCTAssertFalse(store.snapshotFreshness.isJournalProjection)
        let exports = await commands.exports
        XCTAssertEqual(exports, 2, "App writes must still use a full export")
    }

    @MainActor
    func testUnchangedDiskDoesNotVerifyJournalButExplicitSyncSnapshotDoes() async throws {
        let (url, commands) = try fixture()
        let defaults = makeIsolatedUserDefaults()
        defaults.set(true, forKey: BeadazzlePreferenceKeys.usesExperimentalJournalRefresh(projectURL: url))
        let store = BeadStore(userDefaults: defaults, commands: commands)
        defer { store.project.cancelLifecycleWork() }
        store.openProject(url)
        try await waitForStoreToLoad(store, requiresVisibleRows: false)
        store.pauseDataSourceMonitoringForTrackerRecovery()
        let disk = try BeadsSnapshotReader().loadProject(projectURL: url)
        try await commands.change(title: "Newer than disk", operation: "update")
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .externalMarker))
        _ = await store.refresh(reason: .reconcile, showsLoadingIndicator: false)?.value
        _ = await store.refresh(reason: .dataSourceChanged, showsLoadingIndicator: false)?.value
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Newer than disk")
        XCTAssertTrue(store.snapshotFreshness.isJournalProjection)

        // A sync can restore the old database contents. Its byte-identical export
        // still supersedes the newer journal view held in memory.
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .remoteSync))
        XCTAssertFalse(store.completeClaimedReconcileWithoutReload(projectURL: url, source: disk.source))
        _ = await store.refresh(reason: .dataSourceChanged, showsLoadingIndicator: false, preparedSnapshot: disk)?.value
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Before")
        XCTAssertFalse(store.snapshotFreshness.isJournalProjection)
        XCTAssertNil(store.project.journalVerificationDeadline)
        XCTAssertNil(store.project.journalBaseline)
        let readsBefore = await commands.journalSince.count
        try await commands.change(title: "After sync", operation: "update")
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .externalMarker))
        _ = await store.refresh(reason: .reconcile, showsLoadingIndicator: false)?.value
        let reads = await commands.journalSince
        XCTAssertEqual(Array(reads.dropFirst(readsBefore)), [1, 2], "Sync keeps the discovery position without reusing its old projection")
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "After sync")
        XCTAssertFalse(store.snapshotFreshness.isJournalProjection)
    }

    @MainActor
    func testVerificationTaskCanRunAgainAfterEligibilityChangesDuringSleep() async throws {
        let (url, commands) = try fixture()
        let defaults = makeIsolatedUserDefaults()
        defaults.set(true, forKey: BeadazzlePreferenceKeys.usesExperimentalJournalRefresh(projectURL: url))
        let store = BeadStore(userDefaults: defaults, commands: commands, journalVerificationDelay: .milliseconds(50))
        defer { store.project.cancelLifecycleWork() }
        store.openProject(url)
        try await waitForStoreToLoad(store, requiresVisibleRows: false)
        store.pauseDataSourceMonitoringForTrackerRecovery()
        let embedded = try XCTUnwrap(store.projectEnvironment)
        try await commands.change(title: "Journal edit", operation: "update")
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .externalMarker))
        _ = await store.refresh(reason: .reconcile, showsLoadingIndicator: false)?.value
        store.setWorkspaceSceneActive(true, sceneID: UUID())
        XCTAssertNotNil(store.project.journalVerificationTask)
        // Recheck eligibility when the task wakes, not only when it is scheduled.
        var context = embedded.context
        context.doltMode = "server"
        store._projectEnvironment = try BeadsProjectEnvironment(context: context, projectURL: url)
        try await waitUntil { store.project.journalVerificationTask == nil }
        store._projectEnvironment = embedded
        try await commands.changeWithoutJournal(title: "Later full check")
        store.scheduleJournalVerificationIfNeeded()
        try await waitUntil { store.index.issue(with: "bd-one")?.title == "Later full check" }
        XCTAssertNil(store.project.journalVerificationDeadline)
    }

    @MainActor
    func testFailedBackgroundVerificationRetriesWithoutRollingBackData() async throws {
        let (url, commands) = try fixture()
        let defaults = makeIsolatedUserDefaults()
        defaults.set(true, forKey: BeadazzlePreferenceKeys.usesExperimentalJournalRefresh(projectURL: url))
        let store = BeadStore(userDefaults: defaults, commands: commands, journalVerificationDelay: .milliseconds(20))
        defer { store.project.cancelLifecycleWork() }
        store.openProject(url)
        try await waitForStoreToLoad(store, requiresVisibleRows: false)
        store.pauseDataSourceMonitoringForTrackerRecovery()
        store.setWorkspaceSceneActive(true, sceneID: UUID())
        try await commands.change(title: "Newer than disk", operation: "update")
        XCTAssertTrue(store.beginImmediateReconcile(trigger: .externalMarker))
        _ = await store.refresh(reason: .reconcile, showsLoadingIndicator: false)?.value
        await commands.setExportFailure(true)
        try await waitUntil("failed verification", timeout: .seconds(5)) {
            store.project.journalBaseline?.allowsIncrementalRefresh == false
        }
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Newer than disk")
        XCTAssertEqual(store.snapshotFreshness.state, .possiblyStale)
        XCTAssertEqual(store.project.journalBaseline?.allowsIncrementalRefresh, false)
        _ = await store.refresh(reason: .dataSourceChanged, showsLoadingIndicator: false)?.value
        XCTAssertEqual(store.snapshotFreshness.state, .possiblyStale, "An unchanged-file event cannot clear a failed check")
        XCTAssertTrue(store.snapshotFreshness.isJournalProjection)
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Newer than disk")
        await commands.setExportFailure(false)
        try await commands.changeWithoutJournal(title: "Recovered")
        try await waitUntil("recovered verification", timeout: .seconds(5)) {
            store.index.issue(with: "bd-one")?.title == "Recovered"
        }
        XCTAssertEqual(store.index.issue(with: "bd-one")?.title, "Recovered")
        XCTAssertNil(store.project.journalVerificationDeadline)
    }

    private func load(
        _ loader: BeadProjectLoader, url: URL, baseline: BeadsJournalBaseline? = nil,
        previous: LoadedProject? = nil, fast: Bool = false
    ) async throws -> LoadedProject {
        try await loader.refreshSnapshotAndLoadProject(
            projectURL: url, cachedEnvironment: previous?.environment, loadsDefinitionsIfMissing: false,
            usesJournalRefresh: true, mayApplyJournal: fast,
            journalBaseline: baseline ?? previous?.journalBaseline,
            journalDiscoveryCache: previous?.journalDiscoveryCache
        )
    }

    private func fixture() throws -> (URL, JournalRefreshTestCommands) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JournalRefresh-\(UUID().uuidString)")
        let tracker = url.appendingPathComponent(".beads")
        try FileManager.default.createDirectory(at: tracker, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try JournalRefreshFixture.snapshot(title: "Before").write(
            to: tracker.appendingPathComponent("issues.jsonl"), atomically: true, encoding: .utf8
        )
        return (url, try JournalRefreshTestCommands())
    }
}

private enum JournalRefreshFixture {
    static func snapshot(title: String, commentCount: Int = 2) throws -> String {
        var issue = fields(title: title)
        issue["comment_count"] = commentCount
        issue["dependency_count"] = 1
        issue["dependencies"] = [["issue_id": "bd-one", "depends_on_id": "bd-blocker", "type": "blocks"]]
        return String(decoding: try JSONSerialization.data(withJSONObject: issue), as: UTF8.self) + "\n"
    }

    static func fields(title: String) -> [String: Any] {
        ["id": "bd-one", "title": title, "description": "Body", "status": "open", "priority": 2,
         "issue_type": "task", "created_at": "2026-10-01T10:00:00Z", "updated_at": "2026-10-04T10:00:00Z"]
    }

    static func record(sequence: Int64, title: String, operation: String = "update", fields: [String: Any] = [:]) throws -> BeadsJournalRecord {
        let issue = self.fields(title: title).merging(fields) { _, new in new }
        return try BeadsJournalRecord(data: JSONSerialization.data(withJSONObject: [
            "seq": sequence, "op": operation, "issue_id": "bd-one", "issue": issue
        ], options: [.sortedKeys]))
    }
}

private actor JournalRefreshTestCommands: BeadsCommanding {
    private var records: [BeadsJournalRecord]
    private var snapshot: String
    private var enabled = true
    private var exportFails = false
    private var changesDuringExport = false
    private var resetsDuringExport = false
    private var pausesNextRead = false
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var truncationHead: Int64?
    private var tracker: URL?
    private var mode = "embedded"
    private(set) var exports = 0
    private(set) var journalReads = 0
    private(set) var journalSince: [Int64] = []
    private(set) var enabledChecks = 0
    private(set) var contextLoads = 0
    private(set) var definitionReads = 0
    var commandCount: Int { exports + journalReads + enabledChecks + contextLoads + definitionReads }

    init() throws {
        records = [try JournalRefreshFixture.record(sequence: 1, title: "Before")]
        snapshot = try JournalRefreshFixture.snapshot(title: "Before")
    }
    func setEnabled(_ value: Bool) { enabled = value }
    func setExportFailure(_ value: Bool) { exportFails = value }
    func setTruncationHead(_ value: Int64) { truncationHead = value }
    func setTracker(_ value: URL) { tracker = value }
    func setMode(_ value: String) { mode = value }
    func changeDuringNextExport() { changesDuringExport = true }
    func resetDuringNextExport() { resetsDuringExport = true }
    func pauseNextJournalRead() { pausesNextRead = true }
    var isJournalReadPaused: Bool { readContinuation != nil }
    func resumeJournalRead() {
        readContinuation?.resume()
        readContinuation = nil
    }
    func replaceJournal(_ value: [BeadsJournalRecord]) { records = value }
    func append(_ record: BeadsJournalRecord) { records.append(record) }
    func change(title: String, operation: String, commentCount: Int = 2) throws {
        snapshot = try JournalRefreshFixture.snapshot(title: title, commentCount: commentCount)
        records.append(try JournalRefreshFixture.record(sequence: (records.last?.sequence ?? 0) + 1, title: title, operation: operation))
    }
    func changeWithoutJournal(title: String) throws { snapshot = try JournalRefreshFixture.snapshot(title: title) }
    func isEventsJournalEnabled(projectURL: URL) async throws -> Bool {
        enabledChecks += 1
        return enabled
    }
    func readEventsJournal(projectURL: URL, since: Int64, limit: Int) async throws -> BeadsJournalPage {
        journalReads += 1
        journalSince.append(since)
        guard enabled else { throw BeadsJournalError.unavailable }
        if let truncationHead { return .truncated(head: truncationHead) }
        let page = BeadsJournalPage.records(Array(records.filter { $0.sequence > since }.prefix(limit)))
        if pausesNextRead {
            pausesNextRead = false
            await withCheckedContinuation { readContinuation = $0 }
        }
        return page
    }
    func exportReadableSnapshot(projectURL: URL) async throws {
        try await exportReadableSnapshot(projectURL: projectURL, beadsDirectoryURL: tracker ?? projectURL.appendingPathComponent(".beads"))
    }
    func exportReadableSnapshot(projectURL: URL, beadsDirectoryURL: URL) async throws {
        exports += 1
        if exportFails { throw BeadsJournalError.unavailable }
        try snapshot.write(to: beadsDirectoryURL.appendingPathComponent("issues.jsonl"), atomically: true, encoding: .utf8)
        if changesDuringExport {
            changesDuringExport = false
            try change(title: "Changed during export", operation: "update")
        }
        if resetsDuringExport {
            resetsDuringExport = false
            records = [try JournalRefreshFixture.record(sequence: 1, title: "Reset during export")]
            try changeWithoutJournal(title: "Reset during export")
        }
    }
    func loadProjectContext(projectURL: URL) async throws -> BeadsProjectContext {
        contextLoads += 1
        var context = BeadsProjectContext.testContext(projectURL: projectURL)
        context.doltMode = mode
        if let tracker { context.beadsDirectory = tracker.path; context.isRedirected = true }
        return context
    }
    func create(projectURL: URL, draft: IssueDraft) async throws -> String { "bd-created" }
    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws {}
    func updateMetadata(projectURL: URL, issueID: String, assignee: String?, labels: [String]?, originalLabels: [String]?, dueAt: IssueMetadataDateUpdate, deferUntil: IssueMetadataDateUpdate) async throws {}
    func close(projectURL: URL, ids: [String], reason: String?) async throws {}
    func delete(projectURL: URL, ids: [String]) async throws {}
    func bulkUpdate(projectURL: URL, ids: [String], status: String?, type: String?, priority: Int?, deferUntil: IssueMetadataDateUpdate) async throws {}
    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {}
    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {}
    func addComment(projectURL: URL, issueID: String, text: String) async throws {}
    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition] { definitionReads += 1; return [] }
    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] { definitionReads += 1; return [] }
    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws {}
    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws {}
}
