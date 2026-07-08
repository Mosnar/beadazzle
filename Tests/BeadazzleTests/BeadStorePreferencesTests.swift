import XCTest
@testable import Beadazzle

@MainActor
final class BeadStorePreferencesTests: XCTestCase {
    func testPreferenceDefaultsMatchCompactMetadataAndStaleCutoff() {
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: PreferenceTestCommands())

        XCTAssertEqual(store.staleCutoffDays, 14)
        XCTAssertFalse(store.showsOwnerInBeadList)
        XCTAssertFalse(store.showsAssigneeInBeadList)
        XCTAssertFalse(store.showsDueDateInBeadList)
        XCTAssertTrue(store.showsCommentsInBeadList)
        XCTAssertEqual(store.beadListDisplayOptions, .compact)
    }

    func testPreferencesPersistThroughInjectedUserDefaults() {
        let defaults = makeUserDefaults()
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())

        store.bdCLIPath = "/tmp/custom-bd"
        store.staleCutoffDays = 30
        store.showsOwnerInBeadList = true
        store.showsAssigneeInBeadList = true
        store.showsDueDateInBeadList = true
        store.showsCommentsInBeadList = false

        let reloadedStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())

        XCTAssertEqual(reloadedStore.bdCLIPath, "/tmp/custom-bd")
        XCTAssertEqual(reloadedStore.staleCutoffDays, 30)
        XCTAssertTrue(reloadedStore.showsOwnerInBeadList)
        XCTAssertTrue(reloadedStore.showsAssigneeInBeadList)
        XCTAssertTrue(reloadedStore.showsDueDateInBeadList)
        XCTAssertFalse(reloadedStore.showsCommentsInBeadList)
    }

    func testProjectVisibilityPersistsAndKeepsUsedHiddenValuesReachableWithoutOfferingThemForNewChoices() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        store.setStatus("qa", isHidden: true)
        store.setStatus("open", isHidden: true)
        store.setType("incident", isHidden: true)
        store.setType("task", isHidden: true)

        XCTAssertEqual(store.availableStatuses, [])
        XCTAssertEqual(store.availableTypes, [])
        XCTAssertEqual(store.statusOptions(including: "open"), ["open"])
        XCTAssertEqual(store.statusChangeOptions(excluding: "open"), [])
        XCTAssertEqual(store.typeOptions(including: "task"), ["task"])
        XCTAssertEqual(store.statusCounts.map(\.0), ["open"])
        XCTAssertEqual(store.typeCounts.map(\.0), ["task"])

        let reloadedStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        reloadedStore.openProject(projectURL)
        try await waitUntil { !reloadedStore.isLoading && reloadedStore.issue(with: "bd-1") != nil }

        XCTAssertTrue(reloadedStore.isStatusHidden("qa"))
        XCTAssertTrue(reloadedStore.isTypeHidden("incident"))
        XCTAssertEqual(reloadedStore.availableStatuses, [])
        XCTAssertEqual(reloadedStore.availableTypes, [])
        XCTAssertEqual(reloadedStore.statusOptions(including: "open"), ["open"])
        XCTAssertEqual(reloadedStore.statusChangeOptions(excluding: "open"), [])
        XCTAssertEqual(reloadedStore.typeOptions(including: "task"), ["task"])
    }

    func testStatusChangeOptionsExcludeNoOpStatuses() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-open", status: "open", type: "task"))
            \(issueLine(id: "bd-qa", status: "qa", type: "task"))
            \(issueLine(id: "bd-open-2", status: "open", type: "task"))
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-qa") != nil }

        XCTAssertEqual(store.statusChangeOptions(excluding: "open"), ["qa"])
        XCTAssertEqual(store.statusChangeOptions(excluding: "qa"), ["open"])
        XCTAssertEqual(store.statusChangeOptions(forIssueIDs: ["bd-open"]), ["qa"])
        XCTAssertEqual(store.statusChangeOptions(forIssueIDs: ["bd-open", "bd-open-2"]), ["qa"])
        XCTAssertEqual(store.statusChangeOptions(forIssueIDs: ["bd-open", "bd-qa"]), ["open", "qa"])
        XCTAssertEqual(store.statusChangeOptions(forIssueIDs: []), [])
    }

    func testReadyParentRollUpPreferenceDefaultsOnPersistsPerProjectAndRecomputesReadyRows() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-parent","title":"Parent","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            {"_type":"issue","id":"bd-child","title":"Child","status":"blocked","priority":1,"issue_type":"task","parent_id":"bd-parent","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let store = BeadStore(userDefaults: defaults, commands: readyRollUpCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.count(for: .all) == 2 }
        await store.waitForPendingQueryRecompute()

        XCTAssertTrue(store.hidesParentsWithOnlyBlockedChildrenInReady)
        XCTAssertEqual(store.count(for: .ready), 0)
        XCTAssertEqual(store.filteredIssueIDs, [])

        store.hidesParentsWithOnlyBlockedChildrenInReady = false
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.count(for: .ready), 1)
        XCTAssertEqual(store.filteredIssueIDs, ["bd-parent"])

        let reloadedStore = BeadStore(userDefaults: defaults, commands: readyRollUpCommands())
        reloadedStore.openProject(projectURL)
        try await waitUntil { !reloadedStore.isLoading && reloadedStore.count(for: .all) == 2 }
        await reloadedStore.waitForPendingQueryRecompute()

        XCTAssertFalse(reloadedStore.hidesParentsWithOnlyBlockedChildrenInReady)
        XCTAssertEqual(reloadedStore.count(for: .ready), 1)
        XCTAssertEqual(reloadedStore.filteredIssueIDs, ["bd-parent"])

        let otherProjectURL = try makeProject(issueLine(id: "bd-other", status: "open", type: "task"))
        let otherStore = BeadStore(userDefaults: defaults, commands: readyRollUpCommands())
        otherStore.openProject(otherProjectURL)
        try await waitUntil { !otherStore.isLoading && otherStore.count(for: .all) == 1 }

        XCTAssertTrue(otherStore.hidesParentsWithOnlyBlockedChildrenInReady)
    }

    func testReadyParentRollUpPreferenceChangeDuringLoadWinsOverLoadedIndexPreference() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-parent","title":"Parent","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
            {"_type":"issue","id":"bd-child","title":"Child","status":"blocked","priority":1,"issue_type":"task","parent_id":"bd-parent","updated_at":"2026-07-03T20:58:35Z"}
            """
        )
        let store = BeadStore(
            userDefaults: defaults,
            commands: readyRollUpCommands(definitionReadDelay: .milliseconds(200))
        )
        store.openProject(projectURL)
        store.hidesParentsWithOnlyBlockedChildrenInReady = false
        try await waitUntil { !store.isLoading && store.count(for: .all) == 2 }
        await store.waitForPendingQueryRecompute()

        XCTAssertFalse(store.hidesParentsWithOnlyBlockedChildrenInReady)
        XCTAssertEqual(store.count(for: .ready), 1)
        XCTAssertEqual(store.filteredIssueIDs, ["bd-parent"])
    }

    func testMutableTypeOptionsExcludeGateWithoutHidingExistingGateType() async throws {
        let projectURL = try makeProject(
            """
            \(issueLine(id: "bd-task", status: "open", type: "task"))
            \(issueLine(id: "bd-gate", status: "open", type: "gate"))
            """
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-gate") != nil }

        XCTAssertTrue(store.typeOptions(including: "gate").contains("gate"))
        XCTAssertFalse(store.availableMutableTypes.contains("gate"))
        XCTAssertFalse(store.mutableTypeOptions(including: nil).contains("gate"))
        XCTAssertFalse(store.mutableTypeOptions(including: "gate").contains("gate"))
        XCTAssertNotEqual(store.blankDraft().issueType, "gate")
    }

    func testCustomTypeCannotUseReservedGateType() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        let commands = PreferenceTestCommands()
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let didAddType = await store.addCustomType(named: " gate ")

        XCTAssertFalse(didAddType)
        XCTAssertEqual(store.lastError, BeadIssueWorkflowPolicy.reservedIssueTypeError)
        let savedTypeSnapshots = await commands.savedTypeSnapshots
        XCTAssertTrue(savedTypeSnapshots.isEmpty)
    }

    func testCustomTypeAndStatusMutationsUseCommandConfigAPIs() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        let commands = PreferenceTestCommands(
            statusDefinitions: [
                BeadStatusDefinition(name: "open", category: .active, icon: nil, description: nil, isBuiltIn: true, source: .builtIn)
            ],
            typeDefinitions: [
                BeadTypeDefinition(name: "task", description: nil, source: .core)
            ]
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let addedType = await store.addCustomType(named: "incident")
        XCTAssertTrue(addedType)
        try await waitUntil { store.allTypeDefinitions.contains { $0.name == "incident" && $0.isCustom } }
        let addedStatus = await store.addCustomStatus(named: "qa", category: .wip)
        XCTAssertTrue(addedStatus)
        try await waitUntil { store.allStatusDefinitions.contains { $0.name == "qa" && $0.isCustom } }
        let deletedType = await store.deleteCustomType(named: "incident")
        XCTAssertTrue(deletedType)
        try await waitUntil { store.allTypeDefinitions.allSatisfy { $0.name != "incident" } }
        let deletedStatus = await store.deleteCustomStatus(named: "qa")
        XCTAssertTrue(deletedStatus)

        let savedTypeNames = await commands.savedTypeSnapshots.map { $0.map(\.name) }
        let savedStatusNames = await commands.savedStatusSnapshots.map { $0.map(\.name) }

        XCTAssertEqual(savedTypeNames, [["incident"], []])
        XCTAssertEqual(savedStatusNames, [["qa"], []])
    }

    func testCustomMutationsPreserveFreshCustomConfigEvenWhenLoadedMetadataIsIncomplete() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        let commands = PreferenceTestCommands(
            statusDefinitions: [
                BeadStatusDefinition(name: "open", category: .active, icon: nil, description: nil, isBuiltIn: true, source: .builtIn)
            ],
            typeDefinitions: [
                BeadTypeDefinition(name: "task", description: nil, source: .core)
            ],
            customStatusDefinitions: [
                BeadStatusDefinition(name: "triage", category: .active, icon: nil, description: nil, isBuiltIn: false, source: .custom)
            ],
            customTypeDefinitions: [
                BeadTypeDefinition(name: "incident", description: nil, source: .custom)
            ]
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let didAddType = await store.addCustomType(named: "spike")
        let didAddStatus = await store.addCustomStatus(named: "qa", category: .wip)

        XCTAssertTrue(didAddType)
        XCTAssertTrue(didAddStatus)

        let savedTypeNames = await commands.savedTypeSnapshots.map { $0.map(\.name) }
        let savedStatusNames = await commands.savedStatusSnapshots.map { $0.map(\.name) }

        XCTAssertEqual(savedTypeNames, [["incident", "spike"]])
        XCTAssertEqual(savedStatusNames, [["qa", "triage"]])
    }

    func testCustomMutationAbortsWhenFreshCustomConfigReadFails() async throws {
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        let commands = PreferenceTestCommands(
            statusDefinitions: [
                BeadStatusDefinition(name: "open", category: .active, icon: nil, description: nil, isBuiltIn: true, source: .builtIn)
            ],
            typeDefinitions: [
                BeadTypeDefinition(name: "task", description: nil, source: .core)
            ],
            customReadError: PreferenceTestError.configReadFailed
        )
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: commands)
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let didAddType = await store.addCustomType(named: "spike")
        let didAddStatus = await store.addCustomStatus(named: "qa", category: .wip)
        let savedTypeSnapshots = await commands.savedTypeSnapshots
        let savedStatusSnapshots = await commands.savedStatusSnapshots

        XCTAssertFalse(didAddType)
        XCTAssertFalse(didAddStatus)
        XCTAssertEqual(savedTypeSnapshots.count, 0)
        XCTAssertEqual(savedStatusSnapshots.count, 0)
    }

    private func makeProject(_ issuesJSONL: String) throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadStorePreferencesTests-\(UUID().uuidString)", isDirectory: true)
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

    private func issueLine(id: String, status: String, type: String) -> String {
        """
        {"_type":"issue","id":"\(id)","title":"Example","status":"\(status)","priority":1,"issue_type":"\(type)","updated_at":"2026-07-03T20:58:35Z"}
        """
    }

    private func readyRollUpCommands(definitionReadDelay: Duration? = nil) -> PreferenceTestCommands {
        PreferenceTestCommands(
            statusDefinitions: [
                BeadStatusDefinition(name: "open", category: .active, icon: nil, description: nil, isBuiltIn: true, source: .builtIn),
                BeadStatusDefinition(name: "blocked", category: .wip, icon: nil, description: nil, isBuiltIn: true, source: .builtIn),
                BeadStatusDefinition(name: "closed", category: .done, icon: nil, description: nil, isBuiltIn: true, source: .builtIn)
            ],
            typeDefinitions: [
                BeadTypeDefinition(name: "task", description: nil, source: .core)
            ],
            definitionReadDelay: definitionReadDelay
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "BeadStorePreferencesTests-\(UUID().uuidString)"
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

private actor PreferenceTestCommands: BeadsCommanding {
    private var statusDefinitions: [BeadStatusDefinition]
    private var typeDefinitions: [BeadTypeDefinition]
    private var customStatusDefinitions: [BeadStatusDefinition]
    private var customTypeDefinitions: [BeadTypeDefinition]
    private let customReadError: Error?
    private let definitionReadDelay: Duration?
    private(set) var savedStatusSnapshots: [[BeadStatusDefinition]] = []
    private(set) var savedTypeSnapshots: [[BeadTypeDefinition]] = []

    init(
        statusDefinitions: [BeadStatusDefinition] = [
            BeadStatusDefinition(name: "open", category: .active, icon: nil, description: nil, isBuiltIn: true, source: .builtIn),
            BeadStatusDefinition(name: "qa", category: .wip, icon: nil, description: nil, isBuiltIn: false, source: .custom)
        ],
        typeDefinitions: [BeadTypeDefinition] = [
            BeadTypeDefinition(name: "task", description: nil, source: .core),
            BeadTypeDefinition(name: "incident", description: nil, source: .custom)
        ],
        customStatusDefinitions: [BeadStatusDefinition]? = nil,
        customTypeDefinitions: [BeadTypeDefinition]? = nil,
        customReadError: Error? = nil,
        definitionReadDelay: Duration? = nil
    ) {
        self.statusDefinitions = statusDefinitions
        self.typeDefinitions = typeDefinitions
        self.customStatusDefinitions = customStatusDefinitions ?? statusDefinitions.filter(\.isCustom)
        self.customTypeDefinitions = customTypeDefinitions ?? typeDefinitions.filter(\.isCustom)
        self.customReadError = customReadError
        self.definitionReadDelay = definitionReadDelay
    }

    func initialize(projectURL: URL, options: BeadsInitOptions) async throws {}

    func exportReadableSnapshot(projectURL: URL) async throws {}

    func create(projectURL: URL, draft: IssueDraft) async throws -> String { "bd-created" }

    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws {}

    func updateMetadata(
        projectURL: URL,
        issueID: String,
        labels: [String]?,
        originalLabels: [String]?,
        dueAt: IssueMetadataDateUpdate,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {}

    func close(projectURL: URL, ids: [String], reason: String?) async throws {}

    func delete(projectURL: URL, ids: [String]) async throws {}

    func bulkUpdate(projectURL: URL, ids: [String], status: String?, type: String?, priority: Int?) async throws {}

    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {}

    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {}

    func addComment(projectURL: URL, issueID: String, text: String) async throws {}

    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition] {
        await delayDefinitionReadIfNeeded()
        return statusDefinitions
    }

    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] {
        await delayDefinitionReadIfNeeded()
        return typeDefinitions
    }

    func loadCustomStatuses(projectURL: URL) async throws -> [BeadStatusDefinition] {
        if let customReadError {
            throw customReadError
        }
        return customStatusDefinitions
    }

    func loadCustomTypes(projectURL: URL) async throws -> [BeadTypeDefinition] {
        if let customReadError {
            throw customReadError
        }
        return customTypeDefinitions
    }

    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws {
        savedStatusSnapshots.append(statuses)
        customStatusDefinitions = statuses
        statusDefinitions = statusDefinitions.filter { !$0.isCustom } + statuses
    }

    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws {
        savedTypeSnapshots.append(types)
        customTypeDefinitions = types
        typeDefinitions = typeDefinitions.filter { !$0.isCustom } + types
    }

    private func delayDefinitionReadIfNeeded() async {
        if let definitionReadDelay {
            try? await Task.sleep(for: definitionReadDelay)
        }
    }
}

private enum PreferenceTestError: Error {
    case configReadFailed
}
