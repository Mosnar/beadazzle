import Foundation
import XCTest
@testable import Beadazzle

final class BeadsSetupPlannerTests: XCTestCase {
    func testApplyProgressTracksActiveCompletedAndFailedReviewSteps() {
        var progress = BeadsSetupApplyProgress()

        progress.record(.validating)
        XCTAssertEqual(progress.scrollTargetID, "setup-progress-phase")
        progress.record(.stepStarted("config"))
        XCTAssertEqual(progress.status(forStepID: "config"), .inProgress)
        XCTAssertEqual(progress.scrollTargetID, "config")
        XCTAssertEqual(progress.status(forStepID: "hooks"), .pending)

        progress.record(.stepCompleted("config"))
        progress.record(.stepStarted("hooks"))
        progress.record(.stepFailed("hooks"))
        progress.recordFailure()

        XCTAssertEqual(progress.status(forStepID: "config"), .completed)
        XCTAssertEqual(progress.status(forStepID: "hooks"), .failed)

        progress.record(.recoveringProject)
        XCTAssertEqual(progress.status(forStepID: "hooks"), .failed)
        XCTAssertNotNil(progress.phaseMessage)
    }

    func testApplyProgressTracksLocalIntentAfterProjectReload() {
        var progress = BeadsSetupApplyProgress()

        progress.record(.reloadingProject)
        XCTAssertEqual(progress.localIntentStatus, .pending)
        XCTAssertNotNil(progress.phaseMessage)

        progress.record(.savingIntent)
        XCTAssertEqual(progress.localIntentStatus, .inProgress)

        progress.record(.finished)
        XCTAssertEqual(progress.localIntentStatus, .completed)
    }

    func testGuidedUseCaseAsksContributorsWhetherTheyUseTheProjectTracker() {
        var answers = BeadsSetupUseCaseAnswers()

        answers.selectProjectRelationship(.contributing)

        XCTAssertNil(answers.resolvedProfile)
        XCTAssertNil(answers.usesProjectSharedTracker)
        XCTAssertNil(answers.collaborationStyle)

        answers.selectProjectTrackerSharing(true)

        XCTAssertEqual(answers.resolvedProfile, .team)
        XCTAssertNil(answers.collaborationStyle)
    }

    func testGuidedUseCaseRoutesSeparateContributorPlanningToContributorProfile() {
        var answers = BeadsSetupUseCaseAnswers()
        answers.selectProjectRelationship(.contributing)
        answers.selectProjectTrackerSharing(false)

        XCTAssertEqual(answers.resolvedProfile, .contributor)
        XCTAssertNil(answers.collaborationStyle)
    }

    func testGuidedUseCaseRoutesSharedTeamTrackerToTeamProfile() {
        var answers = BeadsSetupUseCaseAnswers()
        answers.selectProjectRelationship(.ownProject)
        answers.selectCollaborationStyle(.team)
        XCTAssertNil(answers.resolvedProfile)

        answers.selectTeamSharing(true)

        XCTAssertEqual(answers.resolvedProfile, .team)
        XCTAssertNil(answers.syncsThroughGit)
    }

    func testContributorJoiningSharedTrackerCannotPublishAnEmptyRemote() {
        var draft = BeadsSetupDraft(profile: .team)
        var answers = BeadsSetupUseCaseAnswers()
        answers.selectProjectRelationship(.contributing)
        answers.selectProjectTrackerSharing(true)
        draft.useCaseAnswers = answers
        draft.remoteURL = "https://github.com/acme/project.git"
        draft.completesRemoteSetup = true

        let plan = BeadsSetupPlanner.plan(
            draft: draft,
            assessment: assessment(
                gitOriginURL: draft.remoteURL,
                gitOriginHasDoltData: false,
                candidateRemoteURL: draft.remoteURL,
                candidateRemoteHasDoltData: false
            )
        )

        XCTAssertFalse(plan.canApply)
        XCTAssertTrue(plan.blockingFindings.contains { $0.id == "contributor-shared-tracker-missing" })
        XCTAssertTrue(plan.blockingFindings.contains { $0.id == "contributor-shared-tracker-publish" })
    }

    func testContributorJoiningSharedTrackerInitializesWithContributorRole() throws {
        var answers = BeadsSetupUseCaseAnswers()
        answers.selectProjectRelationship(.contributing)
        answers.selectProjectTrackerSharing(true)
        var draft = BeadsSetupDraft(profile: .team)
        draft.useCaseAnswers = answers
        draft.remoteURL = "https://github.com/acme/project.git"

        let plan = BeadsSetupPlanner.plan(
            draft: draft,
            assessment: assessment(
                gitOriginURL: draft.remoteURL,
                gitOriginHasDoltData: true,
                candidateRemoteURL: draft.remoteURL,
                candidateRemoteHasDoltData: true
            )
        )
        let initialize = try XCTUnwrap(plan.steps.first { $0.id == "initialize" })

        guard case .initialize(let role, _) = initialize.operation else {
            return XCTFail("Expected an initialize operation")
        }
        XCTAssertEqual(role, "contributor")
    }

    func testApplyFailurePresentationKeepsCompletedProgressAndCommandDetails() {
        let failure = BeadsSetupApplyFailure(
            report: BeadsSetupApplyReport(completedStepIDs: ["initialize", "config"]),
            failedStepTitle: "Publish remote",
            underlyingError: BeadError.commandFailed(
                command: "bd --sandbox dolt push",
                output: "permission denied"
            )
        )

        let presentation = BeadsSetupFailurePresentation.applying(failure)

        XCTAssertTrue(presentation.message.contains("2 earlier setup changes"))
        XCTAssertEqual(presentation.command, "bd --sandbox dolt push")
        XCTAssertEqual(presentation.output, "permission denied")
    }

    func testGuidedUseCaseRoutesSeparateTeamTrackerToLocalProfile() {
        var answers = BeadsSetupUseCaseAnswers()
        answers.selectProjectRelationship(.ownProject)
        answers.selectCollaborationStyle(.team)
        answers.selectTeamSharing(false)

        XCTAssertEqual(answers.resolvedProfile, .local)
        XCTAssertNil(answers.syncsThroughGit)
    }

    func testGuidedUseCaseRoutesUnsyncedSoloWorkToLocalProfile() {
        var answers = BeadsSetupUseCaseAnswers()
        answers.selectProjectRelationship(.ownProject)
        answers.selectCollaborationStyle(.alone)
        answers.selectGitSync(false)

        XCTAssertEqual(answers.resolvedProfile, .local)
    }

    func testChangingAnEarlierGuidedAnswerClearsDependentAnswers() {
        var answers = BeadsSetupUseCaseAnswers(profile: .team)
        XCTAssertEqual(answers.resolvedProfile, .team)

        answers.selectCollaborationStyle(.alone)

        XCTAssertNil(answers.sharesTrackerWithTeam)
        XCTAssertNil(answers.syncsThroughGit)
        XCTAssertNil(answers.resolvedProfile)
    }

    func testChangingContributorRelationshipClearsTrackerChoice() {
        var answers = BeadsSetupUseCaseAnswers(profile: .contributor)
        XCTAssertEqual(answers.resolvedProfile, .contributor)

        answers.selectProjectRelationship(.ownProject)

        XCTAssertNil(answers.usesProjectSharedTracker)
        XCTAssertNil(answers.resolvedProfile)
    }

    func testGuidedAnswersRoundTripWithTheLocalSetupIntent() throws {
        var answers = BeadsSetupUseCaseAnswers()
        answers.selectProjectRelationship(.ownProject)
        answers.selectCollaborationStyle(.team)
        answers.selectTeamSharing(false)
        var draft = BeadsSetupDraft(profile: .local)
        draft.useCaseAnswers = answers

        let data = try JSONEncoder().encode(draft.intent)
        let decoded = try JSONDecoder().decode(BeadsSetupIntent.self, from: data)

        XCTAssertEqual(decoded.useCaseAnswers, answers)
        XCTAssertEqual(decoded.useCaseAnswers?.resolvedProfile, .local)
    }

    func testOlderContributorAnswersDecodeAndAskTheNewTrackerQuestion() throws {
        let data = try JSONEncoder().encode(BeadsSetupUseCaseAnswers(profile: .contributor))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "usesProjectSharedTracker")

        let olderData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(BeadsSetupUseCaseAnswers.self, from: olderData)

        XCTAssertEqual(decoded.projectRelationship, .contributing)
        XCTAssertNil(decoded.usesProjectSharedTracker)
        XCTAssertNil(decoded.resolvedProfile)
    }

    func testEmbeddedMetadataWithoutLocalDatabaseStillRequiresBootstrap() throws {
        let context = try BeadsProjectContext.decode(from: """
        {"backend":"dolt","dolt_mode":"embedded","beads_dir":".beads","role":"maintainer"}
        """)
        var candidate = assessment(initialized: false, bootstrapAction: "sync")
        candidate.environment = try BeadsProjectEnvironment(
            context: context,
            projectURL: candidate.projectURL
        )

        XCTAssertFalse(candidate.isInitialized)
        XCTAssertEqual(
            BeadsSetupPlanner.plan(draft: BeadsSetupDraft(profile: .team), assessment: candidate).steps.first?.operation,
            .bootstrap
        )
    }

    func testServerContextIsInitializedWithoutEmbeddedDatabase() throws {
        let context = try BeadsProjectContext.decode(from: """
        {"backend":"dolt","dolt_mode":"server","beads_dir":".beads","role":"maintainer"}
        """)
        var candidate = assessment(initialized: false)
        candidate.environment = try BeadsProjectEnvironment(
            context: context,
            projectURL: candidate.projectURL
        )

        XCTAssertTrue(candidate.isInitialized)
        var draft = BeadsSetupDraft(profile: .advanced)
        draft.installsHooks = false
        XCTAssertTrue(BeadsSetupPlanner.plan(draft: draft, assessment: candidate).canApply)
    }

    func testNewTeamSetupUsesGitOriginAndForcesAutomaticPushOff() {
        var draft = BeadsSetupDraft()
        let initialAssessment = assessment(
            gitOriginURL: "git@github.com:acme/app.git",
            gitOriginHasDoltData: false
        )
        draft.applyProfileDefaults(.team, assessment: initialAssessment)
        draft.completesRemoteSetup = true

        let plan = BeadsSetupPlanner.plan(
            draft: draft,
            assessment: initialAssessment
        )

        XCTAssertTrue(plan.canApply)
        XCTAssertTrue(plan.steps.contains { step in
            if case .initialize(role: "maintainer", options: _) = step.operation { return true }
            return false
        })
        XCTAssertTrue(plan.steps.contains { $0.operation == .addRemote(name: "origin", url: draft.remoteURL) })
        XCTAssertTrue(plan.steps.contains { step in
            step.operation == .setConfig(key: "dolt.auto-push", value: "false")
        })
        XCTAssertTrue(plan.steps.contains { $0.operation == .pushRemote })
        XCTAssertTrue(plan.steps.allSatisfy { $0.command.contains("--sandbox") })
    }

    func testNewSoloSetupClonesKnownRemoteHistoryAndCanOptIntoAutomaticPush() {
        var draft = BeadsSetupDraft(profile: .solo)
        draft.remoteName = "origin"
        draft.remoteURL = "https://example.com/acme/beads.git"
        draft.allowsAutomaticPush = true

        let plan = BeadsSetupPlanner.plan(
            draft: draft,
            assessment: assessment(
                candidateRemoteURL: draft.remoteURL,
                candidateRemoteHasDoltData: true
            )
        )

        XCTAssertTrue(plan.steps.contains { step in
            if case .initialize(role: "maintainer", let options) = step.operation {
                return options.remoteURL == draft.remoteURL
            }
            return false
        })
        XCTAssertFalse(plan.steps.contains { step in
            if case .addRemote = step.operation { return true }
            return false
        })
        XCTAssertTrue(plan.steps.contains { step in
            step.operation == .setConfig(key: "dolt.auto-push", value: "true")
        })
    }

    func testRemoteInitializationUsesRemoteTimeoutPolicy() {
        XCTAssertTrue(BeadsSetupOperation.initialize(
            role: "maintainer",
            options: BeadsInitOptions(remoteURL: "https://example.com/team.git")
        ).usesRemoteTimeout)
        XCTAssertFalse(BeadsSetupOperation.initialize(
            role: "maintainer",
            options: BeadsInitOptions()
        ).usesRemoteTimeout)
    }

    func testAuditReportsMissingIntendedRemoteWithoutWizardFieldValidation() {
        let intent = BeadsSetupIntent(
            profile: .team,
            remoteName: "origin",
            remoteURLFingerprint: BeadsSetupPlanner.configurationFingerprint("https://example.com/team.git"),
            installsHooks: false,
            allowsAutomaticPush: false,
            backupDestinationFingerprint: nil,
            recordedAt: Date()
        )
        let findings = BeadsSetupPlanner.audit(
            intent: intent,
            assessment: assessment(initialized: true, remotes: [])
        )

        XCTAssertTrue(findings.contains { $0.id == "intended-remote-changed" })
        XCTAssertFalse(findings.contains { $0.id == "missing-remote-url" })
        XCTAssertFalse(findings.contains { $0.id == "missing-remote-name" })
    }

    func testAuditUsesRemoteInspectionFindingWhenRemoteLoadFails() {
        let intent = BeadsSetupIntent(
            profile: .team,
            remoteName: "origin",
            remoteURLFingerprint: BeadsSetupPlanner.configurationFingerprint("https://example.com/team.git"),
            installsHooks: false,
            allowsAutomaticPush: false,
            backupDestinationFingerprint: nil,
            recordedAt: Date()
        )
        let findings = BeadsSetupPlanner.audit(
            intent: intent,
            assessment: assessment(initialized: true, remotes: nil)
        )

        XCTAssertTrue(findings.contains { $0.id == "remote-inspection-required" })
        XCTAssertFalse(findings.contains { $0.id == "intended-remote-changed" })
        XCTAssertFalse(findings.contains { $0.id == "missing-remote-url" })
    }

    func testAuditDoesNotReportConfigDriftWhenConfigInspectionFails() {
        let intent = BeadsSetupIntent(
            profile: .team,
            remoteName: nil,
            remoteURLFingerprint: nil,
            installsHooks: false,
            allowsAutomaticPush: false,
            backupDestinationFingerprint: nil,
            recordedAt: Date()
        )
        var candidate = assessment(initialized: true, config: nil)
        candidate.warnings = ["Could not read project configuration."]

        let findings = BeadsSetupPlanner.audit(intent: intent, assessment: candidate)

        XCTAssertTrue(findings.contains { $0.id == "inspection-warning-0" })
        XCTAssertFalse(findings.contains { $0.id == "pending-config-dolt.auto-push" })
    }

    func testPlannerBlocksConfigWriteWhenExistingConfigInspectionFails() {
        var draft = BeadsSetupDraft(profile: .team)
        draft.remoteURL = "https://example.com/team.git"
        draft.installsHooks = false
        let candidate = assessment(
            initialized: true,
            config: nil,
            remotes: [remote(name: "origin", url: draft.remoteURL)]
        )

        let plan = BeadsSetupPlanner.plan(draft: draft, assessment: candidate)

        XCTAssertTrue(plan.blockingFindings.contains { $0.id == "config-inspection-required" })
        XCTAssertFalse(plan.steps.contains { $0.id == "config-dolt.auto-push" })
    }

    func testNewEmptyRemoteIsAddedAfterLocalInitializationBeforeExplicitPush() {
        var draft = BeadsSetupDraft(profile: .team)
        draft.remoteURL = "git@github.com:acme/new-tracker.git"
        draft.completesRemoteSetup = true
        let candidate = assessment(
            candidateRemoteURL: draft.remoteURL,
            candidateRemoteHasDoltData: false
        )

        let plan = BeadsSetupPlanner.plan(draft: draft, assessment: candidate)

        XCTAssertTrue(plan.canApply)
        XCTAssertTrue(plan.steps.contains { step in
            if case .initialize(_, let options) = step.operation {
                return options.remoteURL.isEmpty
            }
            return false
        })
        XCTAssertTrue(plan.steps.contains {
            $0.operation == .addRemote(name: "origin", url: draft.remoteURL)
        })
        XCTAssertTrue(plan.steps.contains { $0.operation == .pushRemote })
    }

    func testExistingCustomRemoteWithDoltHistoryBlocksBeforeAddingIt() {
        var draft = BeadsSetupDraft(profile: .team)
        draft.remoteName = "shared"
        draft.remoteURL = "https://example.com/team/beads.git"

        let plan = BeadsSetupPlanner.plan(
            draft: draft,
            assessment: assessment(
                initialized: true,
                remotes: [],
                candidateRemoteURL: draft.remoteURL,
                candidateRemoteHasDoltData: true
            )
        )

        XCTAssertFalse(plan.canApply)
        XCTAssertTrue(plan.blockingFindings.contains { $0.id == "ambiguous-local-and-remote-history" })
    }

    func testExistingProjectDoesNotAddRemoteWhenRemoteInspectionFailed() {
        var draft = BeadsSetupDraft(profile: .team)
        draft.remoteURL = "https://example.com/team/beads.git"

        let plan = BeadsSetupPlanner.plan(
            draft: draft,
            assessment: assessment(initialized: true, remotes: nil)
        )

        XCTAssertFalse(plan.canApply)
        XCTAssertTrue(plan.blockingFindings.contains { $0.id == "remote-inspection-required" })
        XCTAssertFalse(plan.steps.contains { step in
            if case .addRemote = step.operation { return true }
            return false
        })
    }

    func testBootstrapInstallsHooksAfterJoining() {
        var draft = BeadsSetupDraft(profile: .team)
        draft.remoteURL = "https://example.com/team/beads.git"

        let plan = BeadsSetupPlanner.plan(
            draft: draft,
            assessment: assessment(
                bootstrapAction: "clone_git_remote",
                gitOriginURL: draft.remoteURL
            )
        )

        XCTAssertEqual(plan.steps.first?.operation, .bootstrap)
        XCTAssertFalse(plan.steps.contains { step in
            if case .addRemote = step.operation { return true }
            return false
        })
        XCTAssertTrue(plan.steps.contains { $0.operation == .installHooks })
    }

    func testBackupSetupIsExplicitAndDoesNotReplaceExistingDestination() {
        var draft = BeadsSetupDraft(profile: .advanced)
        draft.backupDestination = "/Volumes/Backup/beads"
        draft.syncsBackupAfterSetup = true

        let plan = BeadsSetupPlanner.plan(
            draft: draft,
            assessment: assessment(
                initialized: true,
                backup: BeadsBackupStatus(
                    backup: nil,
                    databaseSize: nil,
                    dolt: .init(configured: false)
                )
            )
        )

        XCTAssertTrue(plan.steps.contains {
            $0.operation == .initializeBackup(destination: draft.backupDestination)
        })
        XCTAssertTrue(plan.steps.contains { $0.operation == .syncBackup })
    }

    func testConfiguredBackupCanSyncWhenInspectionOmitsItsURL() {
        var draft = BeadsSetupDraft(profile: .advanced)
        draft.syncsBackupAfterSetup = true

        let plan = BeadsSetupPlanner.plan(
            draft: draft,
            assessment: assessment(
                initialized: true,
                backup: BeadsBackupStatus(
                    backup: nil,
                    databaseSize: nil,
                    dolt: .init(configured: true)
                )
            )
        )

        XCTAssertTrue(plan.steps.contains { $0.operation == .syncBackup })
        XCTAssertFalse(plan.steps.contains {
            if case .initializeBackup = $0.operation { return true }
            return false
        })
    }

    func testPersistedIntentContainsFingerprintsInsteadOfRemoteSecrets() throws {
        var draft = BeadsSetupDraft(profile: .solo)
        draft.remoteURL = "https://secret-token@example.com/team/beads.git"
        draft.backupDestination = "https://backup-token@example.com/backups/beads"

        let data = try JSONEncoder().encode(draft.intent)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(encoded.contains("secret-token"))
        XCTAssertFalse(encoded.contains("backup-token"))
        XCTAssertNotNil(draft.intent.remoteURLFingerprint)
        XCTAssertNotNil(draft.intent.backupDestinationFingerprint)
    }

    func testContributorIntentDoesNotTreatGitUpstreamAsDoltRemoteIntent() {
        var draft = BeadsSetupDraft(profile: .contributor)
        draft.remoteName = "upstream"
        draft.remoteURL = "git@github.com:acme/upstream.git"

        XCTAssertNil(draft.intent.remoteName)
        XCTAssertNil(draft.intent.remoteURLFingerprint)
    }

    func testTeamProfileIgnoresAutomaticPushDraftValue() {
        var draft = BeadsSetupDraft(profile: .team)
        draft.remoteURL = "https://example.com/acme/beads.git"
        draft.allowsAutomaticPush = true

        let plan = BeadsSetupPlanner.plan(draft: draft, assessment: assessment())

        XCTAssertTrue(plan.steps.contains { step in
            step.operation == .setConfig(key: "dolt.auto-push", value: "false")
        })
        XCTAssertFalse(plan.steps.contains { step in
            step.operation == .setConfig(key: "dolt.auto-push", value: "true")
        })
    }

    func testExistingRemoteNameConflictBlocksReplacement() {
        var draft = BeadsSetupDraft(profile: .team)
        draft.remoteURL = "https://example.com/new.git"

        let plan = BeadsSetupPlanner.plan(
            draft: draft,
            assessment: assessment(
                initialized: true,
                remotes: [remote(name: "origin", url: "https://example.com/old.git")]
            )
        )

        XCTAssertFalse(plan.canApply)
        XCTAssertTrue(plan.blockingFindings.contains { $0.id == "remote-url-conflict" })
    }

    func testExistingLocalAndRemoteHistoriesBlockAutomaticReconciliation() {
        var draft = BeadsSetupDraft(profile: .team)
        draft.remoteURL = "https://github.com/acme/app.git"

        let plan = BeadsSetupPlanner.plan(
            draft: draft,
            assessment: assessment(
                initialized: true,
                gitOriginURL: draft.remoteURL,
                gitOriginHasDoltData: true
            )
        )

        XCTAssertFalse(plan.canApply)
        XCTAssertTrue(plan.blockingFindings.contains { $0.id == "ambiguous-local-and-remote-history" })
    }

    func testExistingMaintainerProjectBlocksContributorRoutingMigration() {
        var draft = BeadsSetupDraft(profile: .contributor)
        draft.remoteURL = ""

        let plan = BeadsSetupPlanner.plan(
            draft: draft,
            assessment: assessment(
                initialized: true,
                config: [BeadsSetupConfigEntry(key: "beads.role", value: "maintainer", source: "config.yaml")]
            )
        )

        XCTAssertFalse(plan.canApply)
        XCTAssertTrue(plan.blockingFindings.contains { $0.id == "contributor-routing-transition" })
    }

    func testCleanTeamIntentProducesNoAuditFindings() {
        let intent = BeadsSetupIntent(
            profile: .team,
            remoteName: "origin",
            remoteURLFingerprint: BeadsSetupPlanner.configurationFingerprint("https://example.com/beads.git"),
            installsHooks: true,
            allowsAutomaticPush: false,
            backupDestinationFingerprint: nil,
            recordedAt: Date()
        )
        let assessment = assessment(
            initialized: true,
            config: [BeadsSetupConfigEntry(key: "dolt.auto-push", value: "false", source: "config.yaml")],
            remotes: [remote(name: "origin", url: "https://example.com/beads.git")],
            hooks: BeadsHooksStatus.parse(from: "✓ pre-commit: installed")
        )

        XCTAssertTrue(BeadsSetupPlanner.audit(intent: intent, assessment: assessment).isEmpty)
    }

    func testFindingFingerprintIsOrderIndependentAndChangesWithDetails() {
        let first = BeadsSetupFinding(id: "a", severity: .warning, title: "A", detail: "One")
        let second = BeadsSetupFinding(id: "b", severity: .blocking, title: "B", detail: "Two")

        XCTAssertEqual(
            BeadsSetupPlanner.findingsFingerprint([first, second]),
            BeadsSetupPlanner.findingsFingerprint([second, first])
        )
        XCTAssertNotEqual(
            BeadsSetupPlanner.findingsFingerprint([first]),
            BeadsSetupPlanner.findingsFingerprint([
                BeadsSetupFinding(id: "a", severity: .warning, title: "A", detail: "Changed")
            ])
        )
    }

    private func assessment(
        initialized: Bool = false,
        bootstrapAction: String = "none",
        config: [BeadsSetupConfigEntry]? = [],
        remotes: [BeadsDoltRemote]? = nil,
        hooks: BeadsHooksStatus? = nil,
        backup: BeadsBackupStatus? = nil,
        gitOriginURL: String? = nil,
        gitOriginHasDoltData: Bool? = nil,
        candidateRemoteURL: String? = nil,
        candidateRemoteHasDoltData: Bool? = nil
    ) -> BeadsSetupAssessment {
        BeadsSetupAssessment(
            projectURL: URL(fileURLWithPath: "/tmp/beads-setup-tests"),
            inspectedAt: Date(),
            bootstrap: BeadsSetupBootstrapPreview(
                action: bootstrapAction,
                beadsDirectory: nil,
                database: nil,
                hasExisting: initialized,
                reason: nil,
                suggestion: nil
            ),
            environment: nil,
            config: config.map(ProjectHealthValue.available)
                ?? .unavailable("Project configuration could not be inspected."),
            remotes: remotes.map(BeadsDoltRemotes.init(remotes:)),
            hooks: hooks,
            backup: backup,
            gitOriginURL: gitOriginURL,
            gitUpstreamURL: nil,
            gitOriginHasDoltData: gitOriginHasDoltData,
            gitUpstreamHasDoltData: nil,
            candidateRemoteURL: candidateRemoteURL,
            candidateRemoteHasDoltData: candidateRemoteHasDoltData,
            warnings: []
        )
    }

    private func remote(name: String, url: String) -> BeadsDoltRemote {
        BeadsDoltRemote(name: name, url: url, sqlURL: nil, status: nil)
    }
}

final class BeadsSetupPreferenceRepositoryTests: XCTestCase {
    func testIntentAndDismissalAreScopedToProjectAndSavingIntentClearsDismissal() {
        let defaults = makeIsolatedUserDefaults()
        let repository = BeadsSetupPreferenceRepository(userDefaults: defaults)
        let projectA = URL(fileURLWithPath: "/tmp/project-a")
        let projectB = URL(fileURLWithPath: "/tmp/project-b")
        let intent = BeadsSetupIntent(
            profile: .local,
            remoteName: nil,
            remoteURLFingerprint: nil,
            installsHooks: false,
            allowsAutomaticPush: false,
            backupDestinationFingerprint: nil,
            recordedAt: Date(timeIntervalSince1970: 100)
        )

        repository.saveDismissedFingerprint("old", projectURL: projectA)
        repository.saveIntent(intent, projectURL: projectA)

        XCTAssertEqual(repository.loadIntent(projectURL: projectA), intent)
        XCTAssertNil(repository.loadIntent(projectURL: projectB))
        XCTAssertNil(repository.dismissedFingerprint(projectURL: projectA))

        repository.saveDismissedFingerprint("finding", projectURL: projectA)
        XCTAssertEqual(repository.dismissedFingerprint(projectURL: projectA), "finding")
        XCTAssertNil(repository.dismissedFingerprint(projectURL: projectB))
    }

    func testSetupPreferenceKeysDoNotExposeProjectPaths() {
        let projectURL = URL(fileURLWithPath: "/Users/example/Secret Client/project")

        let intentKey = BeadazzlePreferenceKeys.beadsSetupIntent(projectURL: projectURL)
        let dismissalKey = BeadazzlePreferenceKeys.beadsSetupDismissedFingerprint(projectURL: projectURL)

        XCTAssertFalse(intentKey.contains(projectURL.path))
        XCTAssertFalse(dismissalKey.contains(projectURL.path))
    }

    func testLoadIntentRejectsUnsupportedVersion() throws {
        let defaults = makeIsolatedUserDefaults()
        let repository = BeadsSetupPreferenceRepository(userDefaults: defaults)
        let projectURL = URL(fileURLWithPath: "/tmp/future-setup")
        var intent = BeadsSetupIntent(
            profile: .local,
            remoteName: nil,
            remoteURLFingerprint: nil,
            installsHooks: false,
            allowsAutomaticPush: false,
            backupDestinationFingerprint: nil,
            recordedAt: Date()
        )
        intent.version = BeadsSetupIntent.currentVersion + 1
        defaults.set(
            try JSONEncoder().encode(intent),
            forKey: BeadazzlePreferenceKeys.beadsSetupIntent(projectURL: projectURL)
        )

        XCTAssertNil(repository.loadIntent(projectURL: projectURL))
    }

}
