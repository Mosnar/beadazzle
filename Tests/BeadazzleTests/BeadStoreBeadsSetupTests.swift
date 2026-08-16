import Foundation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadStoreBeadsSetupTests: XCTestCase {
    func testApplyRejectsAPlanThatChangedAfterReview() async throws {
        let projectURL = try makeProject(named: "review")
        let reviewedAssessment = assessment(
            projectURL: projectURL,
            autoPush: false
        )
        let service = BeadsSetupServiceStub(
            assessment: assessment(projectURL: projectURL, autoPush: true)
        )
        let store = BeadStore(
            userDefaults: makeUserDefaults(),
            commands: CurrentDoltTestCommands(),
            beadsSetupService: service
        )
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading }

        var draft = BeadsSetupDraft(profile: .team)
        draft.remoteURL = "https://example.com/team/beads.git"
        draft.installsHooks = false

        do {
            try await store.applyBeadsSetup(draft: draft, assessment: reviewedAssessment)
            XCTFail("Expected the changed plan to require another review")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changed after it was reviewed"))
        }
        let applyCallCount = await service.applyCallCount
        XCTAssertEqual(applyCallCount, 0)
    }

    func testApplyDoesNotRequireReviewAgainForTransientNonblockingWarning() async throws {
        let projectURL = try makeProject(named: "warning-change")
        let reviewedAssessment = assessment(
            projectURL: projectURL,
            autoPush: nil,
            warnings: ["First transient warning"]
        )
        let service = BeadsSetupServiceStub(
            assessment: assessment(
                projectURL: projectURL,
                autoPush: nil,
                warnings: ["Different transient warning"]
            )
        )
        let store = BeadStore(
            userDefaults: makeUserDefaults(),
            commands: CurrentDoltTestCommands(),
            beadsSetupService: service
        )
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading }
        var draft = BeadsSetupDraft(profile: .advanced)
        draft.installsHooks = false

        _ = try await store.applyBeadsSetup(draft: draft, assessment: reviewedAssessment)

        let applyCallCount = await service.applyCallCount
        XCTAssertEqual(applyCallCount, 1)
    }

    func testProjectSwitchCancelsSetupBeforeAnotherStepCanRun() async throws {
        let firstProjectURL = try makeProject(named: "first")
        let secondProjectURL = try makeProject(named: "second")
        let service = BeadsSetupServiceStub(
            assessment: assessment(projectURL: firstProjectURL, autoPush: nil),
            applyDelay: .milliseconds(100)
        )
        let store = BeadStore(
            userDefaults: makeUserDefaults(),
            commands: CurrentDoltTestCommands(),
            beadsSetupService: service
        )
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading }

        var draft = BeadsSetupDraft(profile: .advanced)
        draft.installsHooks = false
        let applyTask = Task {
            try await store.applyBeadsSetup(
                draft: draft,
                assessment: assessment(projectURL: firstProjectURL, autoPush: nil)
            )
        }
        try await waitUntil { await service.applyCallCount == 1 }

        store.openProject(secondProjectURL)

        do {
            _ = try await applyTask.value
            XCTFail("Expected setup to be cancelled by the project switch")
        } catch is CancellationError {
            // Expected.
        }
        try await waitUntil { await service.applyWasCancelled }
        XCTAssertEqual(store.projectURL, secondProjectURL)
        XCTAssertFalse(store.isApplyingBeadsSetup)
        XCTAssertNil(store.setupApplicationTask)
    }

    func testProjectSwitchCannotReceivePostApplyAuditFromPreviousProject() async throws {
        let firstProjectURL = try makeProject(named: "post-apply-first")
        let secondProjectURL = try makeProject(named: "post-apply-second")
        let service = BeadsSetupServiceStub(
            assessment: assessment(projectURL: firstProjectURL, autoPush: nil),
            postApplyInspectDelay: .milliseconds(250)
        )
        let store = BeadStore(
            userDefaults: makeUserDefaults(),
            commands: CurrentDoltTestCommands(),
            beadsSetupService: service
        )
        store.openProject(firstProjectURL)
        try await waitUntil { !store.isLoading }
        var draft = BeadsSetupDraft(profile: .advanced)
        draft.installsHooks = false

        _ = try await store.applyBeadsSetup(
            draft: draft,
            assessment: assessment(projectURL: firstProjectURL, autoPush: nil)
        )
        try await waitUntil { await service.inspectCallCount >= 2 }
        store.openProject(secondProjectURL)
        try await waitUntil { !store.isLoading }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(store.projectURL, secondProjectURL)
        XCTAssertNil(store.beadsSetupAssessment)
        XCTAssertTrue(store.beadsSetupFindings.isEmpty)
    }

    func testSuccessfulSetupRefreshesOwnerIdentity() async throws {
        let projectURL = try makeProject(named: "owner")
        let resolver = SetupOwnerIdentityResolver(identities: [
            .resolved(value: "before-setup@example.com", source: .gitConfiguration),
            .resolved(value: "after-setup@example.com", source: .gitConfiguration)
        ])
        let service = BeadsSetupServiceStub(
            assessment: assessment(projectURL: projectURL, autoPush: nil)
        )
        let store = BeadStore(
            userDefaults: makeUserDefaults(),
            commands: CurrentDoltTestCommands(),
            beadsSetupService: service,
            ownerIdentityResolver: resolver
        )
        store.defaultNewBeadAssignee = .owner
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading }
        try await waitUntil { await resolver.resolveCallCount == 1 }
        var draft = BeadsSetupDraft(profile: .advanced)
        draft.installsHooks = false

        _ = try await store.applyBeadsSetup(
            draft: draft,
            assessment: assessment(projectURL: projectURL, autoPush: nil)
        )
        try await waitUntil { store.ownerIdentity.value == "after-setup@example.com" }

        let resolveCallCount = await resolver.resolveCallCount
        XCTAssertEqual(resolveCallCount, 2)
        XCTAssertEqual(store.blankDraft().assignee, "after-setup@example.com")
    }

    func testSuccessfulSetupReportsValidationCommandsAndReloadProgress() async throws {
        let projectURL = try makeProject(named: "progress")
        let service = BeadsSetupServiceStub(
            assessment: assessment(projectURL: projectURL, autoPush: true)
        )
        let store = BeadStore(
            userDefaults: makeUserDefaults(),
            commands: CurrentDoltTestCommands(),
            beadsSetupService: service
        )
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading }
        var draft = BeadsSetupDraft(profile: .team)
        draft.remoteURL = "https://example.com/team/beads.git"
        draft.installsHooks = false
        let events = BeadsSetupApplyEventRecorder()

        _ = try await store.applyBeadsSetup(
            draft: draft,
            assessment: assessment(projectURL: projectURL, autoPush: true)
        ) { event in
            await events.record(event)
        }

        let recordedEvents = await events.events
        XCTAssertEqual(recordedEvents.first, .validating)
        XCTAssertTrue(recordedEvents.contains(.stepStarted("config-dolt.auto-push")))
        XCTAssertTrue(recordedEvents.contains(.stepCompleted("config-dolt.auto-push")))
        XCTAssertEqual(Array(recordedEvents.suffix(3)), [.reloadingProject, .savingIntent, .finished])
    }

    private func assessment(
        projectURL: URL,
        autoPush: Bool?,
        warnings: [String] = []
    ) -> BeadsSetupAssessment {
        let config = autoPush.map {
            [BeadsSetupConfigEntry(
                key: "dolt.auto-push",
                value: String($0),
                source: "config.yaml"
            )]
        } ?? []
        return BeadsSetupAssessment(
            projectURL: projectURL,
            inspectedAt: Date(),
            bootstrap: BeadsSetupBootstrapPreview(
                action: "none",
                beadsDirectory: ".beads",
                database: "beads",
                hasExisting: true,
                reason: nil,
                suggestion: nil
            ),
            environment: nil,
            config: .available(config),
            remotes: BeadsDoltRemotes(remotes: [
                BeadsDoltRemote(
                    name: "origin",
                    url: "https://example.com/team/beads.git",
                    sqlURL: nil,
                    status: nil
                )
            ]),
            hooks: nil,
            backup: nil,
            gitOriginURL: "https://example.com/team/beads.git",
            gitUpstreamURL: nil,
            gitOriginHasDoltData: true,
            gitUpstreamHasDoltData: nil,
            candidateRemoteURL: "https://example.com/team/beads.git",
            candidateRemoteHasDoltData: true,
            warnings: warnings
        )
    }

    private func makeProject(named name: String) throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadStoreBeadsSetupTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        try """
        {"id":"bd-1","title":"One","status":"open","priority":2,"issue_type":"task","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
        """.write(
            to: beadsURL.appendingPathComponent("issues.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: projectURL) }
        return projectURL
    }

    private func makeUserDefaults() -> UserDefaults {
        makeIsolatedUserDefaults()
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition")
    }
}

private actor BeadsSetupServiceStub: BeadsSetupServicing {
    let assessment: BeadsSetupAssessment
    let applyDelay: Duration?
    let postApplyInspectDelay: Duration?
    private(set) var applyCallCount = 0
    private(set) var inspectCallCount = 0
    private(set) var applyWasCancelled = false

    init(
        assessment: BeadsSetupAssessment,
        applyDelay: Duration? = nil,
        postApplyInspectDelay: Duration? = nil
    ) {
        self.assessment = assessment
        self.applyDelay = applyDelay
        self.postApplyInspectDelay = postApplyInspectDelay
    }

    func inspect(
        projectURL: URL,
        scope: BeadsSetupInspectionScope,
        candidateRemote: BeadsDoltRemote?,
        preloadedEnvironment: BeadsProjectEnvironment?
    ) async throws -> BeadsSetupAssessment {
        inspectCallCount += 1
        if inspectCallCount > 1, let postApplyInspectDelay {
            try await Task.sleep(for: postApplyInspectDelay)
        }
        return assessment
    }

    func apply(
        projectURL: URL,
        plan: BeadsSetupPlan,
        cancellationToken: BeadsSetupCancellationToken,
        progress: @escaping BeadsSetupApplyProgressHandler
    ) async throws -> BeadsSetupApplyReport {
        applyCallCount += 1
        do {
            if let applyDelay {
                try await Task.sleep(for: applyDelay)
            }
            try cancellationToken.checkCancellation()
            for step in plan.steps {
                await progress(.stepStarted(step.id))
                await progress(.stepCompleted(step.id))
            }
        } catch is CancellationError {
            applyWasCancelled = true
            throw CancellationError()
        }
        return BeadsSetupApplyReport(completedStepIDs: plan.steps.map(\.id))
    }
}

private actor BeadsSetupApplyEventRecorder {
    private(set) var events: [BeadsSetupApplyEvent] = []

    func record(_ event: BeadsSetupApplyEvent) {
        events.append(event)
    }
}

private actor SetupOwnerIdentityResolver: BeadOwnerIdentityResolving {
    private var identities: [BeadOwnerIdentity]
    private(set) var resolveCallCount = 0

    init(identities: [BeadOwnerIdentity]) {
        self.identities = identities
    }

    func resolve(projectURL: URL) async -> BeadOwnerIdentity {
        resolveCallCount += 1
        guard !identities.isEmpty else { return .unavailable }
        return identities.removeFirst()
    }
}
