import XCTest
@testable import Beadazzle

@MainActor
final class BeadStoreHierarchyMutationTests: XCTestCase {
    func testChildIssuesForDeletingIncludesAllUnselectedDescendants() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child", status: "closed", dependencies: [("bd-parent", "parent-child")]))
            \(issueLine(id: "bd-grandchild", title: "Grandchild", dependencies: [("bd-child", "parent-child")]))
            """
        )

        XCTAssertEqual(
            loaded.store.childIssues(forDeleting: ["bd-parent"]).map(\.id),
            ["bd-child", "bd-grandchild"]
        )
        XCTAssertEqual(
            loaded.store.childIssues(forDeleting: ["bd-parent", "bd-child"]).map(\.id),
            ["bd-grandchild"]
        )
    }

    func testDeletingBeadSilentlyIncludesOwnedEventRecordsWithoutTreatingThemAsChildren() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(
                id: "bd-parent.1",
                title: "State change: Phase → Testing",
                status: "closed",
                type: "event",
                parentID: "bd-parent"
            ))
            """
        )

        XCTAssertEqual(loaded.store.index.allIssueIDs, ["bd-parent"])
        XCTAssertTrue(loaded.store.childIssues(forDeleting: ["bd-parent"]).isEmpty)

        let didDelete = await loaded.store.delete(issueIDs: ["bd-parent"])

        XCTAssertTrue(didDelete)
        try await waitUntil("optimistic delete materialization") {
            loaded.store.issues.isEmpty
        }
        let calls = await loaded.commands.deleteCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-parent", "bd-parent.1"]])
    }

    func testDeleteCanIncludeAllChildIssues() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            \(issueLine(id: "bd-grandchild", title: "Grandchild", parentID: "bd-child"))
            """
        )
        let childIDs = loaded.store.childIssues(forDeleting: ["bd-parent"]).map(\.id)

        let didDelete = await loaded.store.delete(issueIDs: ["bd-parent"] + childIDs)

        XCTAssertTrue(didDelete)
        try await waitUntil("optimistic delete materialization") {
            loaded.store.issues.isEmpty
        }
        let calls = await loaded.commands.deleteCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-child", "bd-grandchild", "bd-parent"]])
    }

    func testDeleteRejectsRequestFromPreviouslyOpenProject() async throws {
        let firstProjectURL = try makeProject(issueLine(id: "bd-shared", title: "First project"))
        let secondProjectURL = try makeProject(issueLine(id: "bd-shared", title: "Second project"))
        let commands = RecordingHierarchyBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(firstProjectURL)
        try await waitUntil("first project load") {
            !store.isLoading && store.issue(with: "bd-shared")?.title == "First project"
        }
        store.openProject(secondProjectURL)
        XCTAssertEqual(store.projectURL, secondProjectURL.standardizedFileURL)
        try await waitUntil("second project load") {
            !store.isLoading && store.issue(with: "bd-shared")?.title == "Second project"
        }

        let didDelete = await store.delete(
            issueIDs: ["bd-shared"],
            expectedProjectURL: firstProjectURL
        )

        XCTAssertFalse(didDelete)
        XCTAssertNotNil(store.issue(with: "bd-shared"))
        let calls = await commands.deleteCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCloseRejectsParentOnlyWhenDescendantsAreUnresolved() async throws {
        let store = try await makeLoadedStore(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            """
        )

        let didClose = await store.store.close(issueIDs: ["bd-parent"], reason: "done")

        XCTAssertFalse(didClose)
        XCTAssertEqual(store.store.lastError, "Close child beads first or include them: bd-child.")
        let closeCalls = await store.commands.closeCalls
        XCTAssertTrue(closeCalls.isEmpty)
    }

    func testBulkSetRejectsDoneStatusWithoutRequiredDescendants() async throws {
        let store = try await makeLoadedStore(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            """
        )

        let didSet = await store.store.bulkSet(issueIDs: ["bd-parent"], status: "closed")

        XCTAssertFalse(didSet)
        XCTAssertEqual(store.store.lastError, "Close child beads first or include them: bd-child.")
        let bulkUpdateCalls = await store.commands.bulkUpdateCalls
        XCTAssertTrue(bulkUpdateCalls.isEmpty)
    }

    func testSaveRejectsDoneStatusWithoutRequiredDescendants() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            """
        )
        let parent = try XCTUnwrap(loaded.store.issue(with: "bd-parent"))
        var draft = IssueDraft(issue: parent)
        draft.status = "closed"

        let didSave = await loaded.store.save(draft)

        XCTAssertFalse(didSave)
        XCTAssertEqual(loaded.store.lastError, "Close child beads first or include them: bd-child.")
        let updateCalls = await loaded.commands.updateCalls
        XCTAssertTrue(updateCalls.isEmpty)
    }

    func testCustomDoneStatusUsesCompletionGuard() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            """
        )

        let didSet = await loaded.store.bulkSet(issueIDs: ["bd-parent"], status: "accepted")

        XCTAssertFalse(didSet)
        XCTAssertEqual(loaded.store.lastError, "Close child beads first or include them: bd-child.")
        let bulkUpdateCalls = await loaded.commands.bulkUpdateCalls
        XCTAssertTrue(bulkUpdateCalls.isEmpty)
    }

    func testConfirmedCompletionWritesDescendantsDeepestFirst() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(issueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            \(issueLine(id: "bd-grandchild", title: "Grandchild", parentID: "bd-child"))
            """
        )

        let childIssues = loaded.store.openChildIssues(forClosing: ["bd-parent"])
        let didSet = await loaded.store.bulkSet(
            issueIDs: ["bd-parent"] + childIssues.map(\.id),
            status: "closed"
        )

        XCTAssertTrue(didSet)
        let calls = await loaded.commands.bulkUpdateCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-grandchild", "bd-child", "bd-parent"]])
        XCTAssertEqual(calls.map(\.status), ["closed"])
    }

    func testReopenRejectsChildOnlyWhenAncestorsAreDone() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(closedIssueLine(id: "bd-parent", title: "Parent"))
            \(closedIssueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            """
        )

        let didReopen = await loaded.store.reopen(issueIDs: ["bd-child"])

        XCTAssertFalse(didReopen)
        XCTAssertEqual(loaded.store.lastError, "Reopen parent beads first or include them: bd-parent.")
        let bulkUpdateCalls = await loaded.commands.bulkUpdateCalls
        XCTAssertTrue(bulkUpdateCalls.isEmpty)
    }

    func testConfirmedReopenWritesAncestorsShallowestFirst() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(closedIssueLine(id: "bd-grandparent", title: "Grandparent"))
            \(closedIssueLine(id: "bd-parent", title: "Parent", parentID: "bd-grandparent"))
            \(closedIssueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            """
        )

        let didReopen = await loaded.store.reopen(
            issueIDs: ["bd-child"],
            reopeningAncestorIssueIDs: ["bd-parent", "bd-grandparent"]
        )

        XCTAssertTrue(didReopen)
        let calls = await loaded.commands.bulkUpdateCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-grandparent", "bd-parent"], ["bd-child"]])
        XCTAssertEqual(calls.map(\.status), ["open", "open"])
    }

    func testNonDoneStatusChangeCanReopenAncestorsWithActiveStatus() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(closedIssueLine(id: "bd-parent", title: "Parent"))
            \(closedIssueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            """
        )

        let didSet = await loaded.store.bulkSet(
            issueIDs: ["bd-child"],
            status: "deferred",
            reopeningAncestorIssueIDs: ["bd-parent"]
        )

        XCTAssertTrue(didSet)
        let calls = await loaded.commands.bulkUpdateCalls
        XCTAssertEqual(calls.map(\.ids), [["bd-parent"], ["bd-child"]])
        XCTAssertEqual(calls.map(\.status), ["open", "deferred"])
    }

    func testGateRejectionWithCustomDoneStatusPreflightsChildrenBeforeResolving() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(issueLine(id: "bd-gate", title: "Gate", status: "open", type: "gate", extra: #","await_type":"human""#))
            \(issueLine(id: "bd-parent", title: "Parent", status: "blocked", dependencies: [("bd-gate", "blocks")]))
            \(issueLine(id: "bd-child", title: "Child", parentID: "bd-parent"))
            """
        )

        let didReject = await loaded.store.rejectGate(
            id: "bd-gate",
            reason: "not ready",
            targetStatus: "accepted"
        )

        XCTAssertFalse(didReject)
        XCTAssertEqual(loaded.store.lastError, "Close child beads first or include them: bd-child.")
        let resolveGateCalls = await loaded.commands.resolveGateCalls
        let bulkUpdateCalls = await loaded.commands.bulkUpdateCalls
        XCTAssertTrue(resolveGateCalls.isEmpty)
        XCTAssertTrue(bulkUpdateCalls.isEmpty)
    }

    func testParentChildDependencyRejectsOpenChildUnderDoneParent() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(closedIssueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child"))
            """
        )

        let didAdd = await loaded.store.addDependency(
            issueID: "bd-child",
            dependsOnID: "bd-parent",
            type: "parent-child"
        )

        XCTAssertFalse(didAdd)
        XCTAssertEqual(
            loaded.store.lastError,
            "Reopen bd-parent or resolve child beads before adding bd-child as a child: bd-child."
        )
        let addDependencyCalls = await loaded.commands.addDependencyCalls
        XCTAssertTrue(addDependencyCalls.isEmpty)
    }

    func testParentChildDependencyRejectsDoneChildWithUnresolvedDescendantUnderDoneParent() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(closedIssueLine(id: "bd-parent", title: "Parent"))
            \(closedIssueLine(id: "bd-child", title: "Child"))
            \(issueLine(id: "bd-grandchild", title: "Grandchild", parentID: "bd-child"))
            """
        )

        let didAdd = await loaded.store.addDependency(
            issueID: "bd-child",
            dependsOnID: "bd-parent",
            type: "parent-child"
        )

        XCTAssertFalse(didAdd)
        XCTAssertEqual(
            loaded.store.lastError,
            "Reopen bd-parent or resolve child beads before adding bd-child as a child: bd-grandchild."
        )
        let addDependencyCalls = await loaded.commands.addDependencyCalls
        XCTAssertTrue(addDependencyCalls.isEmpty)
    }

    func testParentChildDependencyAllowsResolvedDoneChildUnderDoneParent() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(closedIssueLine(id: "bd-parent", title: "Parent"))
            \(closedIssueLine(id: "bd-child", title: "Child"))
            \(closedIssueLine(id: "bd-grandchild", title: "Grandchild", parentID: "bd-child"))
            """
        )

        let didAdd = await loaded.store.addDependency(
            issueID: "bd-child",
            dependsOnID: "bd-parent",
            type: "parent-child"
        )

        XCTAssertTrue(didAdd)
        let addDependencyCalls = await loaded.commands.addDependencyCalls
        XCTAssertEqual(addDependencyCalls.map(\.issueID), ["bd-child"])
        XCTAssertEqual(addDependencyCalls.map(\.dependsOnID), ["bd-parent"])
        XCTAssertEqual(addDependencyCalls.map(\.type), ["parent-child"])
    }

    func testBlockingDependencyRejectsTaskBlockerForEpic() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(issueLine(id: "bd-task", title: "Task"))
            \(issueLine(id: "bd-epic", title: "Epic", type: "epic"))
            """
        )

        let didAdd = await loaded.store.addDependency(
            issueID: "bd-epic",
            dependsOnID: "bd-task",
            type: "blocks"
        )

        XCTAssertFalse(didAdd)
        XCTAssertEqual(
            loaded.store.lastError,
            "bd-epic is an epic, so it can only be blocked by another epic."
        )
        let addDependencyCalls = await loaded.commands.addDependencyCalls
        XCTAssertTrue(addDependencyCalls.isEmpty)
    }

    func testBlockingDependencyRejectsEpicBlockerForTask() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(issueLine(id: "bd-task", title: "Task"))
            \(issueLine(id: "bd-epic", title: "Epic", type: "epic"))
            """
        )

        let didAdd = await loaded.store.addDependency(
            issueID: "bd-task",
            dependsOnID: "bd-epic",
            type: "blocks"
        )

        XCTAssertFalse(didAdd)
        XCTAssertEqual(
            loaded.store.lastError,
            "bd-epic is an epic, so it can only block other epics."
        )
        let addDependencyCalls = await loaded.commands.addDependencyCalls
        XCTAssertTrue(addDependencyCalls.isEmpty)
    }

    func testBlockingDependencyAllowsEpicToEpic() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(issueLine(id: "bd-blocked", title: "Blocked epic", type: "epic"))
            \(issueLine(id: "bd-blocker", title: "Blocker epic", type: "epic"))
            """
        )

        let didAdd = await loaded.store.addDependency(
            issueID: "bd-blocked",
            dependsOnID: "bd-blocker",
            type: "blocks"
        )

        XCTAssertTrue(didAdd)
        let addDependencyCalls = await loaded.commands.addDependencyCalls
        XCTAssertEqual(addDependencyCalls.map(\.issueID), ["bd-blocked"])
        XCTAssertEqual(addDependencyCalls.map(\.dependsOnID), ["bd-blocker"])
        XCTAssertEqual(addDependencyCalls.map(\.type), ["blocks"])
    }

    func testTypePriorityAndNonParentDependencyMutationsRemainAllowed() async throws {
        let loaded = try await makeLoadedStore(
            """
            \(closedIssueLine(id: "bd-parent", title: "Parent"))
            \(issueLine(id: "bd-child", title: "Child"))
            """
        )

        let didBulkSet = await loaded.store.bulkSet(issueIDs: ["bd-child"], type: "feature", priority: 1)
        let didAddDependency = await loaded.store.addDependency(
            issueID: "bd-child",
            dependsOnID: "bd-parent",
            type: "blocks"
        )

        XCTAssertTrue(didBulkSet)
        XCTAssertTrue(didAddDependency)
        let bulkUpdateCalls = await loaded.commands.bulkUpdateCalls
        let addDependencyCalls = await loaded.commands.addDependencyCalls
        XCTAssertEqual(bulkUpdateCalls.map(\.type), ["feature"])
        XCTAssertEqual(bulkUpdateCalls.map(\.priority), [1])
        XCTAssertEqual(addDependencyCalls.map(\.type), ["blocks"])
    }

    private func makeLoadedStore(_ jsonl: String) async throws -> (store: BeadStore, commands: RecordingHierarchyBeadsCommands) {
        let projectURL = try makeProject(jsonl)
        let commands = RecordingHierarchyBeadsCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && !store.issues.isEmpty }
        return (store, commands)
    }

    private func makeProject(_ jsonl: String) throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadStoreHierarchyMutationTests-\(UUID().uuidString)")
        let beadsURL = projectURL.appendingPathComponent(".beads")
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        try (jsonl + "\n").write(
            to: beadsURL.appendingPathComponent("issues.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        return projectURL
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "BeadStoreHierarchyMutationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func issueLine(
        id: String,
        title: String,
        status: String = "open",
        type: String = "task",
        parentID: String? = nil,
        dependencies: [(String, String)] = [],
        extra: String = ""
    ) -> String {
        let parentFragment = parentID.map { #","parent_id":"\#($0)""# } ?? ""
        let dependencyFragment: String
        if dependencies.isEmpty {
            dependencyFragment = ""
        } else {
            let dependencyJSON = dependencies
                .map { #"{"depends_on_id":"\#($0.0)","type":"\#($0.1)"}"# }
                .joined(separator: ",")
            dependencyFragment = #","dependencies":[\#(dependencyJSON)]"#
        }
        return #"{"_type":"issue","id":"\#(id)","title":"\#(title)","status":"\#(status)","priority":1,"issue_type":"\#(type)","updated_at":"2026-07-03T20:58:35Z"\#(parentFragment)\#(dependencyFragment)\#(extra)}"#
    }

    private func closedIssueLine(id: String, title: String, parentID: String? = nil) -> String {
        let parentFragment = parentID.map { #","parent_id":"\#($0)""# } ?? ""
        return #"{"_type":"issue","id":"\#(id)","title":"\#(title)","status":"closed","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z","closed_at":"2026-07-03T20:58:35Z"\#(parentFragment)}"#
    }

    private func waitUntil(
        _ label: String = "condition",
        timeout: TimeInterval = 3.0,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private actor RecordingHierarchyBeadsCommands: BeadsCommanding {
    private(set) var updateCalls: [(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?)] = []
    private(set) var closeCalls: [(projectURL: URL, ids: [String], reason: String?)] = []
    private(set) var deleteCalls: [(projectURL: URL, ids: [String])] = []
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
    private(set) var addDependencyCalls: [(projectURL: URL, issueID: String, dependsOnID: String, type: String)] = []
    private(set) var resolveGateCalls: [(projectURL: URL, id: String, reason: String?)] = []

    func initialize(projectURL: URL, options: BeadsInitOptions) async throws {}
    func exportReadableSnapshot(projectURL: URL) async throws {}
    func loadProjectContext(projectURL: URL) async throws -> BeadsProjectContext {
        .testContext(projectURL: projectURL)
    }
    func create(projectURL: URL, draft: IssueDraft) async throws -> String { "bd-created" }

    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws {
        updateCalls.append((projectURL, draft, originalIssue))
    }

    func updateMetadata(
        projectURL: URL,
        issueID: String,
        assignee: String?,
        labels: [String]?,
        originalLabels: [String]?,
        dueAt: IssueMetadataDateUpdate,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {}

    func close(projectURL: URL, ids: [String], reason: String?) async throws {
        closeCalls.append((projectURL, ids, reason))
    }

    func delete(projectURL: URL, ids: [String]) async throws {
        deleteCalls.append((projectURL, ids))
    }

    func bulkUpdate(
        projectURL: URL,
        ids: [String],
        status: String?,
        type: String?,
        priority: Int?,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {
        bulkUpdateCalls.append((projectURL, ids, status, type, priority, deferUntil))
    }

    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {
        addDependencyCalls.append((projectURL, issueID, dependsOnID, type))
    }

    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {}
    func addComment(projectURL: URL, issueID: String, text: String) async throws {}

    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition] {
        [
            BeadStatusDefinition(name: "open", category: .active, icon: nil, description: nil, isBuiltIn: true, source: .builtIn),
            BeadStatusDefinition(name: "blocked", category: .wip, icon: nil, description: nil, isBuiltIn: true, source: .builtIn),
            BeadStatusDefinition(name: "deferred", category: .frozen, icon: nil, description: nil, isBuiltIn: true, source: .builtIn),
            BeadStatusDefinition(name: "closed", category: .done, icon: nil, description: nil, isBuiltIn: true, source: .builtIn),
            BeadStatusDefinition(name: "accepted", category: .done, icon: nil, description: nil, source: .custom)
        ]
    }

    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] {
        [
            BeadTypeDefinition(name: "task", description: nil, source: .builtIn),
            BeadTypeDefinition(name: "feature", description: nil, source: .builtIn),
            BeadTypeDefinition(name: "gate", description: nil, source: .builtIn)
        ]
    }

    func loadCustomStatuses(projectURL: URL) async throws -> [BeadStatusDefinition] { [] }
    func loadCustomTypes(projectURL: URL) async throws -> [BeadTypeDefinition] { [] }
    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws {}
    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws {}

    func resolveGate(projectURL: URL, id: String, reason: String?) async throws {
        resolveGateCalls.append((projectURL, id, reason))
    }
}
