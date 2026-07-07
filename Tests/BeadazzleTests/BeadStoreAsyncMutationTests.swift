import XCTest
@testable import Beadazzle

@MainActor
final class BeadStoreAsyncMutationTests: XCTestCase {
    func testBulkSetReturnsTrueAndInvokesCommandOnSuccess() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
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
        XCTAssertFalse(store.canCreateGate(blocking: try XCTUnwrap(store.issue(with: "bd-closed"))))
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

    func testForcedCommentRefreshSetsAndClearsLoadingStateOnSuccess() async throws {
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task","comments":[{"id":"comment-1","body":"Cached comment"}]}
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.select(["bd-1"])

        store.loadCommentsForSelection(force: true)

        XCTAssertTrue(store.isLoadingComments)
        try await waitUntil { !store.isLoadingComments }
        XCTAssertEqual(store.comments.map(\.text), ["Cached comment"])
        XCTAssertNil(store.lastError)
    }

    func testForcedCommentRefreshClearsLoadingStateOnFailure() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", title: "One"))
        let commands = RecordingBeadsCommands()
        await commands.setExportError(StoreMutationTestError.commandFailed)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }
        store.select(["bd-1"])
        try FileManager.default.removeItem(at: projectURL.appendingPathComponent(".beads/issues.jsonl"))

        store.loadCommentsForSelection(force: true)

        XCTAssertTrue(store.isLoadingComments)
        try await waitUntil { !store.isLoadingComments && store.lastError != nil }
        XCTAssertEqual(store.lastError, StoreMutationTestError.commandFailed.localizedDescription)
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
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: RecordingBeadsCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-a") != nil && store.issue(with: "bd-b") != nil }

        store.select(["bd-a"])
        store.select(["bd-b"])

        try await waitUntil {
            store.dependencyIssueID == "bd-b" && store.commentsIssueID == "bd-b"
        }
        XCTAssertEqual(store.selectedIDs, Set(["bd-b"]))
        XCTAssertEqual(store.dependencies.map(\.issueID), ["bd-b"])
        XCTAssertEqual(store.dependencies.map(\.dependsOnID), ["bd-other"])
        XCTAssertEqual(store.comments.map(\.id), ["comment-b"])
        XCTAssertEqual(store.comments(for: "bd-a").map(\.id), ["comment-a"])
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

    private func issueLine(id: String, title: String, status: String = "open", parentID: String? = nil) -> String {
        let parentFragment = parentID.map { ",\"parent_id\":\"\($0)\"" } ?? ""
        return """
        {"_type":"issue","id":"\(id)","title":"\(title)","status":"\(status)","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"\(parentFragment)}
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
        taskStatus: String = "open"
    ) -> String {
        """
        {"_type":"issue","id":"bd-gate","title":"Release gate","description":"Ad-hoc gate blocking bd-task\\n\\nReason: Ship review","status":"\(gateStatus)","priority":1,"issue_type":"gate","await_type":"\(awaitType)","timeout":3600000000000,"created_at":"2026-07-03T20:58:35Z","updated_at":"\(gateUpdatedAt)"}
        {"_type":"issue","id":"bd-task","title":"Ship app","status":"\(taskStatus)","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","dependencies":[{"depends_on_id":"bd-gate","type":"blocks"}]}
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
    private(set) var createCalls: [(projectURL: URL, draft: IssueDraft)] = []
    private(set) var updateCalls: [(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?)] = []
    private(set) var closeCalls: [(projectURL: URL, ids: [String], reason: String?)] = []
    private(set) var bulkUpdateCalls: [(projectURL: URL, ids: [String], status: String?, type: String?, priority: Int?)] = []
    private(set) var mutationEvents: [String] = []
    private(set) var loadGateDetailCalls: [(projectURL: URL, id: String)] = []
    private(set) var resolveGateCalls: [(projectURL: URL, id: String, reason: String?)] = []
    private(set) var checkGatesCalls: [(projectURL: URL, type: String?, escalate: Bool, dryRun: Bool)] = []
    private(set) var createGateCalls: [
        (projectURL: URL, blocks: String, type: GateAwaitType, reason: String?, timeout: String?, awaitID: String?)
    ] = []
    private(set) var addGateWaiterCalls: [(projectURL: URL, id: String, waiter: String)] = []
    private(set) var exportCallCount = 0
    private var createIssueID = "bd-created"
    private var createError: Error?
    private var bulkUpdateError: Error?
    private var bulkUpdateDelay: Duration?
    private var exportError: Error?
    private var gateDetail: BeadGate?
    private var checkGatesOutput = ""

    func setCreateResult(issueID: String) {
        createIssueID = issueID
    }

    func setCreateError(_ error: Error?) {
        createError = error
    }

    func setBulkUpdateError(_ error: Error?) {
        bulkUpdateError = error
    }

    func setBulkUpdateDelay(_ delay: Duration?) {
        bulkUpdateDelay = delay
    }

    func setExportError(_ error: Error?) {
        exportError = error
    }

    func setGateDetail(_ gate: BeadGate?) {
        gateDetail = gate
    }

    func setCheckGatesOutput(_ output: String) {
        checkGatesOutput = output
    }

    func initialize(projectURL: URL, options: BeadsInitOptions) async throws {}

    func exportReadableSnapshot(projectURL: URL) async throws {
        exportCallCount += 1
        if let exportError {
            throw exportError
        }
    }

    func create(projectURL: URL, draft: IssueDraft) async throws -> String {
        createCalls.append((projectURL: projectURL, draft: draft))
        if let createError {
            throw createError
        }

        try appendCreatedIssue(projectURL: projectURL, issueID: createIssueID, draft: draft)
        return createIssueID
    }

    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws {
        updateCalls.append((projectURL: projectURL, draft: draft, originalIssue: originalIssue))
        mutationEvents.append("update:\(draft.id ?? "new")")
    }

    func close(projectURL: URL, ids: [String], reason: String?) async throws {
        closeCalls.append((projectURL: projectURL, ids: ids, reason: reason))
        mutationEvents.append("close:\(ids.joined(separator: ","))")
    }

    func delete(projectURL: URL, ids: [String]) async throws {}

    func bulkUpdate(projectURL: URL, ids: [String], status: String?, type: String?, priority: Int?) async throws {
        if let bulkUpdateDelay {
            try await Task.sleep(for: bulkUpdateDelay)
        }
        if let bulkUpdateError {
            throw bulkUpdateError
        }
        bulkUpdateCalls.append((projectURL: projectURL, ids: ids, status: status, type: type, priority: priority))
        mutationEvents.append("bulk:\(ids.joined(separator: ","))")
    }

    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {}

    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {}

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
        []
    }

    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] {
        []
    }

    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws {}

    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws {}

    private func appendCreatedIssue(projectURL: URL, issueID: String, draft: IssueDraft) throws {
        let record: [String: Any] = [
            "_type": "issue",
            "id": issueID,
            "title": draft.title,
            "status": "open",
            "priority": draft.priority,
            "issue_type": draft.issueType,
            "updated_at": "2026-07-03T20:58:35Z"
        ]
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
