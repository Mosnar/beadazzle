import XCTest
@testable import Beadazzle

@MainActor
final class BeadStoreAsyncMutationTests: XCTestCase {
    func testProjectSwitchCancelsInitializeBeadsCommand() async throws {
        let firstProjectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadStoreInitializeTests-\(UUID().uuidString)", isDirectory: true)
        let secondProjectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadStoreInitializeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: firstProjectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProjectURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: firstProjectURL)
            try? FileManager.default.removeItem(at: secondProjectURL)
        }

        let commands = RecordingBeadsCommands()
        await commands.setInitializationDelay(.seconds(10))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        store.initializeBeads(options: BeadsInitOptions())
        try await waitUntilAsync { await commands.initializeCalls.count == 1 }

        store.openProject(secondProjectURL)
        try await waitUntilAsync { await commands.initializeWasCancelled }

        XCTAssertEqual(store.projectURL, secondProjectURL)
        XCTAssertFalse(store.isInitializingBeads)
        XCTAssertNil(store.initializationTask)
    }

    func testBulkSetReturnsTrueAndInvokesCommandOnSuccess() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        XCTAssertNil(store.refreshTask)
        store.select(["bd-1"])

        let succeeded = await store.bulkSet(status: "closed")

        XCTAssertTrue(succeeded)
        let calls = await commands.bulkUpdateCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.ids, ["bd-1"])
        XCTAssertEqual(calls.first?.status, "closed")
        XCTAssertNil(store.lastError)
    }

    func testBulkSetCanTargetIssueIDsWithoutChangingSelection() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-1", title: "One"))
            \(issueLine(id: "bd-2", title: "Two"))
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil {
            !store.isLoading
                && store.issue(with: "bd-1") != nil
                && store.issue(with: "bd-2") != nil
        }
        store.select(["bd-1"])

        let succeeded = await store.bulkSet(issueIDs: ["bd-2"], status: "closed")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.selectedIDs, Set(["bd-1"]))
        XCTAssertEqual(store.issue(with: "bd-2")?.status, "closed")
        let calls = await commands.bulkUpdateCalls
        XCTAssertEqual(calls.first?.ids, ["bd-2"])
    }

    func testCompletionActionTitlesUseReopenForClosedSelections() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-open", title: "Open"))
            \(issueLine(id: "bd-blocked", title: "Blocked", status: "blocked"))
            \(issueLine(id: "bd-epic", title: "Epic", issueType: "epic"))
            \(closedIssueLine(id: "bd-closed", title: "Closed"))
            \(closedIssueLine(id: "bd-done", title: "Done"))
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-done") != nil }

        XCTAssertEqual(store.completionActionTitle(for: ["bd-open"]), "Close Bead...")
        XCTAssertEqual(store.completionActionTitle(for: ["bd-closed"]), "Reopen Bead")
        XCTAssertEqual(store.completionActionTitle(for: ["bd-closed", "bd-done"]), "Reopen Selected")
        XCTAssertEqual(store.completionActionTitle(for: ["bd-open", "bd-closed"]), "Close Open Selected...")

        XCTAssertTrue(store.canCreateGate(blocking: try XCTUnwrap(store.issue(with: "bd-open"))))
        XCTAssertTrue(store.canCreateGate(blocking: try XCTUnwrap(store.issue(with: "bd-blocked"))))
        XCTAssertFalse(store.canCreateGate(blocking: try XCTUnwrap(store.issue(with: "bd-epic"))))
        XCTAssertFalse(store.canCreateGate(blocking: try XCTUnwrap(store.issue(with: "bd-closed"))))
    }

    func testRelationshipQuickCreateTypeOptionsFollowEpicTier() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-task", title: "Task"))
            \(issueLine(id: "bd-epic", title: "Epic", issueType: "epic"))
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-epic") != nil }

        let taskOptions = store.beadPickerQuickCreateTypeOptions(
            action: .addBlockedBy(issueID: "bd-task"),
            including: nil
        )
        let epicOptions = store.beadPickerQuickCreateTypeOptions(
            action: .addBlockedBy(issueID: "bd-epic"),
            including: nil
        )
        let epicDefault = store.beadPickerDefaultDraft(
            for: .blockedBy(issue: try XCTUnwrap(store.issue(with: "bd-epic")))
        )

        XCTAssertFalse(taskOptions.contains("epic"))
        XCTAssertEqual(Set(epicOptions), ["epic"])
        XCTAssertEqual(epicDefault.issueType, "epic")
    }

    func testReopenClosedIssueUsesOpenStatusAndClearsClosedAtOptimistically() async throws {
        let projectURL = try makeProject(closedIssueLine(id: "bd-1", title: "Closed"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let succeeded = await store.reopen(issueIDs: ["bd-1"])

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.status, "open")
        XCTAssertNil(store.issue(with: "bd-1")?.closedAt)
        let calls = await commands.bulkUpdateCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-1"]])
        XCTAssertEqual(calls.map(\.status), ["open"])
    }

    func testReopenBlockedIssueUsesOpenStatusWithoutDoneFilter() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-blocked", title: "Blocked", status: "blocked"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-blocked") != nil }

        let succeeded = await store.reopenBlockedIssue(issueID: "bd-blocked")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.issue(with: "bd-blocked")?.status, "open")
        let calls = await commands.bulkUpdateCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-blocked"]])
        XCTAssertEqual(calls.map(\.status), ["open"])
    }

    func testBulkSetNonDoneStatusClearsClosedAtOptimistically() async throws {
        let projectURL = try makeProject(closedIssueLine(id: "bd-1", title: "Closed"))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let succeeded = await store.bulkSet(issueIDs: ["bd-1"], status: "deferred")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.status, "deferred")
        XCTAssertNil(store.issue(with: "bd-1")?.closedAt)
    }

    func testBulkSetDeferredStatusCanSetDeferredDateOptimistically() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateDelay(.milliseconds(400))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let deferUntil = try XCTUnwrap(BeadFormatters.parseDate("2026-08-01"))

        let task = Task { @MainActor in
            await store.bulkSet(
                issueIDs: ["bd-1"],
                status: "deferred",
                deferUntil: .set(deferUntil)
            )
        }

        try await waitUntil {
            store.issue(with: "bd-1")?.status == "deferred"
                && store.issue(with: "bd-1")?.deferUntil == deferUntil
        }
        let callsBeforeCommandCompletes = await commands.bulkUpdateCalls
        XCTAssertTrue(callsBeforeCommandCompletes.isEmpty)

        let succeeded = await task.value
        XCTAssertTrue(succeeded)
        let calls = await commands.bulkUpdateCalls
        XCTAssertEqual(calls.first?.status, "deferred")
        XCTAssertEqual(calls.first?.deferUntil, .set(deferUntil))
        let metadataCalls = await commands.metadataUpdateCalls
        XCTAssertTrue(metadataCalls.isEmpty)
    }

    func testBulkSetDeferredStatusCanClearExistingDeferredDate() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","defer_until":"2026-07-11","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let succeeded = await store.bulkSet(
            issueIDs: ["bd-1"],
            status: "deferred",
            deferUntil: .set(nil)
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.status, "deferred")
        XCTAssertNil(store.issue(with: "bd-1")?.deferUntil)
        let calls = await commands.bulkUpdateCalls
        XCTAssertEqual(calls.first?.deferUntil, .set(nil))
    }

    func testBulkSetDeferredStatusRollsBackStatusAndDeferredDateOnFailure() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","defer_until":"2026-07-11","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateError(NSError(domain: "BeadStoreAsyncMutationTests", code: 1))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let originalDate = store.issue(with: "bd-1")?.deferUntil
        let nextDate = try XCTUnwrap(BeadFormatters.parseDate("2026-08-01"))

        let succeeded = await store.bulkSet(
            issueIDs: ["bd-1"],
            status: "deferred",
            deferUntil: .set(nextDate)
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.status, "open")
        XCTAssertEqual(store.issue(with: "bd-1")?.deferUntil, originalDate)
    }

    func testMutationAppliesOptimisticallyBeforeCommandCompletesWithoutLoadingIndicator() async throws {
        // The change must be visible the instant the user makes it — before `bd` returns —
        // and with no loading indicator.
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateDelay(.milliseconds(400))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.select(["bd-1"])

        let task = Task { @MainActor in await store.bulkSet(status: "closed") }
        // Optimistic status lands well before the 400ms command completes.
        try await waitUntil { store.issue(with: "bd-1")?.status == "closed" }
        XCTAssertFalse(store.isLoading)

        let succeeded = await task.value
        XCTAssertTrue(succeeded)
    }

    func testPriorityMutationUpdatesSortedRowsBeforeCommandCompletes() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-high", title: "High", priority: 1))
            \(issueLine(id: "bd-low", title: "Low", priority: 3))
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateDelay(.milliseconds(400))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-low") != nil }
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-high", "bd-low"])

        let task = Task { @MainActor in await store.bulkSet(issueIDs: ["bd-low"], priority: 0) }

        try await waitUntil { store.issue(with: "bd-low")?.priority == 0 }
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-low", "bd-high"])
        XCTAssertFalse(store.isLoading)

        let callsBeforeCommandCompletes = await commands.bulkUpdateCalls
        XCTAssertTrue(callsBeforeCommandCompletes.isEmpty)
        let succeeded = await task.value
        XCTAssertTrue(succeeded)
    }

    func testMetadataUpdateAppliesAssigneeLabelsAndDatesOptimisticallyWithoutSavingDraftText() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"Saved title","description":"Saved description","design":"Saved design","acceptance_criteria":"Saved acceptance","notes":"Saved notes","status":"open","priority":1,"issue_type":"task","assignee":"Before","labels":["old"],"due_at":"2026-07-10","defer_until":"2026-07-11","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setUpdateDelay(.milliseconds(400))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let dueAt = try XCTUnwrap(BeadFormatters.parseDate("2026-07-15"))
        let task = Task { @MainActor in
            await store.updateMetadata(
                issueID: "bd-1",
                assignee: "Sasha",
                labels: ["new", "area:ui"],
                dueAt: .set(dueAt),
                deferUntil: .set(nil)
            )
        }

        try await waitUntil {
            store.issue(with: "bd-1")?.assignee == "Sasha"
                && store.issue(with: "bd-1")?.labels == ["new", "area:ui"]
                && store.issue(with: "bd-1")?.dueAt == dueAt
                && store.issue(with: "bd-1")?.deferUntil == nil
        }
        let callsBeforeCommandCompletes = await commands.metadataUpdateCalls
        XCTAssertTrue(callsBeforeCommandCompletes.isEmpty)

        let succeeded = await task.value
        XCTAssertTrue(succeeded)
        let genericUpdateCalls = await commands.updateCalls
        XCTAssertTrue(genericUpdateCalls.isEmpty)
        let metadataUpdateCalls = await commands.metadataUpdateCalls
        let metadataCall = try XCTUnwrap(metadataUpdateCalls.first)
        XCTAssertEqual(metadataCall.issueID, "bd-1")
        XCTAssertEqual(metadataCall.assignee, "Sasha")
        XCTAssertEqual(metadataCall.labels, ["new", "area:ui"])
        XCTAssertEqual(metadataCall.originalLabels, ["old"])
        XCTAssertEqual(metadataCall.dueAt, .set(dueAt))
        XCTAssertEqual(metadataCall.deferUntil, .set(nil))
    }

    func testRapidMetadataUpdatesWriteInUserOrder() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(400), nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let firstTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", labels: ["first"])
        }
        try await waitUntil { store.issue(with: "bd-1")?.labels == ["first"] }

        let secondTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", labels: ["second"])
        }
        try await waitUntil { store.issue(with: "bd-1")?.labels == ["second"] }
        let callsBeforeFirstWriteCompletes = await commands.metadataUpdateCalls
        XCTAssertTrue(callsBeforeFirstWriteCompletes.isEmpty)

        let firstSucceeded = await firstTask.value
        let secondSucceeded = await secondTask.value
        XCTAssertTrue(firstSucceeded)
        XCTAssertTrue(secondSucceeded)
        let metadataUpdateCalls = await commands.metadataUpdateCalls
        XCTAssertEqual(metadataUpdateCalls.map { $0.labels ?? [] }, [["first"], ["second"]])
    }

    func testRapidFailedMetadataUpdatesRestoreTheLastConfirmedAssignee() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","assignee":"Before","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(400), nil])
        await commands.setUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let firstTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", assignee: "First")
        }
        try await waitUntil { store.issue(with: "bd-1")?.assignee == "First" }

        let secondTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", assignee: "Second")
        }
        try await waitUntil { store.issue(with: "bd-1")?.assignee == "Second" }

        let firstSucceeded = await firstTask.value
        let secondSucceeded = await secondTask.value
        XCTAssertFalse(firstSucceeded)
        XCTAssertFalse(secondSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.assignee, "Before")
    }

    func testRapidMetadataUpdatesKeepALaterSuccessWhenAnEarlierWriteFails() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","assignee":"Before","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(400), nil])
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed, nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let firstTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", assignee: "First")
        }
        try await waitUntil { store.issue(with: "bd-1")?.assignee == "First" }

        let secondTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", assignee: "Second")
        }
        try await waitUntil { store.issue(with: "bd-1")?.assignee == "Second" }

        let firstSucceeded = await firstTask.value
        let secondSucceeded = await secondTask.value
        XCTAssertFalse(firstSucceeded)
        XCTAssertTrue(secondSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.assignee, "Second")
    }

    func testRapidMetadataUpdatesRetainAnEarlierSuccessWhenALaterWriteFails() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","assignee":"Before","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(400), nil])
        await commands.setMetadataUpdateErrors([nil, StoreMutationTestError.commandFailed])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let firstTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", assignee: "First")
        }
        try await waitUntil { store.issue(with: "bd-1")?.assignee == "First" }

        let secondTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", assignee: "Second")
        }
        try await waitUntil { store.issue(with: "bd-1")?.assignee == "Second" }

        let firstSucceeded = await firstTask.value
        let secondSucceeded = await secondTask.value
        XCTAssertTrue(firstSucceeded)
        XCTAssertFalse(secondSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.assignee, "First")
    }

    func testMetadataSettlementPreservesAnUnrelatedOptimisticSave() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","assignee":"Before","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(400)])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let metadataTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", assignee: "Sasha")
        }
        try await waitUntil { store.issue(with: "bd-1")?.assignee == "Sasha" }

        var draft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        draft.title = "Updated"
        let saveTask = Task { @MainActor in
            await store.save(draft)
        }
        try await waitUntil { store.issue(with: "bd-1")?.title == "Updated" }

        let metadataSucceeded = await metadataTask.value
        let saveSucceeded = await saveTask.value
        XCTAssertTrue(metadataSucceeded)
        XCTAssertTrue(saveSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.assignee, "Sasha")
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Updated")
    }

    func testFailedLabelReplacementThenClearUsesEveryPossiblePersistedLabel() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(400), nil])
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed, nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let replacementTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", labels: ["new"])
        }
        try await waitUntil { store.issue(with: "bd-1")?.labels == ["new"] }

        let clearTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", labels: [])
        }
        try await waitUntil { store.issue(with: "bd-1")?.labels == [] }

        let replacementSucceeded = await replacementTask.value
        let clearSucceeded = await clearTask.value
        let metadataUpdateCalls = await commands.metadataUpdateCalls
        XCTAssertFalse(replacementSucceeded)
        XCTAssertTrue(clearSucceeded)
        let clearCall = try XCTUnwrap(metadataUpdateCalls.last)
        XCTAssertEqual(Set(clearCall.originalLabels ?? []), Set(["old", "new"]))
    }

    func testRefreshDefersDuringPendingLabelWriteAndRetainsClearCandidates() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(400), nil])
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed, nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let replacementTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", labels: ["new"])
        }
        try await waitUntil { store.issue(with: "bd-1")?.labels == ["new"] }

        let exportsBeforeRefresh = await commands.exportCallCount
        store.refresh()
        try await Task.sleep(for: .milliseconds(100))
        let exportsDuringMutation = await commands.exportCallCount
        XCTAssertEqual(exportsDuringMutation, exportsBeforeRefresh)
        XCTAssertEqual(store.issue(with: "bd-1")?.labels, ["new"])

        let clearTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", labels: [])
        }
        let replacementSucceeded = await replacementTask.value
        let clearSucceeded = await clearTask.value
        let metadataUpdateCalls = await commands.metadataUpdateCalls
        XCTAssertFalse(replacementSucceeded)
        XCTAssertTrue(clearSucceeded)
        let clearCall = try XCTUnwrap(metadataUpdateCalls.last)
        XCTAssertEqual(Set(clearCall.originalLabels ?? []), Set(["old", "new"]))
    }

    func testRefreshPreservesMetadataSettledAfterLoadBegan() async throws {
        let projectURL = try makeProject(
            #"{"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}"#
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let definitionCallsBeforeRefresh = await commands.definitionLoadCallCount
        await commands.setDefinitionLoadDelay(.milliseconds(300))

        store.refresh()
        try await waitUntilAsync {
            await commands.definitionLoadCallCount >= definitionCallsBeforeRefresh + 2
        }
        let updateSucceeded = await store.updateMetadata(issueID: "bd-1", labels: ["new"])
        await commands.setDefinitionLoadDelay(nil)
        try await waitUntil { !store.isLoading }

        XCTAssertTrue(updateSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.labels, ["new"])
    }

    func testSettledFailedLabelReplacementRetainsPossibleLabelsForImmediateClear() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed, nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let replacementSucceeded = await store.updateMetadata(issueID: "bd-1", labels: ["new"])
        XCTAssertFalse(replacementSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.labels, ["old"])
        XCTAssertEqual(
            Set(store.mutations.possiblyPersistedLabels(for: "bd-1")),
            Set(["old", "new"])
        )

        let clearSucceeded = await store.updateMetadata(issueID: "bd-1", labels: [])
        XCTAssertTrue(clearSucceeded)
        let metadataUpdateCalls = await commands.metadataUpdateCalls
        let clearCall = try XCTUnwrap(metadataUpdateCalls.last)
        XCTAssertEqual(Set(clearCall.originalLabels ?? []), Set(["old", "new"]))
        XCTAssertTrue(store.mutations.possiblyPersistedLabels(for: "bd-1").isEmpty)
    }

    func testFailedLabelReplacementFromEmptyStillWritesImmediateClear() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed, nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let replacementSucceeded = await store.updateMetadata(issueID: "bd-1", labels: ["new"])
        XCTAssertFalse(replacementSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.labels, [])

        let clearSucceeded = await store.updateMetadata(issueID: "bd-1", labels: [])
        XCTAssertTrue(clearSucceeded)
        let metadataUpdateCalls = await commands.metadataUpdateCalls
        let clearCall = try XCTUnwrap(metadataUpdateCalls.last)
        XCTAssertEqual(clearCall.labels, [])
        XCTAssertEqual(clearCall.originalLabels, ["new"])
    }

    func testExcessiveLabelUncertaintyBlocksClearUntilRefresh() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let labels = (0...BeadMutationStore.maximumPossiblyPersistedLabelsPerIssue).map { "label-\($0)" }
        store.mutations.recordPossiblyPersistedLabels(labels, for: "bd-1")
        let exportsBeforeClear = await commands.exportCallCount

        let succeeded = await store.updateMetadata(issueID: "bd-1", labels: [])

        XCTAssertFalse(succeeded)
        XCTAssertEqual(
            store.mutations.possiblyPersistedLabels(for: "bd-1").count,
            BeadMutationStore.maximumPossiblyPersistedLabelsPerIssue
        )
        XCTAssertTrue(store.mutations.labelUncertaintyOverflowed(for: "bd-1"))
        XCTAssertTrue(store.lastError?.contains("Refresh the project") == true)
        let metadataUpdateCalls = await commands.metadataUpdateCalls
        XCTAssertTrue(metadataUpdateCalls.isEmpty)
        try await waitUntilAsync { await commands.exportCallCount > exportsBeforeClear }
    }

    func testPendingLabelCandidatesReachTheBoundBeforeClearCanEnqueue() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        let candidateCount = BeadMutationStore.maximumPossiblyPersistedLabelsPerIssue + 1
        await commands.setMetadataUpdateDelays([.milliseconds(400)])
        await commands.setMetadataUpdateErrors(
            Array(repeating: StoreMutationTestError.commandFailed, count: candidateCount)
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let tasks = (0..<candidateCount).map { index in
            Task { @MainActor in
                await store.updateMetadata(issueID: "bd-1", labels: ["candidate-\(index)"])
            }
        }
        try await waitUntil { store.mutations.labelUncertaintyOverflowed(for: "bd-1") }

        let clearSucceeded = await store.updateMetadata(issueID: "bd-1", labels: [])

        XCTAssertFalse(clearSucceeded)
        XCTAssertEqual(
            store.mutations.possiblyPersistedLabels(for: "bd-1").count,
            BeadMutationStore.maximumPossiblyPersistedLabelsPerIssue
        )
        for task in tasks {
            _ = await task.value
        }
    }

    func testSameValueLabelReplacementRecoversOverflowedUncertainty() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let labels = (0...BeadMutationStore.maximumPossiblyPersistedLabelsPerIssue).map { "label-\($0)" }
        store.mutations.recordPossiblyPersistedLabels(labels, for: "bd-1")

        let succeeded = await store.updateMetadata(issueID: "bd-1", labels: ["old"])

        XCTAssertTrue(succeeded)
        XCTAssertFalse(store.mutations.labelUncertaintyOverflowed(for: "bd-1"))
        XCTAssertTrue(store.mutations.possiblyPersistedLabels(for: "bd-1").isEmpty)
        let calls = await commands.metadataUpdateCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.labels, ["old"])
    }

    func testSuccessfulDeleteClearsFailedLabelUncertainty() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let replacementSucceeded = await store.updateMetadata(issueID: "bd-1", labels: ["new"])
        XCTAssertFalse(replacementSucceeded)
        XCTAssertFalse(store.mutations.possiblyPersistedLabels(for: "bd-1").isEmpty)

        let deleteSucceeded = await store.delete(issueIDs: ["bd-1"])

        XCTAssertTrue(deleteSucceeded)
        XCTAssertTrue(store.mutations.possiblyPersistedLabels(for: "bd-1").isEmpty)
    }

    func testSuccessfulDeleteInvalidatesOverlappingFailedLabelSettlement() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(300)])
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let metadataTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", labels: ["new"])
        }
        try await waitUntil { store.issue(with: "bd-1")?.labels == ["new"] }
        let deleteTask = Task { @MainActor in
            await store.delete(issueIDs: ["bd-1"])
        }

        let metadataSucceeded = await metadataTask.value
        let deleteSucceeded = await deleteTask.value
        XCTAssertFalse(metadataSucceeded)
        XCTAssertTrue(deleteSucceeded)
        XCTAssertNil(store.issue(with: "bd-1"))
        XCTAssertNil(store.mutations.metadataMutations["bd-1"])
        XCTAssertTrue(store.mutations.possiblyPersistedLabels(for: "bd-1").isEmpty)
    }

    func testFailedFullSaveContributesLabelsToImmediateClearRecovery() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setUpdateDelay(.milliseconds(300))
        await commands.setUpdateError(StoreMutationTestError.commandFailed)
        await commands.setMetadataUpdateErrors([nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        var draft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        draft.labels = ["new"]
        let saveTask = Task { @MainActor in
            await store.save(draft)
        }
        try await waitUntil { store.issue(with: "bd-1")?.labels == ["new"] }
        let clearTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", labels: [])
        }

        let saveSucceeded = await saveTask.value
        XCTAssertFalse(saveSucceeded)
        let clearSucceeded = await clearTask.value
        XCTAssertTrue(clearSucceeded)
        let calls = await commands.metadataUpdateCalls
        XCTAssertEqual(Set(calls.last?.originalLabels ?? []), Set(["old", "new"]))
    }

    func testFailedFullSavePreservesLaterSuccessfulSameValueLabelWrite() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setUpdateDelay(.milliseconds(300))
        await commands.setUpdateError(StoreMutationTestError.commandFailed)
        await commands.setMetadataUpdateErrors([nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        var draft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        draft.labels = ["new"]
        let saveTask = Task { @MainActor in
            await store.save(draft)
        }
        try await waitUntil { store.issue(with: "bd-1")?.labels == ["new"] }
        let metadataTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", labels: ["new"])
        }

        let saveSucceeded = await saveTask.value
        let metadataSucceeded = await metadataTask.value
        XCTAssertFalse(saveSucceeded)
        XCTAssertTrue(metadataSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.labels, ["new"])
    }

    func testFailedFocusedDateDoesNotOverwriteLaterSuccessfulBulkDate() async throws {
        let originalDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-10"))
        let focusedDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-20"))
        let bulkDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-30"))
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","defer_until":"2026-07-10","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(300)])
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        XCTAssertEqual(store.issue(with: "bd-1")?.deferUntil, originalDate)

        let metadataTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", deferUntil: .set(focusedDate))
        }
        try await waitUntil { store.issue(with: "bd-1")?.deferUntil == focusedDate }
        let bulkTask = Task { @MainActor in
            await store.bulkSet(issueIDs: ["bd-1"], deferUntil: .set(bulkDate))
        }

        let metadataSucceeded = await metadataTask.value
        let bulkSucceeded = await bulkTask.value
        XCTAssertFalse(metadataSucceeded)
        XCTAssertTrue(bulkSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.deferUntil, bulkDate)
    }

    func testFailedFocusedDateDoesNotOverwriteLaterSuccessfulFullSaveDate() async throws {
        let focusedDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-20"))
        let saveDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-30"))
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","defer_until":"2026-07-10","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(300)])
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let metadataTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", deferUntil: .set(focusedDate))
        }
        try await waitUntil { store.issue(with: "bd-1")?.deferUntil == focusedDate }
        var draft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        draft.title = "Saved"
        draft.deferUntil = saveDate
        let saveTask = Task { @MainActor in
            await store.save(draft)
        }

        let metadataSucceeded = await metadataTask.value
        let saveSucceeded = await saveTask.value
        XCTAssertFalse(metadataSucceeded)
        XCTAssertTrue(saveSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Saved")
        XCTAssertEqual(store.issue(with: "bd-1")?.deferUntil, saveDate)
    }

    func testFailedFocusedDateDoesNotOverwriteLaterSuccessfulSameValueFullSaveDate() async throws {
        let attemptedDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-20"))
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","defer_until":"2026-07-10","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(300)])
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let metadataTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", deferUntil: .set(attemptedDate))
        }
        try await waitUntil { store.issue(with: "bd-1")?.deferUntil == attemptedDate }
        var draft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        draft.title = "Saved"
        let saveTask = Task { @MainActor in await store.save(draft) }

        let metadataSucceeded = await metadataTask.value
        let saveSucceeded = await saveTask.value
        XCTAssertFalse(metadataSucceeded)
        XCTAssertTrue(saveSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Saved")
        XCTAssertEqual(store.issue(with: "bd-1")?.deferUntil, attemptedDate)
    }

    func testFailedBulkDateRestoresSettledFocusedFailureEvenAtSameValue() async throws {
        let originalDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-10"))
        let attemptedDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-20"))
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","defer_until":"2026-07-10","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(300)])
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed])
        await commands.setBulkUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let metadataTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", deferUntil: .set(attemptedDate))
        }
        try await waitUntil { store.issue(with: "bd-1")?.deferUntil == attemptedDate }
        let bulkTask = Task { @MainActor in
            await store.bulkSet(issueIDs: ["bd-1"], deferUntil: .set(attemptedDate))
        }

        let metadataSucceeded = await metadataTask.value
        let bulkSucceeded = await bulkTask.value
        XCTAssertFalse(metadataSucceeded)
        XCTAssertFalse(bulkSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.deferUntil, originalDate)
    }

    func testTwoFailedBulkDateWritesRestoreOriginalValueEvenAtSameValue() async throws {
        let originalDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-10"))
        let attemptedDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-20"))
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","defer_until":"2026-07-10","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateDelay(.milliseconds(300))
        await commands.setBulkUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let firstTask = Task { @MainActor in
            await store.bulkSet(issueIDs: ["bd-1"], deferUntil: .set(attemptedDate))
        }
        try await waitUntil { store.issue(with: "bd-1")?.deferUntil == attemptedDate }
        let secondTask = Task { @MainActor in
            await store.bulkSet(issueIDs: ["bd-1"], deferUntil: .set(attemptedDate))
        }

        let firstSucceeded = await firstTask.value
        let secondSucceeded = await secondTask.value
        XCTAssertFalse(firstSucceeded)
        XCTAssertFalse(secondSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.deferUntil, originalDate)
    }

    func testFailedFullSaveThenFailedBulkDateRestoresOriginalValueEvenAtSameValue() async throws {
        let originalDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-10"))
        let attemptedDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-20"))
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","defer_until":"2026-07-10","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setUpdateDelay(.milliseconds(300))
        await commands.setUpdateError(StoreMutationTestError.commandFailed)
        await commands.setBulkUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        var draft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        draft.deferUntil = attemptedDate
        let saveTask = Task { @MainActor in await store.save(draft) }
        try await waitUntil { store.issue(with: "bd-1")?.deferUntil == attemptedDate }
        let bulkTask = Task { @MainActor in
            await store.bulkSet(issueIDs: ["bd-1"], deferUntil: .set(attemptedDate))
        }

        let saveSucceeded = await saveTask.value
        let bulkSucceeded = await bulkTask.value
        XCTAssertFalse(saveSucceeded)
        XCTAssertFalse(bulkSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.deferUntil, originalDate)
    }

    func testFailedFullSaveThenSuccessfulBulkPreservesBothResults() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setUpdateDelay(.milliseconds(300))
        await commands.setUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        var draft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        draft.title = "Failed save"
        let saveTask = Task { @MainActor in await store.save(draft) }
        try await waitUntil { store.issue(with: "bd-1")?.title == "Failed save" }
        let bulkTask = Task { @MainActor in
            await store.bulkSet(issueIDs: ["bd-1"], priority: 2)
        }

        let saveSucceeded = await saveTask.value
        let bulkSucceeded = await bulkTask.value
        XCTAssertFalse(saveSucceeded)
        XCTAssertTrue(bulkSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "One")
        XCTAssertEqual(store.issue(with: "bd-1")?.priority, 2)
    }

    func testQueuedFullSaveRefreshesIssueBaselineAfterEarlierFailure() async throws {
        let projectURL = try makeProject(
            #"{"_type":"issue","id":"bd-1","title":"Original","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}"#
        )
        let commands = RecordingBeadsCommands()
        await commands.setUpdateDelays([.milliseconds(300), nil])
        await commands.setUpdateErrors([StoreMutationTestError.commandFailed, nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        var firstDraft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        firstDraft.title = "First save"
        firstDraft.labels = ["new"]
        let firstTask = Task { @MainActor in await store.save(firstDraft) }
        try await waitUntil { store.issue(with: "bd-1")?.labels == ["new"] }

        var secondDraft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        secondDraft.title = "Second save"
        let secondTask = Task { @MainActor in await store.save(secondDraft) }

        let firstSucceeded = await firstTask.value
        let secondSucceeded = await secondTask.value
        XCTAssertFalse(firstSucceeded)
        XCTAssertTrue(secondSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Second save")
        XCTAssertEqual(store.issue(with: "bd-1")?.labels, ["new"])
        let calls = await commands.updateCalls
        XCTAssertEqual(calls.map { $0.originalIssue?.title }, ["Original"])
        XCTAssertEqual(calls.map { $0.originalIssue?.labels }, [["old", "new"]])
        XCTAssertEqual(calls.map(\.draft.labels), [["new"]])
    }

    func testFailedFullSaveCannotResurrectLaterSuccessfulDelete() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setUpdateDelay(.milliseconds(300))
        await commands.setUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        var draft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        draft.title = "Failed save"
        let saveTask = Task { @MainActor in await store.save(draft) }
        try await waitUntil { store.issue(with: "bd-1")?.title == "Failed save" }
        let deleteTask = Task { @MainActor in await store.delete(issueIDs: ["bd-1"]) }

        let saveSucceeded = await saveTask.value
        let deleteSucceeded = await deleteTask.value
        XCTAssertFalse(saveSucceeded)
        XCTAssertTrue(deleteSucceeded)
        XCTAssertNil(store.issue(with: "bd-1"))
    }

    func testLaterSuccessfulBulkDateSurvivesFocusedFailureAndThirdRollback() async throws {
        let attemptedDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-20"))
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","defer_until":"2026-07-10","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(300)])
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed])
        await commands.setUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let focusedTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", deferUntil: .set(attemptedDate))
        }
        try await waitUntil { store.issue(with: "bd-1")?.deferUntil == attemptedDate }
        let bulkTask = Task { @MainActor in
            await store.bulkSet(issueIDs: ["bd-1"], deferUntil: .set(attemptedDate))
        }
        var draft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        draft.title = "Will fail"
        let saveTask = Task { @MainActor in await store.save(draft) }

        let focusedSucceeded = await focusedTask.value
        let bulkSucceeded = await bulkTask.value
        let saveSucceeded = await saveTask.value
        XCTAssertFalse(focusedSucceeded)
        XCTAssertTrue(bulkSucceeded)
        XCTAssertFalse(saveSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.deferUntil, attemptedDate)
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "One")
    }

    func testFailedBulkSetCannotResurrectFailedMetadata() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","assignee":"Before","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(300)])
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed])
        await commands.setBulkUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let metadataTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", assignee: "Sasha")
        }
        try await waitUntil { store.issue(with: "bd-1")?.assignee == "Sasha" }
        let bulkTask = Task { @MainActor in
            await store.bulkSet(issueIDs: ["bd-1"], priority: 2)
        }
        try await waitUntil { store.issue(with: "bd-1")?.priority == 2 }

        let metadataSucceeded = await metadataTask.value
        let bulkSucceeded = await bulkTask.value
        XCTAssertFalse(metadataSucceeded)
        XCTAssertFalse(bulkSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.assignee, "Before")
        XCTAssertEqual(store.issue(with: "bd-1")?.priority, 1)
    }

    func testFailedDeleteCannotResurrectFailedMetadata() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","assignee":"Before","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(300)])
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed])
        await commands.setDeleteError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let metadataTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", assignee: "Sasha")
        }
        try await waitUntil { store.issue(with: "bd-1")?.assignee == "Sasha" }
        let deleteTask = Task { @MainActor in
            await store.delete(issueIDs: ["bd-1"])
        }
        try await waitUntil { store.issue(with: "bd-1") == nil }

        let metadataSucceeded = await metadataTask.value
        let deleteSucceeded = await deleteTask.value
        XCTAssertFalse(metadataSucceeded)
        XCTAssertFalse(deleteSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.assignee, "Before")
        XCTAssertNil(store.mutations.metadataMutations["bd-1"])
    }

    func testDelayedDeleteCannotRollBackAcrossProjectABA() async throws {
        let firstProjectURL = try makeProject(issueLine(id: "bd-1", title: "Original A"))
        let secondProjectURL = try makeProject(issueLine(id: "bd-2", title: "Project B"))
        let commands = RecordingBeadsCommands()
        await commands.setDeleteDelay(.milliseconds(400))
        await commands.setDeleteError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let deleteTask = Task { @MainActor in
            await store.delete(issueIDs: ["bd-1"])
        }
        try await waitUntil { store.issue(with: "bd-1") == nil }
        store.openProject(secondProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }
        store.openProject(firstProjectURL)
        try await waitUntil {
            !store.isLoading && store.issue(with: "bd-1")?.title == "Original A"
        }

        let deleteSucceeded = await deleteTask.value
        XCTAssertFalse(deleteSucceeded)
        XCTAssertEqual(store.projectURL, firstProjectURL)
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Original A")
        XCTAssertNil(store.lastError)
    }

    func testAuthoritativeRefreshClearsFailedLabelUncertainty() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let succeeded = await store.updateMetadata(issueID: "bd-1", labels: ["new"])
        XCTAssertFalse(succeeded)
        XCTAssertEqual(
            Set(store.mutations.possiblyPersistedLabels(for: "bd-1")),
            Set(["old", "new"])
        )

        let exportsBeforeRefresh = await commands.exportCallCount
        store.refresh()
        try await waitUntilAsync { await commands.exportCallCount > exportsBeforeRefresh }
        try await waitUntil { !store.isLoading }

        XCTAssertTrue(store.mutations.possiblyPersistedLabels(for: "bd-1").isEmpty)
    }

    func testBlankFullSavePreservesNewerOptimisticAssignee() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        var staleDraft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        staleDraft.title = "Updated"
        let metadataSucceeded = await store.updateMetadata(issueID: "bd-1", assignee: "Sasha")
        XCTAssertTrue(metadataSucceeded)
        await commands.setUpdateDelay(.milliseconds(400))

        let saveTask = Task { @MainActor in
            await store.save(staleDraft)
        }
        try await waitUntil { store.issue(with: "bd-1")?.title == "Updated" }

        XCTAssertEqual(store.issue(with: "bd-1")?.assignee, "Sasha")
        let saveSucceeded = await saveTask.value
        XCTAssertTrue(saveSucceeded)
    }

    func testFailedFullSaveDoesNotResurrectFailedMetadata() async throws {
        let originalUpdatedAt = try XCTUnwrap(BeadFormatters.parseDate("2026-07-03T20:58:35Z"))
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","assignee":"Before","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateDelays([.milliseconds(300)])
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed])
        await commands.setUpdateDelay(.milliseconds(300))
        await commands.setUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let metadataTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", assignee: "Sasha")
        }
        try await waitUntil { store.issue(with: "bd-1")?.assignee == "Sasha" }

        var draft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        draft.title = "Updated"
        let saveTask = Task { @MainActor in
            await store.save(draft)
        }
        try await waitUntil { store.issue(with: "bd-1")?.title == "Updated" }

        let metadataSucceeded = await metadataTask.value
        let saveSucceeded = await saveTask.value
        XCTAssertFalse(metadataSucceeded)
        XCTAssertFalse(saveSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.assignee, "Before")
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "One")
        XCTAssertEqual(store.issue(with: "bd-1")?.updatedAt, originalUpdatedAt)
    }

    func testSuccessfulFocusedMutationDoesNotResurrectMetadataFromFailedFullSave() async throws {
        let originalDueAt = try XCTUnwrap(BeadFormatters.parseDate("2026-07-10"))
        let originalDeferUntil = try XCTUnwrap(BeadFormatters.parseDate("2026-07-11"))
        let failedDueAt = try XCTUnwrap(BeadFormatters.parseDate("2026-07-20"))
        let failedDeferUntil = try XCTUnwrap(BeadFormatters.parseDate("2026-07-21"))
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","assignee":"Before","labels":["old"],"due_at":"2026-07-10","defer_until":"2026-07-11","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setUpdateDelay(.milliseconds(300))
        await commands.setUpdateError(StoreMutationTestError.commandFailed)
        await commands.setMetadataUpdateErrors([nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        var draft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        draft.title = "Failed save"
        draft.labels = ["failed-save"]
        draft.dueAt = failedDueAt
        draft.deferUntil = failedDeferUntil
        let saveTask = Task { @MainActor in
            await store.save(draft)
        }
        try await waitUntil {
            store.issue(with: "bd-1")?.labels == ["failed-save"]
                && store.issue(with: "bd-1")?.dueAt == failedDueAt
                && store.issue(with: "bd-1")?.deferUntil == failedDeferUntil
        }

        let metadataTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", assignee: "Sasha")
        }
        try await waitUntil { store.issue(with: "bd-1")?.assignee == "Sasha" }

        let saveSucceeded = await saveTask.value
        let metadataSucceeded = await metadataTask.value
        XCTAssertFalse(saveSucceeded)
        XCTAssertTrue(metadataSucceeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "One")
        XCTAssertEqual(store.issue(with: "bd-1")?.assignee, "Sasha")
        XCTAssertEqual(store.issue(with: "bd-1")?.labels, ["old"])
        XCTAssertEqual(store.issue(with: "bd-1")?.dueAt, originalDueAt)
        XCTAssertEqual(store.issue(with: "bd-1")?.deferUntil, originalDeferUntil)
    }

    func testFailedMetadataUpdateRestoresUpdatedTimestamp() async throws {
        let originalUpdatedAt = try XCTUnwrap(BeadFormatters.parseDate("2026-07-03T20:58:35Z"))
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","assignee":"Before","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let succeeded = await store.updateMetadata(issueID: "bd-1", assignee: "Sasha")
        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.updatedAt, originalUpdatedAt)
    }

    func testSuccessfulMetadataSettlementDoesNotRebuildUnchangedIndex() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","assignee":"Before","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let revisionBeforeUpdate = store.contentRevision

        let succeeded = await store.updateMetadata(issueID: "bd-1", assignee: "Sasha")
        XCTAssertTrue(succeeded)

        XCTAssertEqual(store.contentRevision, revisionBeforeUpdate + 1)
    }

    func testMetadataMutationStateDrainsOutOfOrderCompletionsInSubmissionOrder() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","assignee":"Before","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let firstID = UUID()
        let secondID = UUID()
        var state = BeadMetadataMutationState(
            confirmedIssue: try XCTUnwrap(store.issue(with: "bd-1")),
            pendingMutations: [
                BeadPendingMetadataMutation(
                    id: firstID,
                    patch: BeadMetadataMutationPatch(
                        assignee: "First",
                        labels: nil,
                        dueAt: .unchanged,
                        deferUntil: .unchanged
                    )
                ),
                BeadPendingMetadataMutation(
                    id: secondID,
                    patch: BeadMetadataMutationPatch(
                        assignee: "Second",
                        labels: nil,
                        dueAt: .unchanged,
                        deferUntil: .unchanged
                    )
                )
            ]
        )

        XCTAssertEqual(state.recordCompletion(id: secondID, succeeded: true)?.count, 0)
        XCTAssertEqual(state.confirmedIssue.assignee, "Before")
        XCTAssertEqual(state.resolvedIssue.assignee, "Second")

        XCTAssertEqual(state.recordCompletion(id: firstID, succeeded: true)?.count, 2)
        XCTAssertTrue(state.pendingMutations.isEmpty)
        XCTAssertEqual(state.confirmedIssue.assignee, "Second")
    }

    func testMetadataSettlementProvenanceUpdatesOnlyItsOwnedFields() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","assignee":"Before","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let originalIssue = try XCTUnwrap(store.issue(with: "bd-1"))
        var assigneeSettlement = originalIssue
        assigneeSettlement.assignee = "Sasha"
        var labelSettlement = originalIssue
        labelSettlement.labels = ["new"]

        let assigneeVersions = store.mutations.recordMetadataWrite(.assignee, for: "bd-1")
        store.mutations.recordMetadataSettlement(
            .assignee,
            issue: assigneeSettlement,
            sourceWriteVersions: assigneeVersions
        )
        let labelVersions = store.mutations.recordMetadataWrite(.labels, for: "bd-1")
        store.mutations.recordMetadataSettlement(
            .labels,
            issue: labelSettlement,
            sourceWriteVersions: labelVersions
        )

        let settlement = try XCTUnwrap(store.mutations.metadataSettlement(for: "bd-1"))
        XCTAssertEqual(settlement.issue.assignee, "Sasha")
        XCTAssertEqual(settlement.issue.labels, ["new"])
    }

    func testMetadataUpdateRollsBackOnCommandFailure() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","labels":["old"],"updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let succeeded = await store.updateMetadata(issueID: "bd-1", labels: ["new"])

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.labels, ["old"])
        XCTAssertEqual(store.lastError, StoreMutationTestError.commandFailed.localizedDescription)
    }

    func testMutationRollsBackOptimisticStateOnCommandFailure() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.select(["bd-1"])

        let succeeded = await store.bulkSet(status: "closed")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.status, "open")
        XCTAssertEqual(store.lastError, StoreMutationTestError.commandFailed.localizedDescription)
    }

    func testFailedAttemptedMutationStillReconcilesInCaseCommandPartiallyWrote() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.select(["bd-1"])
        let exportsBefore = await commands.exportCallCount

        let succeeded = await store.bulkSet(status: "closed")

        XCTAssertFalse(succeeded)
        try await waitUntilAsync { await commands.exportCallCount > exportsBefore }
    }

    func testSuccessfulMutationReconcilesByReExportingSnapshot() async throws {
        // After the write succeeds, a silent reconcile re-exports the readable snapshot so
        // `bd`-computed fields converge — this is what keeps Dolt-backed projects correct.
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.select(["bd-1"])
        let exportsBefore = await commands.exportCallCount

        let succeeded = await store.bulkSet(status: "closed")
        XCTAssertTrue(succeeded)

        try await waitUntilAsync { await commands.exportCallCount > exportsBefore }
    }

    func testRapidMutationsCoalesceIntoASingleReconcile() async throws {
        // Five quick edits must not trigger five export+reload cycles — just one, after
        // the burst settles.
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.select(["bd-1"])
        let exportsBefore = await commands.exportCallCount

        for priority in [0, 1, 2, 3, 4] {
            _ = await store.bulkSet(priority: priority)
        }

        // Exactly one reconcile fires for the whole burst.
        try await waitUntilAsync { await commands.exportCallCount == exportsBefore + 1 }
        // ...and it stays at one after the debounce window has fully elapsed.
        try await Task.sleep(for: .milliseconds(900))
        let exportsAfter = await commands.exportCallCount
        XCTAssertEqual(exportsAfter, exportsBefore + 1)
    }

    func testReconcileIsDeferredUntilInFlightMutationCompletes() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateDelay(.milliseconds(400))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.select(["bd-1"])
        let exportsBefore = await commands.exportCallCount

        let task = Task { @MainActor in await store.bulkSet(priority: 3) }
        // While the write is in flight, no reconcile export should have run yet.
        try await Task.sleep(for: .milliseconds(200))
        let exportsMidFlight = await commands.exportCallCount
        XCTAssertEqual(exportsMidFlight, exportsBefore)

        _ = await task.value
        try await waitUntilAsync { await commands.exportCallCount == exportsBefore + 1 }
    }

    func testManualRefreshReExportsReadableSnapshot() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let exportsBeforeRefresh = await commands.exportCallCount

        store.refresh()

        try await waitUntilAsync { await commands.exportCallCount > exportsBeforeRefresh }
    }

    func testManualRefreshWaitsForActiveGenericMutation() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setUpdateDelay(.milliseconds(400))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        var editedDraft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        editedDraft.title = "Optimistic title"

        let saveTask = Task { @MainActor in await store.save(editedDraft) }
        try await waitUntil { store.issue(with: "bd-1")?.title == "Optimistic title" }
        let exportsBeforeRefresh = await commands.exportCallCount
        store.refresh()
        try await Task.sleep(for: .milliseconds(100))
        let exportsDuringMutation = await commands.exportCallCount

        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Optimistic title")
        XCTAssertEqual(exportsDuringMutation, exportsBeforeRefresh)
        XCTAssertFalse(store.isLoading)
        let saveSucceeded = await saveTask.value
        XCTAssertTrue(saveSucceeded)
    }

    func testGenericMutationInvalidatesManualRefreshThatStartedFirst() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let definitionCallsBeforeRefresh = await commands.definitionLoadCallCount
        await commands.setDefinitionLoadDelay(.milliseconds(400))

        store.refresh()
        try await waitUntilAsync {
            await commands.definitionLoadCallCount >= definitionCallsBeforeRefresh + 2
        }
        var editedDraft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        editedDraft.title = "Optimistic title"
        let saveSucceeded = await store.save(editedDraft)
        XCTAssertTrue(saveSucceeded)
        await commands.setDefinitionLoadDelay(nil)
        try await waitUntil { !store.isLoading }

        XCTAssertEqual(store.issue(with: "bd-1")?.title, "Optimistic title")
    }

    func testManualRefreshPreservesSnapshotAndWarnsWhenExportFails() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await commands.setExportError(StoreMutationTestError.commandFailed)

        store.refresh()

        try await waitUntil { !store.isLoading && store.snapshotFreshness.state == .possiblyStale }
        XCTAssertNotNil(store.issue(with: "bd-1"))
        XCTAssertTrue(store.snapshotFreshness.detail?.contains("Mutation command failed") == true)
        XCTAssertNil(store.lastError)
    }

    func testBulkSetReturnsFalseAndSetsLastErrorOnCommandFailure() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.select(["bd-1"])

        let succeeded = await store.bulkSet(status: "closed")

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.lastError, StoreMutationTestError.commandFailed.localizedDescription)
    }

    func testDelayedBulkFailureCannotRollBackAcrossProjectABA() async throws {
        let firstProjectURL = try makeProject(issueLine(id: "bd-1", title: "Original A"))
        let secondProjectURL = try makeProject(issueLine(id: "bd-2", title: "Project B"))
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateDelay(.milliseconds(400))
        await commands.setBulkUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let bulkTask = Task { @MainActor in
            await store.bulkSet(issueIDs: ["bd-1"], priority: 2)
        }
        try await waitUntil { store.issue(with: "bd-1")?.priority == 2 }
        store.openProject(secondProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }
        store.openProject(firstProjectURL)
        try await waitUntil {
            !store.isLoading && store.issue(with: "bd-1")?.title == "Original A"
        }

        let bulkSucceeded = await bulkTask.value
        XCTAssertFalse(bulkSucceeded)
        XCTAssertEqual(store.projectURL, firstProjectURL)
        XCTAssertEqual(store.issue(with: "bd-1")?.priority, 1)
        XCTAssertNil(store.lastError)
    }

    func testSameProjectABARequestsReconcileAfterStaleSuccessfulWrite() async throws {
        let firstProjectURL = try makeProject(issueLine(id: "bd-1", title: "Original A"))
        let secondProjectURL = try makeProject(issueLine(id: "bd-2", title: "Project B"))
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateDelay(.milliseconds(400))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let bulkTask = Task { @MainActor in
            await store.bulkSet(issueIDs: ["bd-1"], priority: 2)
        }
        try await waitUntil { store.issue(with: "bd-1")?.priority == 2 }
        store.openProject(secondProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let exportsAfterReopen = await commands.exportCallCount

        let bulkSucceeded = await bulkTask.value
        XCTAssertFalse(bulkSucceeded)
        try await waitUntilAsync { await commands.exportCallCount > exportsAfterReopen }
    }

    func testProjectSwitchDoesNotDelayNewProjectOptimisticMutation() async throws {
        let firstProjectURL = try makeProject(issueLine(id: "bd-a", title: "Project A"))
        let secondProjectURL = try makeProject(issueLine(id: "bd-b", title: "Project B"))
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateDelays([.milliseconds(400), nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-a") != nil }

        let firstTask = Task { @MainActor in
            await store.bulkSet(issueIDs: ["bd-a"], priority: 2)
        }
        try await waitUntil { store.issue(with: "bd-a")?.priority == 2 }
        store.openProject(secondProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-b") != nil }

        let secondTask = Task { @MainActor in
            await store.bulkSet(issueIDs: ["bd-b"], priority: 3)
        }
        try await waitUntil { store.issue(with: "bd-b")?.priority == 3 }

        let firstSucceeded = await firstTask.value
        let secondSucceeded = await secondTask.value
        XCTAssertFalse(firstSucceeded)
        XCTAssertTrue(secondSucceeded)
        XCTAssertEqual(store.projectURL, secondProjectURL)
        XCTAssertEqual(store.issue(with: "bd-b")?.priority, 3)
    }

    func testOldProjectMutationDoesNotDelayNewProjectManualRefresh() async throws {
        let firstProjectURL = try makeProject(issueLine(id: "bd-1", title: "Project A"))
        let secondProjectURL = try makeProject(issueLine(id: "bd-2", title: "Project B"))
        let commands = RecordingBeadsCommands()
        await commands.setUpdateDelay(.seconds(1))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        var editedDraft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        editedDraft.title = "Delayed A edit"

        let saveTask = Task { @MainActor in await store.save(editedDraft) }
        try await waitUntil { store.issue(with: "bd-1")?.title == "Delayed A edit" }
        store.openProject(secondProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }
        let exportsBeforeRefresh = await commands.exportCallCount

        store.refresh()
        try await waitUntilAsync { await commands.exportCallCount > exportsBeforeRefresh }

        let oldProjectSaveSucceeded = await saveTask.value
        XCTAssertFalse(oldProjectSaveSucceeded)
    }

    func testMultiIssueBulkSettlementCompletesBeforeOverlappingDelete() async throws {
        let deferredDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-20"))
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-1", title: "One"))
            \(issueLine(id: "bd-2", title: "Two"))
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateDelay(.milliseconds(300))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }

        let bulkTask = Task { @MainActor in
            await store.bulkSet(
                issueIDs: ["bd-1", "bd-2"],
                deferUntil: .set(deferredDate)
            )
        }
        try await waitUntil { store.issue(with: "bd-2")?.deferUntil == deferredDate }
        let deleteTask = Task { @MainActor in await store.delete(issueIDs: ["bd-1"]) }

        let bulkSucceeded = await bulkTask.value
        let deleteSucceeded = await deleteTask.value
        XCTAssertTrue(bulkSucceeded)
        XCTAssertTrue(deleteSucceeded)
        XCTAssertNil(store.issue(with: "bd-1"))
        XCTAssertEqual(store.issue(with: "bd-2")?.deferUntil, deferredDate)
        XCTAssertNil(store.mutations.metadataMutations["bd-2"])
    }

    func testBulkSetDeduplicatesIssueIDsBeforeRegisteringMetadataMutations() async throws {
        let deferredDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-20"))
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let succeeded = await store.bulkSet(
            issueIDs: ["bd-1", "bd-1"],
            deferUntil: .set(deferredDate)
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.deferUntil, deferredDate)
        XCTAssertNil(store.mutations.metadataMutations["bd-1"])
        let calls = await commands.bulkUpdateCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-1"]])
    }

    func testFailedMultiIssueBulkSettlesAndRollsBackWithTwoStateApplications() async throws {
        let deferredDate = try XCTUnwrap(BeadFormatters.parseDate("2026-07-20"))
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-1", title: "One"))
            \(issueLine(id: "bd-2", title: "Two"))
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }
        let revisionBeforeMutation = store.contentRevision

        let succeeded = await store.bulkSet(
            issueIDs: ["bd-1", "bd-2"],
            deferUntil: .set(deferredDate)
        )

        XCTAssertFalse(succeeded)
        XCTAssertNil(store.issue(with: "bd-1")?.deferUntil)
        XCTAssertNil(store.issue(with: "bd-2")?.deferUntil)
        XCTAssertEqual(store.contentRevision, revisionBeforeMutation + 2)
        XCTAssertTrue(store.mutations.metadataMutations.isEmpty)
    }

    func testBulkSetReturnsFalseWhenProjectChangesBeforeCommandCompletes() async throws {
        let firstProjectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let secondProjectURL = try makeProject(issueLine(id: "bd-2", title: "Two"))
        let commands = RecordingBeadsCommands()
        await commands.setBulkUpdateDelay(.milliseconds(150))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.select(["bd-1"])

        let task = Task { @MainActor in
            await store.bulkSet(status: "closed")
        }
        try await Task.sleep(for: .milliseconds(25))
        store.openProject(secondProjectURL)

        let succeeded = await task.value

        XCTAssertFalse(succeeded)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.projectURL, secondProjectURL.standardizedFileURL)
    }

    func testCloseCanIncludeConfirmedOpenChildren() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            \(issueLine(id: "bd-grandchild", title: "Grandchild", status: "review", parentID: "bd-child"))
            \(issueLine(id: "bd-closed", title: "Closed", status: "closed", parentID: "bd-parent"))
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-grandchild") != nil }

        let childIssues = store.openChildIssues(forClosing: ["bd-parent"])
        let succeeded = await store.close(
            issueIDs: ["bd-parent"] + childIssues.map(\.id),
            reason: "Done together"
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(childIssues.map(\.id), ["bd-child", "bd-grandchild"])
        XCTAssertEqual(store.issue(with: "bd-parent")?.status, "closed")
        XCTAssertEqual(store.issue(with: "bd-child")?.status, "closed")
        XCTAssertEqual(store.issue(with: "bd-grandchild")?.status, "closed")
        let calls = await commands.closeCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-grandchild", "bd-child", "bd-parent"]])
        XCTAssertEqual(calls.map(\.reason), ["Done together"])
        let events = await commands.mutationEvents
        XCTAssertEqual(events, ["close:bd-grandchild,bd-child,bd-parent"])
    }

    func testBulkSetClosedStatusClosesConfirmedOpenChildrenBeforeParent() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            \(issueLine(id: "bd-grandchild", title: "Grandchild", status: "review", parentID: "bd-child"))
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-grandchild") != nil }

        let childIssues = store.openChildIssues(forClosing: ["bd-parent"])
        let succeeded = await store.bulkSet(
            issueIDs: ["bd-parent"] + childIssues.map(\.id),
            status: "closed"
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.issue(with: "bd-parent")?.status, "closed")
        XCTAssertEqual(store.issue(with: "bd-child")?.status, "closed")
        XCTAssertEqual(store.issue(with: "bd-grandchild")?.status, "closed")
        let calls = await commands.bulkUpdateCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-grandchild", "bd-child", "bd-parent"]])
        XCTAssertEqual(calls.map(\.status), ["closed"])
        let events = await commands.mutationEvents
        XCTAssertEqual(events, ["bulk:bd-grandchild,bd-child,bd-parent"])
    }

    func testSavingClosedStatusCanCloseConfirmedOpenChildren() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            \(issueLine(id: "bd-grandchild", title: "Grandchild", status: "review", parentID: "bd-child"))
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-grandchild") != nil }
        let parent = try XCTUnwrap(store.issue(with: "bd-parent"))
        var draft = IssueDraft(issue: parent)
        draft.title = "Parent done"
        draft.status = "closed"

        let childIssues = store.openChildIssues(forClosing: ["bd-parent"])
        let succeeded = await store.save(draft, closingChildIssueIDs: childIssues.map(\.id))

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.issue(with: "bd-parent")?.title, "Parent done")
        XCTAssertEqual(store.issue(with: "bd-parent")?.status, "closed")
        XCTAssertEqual(store.issue(with: "bd-child")?.status, "closed")
        XCTAssertEqual(store.issue(with: "bd-grandchild")?.status, "closed")
        let updateCalls = await commands.updateCalls
        let bulkCalls = await commands.bulkUpdateCalls
        XCTAssertEqual(updateCalls.first?.draft.status, "closed")
        XCTAssertEqual(bulkCalls.map(\.ids), [["bd-grandchild", "bd-child"]])
        XCTAssertEqual(bulkCalls.map(\.status), ["closed"])
        let events = await commands.mutationEvents
        XCTAssertEqual(events, ["bulk:bd-grandchild,bd-child", "update:bd-parent"])
    }

    func testCreateSelectsCreatedIssueAfterReloadAndRevealsThroughFilters() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setCreateResult(issueID: "bd-created")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.applyBookmark(.closed)
        store.setStatusFilter("closed", isOn: true)
        store.searchText = "does not match created"

        let succeeded = await store.save(draft(title: "Created from inline"))

        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.selectedIDs, Set(["bd-created"]))
        XCTAssertEqual(store.selectedIssue?.title, "Created from inline")
        await store.waitForPendingQueryRecompute()
        XCTAssertTrue(store.issueListRows.contains { $0.issueID == "bd-created" })
        XCTAssertEqual(store.selectedBookmark, .all)
        XCTAssertTrue(store.statusFilters.isEmpty)
        XCTAssertEqual(store.searchText, "")
        XCTAssertNil(store.lastError)

        let calls = await commands.createCalls
        XCTAssertEqual(calls.map(\.draft.title), ["Created from inline"])
    }

    func testBeginCreatingChildBeadPresetsParentAndSavesWithSingleCreate() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-parent", title: "Parent"))
        let commands = RecordingBeadsCommands()
        await commands.setCreateResult(issueID: "bd-child")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-parent") != nil }

        store.select(["bd-parent"])
        store.beginCreatingChildBead(parentID: "bd-parent")

        var draft = try XCTUnwrap(store.creationDraft)
        XCTAssertEqual(draft.parentID, "bd-parent")
        XCTAssertTrue(store.selectedIDs.isEmpty)
        draft.title = "New child"

        let succeeded = await store.save(draft)

        XCTAssertTrue(succeeded)
        let calls = await commands.createCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.draft.parentID, "bd-parent")
        XCTAssertEqual(store.issue(with: "bd-child")?.parentID, "bd-parent")
    }

    func testChildCreationEligibilityExcludesClosedParentsAndGates() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-open", title: "Open parent"))
            \(closedIssueLine(id: "bd-closed", title: "Closed parent"))
            \(issueLine(id: "bd-gate", title: "Gate", issueType: "gate"))
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-gate") != nil }

        XCTAssertTrue(store.canAddSubIssue(parentID: "bd-open"))
        XCTAssertFalse(store.canAddSubIssue(parentID: "bd-closed"))
        XCTAssertFalse(store.canAddSubIssue(parentID: "bd-gate"))

        store.select(["bd-closed"])
        store.beginCreatingChildBead(parentID: "bd-closed")

        XCTAssertNil(store.creationDraft)
        XCTAssertEqual(store.selectedIDs, Set(["bd-closed"]))
    }

    func testCreateBeadRejectsClosedParentBeforeInvokingCommand() async throws {
        let projectURL = try makeProject(closedIssueLine(id: "bd-parent", title: "Closed parent"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-parent") != nil }

        var draft = store.blankDraft(parentID: "bd-parent")
        draft.title = "New child"
        let createdIssueID = await store.createBead(draft, revealCreated: false)

        XCTAssertNil(createdIssueID)
        XCTAssertEqual(store.lastError, "Reopen bd-parent before adding a sub-issue.")
        let calls = await commands.createCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCreateReturnsFalseAndSetsLastErrorOnCommandFailure() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setCreateError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let succeeded = await store.save(draft(title: "Created from inline"))

        XCTAssertFalse(succeeded)
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertNil(store.issue(with: "bd-created"))
        XCTAssertEqual(store.lastError, StoreMutationTestError.commandFailed.localizedDescription)

        let calls = await commands.createCalls
        XCTAssertEqual(calls.count, 1)
    }

    func testDirectCreateReturnsCommittedIDWhenPostCreateReloadFails() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setCreateResult(issueID: "bd-created")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        await commands.setAppendsCreatedIssue(false)

        let createdIssueID = await store.createBead(
            draft(title: "Committed before reload failure"),
            revealCreated: true
        )

        XCTAssertEqual(createdIssueID, "bd-created")
        XCTAssertFalse(store.selectedIDs.contains("bd-created"))
        let calls = await commands.createCalls
        XCTAssertEqual(calls.count, 1)
    }

    func testDirectCreateWaitsForEarlierOptimisticMutationLifetime() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setUpdateDelay(.milliseconds(300))
        await commands.setUpdateError(StoreMutationTestError.commandFailed)
        await commands.setCreateResult(issueID: "bd-created")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        var editedDraft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        editedDraft.title = "Optimistic title"
        let saveTask = Task { @MainActor in await store.save(editedDraft) }
        try await waitUntil { store.issue(with: "bd-1")?.title == "Optimistic title" }
        let createTask = Task { @MainActor in
            await store.createBead(self.draft(title: "Created after rollback"), revealCreated: true)
        }
        try await Task.sleep(for: .milliseconds(50))
        let createCallsWhileSaveIsPending = await commands.createCalls
        XCTAssertTrue(createCallsWhileSaveIsPending.isEmpty)

        let saveSucceeded = await saveTask.value
        let createdIssueID = await createTask.value
        XCTAssertFalse(saveSucceeded)
        XCTAssertEqual(createdIssueID, "bd-created")
        XCTAssertEqual(store.issue(with: "bd-1")?.title, "One")
        XCTAssertEqual(store.issue(with: "bd-created")?.title, "Created after rollback")
    }

    func testDirectCreateCannotRevealAcrossSameProjectABA() async throws {
        let firstProjectURL = try makeProject(issueLine(id: "bd-1", title: "Original A"))
        let secondProjectURL = try makeProject(issueLine(id: "bd-2", title: "Project B"))
        let commands = RecordingBeadsCommands()
        await commands.setCreateDelay(.milliseconds(400))
        await commands.setCreateResult(issueID: "bd-created")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let createTask = Task { @MainActor in
            await store.createBead(self.draft(title: "Stale create"), revealCreated: true)
        }
        try await waitUntilAsync { await !commands.createCalls.isEmpty }
        store.openProject(secondProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let exportsAfterReopen = await commands.exportCallCount

        let createdIssueID = await createTask.value
        XCTAssertNil(createdIssueID)
        XCTAssertFalse(store.selectedIDs.contains("bd-created"))
        try await waitUntilAsync { await commands.exportCallCount > exportsAfterReopen }
    }

    func testManualRefreshWaitsForDirectCreateReload() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setCreateResult(issueID: "bd-created")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let exportsBeforeCreate = await commands.exportCallCount
        await commands.setExportDelay(.milliseconds(400))

        let createTask = Task { @MainActor in
            await store.createBead(self.draft(title: "Committed create"), revealCreated: true)
        }
        try await waitUntilAsync {
            await commands.exportCallCount > exportsBeforeCreate
        }
        let exportsBeforeRefresh = await commands.exportCallCount
        store.refresh()
        try await Task.sleep(for: .milliseconds(100))
        let exportsDuringCreate = await commands.exportCallCount
        XCTAssertEqual(exportsDuringCreate, exportsBeforeRefresh)
        await commands.setExportDelay(nil)

        let createdIssueID = await createTask.value
        XCTAssertEqual(createdIssueID, "bd-created")
        XCTAssertEqual(store.issue(with: "bd-created")?.title, "Committed create")
    }

    func testCreateRejectsGateDraftWithoutInvokingNormalCreate() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        var gateDraft = draft(title: "Gate from normal create")
        gateDraft.issueType = " gate "

        let succeeded = await store.save(gateDraft)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.lastError, BeadIssueWorkflowPolicy.reservedIssueTypeError)
        let calls = await commands.createCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testUpdateRejectsChangingNormalBeadToGate() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        let issue = try XCTUnwrap(store.issue(with: "bd-1"))
        var gateDraft = IssueDraft(issue: issue)
        gateDraft.issueType = " gate "

        let succeeded = await store.save(gateDraft)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.issue(with: "bd-1")?.issueType, "task")
        XCTAssertEqual(store.lastError, BeadIssueWorkflowPolicy.reservedIssueTypeError)
        let calls = await commands.updateCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testBulkTypeChangeRejectsGateTypeAndGateSelections() async throws {
        let projectURL = try makeProject(gateProjectJSONL(gateUpdatedAt: "2026-07-03T21:58:35Z"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-task") != nil }
        store.select(["bd-task"])
        XCTAssertTrue(store.canSetTypeForSelection)
        store.select(["bd-gate"])
        XCTAssertFalse(store.canSetTypeForSelection)

        let didSetTaskToGate = await store.bulkSet(issueIDs: ["bd-task"], type: "gate")
        let didSetGateToTask = await store.bulkSet(issueIDs: ["bd-gate"], type: "task")

        XCTAssertFalse(didSetTaskToGate)
        XCTAssertFalse(didSetGateToTask)
        XCTAssertEqual(store.issue(with: "bd-task")?.issueType, "task")
        XCTAssertEqual(store.issue(with: "bd-gate")?.issueType, "gate")
        XCTAssertEqual(store.lastError, BeadIssueWorkflowPolicy.reservedIssueTypeError)
        let calls = await commands.bulkUpdateCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testForcedCommentRefreshSetsAndClearsLoadingStateOnSuccess() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setComments(
            [BeadComment(id: "comment-1", issueID: "bd-1", author: nil, text: "Fresh comment", createdAt: nil, updatedAt: nil)],
            for: "bd-1"
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.select(["bd-1"])

        store.loadCommentsForSelection(force: true)

        XCTAssertTrue(store.isLoadingComments)
        try await waitUntil { !store.isLoadingComments }
        XCTAssertEqual(store.comments.map(\.text), ["Fresh comment"])
        XCTAssertNil(store.lastError)
        XCTAssertNil(store.commentLoadError(for: "bd-1"))
    }

    func testForcedCommentRefreshClearsLoadingStateOnFailure() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setCommentLoadError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.select(["bd-1"])
        store.loadCommentsForSelection(force: true)

        XCTAssertTrue(store.isLoadingComments)
        try await waitUntil { !store.isLoadingComments && store.commentLoadError(for: "bd-1") != nil }
        XCTAssertEqual(store.commentLoadError(for: "bd-1"), StoreMutationTestError.commandFailed.localizedDescription)
        XCTAssertNil(store.lastError)
    }

    func testRapidSelectionOnlyAppliesLatestSelectionSideData() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-a","title":"A","status":"open","priority":1,"issue_type":"task","dependencies":[{"depends_on_id":"bd-common","type":"blocks"}],"comments":[{"id":"comment-a","body":"A comment"}]}
            {"_type":"issue","id":"bd-b","title":"B","status":"open","priority":1,"issue_type":"task","dependencies":[{"depends_on_id":"bd-other","type":"blocks"}],"comments":[{"id":"comment-b","body":"B comment"}]}
            {"_type":"issue","id":"bd-common","title":"Common","status":"open","priority":1,"issue_type":"task"}
            {"_type":"issue","id":"bd-other","title":"Other","status":"open","priority":1,"issue_type":"task"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setComments(
            [BeadComment(id: "comment-a", issueID: "bd-a", author: nil, text: "A comment", createdAt: nil, updatedAt: nil)],
            for: "bd-a"
        )
        await commands.setComments(
            [BeadComment(id: "comment-b", issueID: "bd-b", author: nil, text: "B comment", createdAt: nil, updatedAt: nil)],
            for: "bd-b"
        )
        await commands.setCommentLoadDelay(.milliseconds(100))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-a") != nil && store.issue(with: "bd-b") != nil }

        store.select(["bd-a"])
        store.loadCommentsForSelection()
        store.select(["bd-b"])
        store.loadCommentsForSelection()

        try await waitUntil {
            store.dependencyIssueID == "bd-b"
                && store.commentsIssueID == "bd-b"
                && !store.isLoadingComments
                && store.comments.map(\.id) == ["comment-b"]
        }
        XCTAssertEqual(store.selectedIDs, Set(["bd-b"]))
        XCTAssertEqual(store.dependencies.map(\.issueID), ["bd-b"])
        XCTAssertEqual(store.dependencies.map(\.dependsOnID), ["bd-other"])
        XCTAssertEqual(store.comments.map(\.id), ["comment-b"])
        XCTAssertTrue(store.comments(for: "bd-a").isEmpty)
    }

    func testRapidSelectionOnlyPublishesLatestIssueActivity() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-a","title":"A","status":"open","priority":1,"issue_type":"task","created_at":"2026-07-03T20:00:00Z"}
            {"_type":"issue","id":"bd-b","title":"B","status":"open","priority":1,"issue_type":"task","created_at":"2026-07-03T20:00:00Z"}
            """
        )
        let interactions = """
        {"id":"int-a","kind":"field_change","created_at":"2026-07-03T20:01:00Z","issue_id":"bd-a","extra":{"field":"priority","old_value":"2","new_value":"1"}}
        {"id":"int-b","kind":"field_change","created_at":"2026-07-03T20:02:00Z","issue_id":"bd-b","extra":{"field":"assignee","new_value":"ransom"}}
        """
        try interactions.write(
            to: projectURL.appendingPathComponent(".beads/interactions.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-b") != nil }

        store.select(["bd-a"])
        store.select(["bd-b"])

        try await waitUntil {
            store.activityIssueID == "bd-b"
                && !store.isLoadingActivity(for: "bd-b")
                && store.activityItems(for: "bd-b").contains { $0.id == "event-int-b" }
        }
        XCTAssertTrue(store.activityItems(for: "bd-a").isEmpty)
        XCTAssertFalse(store.activityItems(for: "bd-b").contains { $0.id == "event-int-a" })
    }

    func testGatePresentationComesFromSnapshotWithoutGateRoster() async throws {
        let projectURL = try makeProject(gateProjectJSONL(gateUpdatedAt: "2026-07-03T21:58:35Z"))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-gate") != nil }

        let gate = try XCTUnwrap(store.gate(for: "bd-gate"))
        XCTAssertEqual(gate.awaitType, .timer)
        XCTAssertEqual(gate.timeoutNanoseconds, 3_600_000_000_000)
        XCTAssertEqual(gate.reason, "Ship review")
        XCTAssertEqual(gate.blocksIssueID, "bd-task")

        let blockingGates = store.gatesBlocking(issueID: "bd-task")
        XCTAssertEqual(blockingGates.map(\.id), ["bd-gate"])
        XCTAssertEqual(blockingGates.first?.awaitType, .timer)

        store.applyBookmark(.gates)
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["bd-gate", "bd-task"])
    }

    func testBlockedReasonPresentationClassifiesSnapshotBlockersAndBlockedBookmarkOnly() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-active","title":"Active blocked","status":"blocked","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"bd-blocker","type":"blocks"}]}
            {"_type":"issue","id":"bd-gated","title":"Gate blocked","status":"blocked","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"g-human","type":"blocks"}]}
            {"_type":"issue","id":"bd-external","title":"External blocked","status":"blocked","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"external:project:capability","type":"blocks"}]}
            {"_type":"issue","id":"bd-resolved","title":"Resolved gate blocked","status":"blocked","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"g-closed","type":"blocks"}]}
            {"_type":"issue","id":"bd-manual","title":"Manual blocked","status":"blocked","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            {"_type":"issue","id":"bd-parent","title":"Parent blocked by child","status":"blocked","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            {"_type":"issue","id":"bd-child","title":"Child blocked","status":"blocked","priority":0,"issue_type":"task","parent_id":"bd-parent","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"bd-blocker","type":"blocks"}]}
            {"_type":"issue","id":"bd-low-child","title":"Low priority child blocked","status":"blocked","priority":3,"issue_type":"task","parent_id":"bd-parent","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"bd-blocker","type":"blocks"}]}
            {"_type":"issue","id":"bd-open-parent","title":"Open parent with gated child","status":"open","priority":1,"issue_type":"epic","updated_at":"2026-07-03T20:58:35Z"}
            {"_type":"issue","id":"bd-gated-child","title":"Gated child","status":"blocked","priority":0,"issue_type":"task","parent_id":"bd-open-parent","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"g-human","type":"blocks"}]}
            {"_type":"issue","id":"bd-blocker","title":"Fix upstream","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            {"_type":"issue","id":"g-human","title":"Human gate","description":"Ad-hoc gate blocking bd-gated\\n\\nReason: Need approval","status":"open","priority":1,"issue_type":"gate","await_type":"human","updated_at":"2026-07-03T20:58:35Z"}
            {"_type":"issue","id":"g-closed","title":"Closed gate","description":"Ad-hoc gate blocking bd-resolved\\n\\nReason: PR merged","status":"closed","priority":1,"issue_type":"gate","await_type":"gh:pr","await_id":"42","updated_at":"2026-07-03T20:58:35Z","closed_at":"2026-07-03T21:58:35Z"}
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-manual") != nil }
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(store.blockedReasonPresentation(for: "bd-active", bookmark: .all, now: now))
        XCTAssertNil(store.blockedReasonPresentation(for: "bd-active", bookmark: .open, now: now))

        let active = try XCTUnwrap(store.blockedReasonPresentation(for: "bd-active", bookmark: .blocked, now: now))
        XCTAssertEqual(active.kind, .issue)
        XCTAssertEqual(active.title, "Blocked by bd-blocker: Fix upstream")

        let gated = try XCTUnwrap(store.blockedReasonPresentation(for: "bd-gated", bookmark: .blocked, now: now))
        XCTAssertEqual(gated.kind, .gate)
        XCTAssertEqual(gated.title, "Waiting on Awaiting approval")
        XCTAssertTrue(gated.help.contains("Reason: Need approval"))

        let external = try XCTUnwrap(store.blockedReasonPresentation(for: "bd-external", bookmark: .blocked, now: now))
        XCTAssertEqual(external.kind, .external)
        XCTAssertEqual(external.title, "Blocked by external reference")
        XCTAssertTrue(external.help.contains("external:project:capability"))

        let resolved = try XCTUnwrap(store.blockedReasonPresentation(for: "bd-resolved", bookmark: .blocked, now: now))
        XCTAssertEqual(resolved.kind, .resolvedGate)
        XCTAssertEqual(resolved.title, "Resolved gate; status still blocked")
        XCTAssertTrue(resolved.help.contains("Gate g-closed: Awaiting PR #42"))

        let manual = try XCTUnwrap(store.blockedReasonPresentation(for: "bd-manual", bookmark: .blocked, now: now))
        XCTAssertEqual(manual.kind, .unexplained)
        XCTAssertEqual(manual.title, "Marked blocked; no active blocker found")

        let parent = try XCTUnwrap(store.blockedReasonPresentation(for: "bd-parent", bookmark: .blocked, now: now))
        XCTAssertEqual(parent.kind, .subissue)
        XCTAssertEqual(parent.title, "Sub-issue blocked by bd-blocker: Fix upstream")
        XCTAssertTrue(parent.help.contains("Sub-issue bd-child: Child blocked"))

        XCTAssertNil(store.blockedReasonPresentation(for: "bd-open-parent", now: now))
        XCTAssertNil(store.blockedReasonPresentation(for: "bd-open-parent", bookmark: .all, now: now))
        let openParent = try XCTUnwrap(store.blockedReasonPresentation(for: "bd-open-parent", bookmark: .blocked, now: now))
        XCTAssertEqual(openParent.kind, .subissue)
        XCTAssertEqual(openParent.title, "Sub-issue waiting on Awaiting approval")
        XCTAssertTrue(openParent.help.contains("Sub-issue bd-gated-child: Gated child"))
    }

    func testGatesBookmarkIgnoresActiveFiltersAndUserSortWithoutClearingThem() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"g-pending","title":"A Pending gate","status":"open","priority":1,"issue_type":"gate","await_type":"gh:pr","updated_at":"2026-07-03T21:58:35Z"}
            {"_type":"issue","id":"g-human","title":"Z Human gate","status":"open","priority":1,"issue_type":"gate","await_type":"human","updated_at":"2026-07-03T21:58:35Z"}
            {"_type":"issue","id":"bd-low","title":"Low blocked bead","status":"open","priority":3,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"g-pending","type":"blocks"}]}
            {"_type":"issue","id":"bd-high","title":"High blocked bead","status":"open","priority":0,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"g-human","type":"blocks"}]}
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "g-human") != nil }

        store.setStatusFilter("closed", isOn: true)
        store.setTypeFilter("bug", isOn: true)
        store.setPriorityFilter(4, isOn: true)
        store.setLabelFilter("missing", isOn: true)
        store.sort = .title
        store.sortDirection = .ascending
        store.applyBookmark(.gates)
        await store.waitForPendingQueryRecompute()

        XCTAssertTrue(store.hasActiveFilters)
        XCTAssertEqual(store.sort, .title)
        XCTAssertEqual(store.sortDirection, .ascending)
        XCTAssertEqual(store.issueListRows.map(\.issueID), ["g-human", "bd-high", "g-pending", "bd-low"])

        store.applyBookmark(.all)
        await store.waitForPendingQueryRecompute()
        XCTAssertTrue(store.issueListRows.isEmpty)
    }

    func testNextGateTimerExpiryUsesFutureOpenTimerGatesOnly() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"g-elapsed","title":"Elapsed timer","status":"open","priority":1,"issue_type":"gate","await_type":"timer","timeout":3600000000000,"created_at":"2026-07-03T20:00:00Z","updated_at":"2026-07-03T20:00:00Z"}
            {"_type":"issue","id":"g-next","title":"Next timer","status":"open","priority":1,"issue_type":"gate","await_type":"timer","timeout":7200000000000,"created_at":"2026-07-03T20:00:00Z","updated_at":"2026-07-03T20:00:00Z"}
            {"_type":"issue","id":"g-human","title":"Human gate","status":"open","priority":1,"issue_type":"gate","await_type":"human","updated_at":"2026-07-03T20:00:00Z"}
            {"_type":"issue","id":"g-closed","title":"Closed future timer","status":"closed","priority":1,"issue_type":"gate","await_type":"timer","timeout":10800000000000,"created_at":"2026-07-03T20:00:00Z","updated_at":"2026-07-03T20:00:00Z","closed_at":"2026-07-03T20:00:00Z"}
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "g-next") != nil }

        let now = try XCTUnwrap(BeadFormatters.parseDate("2026-07-03T21:30:00Z"))
        let expectedNextExpiry = try XCTUnwrap(BeadFormatters.parseDate("2026-07-03T22:00:00Z"))

        XCTAssertNil(store.nextGateTimerExpiry(after: now))
        store.applyBookmark(.gates)
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.nextGateTimerExpiry(after: now), expectedNextExpiry)
    }

    func testNextGateTimerExpiryIncludesTimerGatesBlockingBlockedRows() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"g-elapsed","title":"Elapsed timer","status":"open","priority":1,"issue_type":"gate","await_type":"timer","timeout":3600000000000,"created_at":"2026-07-03T20:00:00Z","updated_at":"2026-07-03T20:00:00Z"}
            {"_type":"issue","id":"g-next","title":"Next timer","status":"open","priority":1,"issue_type":"gate","await_type":"timer","timeout":7200000000000,"created_at":"2026-07-03T20:00:00Z","updated_at":"2026-07-03T20:00:00Z"}
            {"_type":"issue","id":"g-unlinked","title":"Unlinked timer","status":"open","priority":1,"issue_type":"gate","await_type":"timer","timeout":5400000000000,"created_at":"2026-07-03T20:00:00Z","updated_at":"2026-07-03T20:00:00Z"}
            {"_type":"issue","id":"g-closed","title":"Closed future timer","status":"closed","priority":1,"issue_type":"gate","await_type":"timer","timeout":10800000000000,"created_at":"2026-07-03T20:00:00Z","updated_at":"2026-07-03T20:00:00Z","closed_at":"2026-07-03T20:00:00Z"}
            {"_type":"issue","id":"bd-elapsed","title":"Elapsed blocked","status":"blocked","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"g-elapsed","type":"blocks"}]}
            {"_type":"issue","id":"bd-next","title":"Next blocked","status":"blocked","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"g-next","type":"blocks"}]}
            {"_type":"issue","id":"bd-closed","title":"Closed gate blocked","status":"blocked","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"g-closed","type":"blocks"}]}
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-next") != nil }

        let now = try XCTUnwrap(BeadFormatters.parseDate("2026-07-03T21:30:00Z"))
        let expectedNextExpiry = try XCTUnwrap(BeadFormatters.parseDate("2026-07-03T22:00:00Z"))

        XCTAssertNil(store.nextGateTimerExpiry(after: now))
        store.applyBookmark(.blocked)
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.nextGateTimerExpiry(after: now), expectedNextExpiry)
    }

    func testSelectedGateLoadsWaitersOnlyWhenGateUpdatedAtChanges() async throws {
        let projectURL = try makeProject(gateProjectJSONL(gateUpdatedAt: "2026-07-03T21:58:35Z"))
        let commands = RecordingBeadsCommands()
        await commands.setGateDetail(gateDetail(updatedAt: "2026-07-03T21:58:35Z", waiters: ["bd-task"]))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-gate") != nil }

        store.select(["bd-gate"])

        try await waitUntil { store.gate(for: "bd-gate")?.waiters == ["bd-task"] }
        var loadGateDetailCalls = await commands.loadGateDetailCalls
        XCTAssertEqual(loadGateDetailCalls.map(\.id), ["bd-gate"])

        let revision = store.contentRevision
        store.refresh()
        try await waitUntil { !store.isLoading && store.contentRevision > revision }
        try await Task.sleep(for: .milliseconds(100))
        loadGateDetailCalls = await commands.loadGateDetailCalls
        XCTAssertEqual(loadGateDetailCalls.map(\.id), ["bd-gate"])

        await commands.setGateDetail(gateDetail(updatedAt: "2026-07-03T22:58:35Z", waiters: ["bd-task", "bd-other"]))
        try gateProjectJSONL(gateUpdatedAt: "2026-07-03T22:58:35Z").write(
            to: projectURL.appendingPathComponent(".beads/issues.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        store.refresh()

        try await waitUntil { store.gate(for: "bd-gate")?.waiters == ["bd-task", "bd-other"] }
        loadGateDetailCalls = await commands.loadGateDetailCalls
        XCTAssertEqual(loadGateDetailCalls.map(\.id), ["bd-gate", "bd-gate"])
    }

    func testGateActionWrappersInvokeCommands() async throws {
        let projectURL = try makeProject(gateProjectJSONL(gateUpdatedAt: "2026-07-03T21:58:35Z"))
        let commands = RecordingBeadsCommands()
        await commands.setCheckGatesOutput("checked 1 gate")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-gate") != nil }

        let didResolve = await store.resolveGate(id: "bd-gate", reason: " approved ")
        let checkOutput = await store.checkGates(type: "timer", escalate: true, dryRun: true)
        let didCreate = await store.createGate(
            blocks: "bd-task",
            type: .githubPR,
            reason: " needs review ",
            timeout: " ",
            awaitID: " 42 "
        )
        let didAddWaiter = await store.addGateWaiter(id: "bd-gate", waiter: " bd-task ")

        XCTAssertTrue(didResolve)
        XCTAssertEqual(checkOutput, "checked 1 gate")
        XCTAssertTrue(didCreate)
        XCTAssertTrue(didAddWaiter)

        let resolveGateCalls = await commands.resolveGateCalls
        let checkGatesCalls = await commands.checkGatesCalls
        let createGateCalls = await commands.createGateCalls
        let addGateWaiterCalls = await commands.addGateWaiterCalls

        XCTAssertEqual(resolveGateCalls.map(\.id), ["bd-gate"])
        XCTAssertEqual(resolveGateCalls.first?.reason, "approved")
        XCTAssertEqual(checkGatesCalls.first?.type, "timer")
        XCTAssertEqual(checkGatesCalls.first?.escalate, true)
        XCTAssertEqual(checkGatesCalls.first?.dryRun, true)
        XCTAssertEqual(createGateCalls.first?.blocks, "bd-task")
        XCTAssertEqual(createGateCalls.first?.type, .githubPR)
        XCTAssertEqual(createGateCalls.first?.reason, "needs review")
        XCTAssertNil(createGateCalls.first?.timeout)
        XCTAssertEqual(createGateCalls.first?.awaitID, "42")
        XCTAssertEqual(addGateWaiterCalls.first?.waiter, "bd-task")
        XCTAssertNil(store.lastError)
    }

    func testCreateGateRejectsClosedBlockedBeads() async throws {
        let projectURL = try makeProject(closedIssueLine(id: "bd-closed", title: "Closed"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-closed") != nil }

        let didCreate = await store.createGate(
            blocks: "bd-closed",
            type: .human,
            reason: nil,
            timeout: nil,
            awaitID: nil
        )

        XCTAssertFalse(didCreate)
        XCTAssertEqual(store.lastError, "Reopen bd-closed before creating a gate.")
        let createGateCalls = await commands.createGateCalls
        XCTAssertTrue(createGateCalls.isEmpty)
    }

    func testCreateGateRejectsEpicsBeforeInvokingCommand() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-epic", title: "Epic", issueType: "epic"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-epic") != nil }

        let didCreate = await store.createGate(
            blocks: "bd-epic",
            type: .human,
            reason: nil,
            timeout: nil,
            awaitID: nil
        )

        XCTAssertFalse(didCreate)
        XCTAssertEqual(store.lastError, BeadIssueWorkflowPolicy.unsupportedEpicGateError)
        let createGateCalls = await commands.createGateCalls
        XCTAssertTrue(createGateCalls.isEmpty)
    }

    func testApprovingHumanGateOpensEligibleBlockedBeads() async throws {
        let projectURL = try makeProject(gateProjectJSONL(
            gateUpdatedAt: "2026-07-03T21:58:35Z",
            awaitType: "human",
            taskStatus: "blocked"
        ))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-task") != nil }

        let didApprove = await store.approveGate(id: "bd-gate", reason: " approved ")

        XCTAssertTrue(didApprove)
        XCTAssertEqual(store.issue(with: "bd-task")?.status, "open")
        let resolveGateCalls = await commands.resolveGateCalls
        let bulkUpdateCalls = await commands.bulkUpdateCalls
        XCTAssertEqual(resolveGateCalls.map(\.id), ["bd-gate"])
        XCTAssertEqual(resolveGateCalls.first?.reason, "approved")
        XCTAssertEqual(bulkUpdateCalls.map(\.ids), [["bd-task"]])
        XCTAssertEqual(bulkUpdateCalls.map(\.status), ["open"])
    }

    func testApprovingHumanGateDoesNotOpenBeadWithAnotherActiveBlocker() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-gate","title":"Human gate","description":"Ad-hoc gate blocking bd-task","status":"open","priority":1,"issue_type":"gate","await_type":"human","updated_at":"2026-07-03T21:58:35Z"}
            {"_type":"issue","id":"bd-other","title":"Other blocker","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            {"_type":"issue","id":"bd-task","title":"Ship app","status":"blocked","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"bd-gate","type":"blocks"},{"depends_on_id":"bd-other","type":"blocks"}]}
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-task") != nil }

        let didApprove = await store.approveGate(id: "bd-gate", reason: nil)

        XCTAssertTrue(didApprove)
        XCTAssertEqual(store.issue(with: "bd-task")?.status, "blocked")
        let bulkUpdateCalls = await commands.bulkUpdateCalls
        XCTAssertTrue(bulkUpdateCalls.isEmpty)
    }

    func testRejectingHumanGateAppliesSelectedStatus() async throws {
        let projectURL = try makeProject(gateProjectJSONL(
            gateUpdatedAt: "2026-07-03T21:58:35Z",
            awaitType: "human",
            taskStatus: "blocked"
        ))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-task") != nil }

        let rejectedWithoutReason = await store.rejectGate(id: "bd-gate", reason: " ", targetStatus: "deferred")
        let didReject = await store.rejectGate(id: "bd-gate", reason: "not enough evidence", targetStatus: "deferred")

        XCTAssertFalse(rejectedWithoutReason)
        XCTAssertTrue(didReject)
        XCTAssertEqual(store.issue(with: "bd-task")?.status, "deferred")
        let resolveGateCalls = await commands.resolveGateCalls
        let bulkUpdateCalls = await commands.bulkUpdateCalls
        XCTAssertEqual(resolveGateCalls.map(\.reason), ["Rejected: not enough evidence"])
        XCTAssertEqual(bulkUpdateCalls.map(\.ids), [["bd-task"]])
        XCTAssertEqual(bulkUpdateCalls.map(\.status), ["deferred"])
        XCTAssertEqual(bulkUpdateCalls.map(\.deferUntil), [.set(nil)])
    }

    func testRejectingHumanGateCanClearDeferredDateForDeferredStatus() async throws {
        let projectURL = try makeProject(gateProjectJSONL(
            gateUpdatedAt: "2026-07-03T21:58:35Z",
            awaitType: "human",
            taskStatus: "blocked",
            taskDeferUntil: "2026-07-11"
        ))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-task") != nil }

        let didReject = await store.rejectGate(
            id: "bd-gate",
            reason: "not enough evidence",
            targetStatus: "deferred",
            deferUntil: .set(nil)
        )

        XCTAssertTrue(didReject)
        XCTAssertEqual(store.issue(with: "bd-task")?.status, "deferred")
        XCTAssertNil(store.issue(with: "bd-task")?.deferUntil)
        let bulkUpdateCalls = await commands.bulkUpdateCalls
        XCTAssertEqual(bulkUpdateCalls.map(\.ids), [["bd-task"]])
        XCTAssertEqual(bulkUpdateCalls.map(\.status), ["deferred"])
        XCTAssertEqual(bulkUpdateCalls.map(\.deferUntil), [.set(nil)])
    }

    func testRejectingHumanGateCanSetDeferredDateForDeferredStatus() async throws {
        let projectURL = try makeProject(gateProjectJSONL(
            gateUpdatedAt: "2026-07-03T21:58:35Z",
            awaitType: "human",
            taskStatus: "blocked"
        ))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-task") != nil }
        let deferUntil = try XCTUnwrap(BeadFormatters.parseDate("2026-08-01"))

        let didReject = await store.rejectGate(
            id: "bd-gate",
            reason: "not enough evidence",
            targetStatus: "deferred",
            deferUntil: .set(deferUntil)
        )

        XCTAssertTrue(didReject)
        XCTAssertEqual(store.issue(with: "bd-task")?.status, "deferred")
        XCTAssertEqual(store.issue(with: "bd-task")?.deferUntil, deferUntil)
        let bulkUpdateCalls = await commands.bulkUpdateCalls
        XCTAssertEqual(bulkUpdateCalls.map(\.ids), [["bd-task"]])
        XCTAssertEqual(bulkUpdateCalls.map(\.status), ["deferred"])
        XCTAssertEqual(bulkUpdateCalls.map(\.deferUntil), [.set(deferUntil)])
    }

    func testRejectingHumanGateWithClosedStatusUsesCloseReason() async throws {
        let projectURL = try makeProject(gateProjectJSONL(
            gateUpdatedAt: "2026-07-03T21:58:35Z",
            awaitType: "human",
            taskStatus: "blocked"
        ))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-task") != nil }

        let didReject = await store.rejectGate(id: "bd-gate", reason: "validation failed", targetStatus: "closed")

        XCTAssertTrue(didReject)
        XCTAssertEqual(store.issue(with: "bd-task")?.status, "closed")
        let closeCalls = await commands.closeCalls
        XCTAssertEqual(closeCalls.map(\.ids), [["bd-task"]])
        XCTAssertEqual(closeCalls.map(\.reason), ["Rejected: validation failed"])
    }

    func testClosedGatesDoNotRenderAsActiveBlockersAndCanSurfaceStaleBlockedRepair() async throws {
        let projectURL = try makeProject(gateProjectJSONL(
            gateUpdatedAt: "2026-07-03T21:58:35Z",
            gateStatus: "closed",
            awaitType: "human",
            taskStatus: "blocked"
        ))
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-task") != nil }

        XCTAssertTrue(store.gatesBlocking(issueID: "bd-task").isEmpty)
        XCTAssertEqual(store.resolvedGatesBlocking(issueID: "bd-task").map(\.id), ["bd-gate"])
        XCTAssertEqual(store.resolvedGatesForStaleBlockedIssue(issueID: "bd-task").map(\.id), ["bd-gate"])
    }

    func testActiveBlockedSubissueSuppressesStaleGateRepairForParent() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-parent","title":"Parent","status":"blocked","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"bd-gate","type":"blocks"}]}
            {"_type":"issue","id":"bd-child","title":"Child","status":"blocked","priority":0,"issue_type":"task","parent_id":"bd-parent","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"bd-blocker","type":"blocks"}]}
            {"_type":"issue","id":"bd-blocker","title":"Fix upstream","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            {"_type":"issue","id":"bd-gate","title":"Closed gate","description":"Ad-hoc gate blocking bd-parent\\n\\nReason: Already cleared","status":"closed","priority":1,"issue_type":"gate","await_type":"human","updated_at":"2026-07-03T21:58:35Z","closed_at":"2026-07-03T21:58:35Z"}
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-parent") != nil }

        XCTAssertEqual(store.resolvedGatesForStaleBlockedIssue(issueID: "bd-parent").map(\.id), [])
        let parent = try XCTUnwrap(store.blockedReasonPresentation(for: "bd-parent", now: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(parent.kind, .subissue)
        XCTAssertEqual(parent.title, "Sub-issue blocked by bd-blocker: Fix upstream")
    }

    func testSetParentOptimisticallyUpdatesParentAndUsesParentCommand() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child"))
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-child") != nil }

        let didSet = await store.setParent(issueID: "bd-child", parentID: "bd-parent")

        XCTAssertTrue(didSet)
        XCTAssertEqual(store.parentIssue(for: "bd-child")?.id, "bd-parent")
        XCTAssertEqual(store.issue(with: "bd-child")?.parentID, "bd-parent")
        let calls = await commands.setParentCalls
        XCTAssertEqual(calls.map(\.issueID), ["bd-child"])
        XCTAssertEqual(calls.map(\.parentID), ["bd-parent"])
    }

    func testQueuedSetParentRetriesSameValueAfterEarlierFailureRollsBack() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child"))
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setSetParentDelays([.milliseconds(300), nil])
        await commands.setSetParentErrors([StoreMutationTestError.commandFailed, nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-child") != nil }

        let firstTask = Task { @MainActor in
            await store.setParent(issueID: "bd-child", parentID: "bd-parent")
        }
        try await waitUntil { store.issue(with: "bd-child")?.parentID == "bd-parent" }
        let secondTask = Task { @MainActor in
            await store.setParent(issueID: "bd-child", parentID: "bd-parent")
        }

        let firstSucceeded = await firstTask.value
        let secondSucceeded = await secondTask.value
        XCTAssertFalse(firstSucceeded)
        XCTAssertTrue(secondSucceeded)
        XCTAssertEqual(store.issue(with: "bd-child")?.parentID, "bd-parent")
        let calls = await commands.setParentCalls
        XCTAssertEqual(calls.map(\.parentID), ["bd-parent", "bd-parent"])
    }

    func testSetStateSwapsDimensionLabelOptimisticallyAndUsesSetStateCommand() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"Task","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design","keeper"]}
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let didSet = await store.setState(issueID: "bd-1", dimension: "phase", value: "implementation", reason: "Design proven")

        XCTAssertTrue(didSet)
        let labels = store.issue(with: "bd-1")?.labels ?? []
        XCTAssertTrue(labels.contains("phase:implementation"))
        XCTAssertTrue(labels.contains("keeper"))
        XCTAssertFalse(labels.contains("phase:design"))
        let calls = await commands.setStateCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.issueID, "bd-1")
        XCTAssertEqual(calls.first?.dimension, "phase")
        XCTAssertEqual(calls.first?.value, "implementation")
        XCTAssertEqual(calls.first?.reason, "Design proven")
    }

    func testClearStateRemovesDimensionLabelOptimisticallyAndRecordsReason() async throws {
        let projectURL = try makeProject(
            #"{"_type":"issue","id":"bd-1","title":"Task","status":"open","priority":1,"issue_type":"task","labels":["phase:implementation","keeper"],"updated_at":"2026-07-03T20:58:35Z"}"#
        )
        let commands = RecordingBeadsCommands()
        await commands.setClearStateDelays([.milliseconds(250)])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let clearTask = Task { @MainActor in
            await store.clearState(issueID: "bd-1", dimension: "phase", reason: "Reset workflow")
        }
        try await waitUntil {
            BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-1")?.labels ?? []) == nil
        }

        XCTAssertEqual(
            BeadStateLabel.value(of: "phase", in: store.index.issue(with: "bd-1")?.labels ?? []),
            "implementation",
            "Clearing a state should not rebuild the project index on the interaction path."
        )
        XCTAssertTrue(store.issue(with: "bd-1")?.labels.contains("keeper") == true)
        let didClear = await clearTask.value
        XCTAssertTrue(didClear)
        let calls = await commands.clearStateCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.issueID, "bd-1")
        XCTAssertEqual(calls.first?.dimension, "phase")
        XCTAssertEqual(calls.first?.currentValue, "implementation")
        XCTAssertEqual(calls.first?.reason, "Reset workflow")
    }

    func testBulkAddLabelsPreservesExistingLabelsAndUsesOneAdditiveCommand() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design","keeper"]}
            {"_type":"issue","id":"bd-2","title":"Two","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["existing"]}
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }

        let result = await store.addLabels(
            issueIDs: ["bd-2", "bd-1"],
            labels: ["new", "second"]
        )

        XCTAssertTrue(result.isSuccessful)
        XCTAssertEqual(result.progress, BulkMutationProgress(
            completedCount: 2,
            totalCount: 2,
            succeededCount: 2,
            failedCount: 0
        ))
        XCTAssertEqual(
            Set(store.issue(with: "bd-1")?.labels ?? []),
            ["phase:design", "keeper", "new", "second"]
        )
        XCTAssertEqual(
            Set(store.issue(with: "bd-2")?.labels ?? []),
            ["existing", "new", "second"]
        )
        let calls = await commands.addLabelsCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.ids, ["bd-1", "bd-2"])
        XCTAssertEqual(calls.first?.labels, ["new", "second"])
    }

    func testBulkAddLabelsSkipsBeadsThatAlreadyHaveEveryLabel() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["new"]}
            {"_type":"issue","id":"bd-2","title":"Two","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }

        let result = await store.addLabels(issueIDs: ["bd-1", "bd-2"], labels: ["new"])

        XCTAssertTrue(result.isSuccessful)
        XCTAssertEqual(result.progress.totalCount, 1)

        let calls = await commands.addLabelsCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-2"]])
    }

    func testBulkAddLabelsFailureRollsBackEveryTargetAndUsesStandardRetry() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["one"]}
            {"_type":"issue","id":"bd-2","title":"Two","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["two"]}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setAddLabelsError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }

        let result = await store.addLabels(issueIDs: ["bd-1", "bd-2"], labels: ["new"])

        XCTAssertFalse(result.isSuccessful)
        XCTAssertEqual(result.progress.failedCount, 2)
        XCTAssertEqual(store.issue(with: "bd-1")?.labels, ["one"])
        XCTAssertEqual(store.issue(with: "bd-2")?.labels, ["two"])
        XCTAssertEqual(store.currentFailure?.title, "Couldn't add labels to 2 beads")
        XCTAssertTrue(store.currentFailure?.isRetryable == true)
    }

    func testBulkAddLabelsKeepsSuccessfulChunksAndRetriesOnlyFailedBeads() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["one"]}
            {"_type":"issue","id":"bd-2","title":"Two","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["two"]}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setAddLabelsErrors([
            nil,
            BeadError.commandFailed(command: "bd update bd-2 --add-label new", output: "second batch failed")
        ])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }

        let result = await store.addLabels(
            issueIDs: ["bd-1", "bd-2"],
            labels: ["new"],
            maximumCommandArgumentBytes: 28
        )

        XCTAssertFalse(result.isSuccessful)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.progress.succeededCount, 1)
        XCTAssertEqual(result.progress.failedCount, 1)
        XCTAssertEqual(result.failedIssueIDs, ["bd-2"])
        XCTAssertEqual(Set(store.issue(with: "bd-1")?.labels ?? []), ["one", "new"])
        XCTAssertEqual(store.issue(with: "bd-2")?.labels, ["two"])
        var calls = await commands.addLabelsCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-1"], ["bd-2"]])
        XCTAssertEqual(store.currentFailure?.command, "bd update bd-2 --add-label new")
        XCTAssertEqual(store.currentFailure?.output, "second batch failed")

        await commands.setAddLabelsErrors([nil])
        store.retryCurrentFailure()
        try await waitUntilAsync { await commands.addLabelsCalls.count == 3 }

        calls = await commands.addLabelsCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-1"], ["bd-2"], ["bd-2"]])
        XCTAssertNil(store.currentFailure)
    }

    func testBulkAddLabelsStopsBeforeNextChunkAndKeepsCompletedChanges() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            {"_type":"issue","id":"bd-2","title":"Two","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setAddLabelsDelays([.milliseconds(300)])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }

        let task = Task { @MainActor in
            await store.addLabels(
                issueIDs: ["bd-1", "bd-2"],
                labels: ["new"],
                maximumCommandArgumentBytes: 28
            )
        }
        try await waitUntilAsync { await commands.addLabelsCalls.count == 1 }
        task.cancel()

        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.progress.completedCount, 1)
        XCTAssertEqual(result.progress.succeededCount, 1)
        XCTAssertEqual(result.progress.remainingCount, 1)
        XCTAssertEqual(Set(store.issue(with: "bd-1")?.labels ?? []), ["new"])
        XCTAssertEqual(store.issue(with: "bd-2")?.labels, [])
        let calls = await commands.addLabelsCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-1"]])
        XCTAssertNil(store.currentFailure)
    }

    func testBulkAddLabelsRejectsManagedPropertyLabelsBeforeRunningCommand() async throws {
        let projectURL = try makeProject(
            #"{"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design","keeper"]}"#
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        XCTAssertTrue(store.pinStateDimension("phase"))

        let result = await store.addLabels(issueIDs: ["bd-1"], labels: ["phase:ready"])

        XCTAssertFalse(result.isSuccessful)
        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertEqual(Set(store.issue(with: "bd-1")?.labels ?? []), ["phase:design", "keeper"])
        XCTAssertTrue(store.currentFailure?.message.contains("Use Set Property") == true)
        let calls = await commands.addLabelsCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testBulkSetStateContinuesAfterFailureAndRetriesOnlyFailedBeads() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design"]}
            {"_type":"issue","id":"bd-2","title":"Two","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design"]}
            {"_type":"issue","id":"bd-3","title":"Three","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:implementation"]}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setSetStateErrors([nil, StoreMutationTestError.commandFailed])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-3") != nil }
        var completedCounts: [Int] = []
        var totalCounts: [Int] = []

        let result = await store.bulkSetState(
            issueIDs: ["bd-3", "bd-2", "bd-1"],
            dimension: "phase",
            value: "implementation",
            reason: "Ready",
            progress: { progress in
                completedCounts.append(progress.completedCount)
                totalCounts.append(progress.totalCount)
            }
        )

        XCTAssertFalse(result.isSuccessful)
        XCTAssertEqual(result.progress.succeededCount, 1)
        XCTAssertEqual(result.progress.failedCount, 1)
        XCTAssertEqual(BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-1")?.labels ?? []), "implementation")
        XCTAssertEqual(BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-2")?.labels ?? []), "design")
        XCTAssertEqual(store.currentFailure?.title, "Couldn't set phase on 1 bead")
        var calls = await commands.setStateCalls
        XCTAssertEqual(calls.map(\.issueID), ["bd-1", "bd-2"])
        XCTAssertEqual(calls.map(\.reason), ["Ready", "Ready"])
        XCTAssertEqual(completedCounts, [0, 1, 2])
        XCTAssertEqual(totalCounts, [2, 2, 2])

        await commands.setSetStateErrors([nil])
        store.retryCurrentFailure()
        try await waitUntilAsync { await commands.setStateCalls.count == 3 }

        calls = await commands.setStateCalls
        XCTAssertEqual(calls.map(\.issueID), ["bd-1", "bd-2", "bd-2"])
        XCTAssertEqual(BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-2")?.labels ?? []), "implementation")
        XCTAssertNil(store.currentFailure)
    }

    func testBulkSetStateStopsEnqueuingOldProjectCommandsAfterProjectSwitch() async throws {
        let firstProjectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design"]}
            {"_type":"issue","id":"bd-2","title":"Two","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design"]}
            {"_type":"issue","id":"bd-3","title":"Three","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design"]}
            """
        )
        let secondProjectURL = try makeProject(issueLine(id: "other-1", title: "Other"))
        let commands = RecordingBeadsCommands()
        await commands.setSetStateDelays([.milliseconds(400)])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-3") != nil }

        let task = Task { @MainActor in
            await store.bulkSetState(
                issueIDs: ["bd-1", "bd-2", "bd-3"],
                dimension: "phase",
                value: "implementation"
            )
        }
        try await waitUntilAsync { await commands.setStateCalls.count == 1 }
        store.openProject(secondProjectURL)

        let result = await task.value
        XCTAssertFalse(result.isSuccessful)
        XCTAssertEqual(result.outcome, .superseded)
        let calls = await commands.setStateCalls
        XCTAssertEqual(calls.map(\.issueID), ["bd-1"])
        XCTAssertEqual(store.projectURL, secondProjectURL)
    }

    func testBulkSetStateStopsBeforeNextBeadAndRestoresUnattemptedOverrides() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design"]}
            {"_type":"issue","id":"bd-2","title":"Two","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design"]}
            {"_type":"issue","id":"bd-3","title":"Three","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design"]}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setSetStateDelays([.milliseconds(300)])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-3") != nil }

        let task = Task { @MainActor in
            await store.bulkSetState(
                issueIDs: ["bd-1", "bd-2", "bd-3"],
                dimension: "phase",
                value: "implementation"
            )
        }
        try await waitUntilAsync { await commands.setStateCalls.count == 1 }
        task.cancel()

        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.progress.completedCount, 1)
        XCTAssertEqual(result.progress.succeededCount, 1)
        XCTAssertEqual(result.progress.remainingCount, 2)
        let calls = await commands.setStateCalls
        XCTAssertEqual(calls.map(\.issueID), ["bd-1"])
        XCTAssertEqual(BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-1")?.labels ?? []), "implementation")
        XCTAssertEqual(BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-2")?.labels ?? []), "design")
        XCTAssertEqual(BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-3")?.labels ?? []), "design")
        XCTAssertNil(store.currentFailure)
    }

    func testBulkSetStateReportsEveryFailedCommand() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design"]}
            {"_type":"issue","id":"bd-2","title":"Two","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design"]}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setSetStateErrors([
            BeadError.commandFailed(command: "bd set-state bd-1 phase=ready", output: "first failure"),
            BeadError.commandFailed(command: "bd set-state bd-2 phase=ready", output: "second failure")
        ])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-2") != nil }

        let result = await store.bulkSetState(
            issueIDs: ["bd-1", "bd-2"],
            dimension: "phase",
            value: "ready"
        )

        XCTAssertFalse(result.isSuccessful)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertEqual(result.progress.failedCount, 2)
        XCTAssertEqual(store.currentFailure?.title, "Couldn't set phase on 2 beads")
        XCTAssertTrue(store.currentFailure?.message.contains("2 commands failed") == true)
        XCTAssertTrue(store.currentFailure?.output?.contains("bd set-state bd-1 phase=ready") == true)
        XCTAssertTrue(store.currentFailure?.output?.contains("first failure") == true)
        XCTAssertTrue(store.currentFailure?.output?.contains("bd set-state bd-2 phase=ready") == true)
        XCTAssertTrue(store.currentFailure?.output?.contains("second failure") == true)
    }

    func testSetStateFailureRollsBackOptimisticLabelSwap() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"Task","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design"]}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setSetStateErrors([StoreMutationTestError.commandFailed])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let didSet = await store.setState(issueID: "bd-1", dimension: "phase", value: "implementation")

        XCTAssertFalse(didSet)
        XCTAssertEqual(store.issue(with: "bd-1")?.labels, ["phase:design"])
        XCTAssertNotNil(store.currentFailure)
        let calls = await commands.setStateCalls
        XCTAssertEqual(calls.count, 1)
    }

    func testClearStateFailureRestoresCurrentValue() async throws {
        let projectURL = try makeProject(
            #"{"_type":"issue","id":"bd-1","title":"Task","status":"open","priority":1,"issue_type":"task","labels":["phase:design"],"updated_at":"2026-07-03T20:58:35Z"}"#
        )
        let commands = RecordingBeadsCommands()
        await commands.setClearStateErrors([StoreMutationTestError.commandFailed])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let didClear = await store.clearState(issueID: "bd-1", dimension: "phase")

        XCTAssertFalse(didClear)
        XCTAssertEqual(
            BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-1")?.labels ?? []),
            "design"
        )
        XCTAssertNotNil(store.currentFailure)
        let calls = await commands.clearStateCalls
        XCTAssertEqual(calls.count, 1)
    }

    func testSetStateRejectsInvalidDimensionAndBlankValueWithoutRunningCommands() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "Task"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let didSetInvalidDimension = await store.setState(issueID: "bd-1", dimension: "bad:dimension", value: "x")
        let didSetInvalidValue = await store.setState(issueID: "bd-1", dimension: "phase", value: "   ")

        XCTAssertFalse(didSetInvalidDimension)
        XCTAssertFalse(didSetInvalidValue)
        let calls = await commands.setStateCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSetStatePreservesCaseAndAllowsCommaAndEqualsInValue() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "Task"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let didSet = await store.setState(
            issueID: "bd-1",
            dimension: "Phase.Name",
            value: "in,review=ready"
        )

        XCTAssertTrue(didSet)
        XCTAssertTrue(store.issue(with: "bd-1")?.labels.contains("Phase.Name:in,review=ready") == true)
        let calls = await commands.setStateCalls
        XCTAssertEqual(calls.map(\.dimension), ["Phase.Name"])
        XCTAssertEqual(calls.map(\.value), ["in,review=ready"])
    }

    func testSetStateSkipsCommandWhenValueAlreadyCurrent() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"Task","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","labels":["phase:design"]}
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let didSet = await store.setState(issueID: "bd-1", dimension: "phase", value: "design")

        XCTAssertTrue(didSet)
        let calls = await commands.setStateCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSetStateUsesConstantSizeOverlayUntilAuthoritativeIndexRefresh() async throws {
        let projectURL = try makeProject(
            #"{"_type":"issue","id":"bd-1","title":"Task","status":"open","priority":1,"issue_type":"task","labels":["phase:design"],"updated_at":"2026-07-03T20:58:35Z"}"#
        )
        let commands = RecordingBeadsCommands()
        await commands.setSetStateDelays([.milliseconds(400)])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let stateTask = Task { @MainActor in
            await store.setState(issueID: "bd-1", dimension: "phase", value: "implementation")
        }
        try await waitUntil {
            BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-1")?.labels ?? []) == "implementation"
        }

        XCTAssertEqual(
            BeadStateLabel.value(of: "phase", in: store.index.issue(with: "bd-1")?.labels ?? []),
            "design",
            "The immediate interaction path must not rebuild the project-wide index."
        )
        let stateSucceeded = await stateTask.value
        XCTAssertTrue(stateSucceeded)
    }

    func testSuccessfulStateWriteDoesNotClearOlderLabelUncertainty() async throws {
        let projectURL = try makeProject(
            #"{"_type":"issue","id":"bd-1","title":"Task","status":"open","priority":1,"issue_type":"task","labels":["phase:design"],"updated_at":"2026-07-03T20:58:35Z"}"#
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.mutations.recordPossiblyPersistedLabels(["possibly-written"], for: "bd-1")

        let didSet = await store.setState(
            issueID: "bd-1",
            dimension: "phase",
            value: "implementation"
        )

        XCTAssertTrue(didSet)
        XCTAssertTrue(
            store.mutations.possiblyPersistedLabels(for: "bd-1").contains("possibly-written"),
            "A granular state command cannot prove the complete ordinary-label set."
        )
    }

    func testAuthoritativeRefreshRetiresStateOverlayAndAcceptsSnapshotValue() async throws {
        let projectURL = try makeProject(
            #"{"_type":"issue","id":"bd-1","title":"Task","status":"open","priority":1,"issue_type":"task","labels":["phase:design"],"updated_at":"2026-07-03T20:58:35Z"}"#
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let didSet = await store.setState(
            issueID: "bd-1",
            dimension: "phase",
            value: "implementation"
        )
        XCTAssertTrue(didSet)
        XCTAssertEqual(
            BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-1")?.labels ?? []),
            "implementation"
        )

        let exportsBeforeRefresh = await commands.exportCallCount
        store.refresh()
        try await waitUntilAsync { await commands.exportCallCount > exportsBeforeRefresh }
        try await waitUntil { !store.isLoading }

        XCTAssertEqual(
            BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-1")?.labels ?? []),
            "design",
            "A successful reload must hand ownership back to the authoritative snapshot."
        )
        XCTAssertTrue(store.stateLabelOverridesByIssueID.isEmpty)
    }

    func testFailedRefreshKeepsStateOverlayOverStaleSnapshot() async throws {
        let projectURL = try makeProject(
            #"{"_type":"issue","id":"bd-1","title":"Task","status":"open","priority":1,"issue_type":"task","labels":["phase:design"],"updated_at":"2026-07-03T20:58:35Z"}"#
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let didSet = await store.setState(
            issueID: "bd-1",
            dimension: "phase",
            value: "implementation"
        )
        XCTAssertTrue(didSet)
        await commands.setExportError(StoreMutationTestError.commandFailed)

        let exportsBeforeRefresh = await commands.exportCallCount
        store.refresh()
        try await waitUntilAsync { await commands.exportCallCount > exportsBeforeRefresh }
        try await waitUntil { !store.isLoading }

        XCTAssertEqual(
            BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-1")?.labels ?? []),
            "implementation",
            "A stale fallback snapshot must not roll back a confirmed optimistic value."
        )
        XCTAssertFalse(store.stateLabelOverridesByIssueID.isEmpty)
    }

    func testConcurrentOrdinaryLabelEditCannotOverwriteInFlightStateAfterUnpinning() async throws {
        let projectURL = try makeProject(
            #"{"_type":"issue","id":"bd-1","title":"Task","status":"open","priority":1,"issue_type":"task","labels":["phase:design","old"],"updated_at":"2026-07-03T20:58:35Z"}"#
        )
        let commands = RecordingBeadsCommands()
        await commands.setSetStateDelays([.milliseconds(250)])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        XCTAssertTrue(store.pinStateDimension("phase"))

        let stateTask = Task { @MainActor in
            await store.setState(issueID: "bd-1", dimension: "phase", value: "implementation")
        }
        try await waitUntil {
            BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-1")?.labels ?? []) == "implementation"
        }
        store.unpinStateDimension("phase")
        XCTAssertFalse(store.isStateDimensionPinned("phase"))
        let labelsTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", labels: ["phase:design", "new"])
        }

        let stateSucceeded = await stateTask.value
        let labelsSucceeded = await labelsTask.value
        XCTAssertTrue(stateSucceeded)
        XCTAssertTrue(labelsSucceeded)
        let labels = store.issue(with: "bd-1")?.labels ?? []
        XCTAssertTrue(labels.contains("phase:implementation"))
        XCTAssertTrue(labels.contains("new"))
        XCTAssertFalse(labels.contains("phase:design"))
        let metadataCalls = await commands.metadataUpdateCalls
        XCTAssertEqual(metadataCalls.last?.labels, ["new"])
        XCTAssertFalse(metadataCalls.last?.originalLabels?.contains(where: { $0.hasPrefix("phase:") }) == true)
    }

    func testFailedStateWriteDoesNotSurviveThroughConcurrentOrdinaryLabelEdit() async throws {
        let projectURL = try makeProject(
            #"{"_type":"issue","id":"bd-1","title":"Task","status":"open","priority":1,"issue_type":"task","labels":["phase:design","old"],"updated_at":"2026-07-03T20:58:35Z"}"#
        )
        let commands = RecordingBeadsCommands()
        await commands.setSetStateDelays([.milliseconds(250)])
        await commands.setSetStateErrors([StoreMutationTestError.commandFailed])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        XCTAssertTrue(store.pinStateDimension("phase"))

        let stateTask = Task { @MainActor in
            await store.setState(issueID: "bd-1", dimension: "phase", value: "implementation")
        }
        try await waitUntil {
            BeadStateLabel.value(of: "phase", in: store.issue(with: "bd-1")?.labels ?? []) == "implementation"
        }
        let labelsTask = Task { @MainActor in
            await store.updateMetadata(issueID: "bd-1", labels: ["phase:design", "new"])
        }

        let stateSucceeded = await stateTask.value
        let labelsSucceeded = await labelsTask.value
        XCTAssertFalse(stateSucceeded)
        XCTAssertTrue(labelsSucceeded)
        let labels = store.issue(with: "bd-1")?.labels ?? []
        XCTAssertTrue(labels.contains("phase:design"))
        XCTAssertTrue(labels.contains("new"))
        XCTAssertFalse(labels.contains("phase:implementation"))
    }

    func testStaleFullSavePreservesManagedStateAndOmitsItFromGenericCommand() async throws {
        let projectURL = try makeProject(
            #"{"_type":"issue","id":"bd-1","title":"Task","status":"open","priority":1,"issue_type":"task","labels":["phase:design","keeper"],"updated_at":"2026-07-03T20:58:35Z"}"#
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        XCTAssertTrue(store.pinStateDimension("phase"))
        var staleDraft = IssueDraft(issue: try XCTUnwrap(store.issue(with: "bd-1")))
        staleDraft.title = "Edited title"

        let stateSucceeded = await store.setState(
            issueID: "bd-1",
            dimension: "phase",
            value: "implementation"
        )
        let saveSucceeded = await store.save(staleDraft)
        XCTAssertTrue(stateSucceeded)
        XCTAssertTrue(saveSucceeded)

        let issue = try XCTUnwrap(store.issue(with: "bd-1"))
        XCTAssertEqual(issue.title, "Edited title")
        XCTAssertEqual(BeadStateLabel.value(of: "phase", in: issue.labels), "implementation")
        let updateCalls = await commands.updateCalls
        XCTAssertEqual(updateCalls.last?.draft.labels, ["keeper"])
        XCTAssertFalse(updateCalls.last?.originalIssue?.labels.contains(where: { $0.hasPrefix("phase:") }) == true)
    }

    func testSetParentClearsExistingParent() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.parentIssue(for: "bd-child") != nil }

        let didClear = await store.setParent(issueID: "bd-child", parentID: nil)

        XCTAssertTrue(didClear)
        XCTAssertNil(store.parentIssue(for: "bd-child"))
        XCTAssertNil(store.issue(with: "bd-child")?.parentID)
        let calls = await commands.setParentCalls
        XCTAssertEqual(calls.map(\.issueID), ["bd-child"])
        XCTAssertEqual(calls.first?.parentID, nil)
    }

    func testSetParentClearsDependencyBackedParentWhenParentIDFieldIsMissing() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            {"_type":"issue","id":"bd-child","title":"Child","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"issue_id":"bd-child","depends_on_id":"bd-parent","type":"parent-child"}]}
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.parentIssue(for: "bd-child") != nil }
        XCTAssertNil(store.issue(with: "bd-child")?.parentID)

        let didClear = await store.setParent(issueID: "bd-child", parentID: nil)

        XCTAssertTrue(didClear)
        XCTAssertNil(store.parentIssue(for: "bd-child"))
        let calls = await commands.setParentCalls
        XCTAssertEqual(calls.map(\.issueID), ["bd-child"])
        XCTAssertEqual(calls.first?.parentID, nil)
    }

    func testSetParentRejectsOpenChildUnderDoneParent() async throws {
        let projectURL = try makeProject(
            """
            \(closedIssueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child"))
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-child") != nil }

        let didSet = await store.setParent(issueID: "bd-child", parentID: "bd-parent")

        XCTAssertFalse(didSet)
        XCTAssertEqual(
            store.lastError,
            "Reopen bd-parent or resolve child beads before adding bd-child as a child: bd-child."
        )
        let calls = await commands.setParentCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSetParentTreatsExistingRelationshipAsNoOpWhenParentIsDone() async throws {
        let projectURL = try makeProject(
            """
            \(closedIssueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.parentIssue(for: "bd-child") != nil }

        let didSet = await store.setParent(issueID: "bd-child", parentID: "bd-parent")

        XCTAssertTrue(didSet)
        XCTAssertNil(store.lastError)
        let calls = await commands.setParentCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testPickerRelationshipActionsUseExpectedDependencyDirections() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-current", title: "Current"))
            \(issueLine(id: "bd-other", title: "Other"))
            """
        )
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-other") != nil }

        let blockedBy = await store.applyBeadPickerSelection("bd-other", action: .addBlockedBy(issueID: "bd-current"))
        let blocks = await store.applyBeadPickerSelection("bd-other", action: .addBlocks(issueID: "bd-current"))

        XCTAssertTrue(blockedBy)
        XCTAssertTrue(blocks)
        let calls = await commands.addDependencyCalls
        XCTAssertEqual(calls.map(\.issueID), ["bd-current", "bd-other"])
        XCTAssertEqual(calls.map(\.dependsOnID), ["bd-other", "bd-current"])
        XCTAssertEqual(calls.map(\.type), ["blocks", "blocks"])
    }

    func testCreateBeadCanReturnCreatedIDWithoutStealingSelection() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-current", title: "Current"))
            \(issueLine(id: "bd-parent", title: "Parent"))
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setCreateResult(issueID: "bd-child")
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-current") != nil }
        store.select(["bd-current"])

        var draft = store.blankDraft(parentID: "bd-parent")
        draft.title = "Quick child"
        let createdID = await store.createBead(draft, revealCreated: false)

        XCTAssertEqual(createdID, "bd-child")
        XCTAssertEqual(store.selectedIDs, Set(["bd-current"]))
        XCTAssertEqual(store.issue(with: "bd-child")?.parentID, "bd-parent")
        let calls = await commands.createCalls
        XCTAssertEqual(calls.map(\.draft.title), ["Quick child"])
        XCTAssertEqual(calls.map(\.draft.parentID), ["bd-parent"])
    }

    // MARK: Unified mutation feedback

    func testReportMutationFailureExtractsCommandAndOutput() {
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.reportMutationFailure(
            BeadError.commandFailed(command: "bd update bd-1", output: "boom"),
            title: "Couldn't update bd-1"
        )
        XCTAssertEqual(store.currentFailure?.command, "bd update bd-1")
        XCTAssertEqual(store.currentFailure?.output, "boom")
        XCTAssertEqual(store.currentFailure?.message, "The Beads command failed.")
        XCTAssertEqual(store.currentFailure?.title, "Couldn't update bd-1")
        XCTAssertTrue(store.currentFailure?.dialogMessage.contains("boom") == true)
    }

    func testReportMutationFailureFallsBackToLocalizedDescription() {
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.reportMutationFailure(StoreMutationTestError.commandFailed, title: "Nope")
        XCTAssertNil(store.currentFailure?.command)
        XCTAssertEqual(store.currentFailure?.message, "Mutation command failed")
    }

    func testFailureQueueCoalescesDuplicatesAndDismissPops() {
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.enqueueFailure(BeadMutationFailure(title: "T", message: "m", command: "c", output: "o"))
        store.enqueueFailure(BeadMutationFailure(title: "T", message: "m", command: "c", output: "o"))
        XCTAssertEqual(store.pendingFailures.count, 1)
        store.dismissCurrentFailure()
        XCTAssertTrue(store.pendingFailures.isEmpty)
        XCTAssertNil(store.currentFailure)
    }

    func testLastErrorShimEnqueuesAndNilAssignmentIsANoOp() {
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.lastError = "oops"
        XCTAssertEqual(store.currentFailure?.message, "oops")
        XCTAssertEqual(store.lastError, "oops")
        XCTAssertFalse(store.currentFailure?.isRetryable ?? true)

        // Loads/reconciles clear `lastError` incidentally; that must not wipe a failure the
        // user hasn't acted on (it made the dialog flash away). Only the dialog pops it.
        store.lastError = nil
        XCTAssertEqual(store.currentFailure?.message, "oops")
        store.dismissCurrentFailure()
        XCTAssertTrue(store.pendingFailures.isEmpty)
    }

    func testFailedMetadataUpdateEnqueuesRetryableFailureThatReruns() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed, nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let succeeded = await store.updateMetadata(issueID: "bd-1", assignee: "alice")

        XCTAssertFalse(succeeded)
        let failure = try XCTUnwrap(store.currentFailure)
        XCTAssertTrue(failure.title.contains("bd-1"))
        XCTAssertTrue(failure.isRetryable)

        // Try Again re-enters the guarded mutation; the second attempt has no injected error.
        store.retryCurrentFailure()
        try await waitUntil {
            store.pendingFailures.isEmpty && store.issue(with: "bd-1")?.assignee == "alice"
        }
        XCTAssertNil(store.currentFailure)
    }

    func testTryAgainIsDroppedWhenANewerEditSupersededTheFailedWrite() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setMetadataUpdateErrors([StoreMutationTestError.commandFailed, nil, nil])
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let failed = await store.updateMetadata(issueID: "bd-1", assignee: "alice")
        XCTAssertFalse(failed)
        XCTAssertTrue(store.currentFailure?.isRetryable == true)

        // A newer edit lands before the user acts on the dialog (writes are serialized,
        // so this is a realistic rapid-edit timeline).
        let superseded = await store.updateMetadata(issueID: "bd-1", assignee: "bob")
        XCTAssertTrue(superseded)

        // Try Again must drop the stale retry rather than overwrite the newer edit.
        store.retryCurrentFailure()
        XCTAssertTrue(store.pendingFailures.isEmpty)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(store.issue(with: "bd-1")?.assignee, "bob")
        // The mock records only non-throwing calls, so exactly one call (bob's) is expected.
        // Had the stale retry run, it would have consumed the next injected success and put
        // alice back — recording a second call and flipping the assignee.
        let calls = await commands.metadataUpdateCalls
        XCTAssertEqual(calls.map(\.assignee), ["bob"])
    }

    func testConsumeMostRecentFailureLeavesOlderQueuedFailures() {
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.enqueueFailure(BeadMutationFailure(title: "A", message: "first"))
        store.enqueueFailure(BeadMutationFailure(title: "B", message: "second"))

        XCTAssertEqual(store.consumeMostRecentFailure()?.message, "second")
        XCTAssertEqual(store.currentFailure?.message, "first")
        XCTAssertEqual(store.pendingFailures.count, 1)
    }

    private func makeProject(_ issuesJSONL: String) throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadStoreAsyncMutationTests-\(UUID().uuidString)", isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        try issuesJSONL.write(
            to: beadsURL.appendingPathComponent("issues.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL)
        }
        return projectURL
    }

    private func issueLine(
        id: String,
        title: String,
        status: String = "open",
        priority: Int = 1,
        parentID: String? = nil,
        issueType: String = "task"
    ) -> String {
        let parentFragment = parentID.map { ",\"parent_id\":\"\($0)\"" } ?? ""
        return """
        {"_type":"issue","id":"\(id)","title":"\(title)","status":"\(status)","priority":\(priority),"issue_type":"\(issueType)","updated_at":"2026-07-03T20:58:35Z"\(parentFragment)}
        """
    }

    private func closedIssueLine(id: String, title: String, parentID: String? = nil) -> String {
        let parentFragment = parentID.map { ",\"parent_id\":\"\($0)\"" } ?? ""
        return """
        {"_type":"issue","id":"\(id)","title":"\(title)","status":"closed","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","closed_at":"2026-07-03T20:58:35Z"\(parentFragment)}
        """
    }

    private func gateProjectJSONL(
        gateUpdatedAt: String,
        gateStatus: String = "open",
        awaitType: String = "timer",
        taskStatus: String = "open",
        taskDeferUntil: String? = nil
    ) -> String {
        let taskDeferFragment = taskDeferUntil.map { #","defer_until":"\#($0)""# } ?? ""
        return """
        {"_type":"issue","id":"bd-gate","title":"Release gate","description":"Ad-hoc gate blocking bd-task\\n\\nReason: Ship review","status":"\(gateStatus)","priority":1,"issue_type":"gate","await_type":"\(awaitType)","timeout":3600000000000,"created_at":"2026-07-03T20:58:35Z","updated_at":"\(gateUpdatedAt)"}
        {"_type":"issue","id":"bd-task","title":"Ship app","status":"\(taskStatus)","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"\(taskDeferFragment),"dependencies":[{"depends_on_id":"bd-gate","type":"blocks"}]}
        """
    }

    private func gateDetail(updatedAt: String, waiters: [String]) -> BeadGate {
        BeadGate(
            id: "bd-gate",
            title: "Release gate",
            awaitType: .timer,
            status: "open",
            reason: "Ship review",
            awaitID: nil,
            timeoutNanoseconds: 3_600_000_000_000,
            createdAt: BeadFormatters.parseDate("2026-07-03T20:58:35Z"),
            updatedAt: BeadFormatters.parseDate(updatedAt),
            waiters: waiters,
            blocksIssueID: "bd-task"
        )
    }

    private func draft(title: String) -> IssueDraft {
        IssueDraft(
            id: nil,
            title: title,
            description: "",
            design: "",
            acceptanceCriteria: "",
            notes: "",
            status: "open",
            priority: 2,
            issueType: "task",
            assignee: "",
            labelsText: ""
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "BeadStoreAsyncMutationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
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

    private func waitUntilAsync(
        timeout: TimeInterval = 3.0,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private actor RecordingBeadsCommands: BeadsCommanding {
    private(set) var initializeCalls: [URL] = []
    private(set) var initializeWasCancelled = false
    private(set) var createCalls: [(projectURL: URL, draft: IssueDraft)] = []
    private(set) var updateCalls: [(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?)] = []
    private(set) var metadataUpdateCalls: [
        (
            projectURL: URL,
            issueID: String,
            assignee: String?,
            labels: [String]?,
            originalLabels: [String]?,
            dueAt: IssueMetadataDateUpdate,
            deferUntil: IssueMetadataDateUpdate
        )
    ] = []
    private(set) var closeCalls: [(projectURL: URL, ids: [String], reason: String?)] = []
    private(set) var bulkUpdateCalls: [
        (
            projectURL: URL,
            ids: [String],
            status: String?,
            type: String?,
            priority: Int?,
            deferUntil: IssueMetadataDateUpdate
        )
    ] = []
    private(set) var setParentCalls: [(projectURL: URL, issueID: String, parentID: String?)] = []
    private(set) var setStateCalls: [(projectURL: URL, issueID: String, dimension: String, value: String, reason: String?)] = []
    private(set) var clearStateCalls: [
        (projectURL: URL, issueID: String, dimension: String, currentValue: String, reason: String?)
    ] = []
    private(set) var addLabelsCalls: [(projectURL: URL, ids: [String], labels: [String])] = []
    private(set) var addDependencyCalls: [(projectURL: URL, issueID: String, dependsOnID: String, type: String)] = []
    private(set) var mutationEvents: [String] = []
    private(set) var loadGateDetailCalls: [(projectURL: URL, id: String)] = []
    private(set) var resolveGateCalls: [(projectURL: URL, id: String, reason: String?)] = []
    private(set) var checkGatesCalls: [(projectURL: URL, type: String?, escalate: Bool, dryRun: Bool)] = []
    private(set) var createGateCalls: [
        (projectURL: URL, blocks: String, type: GateAwaitType, reason: String?, timeout: String?, awaitID: String?)
    ] = []
    private(set) var addGateWaiterCalls: [(projectURL: URL, id: String, waiter: String)] = []
    private(set) var loadCommentsCalls: [(projectURL: URL, issueID: String)] = []
    private(set) var exportCallCount = 0
    private(set) var definitionLoadCallCount = 0
    private var createIssueID = "bd-created"
    private var createError: Error?
    private var createDelay: Duration?
    private var updateError: Error?
    private var updateDelay: Duration?
    private var updateDelays: [Duration?] = []
    private var updateErrors: [Error?] = []
    private var metadataUpdateDelays: [Duration?] = []
    private var metadataUpdateErrors: [Error?] = []
    private var bulkUpdateError: Error?
    private var bulkUpdateDelay: Duration?
    private var bulkUpdateDelays: [Duration?] = []
    private var deleteError: Error?
    private var deleteDelay: Duration?
    private var setParentDelays: [Duration?] = []
    private var setParentErrors: [Error?] = []
    private var setStateDelays: [Duration?] = []
    private var setStateErrors: [Error?] = []
    private var clearStateDelays: [Duration?] = []
    private var clearStateErrors: [Error?] = []
    private var addLabelsDelays: [Duration?] = []
    private var addLabelsErrors: [Error?] = []
    private var exportError: Error?
    private var exportDelay: Duration?
    private var commentsByIssueID: [String: [BeadComment]] = [:]
    private var commentLoadError: Error?
    private var commentLoadDelay: Duration?
    private var gateDetail: BeadGate?
    private var checkGatesOutput = ""
    private var initializationDelay: Duration?
    private var definitionLoadDelay: Duration?
    private var appendsCreatedIssue = true

    func setInitializationDelay(_ delay: Duration?) {
        initializationDelay = delay
    }

    func setDefinitionLoadDelay(_ delay: Duration?) {
        definitionLoadDelay = delay
    }

    func setAppendsCreatedIssue(_ appendsCreatedIssue: Bool) {
        self.appendsCreatedIssue = appendsCreatedIssue
    }

    func setCreateResult(issueID: String) {
        createIssueID = issueID
    }

    func setCreateError(_ error: Error?) {
        createError = error
    }

    func setCreateDelay(_ delay: Duration?) {
        createDelay = delay
    }

    func setUpdateError(_ error: Error?) {
        updateError = error
    }

    func setUpdateDelay(_ delay: Duration?) {
        updateDelay = delay
    }

    func setUpdateDelays(_ delays: [Duration?]) {
        updateDelays = delays
    }

    func setUpdateErrors(_ errors: [Error?]) {
        updateErrors = errors
    }

    func setMetadataUpdateDelays(_ delays: [Duration?]) {
        metadataUpdateDelays = delays
    }

    func setMetadataUpdateErrors(_ errors: [Error?]) {
        metadataUpdateErrors = errors
    }

    func setBulkUpdateError(_ error: Error?) {
        bulkUpdateError = error
    }

    func setBulkUpdateDelay(_ delay: Duration?) {
        bulkUpdateDelay = delay
    }

    func setBulkUpdateDelays(_ delays: [Duration?]) {
        bulkUpdateDelays = delays
    }

    func setDeleteError(_ error: Error?) {
        deleteError = error
    }

    func setDeleteDelay(_ delay: Duration?) {
        deleteDelay = delay
    }

    func setSetParentDelays(_ delays: [Duration?]) {
        setParentDelays = delays
    }

    func setSetStateErrors(_ errors: [Error?]) {
        setStateErrors = errors
    }

    func setSetStateDelays(_ delays: [Duration?]) {
        setStateDelays = delays
    }

    func setClearStateErrors(_ errors: [Error?]) {
        clearStateErrors = errors
    }

    func setClearStateDelays(_ delays: [Duration?]) {
        clearStateDelays = delays
    }

    func setAddLabelsError(_ error: Error?) {
        addLabelsErrors = [error]
    }

    func setAddLabelsErrors(_ errors: [Error?]) {
        addLabelsErrors = errors
    }

    func setAddLabelsDelays(_ delays: [Duration?]) {
        addLabelsDelays = delays
    }

    func setSetParentErrors(_ errors: [Error?]) {
        setParentErrors = errors
    }

    func setExportError(_ error: Error?) {
        exportError = error
    }

    func setExportDelay(_ delay: Duration?) {
        exportDelay = delay
    }

    func setComments(_ comments: [BeadComment], for issueID: String) {
        commentsByIssueID[issueID] = comments
    }

    func setCommentLoadError(_ error: Error?) {
        commentLoadError = error
    }

    func setCommentLoadDelay(_ delay: Duration?) {
        commentLoadDelay = delay
    }

    func setGateDetail(_ gate: BeadGate?) {
        gateDetail = gate
    }

    func setCheckGatesOutput(_ output: String) {
        checkGatesOutput = output
    }

    func initialize(projectURL: URL, options: BeadsInitOptions) async throws {
        initializeCalls.append(projectURL)
        do {
            if let initializationDelay {
                try await Task.sleep(for: initializationDelay)
            }
        } catch is CancellationError {
            initializeWasCancelled = true
            throw CancellationError()
        }
    }

    func exportReadableSnapshot(projectURL: URL) async throws {
        exportCallCount += 1
        if let exportDelay {
            try await Task.sleep(for: exportDelay)
        }
        if let exportError {
            throw exportError
        }
    }

    func loadProjectContext(projectURL: URL) async throws -> BeadsProjectContext {
        .testContext(projectURL: projectURL)
    }

    func create(projectURL: URL, draft: IssueDraft) async throws -> String {
        createCalls.append((projectURL: projectURL, draft: draft))
        if let createDelay {
            try await Task.sleep(for: createDelay)
        }
        if let createError {
            throw createError
        }

        if appendsCreatedIssue {
            try appendCreatedIssue(projectURL: projectURL, issueID: createIssueID, draft: draft)
        }
        return createIssueID
    }

    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws {
        let delay = updateDelays.isEmpty ? updateDelay : updateDelays.removeFirst()
        if let delay {
            try await Task.sleep(for: delay)
        }
        let error = updateErrors.isEmpty ? updateError : updateErrors.removeFirst()
        if let error {
            throw error
        }
        updateCalls.append((projectURL: projectURL, draft: draft, originalIssue: originalIssue))
        mutationEvents.append("update:\(draft.id ?? "new")")
    }

    func updateMetadata(
        projectURL: URL,
        issueID: String,
        assignee: String?,
        labels: [String]?,
        originalLabels: [String]?,
        dueAt: IssueMetadataDateUpdate,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {
        let delay: Duration?
        if metadataUpdateDelays.isEmpty {
            delay = updateDelay
        } else {
            delay = metadataUpdateDelays.removeFirst()
        }
        if let delay {
            try await Task.sleep(for: delay)
        }
        let error: Error?
        if metadataUpdateErrors.isEmpty {
            error = updateError
        } else {
            error = metadataUpdateErrors.removeFirst()
        }
        if let error {
            throw error
        }
        metadataUpdateCalls.append((
            projectURL: projectURL,
            issueID: issueID,
            assignee: assignee,
            labels: labels,
            originalLabels: originalLabels,
            dueAt: dueAt,
            deferUntil: deferUntil
        ))
        mutationEvents.append("metadata:\(issueID)")
    }

    func close(projectURL: URL, ids: [String], reason: String?) async throws {
        closeCalls.append((projectURL: projectURL, ids: ids, reason: reason))
        mutationEvents.append("close:\(ids.joined(separator: ","))")
    }

    func delete(projectURL: URL, ids: [String]) async throws {
        if let deleteDelay {
            try await Task.sleep(for: deleteDelay)
        }
        if let deleteError {
            throw deleteError
        }
    }

    func bulkUpdate(
        projectURL: URL,
        ids: [String],
        status: String?,
        type: String?,
        priority: Int?,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {
        let delay = bulkUpdateDelays.isEmpty ? bulkUpdateDelay : bulkUpdateDelays.removeFirst()
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let bulkUpdateError {
            throw bulkUpdateError
        }
        bulkUpdateCalls.append((
            projectURL: projectURL,
            ids: ids,
            status: status,
            type: type,
            priority: priority,
            deferUntil: deferUntil
        ))
        mutationEvents.append("bulk:\(ids.joined(separator: ","))")
    }

    func setParent(projectURL: URL, issueID: String, parentID: String?) async throws {
        setParentCalls.append((projectURL: projectURL, issueID: issueID, parentID: parentID))
        if !setParentDelays.isEmpty, let delay = setParentDelays.removeFirst() {
            try await Task.sleep(for: delay)
        }
        if !setParentErrors.isEmpty, let error = setParentErrors.removeFirst() {
            throw error
        }
        mutationEvents.append("parent:\(issueID)")
    }

    func setState(projectURL: URL, issueID: String, dimension: String, value: String, reason: String?) async throws {
        setStateCalls.append((projectURL: projectURL, issueID: issueID, dimension: dimension, value: value, reason: reason))
        if !setStateDelays.isEmpty, let delay = setStateDelays.removeFirst() {
            try await Task.sleep(for: delay)
        }
        if !setStateErrors.isEmpty, let error = setStateErrors.removeFirst() {
            throw error
        }
        mutationEvents.append("state:\(issueID):\(dimension)=\(value)")
    }

    func clearState(
        projectURL: URL,
        issueID: String,
        dimension: String,
        currentValue: String,
        reason: String?
    ) async throws {
        clearStateCalls.append((
            projectURL: projectURL,
            issueID: issueID,
            dimension: dimension,
            currentValue: currentValue,
            reason: reason
        ))
        if !clearStateDelays.isEmpty, let delay = clearStateDelays.removeFirst() {
            try await Task.sleep(for: delay)
        }
        if !clearStateErrors.isEmpty, let error = clearStateErrors.removeFirst() {
            throw error
        }
        mutationEvents.append("state:\(issueID):\(dimension)=none")
    }

    func addLabels(projectURL: URL, ids: [String], labels: [String]) async throws {
        addLabelsCalls.append((projectURL: projectURL, ids: ids, labels: labels))
        if !addLabelsDelays.isEmpty, let delay = addLabelsDelays.removeFirst() {
            try await Task.sleep(for: delay)
        }
        if !addLabelsErrors.isEmpty, let error = addLabelsErrors.removeFirst() {
            throw error
        }
        mutationEvents.append("labels:\(ids.joined(separator: ","))")
    }

    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {
        addDependencyCalls.append((projectURL: projectURL, issueID: issueID, dependsOnID: dependsOnID, type: type))
        mutationEvents.append("dep:\(issueID)->\(dependsOnID):\(type)")
    }

    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {}

    func loadComments(projectURL: URL, issueID: String) async throws -> [BeadComment] {
        loadCommentsCalls.append((projectURL: projectURL, issueID: issueID))
        if let commentLoadDelay {
            try await Task.sleep(for: commentLoadDelay)
        }
        if let commentLoadError {
            throw commentLoadError
        }
        return commentsByIssueID[issueID] ?? []
    }

    func addComment(projectURL: URL, issueID: String, text: String) async throws {}

    func loadGateDetail(projectURL: URL, id: String) async throws -> BeadGate? {
        loadGateDetailCalls.append((projectURL: projectURL, id: id))
        return gateDetail
    }

    func resolveGate(projectURL: URL, id: String, reason: String?) async throws {
        resolveGateCalls.append((projectURL: projectURL, id: id, reason: reason))
    }

    func checkGates(projectURL: URL, type: String?, escalate: Bool, dryRun: Bool) async throws -> String {
        checkGatesCalls.append((projectURL: projectURL, type: type, escalate: escalate, dryRun: dryRun))
        return checkGatesOutput
    }

    func createGate(projectURL: URL, blocks: String, type: GateAwaitType, reason: String?, timeout: String?, awaitID: String?) async throws -> String {
        createGateCalls.append(
            (projectURL: projectURL, blocks: blocks, type: type, reason: reason, timeout: timeout, awaitID: awaitID)
        )
        return "bd-gate-created"
    }

    func addGateWaiter(projectURL: URL, id: String, waiter: String) async throws {
        addGateWaiterCalls.append((projectURL: projectURL, id: id, waiter: waiter))
    }

    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition] {
        definitionLoadCallCount += 1
        if let definitionLoadDelay {
            try await Task.sleep(for: definitionLoadDelay)
        }
        return []
    }

    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] {
        definitionLoadCallCount += 1
        if let definitionLoadDelay {
            try await Task.sleep(for: definitionLoadDelay)
        }
        return []
    }

    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws {}

    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws {}

    private func appendCreatedIssue(projectURL: URL, issueID: String, draft: IssueDraft) throws {
        var record: [String: Any] = [
            "_type": "issue",
            "id": issueID,
            "title": draft.title,
            "status": "open",
            "priority": draft.priority,
            "issue_type": draft.issueType,
            "updated_at": "2026-07-03T20:58:35Z"
        ]
        if let parentID = draft.parentID {
            record["parent_id"] = parentID
        }
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        guard let line = String(data: data, encoding: .utf8) else { return }

        let snapshotURL = projectURL
            .appendingPathComponent(".beads", isDirectory: true)
            .appendingPathComponent("issues.jsonl")
        let handle = try FileHandle(forWritingTo: snapshotURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        handle.write(Data(("\n" + line + "\n").utf8))
    }
}

private enum StoreMutationTestError: LocalizedError {
    case commandFailed

    var errorDescription: String? {
        "Mutation command failed"
    }
}
