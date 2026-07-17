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
        XCTAssertTrue(store.automaticallyRefreshesExternalChanges)
        XCTAssertTrue(store.stateDimensionDisplayNames.isEmpty)
        XCTAssertTrue(store.stateValueDisplayNames.isEmpty)
        XCTAssertTrue(store.archivedStateValuesByDimension.isEmpty)
        XCTAssertEqual(store.beadListDisplayOptions, .compact)
    }

    func testAppPreferencesPersistThroughInjectedUserDefaults() {
        let defaults = makeUserDefaults()
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())

        store.bdCLIPath = "/tmp/custom-bd"

        let reloadedStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())

        XCTAssertEqual(reloadedStore.bdCLIPath, "/tmp/custom-bd")
        XCTAssertEqual(reloadedStore.staleCutoffDays, 14)
        XCTAssertEqual(reloadedStore.beadListDisplayOptions, .compact)
    }

    func testPinnedStateDimensionsPersistOrderPerProjectAndDropInvalidEntries() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        let otherProjectURL = try makeProject(issueLine(id: "bd-2", status: "open", type: "task"))
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        XCTAssertTrue(store.pinnedStateDimensions.isEmpty)
        XCTAssertTrue(store.pinStateDimension("Phase"))
        XCTAssertTrue(store.pinStateDimension("health"))
        XCTAssertTrue(store.pinStateDimension("phase"))
        XCTAssertFalse(store.pinStateDimension("bad:dimension"))
        XCTAssertEqual(store.pinnedStateDimensions, ["Phase", "health", "phase"])
        XCTAssertTrue(store.pinStateDimension("track", at: 1))
        XCTAssertEqual(store.pinnedStateDimensions, ["Phase", "track", "health", "phase"])
        XCTAssertTrue(store.pinStateDimension("track", at: 0))
        XCTAssertEqual(store.pinnedStateDimensions, ["Phase", "track", "health", "phase"])
        store.unpinStateDimension("track")
        XCTAssertEqual(store.pinnedStateDimensions, ["Phase", "health", "phase"])
        XCTAssertEqual(store.stateDimensionDisplayName(for: "phase"), "Phase")
        XCTAssertTrue(store.setStateDimensionDisplayName("Delivery Phase", for: "phase"))
        XCTAssertFalse(store.setStateDimensionDisplayName("   ", for: "health"))
        XCTAssertEqual(store.stateDimensionDisplayName(for: "phase"), "Delivery Phase")
        XCTAssertTrue(store.setStateDimensionDisplayName("Phase", for: "phase"))
        XCTAssertNil(store.stateDimensionDisplayNames["phase"])
        XCTAssertTrue(store.setStateDimensionDisplayName("Delivery Phase", for: "phase"))

        store.movePinnedStateDimensions(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(store.pinnedStateDimensions, ["phase", "Phase", "health"])
        XCTAssertFalse(store.canMovePinnedStateDimensionUp("phase"))
        XCTAssertTrue(store.canMovePinnedStateDimensionDown("phase"))

        store.movePinnedStateDimensionDown("phase")
        store.movePinnedStateDimensionUp("health")
        XCTAssertEqual(store.pinnedStateDimensions, ["Phase", "health", "phase"])

        store.unpinStateDimension("health")
        XCTAssertEqual(store.pinnedStateDimensions, ["Phase", "phase"])

        let reloadedStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        reloadedStore.openProject(projectURL)
        try await waitUntil { !reloadedStore.isLoading && reloadedStore.issue(with: "bd-1") != nil }
        XCTAssertEqual(reloadedStore.pinnedStateDimensions, ["Phase", "phase"])
        XCTAssertEqual(reloadedStore.stateDimensionDisplayName(for: "phase"), "Delivery Phase")

        let otherStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        otherStore.openProject(otherProjectURL)
        try await waitUntil { !otherStore.isLoading && otherStore.issue(with: "bd-2") != nil }
        XCTAssertTrue(otherStore.pinnedStateDimensions.isEmpty)
        XCTAssertEqual(otherStore.stateDimensionDisplayName(for: "phase"), "Phase")
    }

    func testStateDimensionDisplayNameNormalizationDropsInvalidAndDefaultOverrides() {
        XCTAssertEqual(
            BeadStore.normalizedStateDimensionDisplayNames([
                "phase": " Delivery Phase ",
                "health": "Health",
                "track": "Track\nName",
                "bad:dimension": "Invalid"
            ]),
            ["phase": "Delivery Phase"]
        )
    }

    func testStateValuePresentationPreferencesPersistPerProjectAndRemainSparse() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(
            """
            {"_type":"issue","id":"bd-1","title":"Example","status":"open","priority":1,"issue_type":"task","labels":["phase:awaiting_deploy"]}
            {"_type":"issue","id":"bd-state-event","title":"State change: phase → awaiting_deploy","status":"closed","priority":1,"issue_type":"event"}
            """
        )
        let otherProjectURL = try makeProject(issueLine(id: "bd-2", status: "open", type: "task"))
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        XCTAssertEqual(store.stateValueDisplayName(for: "awaiting_deploy", in: "phase"), "awaiting_deploy")
        XCTAssertFalse(store.isStateValueArchived("awaiting_deploy", in: "phase"))
        XCTAssertEqual(store.stateValueUsageCount(for: "awaiting_deploy", in: "phase"), 1)

        XCTAssertTrue(store.setStateValueDisplayName("Awaiting Deploy", for: "awaiting_deploy", in: "phase"))
        XCTAssertTrue(store.setStateValue("awaiting_deploy", in: "phase", isArchived: true))
        XCTAssertFalse(store.setStateValueDisplayName("   ", for: "awaiting_deploy", in: "phase"))
        XCTAssertFalse(store.setStateValue("   ", in: "phase", isArchived: true))

        XCTAssertEqual(store.stateValueDisplayNames, ["phase": ["awaiting_deploy": "Awaiting Deploy"]])
        XCTAssertEqual(store.archivedStateValuesByDimension, ["phase": ["awaiting_deploy"]])
        XCTAssertEqual(
            store.stateValueCatalog(for: "phase"),
            BeadStateValueCatalog(
                active: [],
                archived: [
                    BeadStateValuePresentation(
                        value: "awaiting_deploy",
                        displayName: "Awaiting Deploy",
                        isArchived: true
                    )
                ]
            )
        )

        XCTAssertTrue(store.setStateValueDisplayName("awaiting_deploy", for: "awaiting_deploy", in: "phase"))
        XCTAssertNil(store.stateValueDisplayNames["phase"])
        XCTAssertTrue(store.setStateValueDisplayName("Awaiting Deploy", for: "awaiting_deploy", in: "phase"))

        let reloadedStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        reloadedStore.openProject(projectURL)
        try await waitUntil { !reloadedStore.isLoading && reloadedStore.issue(with: "bd-1") != nil }
        XCTAssertEqual(reloadedStore.stateValueDisplayName(for: "awaiting_deploy", in: "phase"), "Awaiting Deploy")
        XCTAssertTrue(reloadedStore.isStateValueArchived("awaiting_deploy", in: "phase"))

        let otherStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        otherStore.openProject(otherProjectURL)
        try await waitUntil { !otherStore.isLoading && otherStore.issue(with: "bd-2") != nil }
        XCTAssertEqual(otherStore.stateValueDisplayName(for: "awaiting_deploy", in: "phase"), "awaiting_deploy")
        XCTAssertFalse(otherStore.isStateValueArchived("awaiting_deploy", in: "phase"))
    }

    func testStateValuePreferenceNormalizationDropsInvalidDefaultAndEmptyEntries() {
        XCTAssertEqual(
            BeadStore.normalizedStateValueDisplayNames([
                "phase": [
                    "awaiting_deploy": " Awaiting Deploy ",
                    "active": "active",
                    "invalid": "Two\nLines",
                    "   ": "Missing Value"
                ],
                "bad:dimension": ["active": "Active"]
            ]),
            ["phase": ["awaiting_deploy": "Awaiting Deploy"]]
        )
        XCTAssertEqual(
            BeadStore.normalizedArchivedStateValues([
                "phase": ["awaiting_deploy", "   "],
                "bad:dimension": ["active"],
                "health": []
            ]),
            ["phase": ["awaiting_deploy"]]
        )
    }

    func testProjectListDisplayOptionsPersistPerProject() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        let otherProjectURL = try makeProject(issueLine(id: "bd-2", status: "open", type: "task"))
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        XCTAssertEqual(store.beadListDisplayOptions, .compact)

        store.showsOwnerInBeadList = true
        store.showsAssigneeInBeadList = true
        store.showsDueDateInBeadList = true
        store.showsCommentsInBeadList = false

        XCTAssertEqual(
            store.beadListDisplayOptions,
            BeadListDisplayOptions(showsOwner: true, showsAssignee: true, showsDueDate: true, showsComments: false)
        )

        let reloadedStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        reloadedStore.openProject(projectURL)
        try await waitUntil { !reloadedStore.isLoading && reloadedStore.issue(with: "bd-1") != nil }

        XCTAssertTrue(reloadedStore.showsOwnerInBeadList)
        XCTAssertTrue(reloadedStore.showsAssigneeInBeadList)
        XCTAssertTrue(reloadedStore.showsDueDateInBeadList)
        XCTAssertFalse(reloadedStore.showsCommentsInBeadList)

        let otherStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        otherStore.openProject(otherProjectURL)
        try await waitUntil { !otherStore.isLoading && otherStore.issue(with: "bd-2") != nil }

        XCTAssertEqual(otherStore.beadListDisplayOptions, .compact)
    }

    func testExternalRefreshPreferencePersistsPerProjectAndDefaultsOn() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        let otherProjectURL = try makeProject(issueLine(id: "bd-2", status: "open", type: "task"))
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        XCTAssertTrue(store.automaticallyRefreshesExternalChanges)
        store.automaticallyRefreshesExternalChanges = false

        let reloadedStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        reloadedStore.openProject(projectURL)
        try await waitUntil { !reloadedStore.isLoading && reloadedStore.issue(with: "bd-1") != nil }
        XCTAssertFalse(reloadedStore.automaticallyRefreshesExternalChanges)

        let otherStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        otherStore.openProject(otherProjectURL)
        try await waitUntil { !otherStore.isLoading && otherStore.issue(with: "bd-2") != nil }
        XCTAssertTrue(otherStore.automaticallyRefreshesExternalChanges)
    }

    func testLegacyGlobalPreferencesSeedProjectScopedPreferences() async throws {
        let defaults = makeUserDefaults()
        defaults.set(30, forKey: BeadazzlePreferenceKeys.legacyStaleCutoffDays)
        defaults.set(true, forKey: BeadazzlePreferenceKeys.legacyShowsOwnerInBeadList)
        defaults.set(true, forKey: BeadazzlePreferenceKeys.legacyShowsAssigneeInBeadList)
        defaults.set(true, forKey: BeadazzlePreferenceKeys.legacyShowsDueDateInBeadList)
        defaults.set(false, forKey: BeadazzlePreferenceKeys.legacyShowsCommentsInBeadList)
        let projectURL = try makeProject(issueLine(id: "bd-legacy", status: "open", type: "task"))
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())

        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-legacy") != nil }

        XCTAssertEqual(store.staleCutoffDays, 30)
        XCTAssertEqual(
            store.beadListDisplayOptions,
            BeadListDisplayOptions(showsOwner: true, showsAssignee: true, showsDueDate: true, showsComments: false)
        )
        XCTAssertEqual(
            defaults.integer(forKey: BeadazzlePreferenceKeys.staleCutoffDays(projectURL: projectURL)),
            30
        )
        XCTAssertTrue(defaults.bool(forKey: BeadazzlePreferenceKeys.showsOwnerInBeadList(projectURL: projectURL)))
        XCTAssertTrue(defaults.bool(forKey: BeadazzlePreferenceKeys.showsAssigneeInBeadList(projectURL: projectURL)))
        XCTAssertTrue(defaults.bool(forKey: BeadazzlePreferenceKeys.showsDueDateInBeadList(projectURL: projectURL)))
        XCTAssertFalse(defaults.bool(forKey: BeadazzlePreferenceKeys.showsCommentsInBeadList(projectURL: projectURL)))
    }

    func testProjectScopedPreferencesOverrideLegacyGlobalPreferences() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(issueLine(id: "bd-scoped", status: "open", type: "task"))
        defaults.set(30, forKey: BeadazzlePreferenceKeys.legacyStaleCutoffDays)
        defaults.set(true, forKey: BeadazzlePreferenceKeys.legacyShowsOwnerInBeadList)
        defaults.set(7, forKey: BeadazzlePreferenceKeys.staleCutoffDays(projectURL: projectURL))
        defaults.set(false, forKey: BeadazzlePreferenceKeys.showsOwnerInBeadList(projectURL: projectURL))
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())

        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-scoped") != nil }

        XCTAssertEqual(store.staleCutoffDays, 7)
        XCTAssertFalse(store.showsOwnerInBeadList)
    }

    func testStaleCutoffPersistsPerProjectAndRecomputesStaleRows() async throws {
        let defaults = makeUserDefaults()
        let tenDaysAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-10 * 24 * 60 * 60))
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task", updatedAt: tenDaysAgo))
        let otherProjectURL = try makeProject(issueLine(id: "bd-2", status: "open", type: "task", updatedAt: tenDaysAgo))
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        XCTAssertEqual(store.staleCutoffDays, 14)
        XCTAssertEqual(store.count(for: .stale), 0)

        store.staleCutoffDays = 7
        await store.waitForPendingQueryRecompute()

        XCTAssertEqual(store.staleCutoffDays, 7)
        XCTAssertEqual(store.count(for: .stale), 1)

        let reloadedStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        reloadedStore.openProject(projectURL)
        try await waitUntil { !reloadedStore.isLoading && reloadedStore.issue(with: "bd-1") != nil }
        await reloadedStore.waitForPendingQueryRecompute()

        XCTAssertEqual(reloadedStore.staleCutoffDays, 7)
        XCTAssertEqual(reloadedStore.count(for: .stale), 1)

        let otherStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        otherStore.openProject(otherProjectURL)
        try await waitUntil { !otherStore.isLoading && otherStore.issue(with: "bd-2") != nil }
        await otherStore.waitForPendingQueryRecompute()

        XCTAssertEqual(otherStore.staleCutoffDays, 14)
        XCTAssertEqual(otherStore.count(for: .stale), 0)
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

    func testOptionInventoryDocumentsPersistentOptionOwnership() {
        let entries = BeadazzleOptionInventory.entries
        let expectedIDs: Set<String> = [
            "bdCLIPath",
            "automaticallyChecksForUpdates",
            "receivesBetaUpdates",
            "staleCutoffDays",
            "hidesParentsWithOnlyBlockedChildrenInReady",
            "automaticallyRefreshesExternalChanges",
            "hiddenTypes",
            "hiddenStatuses",
            "showsOwnerInBeadList",
            "showsAssigneeInBeadList",
            "showsDueDateInBeadList",
            "showsCommentsInBeadList",
            "pinnedStateDimensions",
            "stateDimensionDisplayNames",
            "stateValueDisplayNames",
            "archivedStateValues",
            "savedViews",
            "workspaceState"
        ]

        XCTAssertEqual(Set(entries.map(\.id)), expectedIDs)
        XCTAssertEqual(entries.map(\.id).count, Set(entries.map(\.id)).count)
        XCTAssertTrue(entries.allSatisfy { !$0.persistence.isEmpty })
        XCTAssertTrue(entries.allSatisfy { !$0.defaultValue.isEmpty })
        XCTAssertTrue(entries.allSatisfy { !$0.uiLocation.isEmpty })
        XCTAssertTrue(entries.allSatisfy { !$0.behavior.isEmpty })
        XCTAssertEqual(
            Set(entries.filter { $0.scope == .projectViewOption }.map(\.uiLocation)),
            Set(["Issue List > View Options", "Sidebar > Bookmarks", "Project Settings > Storage", "Project Settings > Properties"])
        )
    }

    func testSavedViewsCapturePersistPerProjectAndRebuildCounts() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject([
            issueLine(id: "bd-1", status: "open", type: "task"),
            issueLine(id: "bd-2", status: "closed", type: "bug")
        ].joined(separator: "\n"))
        let otherProjectURL = try makeProject(issueLine(id: "other-1", status: "open", type: "task"))
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        store.applyBookmark(.all)
        store.statusFilters = ["open"]
        store.typeFilters = ["task"]
        store.priorityFilters = [1]
        store.labelFilters = []
        store.searchText = "Example"
        store.sort = .updated
        store.sortDirection = .descending
        await store.waitForPendingQueryRecompute()
        store.saveCurrentViewAsBookmark(name: "  Open Tasks  ", symbolName: "not.a.real.symbol")
        await store.waitForPendingQueryRecompute()
        await store.waitForPendingSavedViewCountRebuild()

        let saved = try XCTUnwrap(store.savedViews.first)
        XCTAssertEqual(saved.name, "Open Tasks")
        XCTAssertEqual(saved.symbolName, BeadSavedViewSymbols.fallback)
        XCTAssertEqual(saved.query.basePreset, .all)
        XCTAssertEqual(saved.query.statusFilters, ["open"])
        XCTAssertEqual(saved.query.typeFilters, ["task"])
        XCTAssertEqual(saved.query.priorityFilters, [1])
        XCTAssertEqual(saved.query.searchText, "Example")
        XCTAssertEqual(saved.ordering.fallbackSort.field, .updated)
        XCTAssertEqual(saved.ordering.fallbackSort.direction, .descending)
        XCTAssertEqual(store.activeSavedViewID, saved.id)
        XCTAssertEqual(store.count(forSavedViewID: saved.id), 1)

        store.statusFilters = []
        XCTAssertNil(store.activeSavedViewID)
        store.applyBookmark(.all)
        store.typeFilters = []
        store.priorityFilters = []
        store.searchText = ""

        store.applySavedView(id: saved.id)
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.filteredIssueIDs, ["bd-1"])
        XCTAssertEqual(store.activeSavedViewID, saved.id)

        let reloaded = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        reloaded.openProject(projectURL)
        try await waitUntil { !reloaded.isLoading && reloaded.issue(with: "bd-1") != nil }
        await reloaded.waitForPendingSavedViewCountRebuild()
        XCTAssertEqual(reloaded.savedViews, [saved])
        XCTAssertEqual(reloaded.count(forSavedViewID: saved.id), 1)

        reloaded.duplicateSavedView(id: saved.id)
        XCTAssertEqual(reloaded.savedViews.count, 2)
        XCTAssertNotEqual(reloaded.savedViews[0].id, reloaded.savedViews[1].id)
        XCTAssertEqual(reloaded.savedViews[1].name, "Open Tasks Copy")

        let otherStore = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        otherStore.openProject(otherProjectURL)
        try await waitUntil { !otherStore.isLoading && otherStore.issue(with: "other-1") != nil }
        XCTAssertTrue(otherStore.savedViews.isEmpty)
    }

    func testSavedViewCRUDAndOrderingPersist() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        store.saveCurrentViewAsBookmark(name: "First", symbolName: "bookmark")
        store.saveCurrentViewAsBookmark(name: "Second", symbolName: "star")
        let firstID = try XCTUnwrap(store.savedViews.first?.id)
        let secondID = try XCTUnwrap(store.savedViews.last?.id)

        store.renameSavedView(id: firstID, to: "Renamed")
        store.setSavedViewSymbol(id: firstID, symbolName: "flag")
        store.moveSavedViewDown(id: firstID)
        XCTAssertEqual(store.savedViews.map(\.id), [secondID, firstID])
        store.moveSavedViewUp(id: firstID)
        XCTAssertEqual(store.savedViews.map(\.id), [firstID, secondID])
        store.moveSavedViews(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(store.savedViews.map(\.id), [secondID, firstID])
        store.duplicateSavedView(id: firstID)
        let duplicateID = try XCTUnwrap(store.savedViews.last?.id)
        XCTAssertNotEqual(duplicateID, firstID)
        XCTAssertEqual(store.savedViews.last?.name, "Renamed Copy")
        store.deleteSavedView(id: secondID)
        await store.waitForPendingSavedViewCountRebuild()
        XCTAssertEqual(Set(store.savedViewCounts.keys), Set([firstID, duplicateID]))

        let reloaded = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        reloaded.openProject(projectURL)
        try await waitUntil { !reloaded.isLoading && reloaded.issue(with: "bd-1") != nil }

        XCTAssertEqual(reloaded.savedViews.map(\.id), [firstID, duplicateID])
        XCTAssertEqual(reloaded.savedViews.first?.name, "Renamed")
        XCTAssertEqual(reloaded.savedViews.first?.symbolName, "flag")
    }

    func testSavingWithoutReadableProjectDoesNothing() {
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: PreferenceTestCommands())

        store.saveCurrentViewAsBookmark(name: "Should Not Save", symbolName: "bookmark")

        XCTAssertTrue(store.savedViews.isEmpty)
        XCTAssertNil(store.activeSavedViewID)
    }

    func testSuggestedSavedViewNamesAreContextualAndUnique() async throws {
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: PreferenceTestCommands())
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        XCTAssertEqual(store.suggestedSavedViewName, "Ready")
        store.saveCurrentViewAsBookmark(name: "Ready", symbolName: "bookmark")
        XCTAssertEqual(store.suggestedSavedViewName, "Ready 2")
        store.searchText = "crash"
        XCTAssertEqual(store.suggestedSavedViewName, "Search: crash")
        XCTAssertTrue(store.currentSavedViewSummary.contains("search text"))
    }

    func testAdvancedSavedViewAppliesCountsAndSurvivesToolbarDrift() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject([
            issueLine(id: "bd-1", status: "open", type: "task"),
            issueLine(id: "bd-2", status: "open", type: "task")
        ].joined(separator: "\n"))
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let condition = BeadFilterCondition(
            field: .id,
            operation: .isEqual,
            value: BeadFilterValue(text: "bd-1")
        )
        var filter = store.currentSavedViewQuery
        filter.advancedPredicate = BeadFilterGroup(children: [.condition(condition)])
        store.saveConfiguredView(
            name: "Only One",
            symbolName: "bookmark",
            query: filter,
            ordering: store.currentSavedViewOrdering
        )
        await store.waitForPendingQueryRecompute()
        await store.waitForPendingSavedViewCountRebuild()

        let id = try XCTUnwrap(store.activeSavedViewID)
        XCTAssertEqual(store.filteredIssueIDs, ["bd-1"])
        XCTAssertEqual(store.count(forSavedViewID: id), 1)
        XCTAssertEqual(store.advancedFilterCount, 1)

        store.setPriorityFilter(1, isOn: true)
        XCTAssertNil(store.activeSavedViewID)
        XCTAssertEqual(store.sourceSavedViewID, id)
        XCTAssertTrue(store.isSavedViewDrifted)
        XCTAssertEqual(store.advancedFilterCount, 1)

        store.sort = .updated
        store.sortDirection = .descending
        store.updateSavedViewFilterFromCurrentState(id: id)
        XCTAssertEqual(store.activeSavedViewID, id)
        XCTAssertEqual(store.sourceSavedViewID, id)
        XCTAssertFalse(store.isSavedViewDrifted)
        XCTAssertEqual(store.savedViews.first?.ordering.fallbackSort, BeadSavedViewSort(
            field: .updated,
            direction: .descending
        ))

        store.setPriorityFilter(2, isOn: true)
        store.revertToSourceSavedView()
        await store.waitForPendingQueryRecompute()
        XCTAssertEqual(store.activeSavedViewID, id)
        XCTAssertFalse(store.isSavedViewDrifted)

        store.applyBookmark(.all)
        await store.waitForPendingQueryRecompute()
        XCTAssertNil(store.sourceSavedViewID)
        XCTAssertEqual(store.advancedFilterCount, 0)

        store.applySavedView(id: id)
        store.clearAdvancedFilters()
        XCTAssertTrue(store.updateWouldReplaceAdvancedRules(id: id))
    }

    func testSavedViewLoadingSkipsMalformedSibling() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        let valid = BeadSavedView(
            id: UUID(),
            name: "Valid",
            symbolName: "bookmark",
            query: BeadSavedViewQuery(
                basePreset: .all,
                statusFilters: [],
                typeFilters: [],
                priorityFilters: [],
                labelFilters: [],
                searchText: ""
            ),
            ordering: .sorted(BeadSavedViewSort(field: .priority, direction: .ascending))
        )
        let validObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BeadSavedViewNode.view(valid)))
        let payload = try JSONSerialization.data(withJSONObject: [
            "version": BeadSavedViewsPayload.currentVersion,
            "rootNodes": [validObject, ["kind": "broken"]]
        ])
        defaults.set(payload, forKey: BeadazzlePreferenceKeys.savedViews(projectURL: projectURL))

        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        let key = BeadazzlePreferenceKeys.savedViews(projectURL: projectURL)
        XCTAssertEqual(store.savedViews, [valid])
        XCTAssertEqual(store.savedViewRecoveryIssueCount, 1)
        XCTAssertNotNil(store.savedViewsPersistenceMessage)
        XCTAssertEqual(defaults.data(forKey: "\(key).Recovery"), payload)

        store.acceptRecoveredSavedViews()
        XCTAssertEqual(store.savedViewPersistenceState, .ready)
        XCTAssertNil(store.savedViewsPersistenceMessage)
        let persisted = try XCTUnwrap(defaults.data(forKey: key))
        XCTAssertEqual(
            try JSONDecoder().decode(BeadSavedViewsPayload.self, from: persisted).rootNodes,
            [.view(valid)]
        )
    }

    func testUnsupportedFuturePayloadIsPreservedAndReadOnly() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        let payload = try JSONSerialization.data(withJSONObject: ["version": 99, "rootNodes": []])
        let key = BeadazzlePreferenceKeys.savedViews(projectURL: projectURL)
        defaults.set(payload, forKey: key)
        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        XCTAssertTrue(store.savedViewsHaveUnsupportedVersion)
        XCTAssertNotNil(store.savedViewsPersistenceMessage)
        XCTAssertTrue(store.savedViews.isEmpty)
        store.saveCurrentViewAsBookmark(name: "Must Not Overwrite", symbolName: "bookmark")
        XCTAssertTrue(store.savedViews.isEmpty)
        XCTAssertEqual(defaults.data(forKey: key), payload)
        XCTAssertNotNil(store.lastError)

        store.resetSavedViews()
        XCTAssertFalse(store.savedViewsPayloadIsCorrupt)
        XCTAssertNil(store.savedViewsPersistenceMessage)
        XCTAssertNil(defaults.data(forKey: key))
        XCTAssertEqual(defaults.data(forKey: "\(key).Recovery"), payload)

        store.saveCurrentViewAsBookmark(name: "Fresh", symbolName: "bookmark")
        XCTAssertEqual(store.savedViews.map(\.name), ["Fresh"])
        XCTAssertNotNil(defaults.data(forKey: key))
    }

    func testCorruptSavedViewPayloadIsPreservedAndReadOnly() async throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(issueLine(id: "bd-1", status: "open", type: "task"))
        let payload = Data("not-json".utf8)
        let key = BeadazzlePreferenceKeys.savedViews(projectURL: projectURL)
        defaults.set(payload, forKey: key)

        let store = BeadStore(userDefaults: defaults, commands: PreferenceTestCommands())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.issue(with: "bd-1") != nil }

        XCTAssertTrue(store.savedViewsPayloadIsCorrupt)
        XCTAssertEqual(store.savedViewRecoveryIssueCount, 1)
        XCTAssertEqual(defaults.data(forKey: "\(key).Recovery"), payload)
        store.saveCurrentViewAsBookmark(name: "Must Not Overwrite", symbolName: "bookmark")
        XCTAssertTrue(store.savedViews.isEmpty)
        XCTAssertEqual(defaults.data(forKey: key), payload)
        XCTAssertNotNil(store.lastError)
    }

    private func issueLine(
        id: String,
        status: String,
        type: String,
        updatedAt: String = "2026-07-03T20:58:35Z"
    ) -> String {
        """
        {"_type":"issue","id":"\(id)","title":"Example","status":"\(status)","priority":1,"issue_type":"\(type)","updated_at":"\(updatedAt)"}
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
