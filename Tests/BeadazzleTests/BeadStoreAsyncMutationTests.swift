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

    private func issueLine(id: String, title: String) -> String {
        """
        {"_type":"issue","id":"\(id)","title":"\(title)","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
        """
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
}

private actor RecordingBeadsCommands: BeadsCommanding {
    private(set) var createCalls: [(projectURL: URL, draft: IssueDraft)] = []
    private(set) var bulkUpdateCalls: [(projectURL: URL, ids: [String], status: String?, type: String?, priority: Int?)] = []
    private var createIssueID = "bd-created"
    private var createError: Error?
    private var bulkUpdateError: Error?
    private var bulkUpdateDelay: Duration?
    private var exportError: Error?

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

    func initialize(projectURL: URL, options: BeadsInitOptions) async throws {}

    func exportReadableSnapshot(projectURL: URL) async throws {
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

    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws {}

    func close(projectURL: URL, ids: [String], reason: String?) async throws {}

    func delete(projectURL: URL, ids: [String]) async throws {}

    func bulkUpdate(projectURL: URL, ids: [String], status: String?, type: String?, priority: Int?) async throws {
        if let bulkUpdateDelay {
            try await Task.sleep(for: bulkUpdateDelay)
        }
        if let bulkUpdateError {
            throw bulkUpdateError
        }
        bulkUpdateCalls.append((projectURL: projectURL, ids: ids, status: status, type: type, priority: priority))
    }

    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {}

    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {}

    func addComment(projectURL: URL, issueID: String, text: String) async throws {}

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
