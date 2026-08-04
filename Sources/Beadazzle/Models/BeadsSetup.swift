import Foundation

enum BeadsSetupProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case local
    case solo
    case team
    case contributor
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .local: "Private / Local"
        case .solo: "Solo Synced"
        case .team: "Team Shared"
        case .contributor: "Contributor Planning"
        case .advanced: "Advanced / Existing"
        }
    }

    var detail: String {
        switch self {
        case .local:
            "Keep the tracker on this Mac without a Dolt remote."
        case .solo:
            "Use a Dolt remote as a backup or to move between your own Macs."
        case .team:
            "Share the tracker through a Dolt remote with explicit pull and push."
        case .contributor:
            "Keep planning data outside the maintainer tracker and follow contributor routing."
        case .advanced:
            "Audit the current setup and make only explicitly selected safe changes."
        }
    }

    var systemImage: String {
        switch self {
        case .local: "internaldrive"
        case .solo: "person.crop.circle.badge.checkmark"
        case .team: "person.2"
        case .contributor: "arrow.triangle.branch"
        case .advanced: "slider.horizontal.3"
        }
    }
}

enum BeadsSetupProjectRelationship: Codable, Equatable, Sendable {
    case ownProject
    case contributing
}

enum BeadsSetupCollaborationStyle: Codable, Equatable, Sendable {
    case alone
    case team
}

struct BeadsSetupUseCaseAnswers: Codable, Equatable, Sendable {
    var projectRelationship: BeadsSetupProjectRelationship?
    var usesProjectSharedTracker: Bool?
    var collaborationStyle: BeadsSetupCollaborationStyle?
    var sharesTrackerWithTeam: Bool?
    var syncsThroughGit: Bool?
    var usesAdvancedSetup = false

    init(profile: BeadsSetupProfile? = nil) {
        guard let profile else { return }
        switch profile {
        case .local:
            projectRelationship = .ownProject
            collaborationStyle = .alone
            syncsThroughGit = false
        case .solo:
            projectRelationship = .ownProject
            collaborationStyle = .alone
            syncsThroughGit = true
        case .team:
            projectRelationship = .ownProject
            collaborationStyle = .team
            sharesTrackerWithTeam = true
        case .contributor:
            projectRelationship = .contributing
            usesProjectSharedTracker = false
        case .advanced:
            usesAdvancedSetup = true
        }
    }

    var resolvedProfile: BeadsSetupProfile? {
        if usesAdvancedSetup { return .advanced }
        switch projectRelationship {
        case .contributing:
            guard let usesProjectSharedTracker else { return nil }
            return usesProjectSharedTracker ? .team : .contributor
        case .ownProject:
            guard let collaborationStyle else { return nil }
            if collaborationStyle == .team {
                guard let sharesTrackerWithTeam else { return nil }
                return sharesTrackerWithTeam ? .team : .local
            }
            guard let syncsThroughGit else { return nil }
            return syncsThroughGit ? .solo : .local
        case nil:
            return nil
        }
    }

    mutating func selectProjectRelationship(_ relationship: BeadsSetupProjectRelationship) {
        projectRelationship = relationship
        usesProjectSharedTracker = nil
        collaborationStyle = nil
        sharesTrackerWithTeam = nil
        syncsThroughGit = nil
        usesAdvancedSetup = false
    }

    mutating func selectProjectTrackerSharing(_ usesSharedTracker: Bool) {
        usesProjectSharedTracker = usesSharedTracker
        collaborationStyle = nil
        sharesTrackerWithTeam = nil
        syncsThroughGit = nil
        usesAdvancedSetup = false
    }

    mutating func selectCollaborationStyle(_ style: BeadsSetupCollaborationStyle) {
        collaborationStyle = style
        sharesTrackerWithTeam = nil
        syncsThroughGit = nil
        usesAdvancedSetup = false
    }

    mutating func selectTeamSharing(_ sharesTracker: Bool) {
        sharesTrackerWithTeam = sharesTracker
        syncsThroughGit = nil
        usesAdvancedSetup = false
    }

    mutating func selectGitSync(_ syncsThroughGit: Bool) {
        self.syncsThroughGit = syncsThroughGit
        usesAdvancedSetup = false
    }

    mutating func selectAdvancedSetup() {
        projectRelationship = nil
        usesProjectSharedTracker = nil
        collaborationStyle = nil
        sharesTrackerWithTeam = nil
        syncsThroughGit = nil
        usesAdvancedSetup = true
    }
}

struct BeadsSetupIntent: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var profile: BeadsSetupProfile
    var useCaseAnswers: BeadsSetupUseCaseAnswers? = nil
    var remoteName: String?
    var remoteURLFingerprint: String?
    var installsHooks: Bool
    var allowsAutomaticPush: Bool
    var backupDestinationFingerprint: String?
    var recordedAt: Date
}

struct BeadsSetupDraft: Equatable, Sendable {
    var profile: BeadsSetupProfile = .team
    var prefix = ""
    var usesStealthMode = false
    var skipsAgents = false
    var installsHooks = true
    var remoteName = "origin"
    var remoteURL = ""
    var completesRemoteSetup = false
    var allowsAutomaticPush = false
    var backupDestination = ""
    var syncsBackupAfterSetup = false
    var useCaseAnswers: BeadsSetupUseCaseAnswers?

    mutating func applyProfileDefaults(_ profile: BeadsSetupProfile, assessment: BeadsSetupAssessment?) {
        self.profile = profile
        switch profile {
        case .local:
            remoteURL = ""
            completesRemoteSetup = false
            allowsAutomaticPush = false
        case .solo:
            remoteName = assessment?.remotes?.primaryRemote?.name ?? remoteName
            remoteURL = assessment?.suggestedRemoteURL ?? remoteURL
        case .team:
            remoteName = assessment?.remotes?.primaryRemote?.name ?? remoteName
            remoteURL = assessment?.suggestedRemoteURL ?? remoteURL
            allowsAutomaticPush = false
        case .contributor:
            remoteName = "upstream"
            remoteURL = assessment?.gitUpstreamURL ?? assessment?.suggestedRemoteURL ?? remoteURL
            completesRemoteSetup = false
            allowsAutomaticPush = false
        case .advanced:
            break
        }
    }

    var intent: BeadsSetupIntent {
        let recordsDoltRemote = profile == .solo || profile == .team
        return BeadsSetupIntent(
            profile: profile,
            useCaseAnswers: useCaseAnswers,
            remoteName: recordsDoltRemote ? remoteName.nilIfBlank : nil,
            remoteURLFingerprint: recordsDoltRemote
                ? remoteURL.nilIfBlank.map(BeadsSetupPlanner.configurationFingerprint)
                : nil,
            installsHooks: installsHooks && !usesStealthMode,
            allowsAutomaticPush: profile == .solo && allowsAutomaticPush,
            backupDestinationFingerprint: backupDestination.nilIfBlank.map(BeadsSetupPlanner.configurationFingerprint),
            recordedAt: Date()
        )
    }
}

struct BeadsSetupConfigEntry: Codable, Equatable, Sendable {
    var key: String
    var value: String
    var source: String
}

struct BeadsSetupBootstrapPreview: Codable, Equatable, Sendable {
    var action: String?
    var beadsDirectory: String?
    var database: String?
    var hasExisting: Bool?
    var reason: String?
    var suggestion: String?

    enum CodingKeys: String, CodingKey {
        case action
        case beadsDirectory = "beads_dir"
        case database
        case hasExisting = "has_existing"
        case reason
        case suggestion
    }

    var recommendsBootstrap: Bool {
        guard let action = action?.lowercased() else { return false }
        return action != "none" && action != "init"
    }
}

struct BeadsSetupAssessment: Equatable, Sendable {
    var projectURL: URL
    var inspectedAt: Date
    var bootstrap: BeadsSetupBootstrapPreview
    var environment: BeadsProjectEnvironment?
    var localDatabaseReadability: ProjectHealthValue<Bool> = .available(false)
    var config: ProjectHealthValue<[BeadsSetupConfigEntry]>
    var remotes: BeadsDoltRemotes?
    var hooks: BeadsHooksStatus?
    var backup: BeadsBackupStatus?
    var configurationInspection: BeadsProjectConfigurationInspection? = nil
    var gitOriginURL: String?
    var gitUpstreamURL: String?
    var gitOriginHasDoltData: Bool? = nil
    var gitUpstreamHasDoltData: Bool? = nil
    var candidateRemoteURL: String? = nil
    var candidateRemoteHasDoltData: Bool? = nil
    var warnings: [String]

    var isInitialized: Bool {
        if let environment, environment.storageMode != .embedded {
            return true
        }
        return localDatabaseReadability.value == true || bootstrap.hasExisting == true
    }

    var suggestedRemoteURL: String? {
        remotes?.primaryRemote?.url ?? gitOriginURL ?? gitUpstreamURL
    }

    func effectiveConfigValue(_ key: String) -> String? {
        config.value?.last(where: { $0.key == key && $0.source != "default" })?.value
            ?? config.value?.last(where: { $0.key == key })?.value
    }

    func effectiveBoolConfigValue(_ key: String) -> Bool? {
        guard let value = effectiveConfigValue(key)?.lowercased() else { return nil }
        return switch value {
        case "true", "yes", "1", "on": true
        case "false", "no", "0", "off": false
        default: nil
        }
    }
}

enum BeadsSetupFindingSeverity: Int, Codable, Comparable, Sendable {
    case information
    case warning
    case blocking

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct BeadsSetupFinding: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var severity: BeadsSetupFindingSeverity
    var title: String
    var detail: String

    var isActionable: Bool { severity >= .warning }
}

enum BeadsSetupChangeScope: String, Codable, Sendable {
    case beadazzleOnly
    case checkoutLocal
    case gitTracked
    case remoteOperation

    var title: String {
        switch self {
        case .beadazzleOnly: "Beadazzle only"
        case .checkoutLocal: "This checkout"
        case .gitTracked: "Git-tracked configuration"
        case .remoteOperation: "Remote operation"
        }
    }
}

enum BeadsSetupOperation: Equatable, Sendable {
    case bootstrap
    case initialize(role: String, options: BeadsInitOptions)
    case setConfig(key: String, value: String)
    case addRemote(name: String, url: String)
    case installHooks
    case uninstallHooks
    case initializeBackup(destination: String)
    case syncBackup
    case pushRemote

    var arguments: [String] {
        switch self {
        case .bootstrap:
            ["--sandbox", "bootstrap", "--yes"]
        case .initialize(let role, let options):
            ["--sandbox", "init", "--non-interactive", "--role", role]
                + BeadsCommandArguments.initializeOptionArguments(options: options)
        case .setConfig(let key, let value):
            ["--sandbox", "config", "set", key, value]
        case .addRemote(let name, let url):
            ["--sandbox", "dolt", "remote", "add", name, url]
        case .installHooks:
            ["--sandbox", "hooks", "install"]
        case .uninstallHooks:
            ["--sandbox", "hooks", "uninstall"]
        case .initializeBackup(let destination):
            ["--sandbox", "backup", "init", destination]
        case .syncBackup:
            ["--sandbox", "backup", "sync"]
        case .pushRemote:
            ["--sandbox", "dolt", "push"]
        }
    }

    var usesRemoteTimeout: Bool {
        switch self {
        case .bootstrap, .syncBackup, .pushRemote:
            true
        case .initialize(_, let options):
            options.remoteURL.nilIfBlank != nil
        case .setConfig, .addRemote, .installHooks, .uninstallHooks, .initializeBackup:
            false
        }
    }
}

struct BeadsSetupStep: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var detail: String
    var scopes: [BeadsSetupChangeScope]
    var operation: BeadsSetupOperation

    var command: String {
        ShellCommand.render(executable: "bd", arguments: operation.arguments)
    }
}

struct BeadsSetupPlan: Equatable, Sendable {
    var profile: BeadsSetupProfile
    var findings: [BeadsSetupFinding]
    var steps: [BeadsSetupStep]

    var blockingFindings: [BeadsSetupFinding] {
        findings.filter { $0.severity == .blocking }
    }

    var canApply: Bool { blockingFindings.isEmpty }
}

struct BeadsSetupApplyReport: Equatable, Sendable {
    var completedStepIDs: [String]
}

enum BeadsSetupApplyEvent: Equatable, Sendable {
    case validating
    case stepStarted(String)
    case stepCompleted(String)
    case stepFailed(String)
    case reloadingProject
    case recoveringProject
    case savingIntent
    case finished
}

typealias BeadsSetupApplyProgressHandler = @Sendable (BeadsSetupApplyEvent) async -> Void

enum BeadsSetupReviewItemStatus: Equatable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
}

struct BeadsSetupApplyProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case validating
        case applying
        case reloadingProject
        case recoveringProject
        case savingIntent
        case finished
        case failed
    }

    private(set) var phase = Phase.idle
    private(set) var activeStepID: String?
    private(set) var completedStepIDs: Set<String> = []
    private(set) var failedStepID: String?

    mutating func record(_ event: BeadsSetupApplyEvent) {
        switch event {
        case .validating:
            phase = .validating
            activeStepID = nil
            completedStepIDs = []
            failedStepID = nil
        case .stepStarted(let stepID):
            phase = .applying
            activeStepID = stepID
        case .stepCompleted(let stepID):
            completedStepIDs.insert(stepID)
            if activeStepID == stepID {
                activeStepID = nil
            }
        case .stepFailed(let stepID):
            phase = .failed
            failedStepID = stepID
            activeStepID = nil
        case .reloadingProject:
            phase = .reloadingProject
            activeStepID = nil
        case .recoveringProject:
            phase = .recoveringProject
            activeStepID = nil
        case .savingIntent:
            phase = .savingIntent
            activeStepID = nil
        case .finished:
            phase = .finished
            activeStepID = nil
        }
    }

    mutating func recordFailure() {
        if failedStepID == nil {
            failedStepID = activeStepID
        }
        activeStepID = nil
        phase = .failed
    }

    func status(forStepID stepID: String) -> BeadsSetupReviewItemStatus {
        if failedStepID == stepID { return .failed }
        if completedStepIDs.contains(stepID) { return .completed }
        if activeStepID == stepID { return .inProgress }
        return .pending
    }

    var localIntentStatus: BeadsSetupReviewItemStatus {
        switch phase {
        case .savingIntent:
            return .inProgress
        case .finished:
            return .completed
        default:
            return .pending
        }
    }

    var phaseMessage: String? {
        switch phase {
        case .validating:
            return "Checking that the reviewed setup is still current…"
        case .reloadingProject:
            return "Commands finished. Exporting and reloading the project…"
        case .recoveringProject:
            return "Setup stopped. Reloading any readable project data…"
        default:
            return nil
        }
    }

    var scrollTargetID: String? {
        if let activeStepID { return activeStepID }
        if let failedStepID { return failedStepID }
        switch phase {
        case .validating, .reloadingProject, .recoveringProject:
            return "setup-progress-phase"
        case .savingIntent:
            return "setup-local-intent"
        case .failed:
            return "setup-failure"
        default:
            return nil
        }
    }
}

struct BeadsSetupApplyFailure: LocalizedError {
    var report: BeadsSetupApplyReport
    var failedStepTitle: String
    var underlyingError: Error

    var errorDescription: String? {
        let completed = report.completedStepIDs.count
        let prefix = completed == 0
            ? "No setup changes completed."
            : "\(completed) setup change\(completed == 1 ? "" : "s") completed before setup stopped."
        return "\(prefix) \(failedStepTitle) failed: \(underlyingError.localizedDescription)"
    }
}

struct BeadsSetupFailurePresentation: Equatable, Sendable {
    var title: String
    var message: String
    var command: String?
    var output: String?

    static func inspection(_ error: Error) -> BeadsSetupFailurePresentation {
        let details = commandDetails(from: error)
        return BeadsSetupFailurePresentation(
            title: "Couldn't inspect Beads setup",
            message: details == nil
                ? error.localizedDescription
                : "The Beads command failed while inspecting this project.",
            command: details?.command,
            output: details?.output
        )
    }

    static func applying(_ error: Error) -> BeadsSetupFailurePresentation {
        guard let failure = error as? BeadsSetupApplyFailure else {
            let details = commandDetails(from: error)
            return BeadsSetupFailurePresentation(
                title: "Couldn't apply Beads setup",
                message: details == nil ? error.localizedDescription : "The Beads command failed.",
                command: details?.command,
                output: details?.output
            )
        }

        let completed = failure.report.completedStepIDs.count
        let progress = completed == 0
            ? "No setup changes completed."
            : "\(completed) earlier setup change\(completed == 1 ? "" : "s") completed and \(completed == 1 ? "was" : "were") kept."
        let details = commandDetails(from: failure.underlyingError)
        let underlyingMessage = details == nil ? " \(failure.underlyingError.localizedDescription)" : ""
        return BeadsSetupFailurePresentation(
            title: "Couldn't apply Beads setup",
            message: "Setup stopped while trying to \(failure.failedStepTitle.lowercased()). \(progress)\(underlyingMessage)",
            command: details?.command,
            output: details?.output
        )
    }

    private static func commandDetails(from error: Error) -> (command: String, output: String)? {
        guard case let BeadError.commandFailed(command, output) = error else { return nil }
        return (command, output)
    }
}

enum BeadsSetupPlanner {
    static func plan(draft: BeadsSetupDraft, assessment: BeadsSetupAssessment) -> BeadsSetupPlan {
        var findings = assessment.warnings.enumerated().map { index, warning in
            BeadsSetupFinding(
                id: "inspection-warning-\(index)",
                severity: .warning,
                title: "Inspection was incomplete",
                detail: warning
            )
        }
        var steps: [BeadsSetupStep] = []
        let usesBootstrap = !assessment.isInitialized && assessment.bootstrap.recommendsBootstrap
        let wantsHooks = draft.installsHooks && !draft.usesStealthMode
        let wantsRemote = draft.profile == .solo || draft.profile == .team
        let requestedRemoteURL = wantsRemote ? draft.remoteURL.nilIfBlank : nil
        let candidateHasDoltData = requestedRemoteHasDoltData(
            draft: draft,
            assessment: assessment
        )
        let bootstrapHandlesRemote = usesBootstrap && assessment.suggestedRemoteURL != nil
        let initializesFromRemote = !assessment.isInitialized
            && !usesBootstrap
            && requestedRemoteURL != nil
            && (candidateHasDoltData == true || (candidateHasDoltData == nil && !draft.completesRemoteSetup))
        let joinsSomeoneElsesSharedTracker = draft.useCaseAnswers?.projectRelationship == .contributing
            && draft.useCaseAnswers?.usesProjectSharedTracker == true

        let storageMode = assessment.environment?.storageMode
        if storageMode == .embedded,
           !assessment.isInitialized,
           assessment.localDatabaseReadability.value == nil {
            findings.append(BeadsSetupFinding(
                id: "local-database-inspection-required",
                severity: .blocking,
                title: "The local task database could not be inspected",
                detail: "Check the project again before joining or creating a tracker. Beadazzle will not overwrite an embedded database whose state is unknown."
            ))
        }
        if let storageMode, storageMode != .embedded {
            findings.append(BeadsSetupFinding(
                id: "server-mode-audit-only",
                severity: draft.profile == .advanced ? .information : .blocking,
                title: "Server storage is audit-only",
                detail: "The wizard can inspect server and shared-server projects, but it does not create or migrate them."
            ))
        }

        if !assessment.isInitialized {
            if assessment.bootstrap.recommendsBootstrap {
                steps.append(BeadsSetupStep(
                    id: "bootstrap",
                    title: "Join the existing tracker",
                    detail: "Bootstrap the Dolt database advertised by this Git checkout.",
                    scopes: [.checkoutLocal, .remoteOperation],
                    operation: .bootstrap
                ))
            } else {
                let joinsAsContributor = draft.profile == .contributor
                    || draft.useCaseAnswers?.projectRelationship == .contributing
                let role = joinsAsContributor ? "contributor" : "maintainer"
                let options = BeadsInitOptions(
                    prefix: draft.prefix,
                    usesStealthMode: draft.usesStealthMode,
                    skipsAgents: draft.skipsAgents,
                    skipsHooks: !wantsHooks,
                    remoteURL: initializesFromRemote ? draft.remoteURL : ""
                )
                steps.append(BeadsSetupStep(
                    id: "initialize",
                    title: "Initialize Beads",
                    detail: "Create a current Dolt-backed tracker for this checkout.",
                    scopes: wantsRemote && options.remoteURL.nilIfBlank != nil
                        ? [.checkoutLocal, .gitTracked, .remoteOperation]
                        : [.checkoutLocal, .gitTracked],
                    operation: .initialize(role: role, options: options)
                ))
            }
        }

        if draft.profile == .contributor, assessment.isInitialized {
            let role = assessment.effectiveConfigValue("beads.role")
            if role != "contributor" {
                findings.append(BeadsSetupFinding(
                    id: "contributor-routing-transition",
                    severity: .blocking,
                    title: "Contributor routing needs a reviewed migration",
                    detail: "This tracker is already initialized as \(role ?? "a maintainer workspace"). The wizard will not relocate planning data or rewrite routing automatically."
                ))
            }
        }
        if draft.profile == .contributor,
           !assessment.isInitialized,
           assessment.gitUpstreamURL == nil {
            findings.append(BeadsSetupFinding(
                id: "contributor-upstream-required",
                severity: .blocking,
                title: "A Git upstream remote is required",
                detail: "Add the maintainer repository as the Git upstream remote so bd can establish contributor routing without guessing a destination."
            ))
        }
        if joinsSomeoneElsesSharedTracker,
           !assessment.isInitialized,
           !usesBootstrap,
           candidateHasDoltData == false {
            findings.append(BeadsSetupFinding(
                id: "contributor-shared-tracker-missing",
                severity: .blocking,
                title: "No shared task database was found",
                detail: "This remote does not advertise the project’s Dolt task data. Ask a maintainer for the project’s Beads remote instead of creating a new shared tracker from this checkout."
            ))
        }
        if joinsSomeoneElsesSharedTracker, draft.completesRemoteSetup {
            findings.append(BeadsSetupFinding(
                id: "contributor-shared-tracker-publish",
                severity: .blocking,
                title: "Joining cannot publish a new tracker",
                detail: "A contributor joining the project tracker must clone or bootstrap its existing task history. Publishing a new database requires the project maintainer setup."
            ))
        }

        if draft.profile == .local, let remotes = assessment.remotes, !remotes.remotes.isEmpty {
            findings.append(BeadsSetupFinding(
                id: "local-existing-remotes",
                severity: .information,
                title: "Existing Dolt remote will be preserved",
                detail: "Local mode does not remove configured remotes. Remove one explicitly in the CLI if it is no longer wanted."
            ))
        }

        if wantsRemote, draft.remoteName.nilIfBlank == nil {
            findings.append(BeadsSetupFinding(
                id: "missing-remote-name",
                severity: .blocking,
                title: "A remote name is required",
                detail: "Enter the Dolt remote name used by this checkout."
            ))
        }
        if initializesFromRemote, draft.remoteName != "origin" {
            findings.append(BeadsSetupFinding(
                id: "initial-remote-name",
                severity: .blocking,
                title: "New checkouts clone into origin",
                detail: "bd init --remote creates the initial remote as origin. Use origin here, then add another remote after setup if needed."
            ))
        }
        if usesBootstrap,
           wantsRemote,
           let requestedRemoteURL,
           let suggestedRemoteURL = assessment.suggestedRemoteURL,
           normalizedRemote(requestedRemoteURL) != normalizedRemote(suggestedRemoteURL) {
            findings.append(BeadsSetupFinding(
                id: "bootstrap-remote-conflict",
                severity: .blocking,
                title: "This checkout already advertises a tracker",
                detail: "Bootstrap must join the tracker advertised by this checkout. Complete that setup before configuring a different Dolt remote."
            ))
        }

        if wantsRemote, let requestedURL = requestedRemoteURL {
            if assessment.isInitialized, assessment.remotes == nil {
                findings.append(BeadsSetupFinding(
                    id: "remote-inspection-required",
                    severity: .blocking,
                    title: "Dolt remotes could not be inspected",
                    detail: "Review the remote status again before adding or publishing to a destination."
                ))
            } else if let remotes = assessment.remotes,
                      let existing = remotes.remotes.first(where: { $0.name == draft.remoteName }) {
                if normalizedRemote(existing.url) != normalizedRemote(requestedURL) {
                    findings.append(BeadsSetupFinding(
                        id: "remote-url-conflict",
                        severity: .blocking,
                        title: "Remote name already points somewhere else",
                        detail: "\(draft.remoteName) currently points to \(existing.url). The wizard will not replace it or reconcile two histories automatically."
                    ))
                }
            } else if assessment.isInitialized || (!bootstrapHandlesRemote && !initializesFromRemote) {
                steps.append(BeadsSetupStep(
                    id: "add-remote",
                    title: "Add Dolt remote",
                    detail: "Configure \(draft.remoteName) for database synchronization.",
                    scopes: [.checkoutLocal],
                    operation: .addRemote(name: draft.remoteName, url: requestedURL)
                ))
            }
        } else if wantsRemote {
            findings.append(BeadsSetupFinding(
                id: "missing-remote-url",
                severity: .blocking,
                title: "A remote URL is required",
                detail: "Choose the Git origin suggestion or enter the Dolt remote URL your team uses."
            ))
        }

        let createsLocalHistoryBeforeAddingRemote = assessment.isInitialized
            || (!bootstrapHandlesRemote && !initializesFromRemote)
        if createsLocalHistoryBeforeAddingRemote,
           wantsRemote,
           assessment.remotes?.remotes.isEmpty != false,
           candidateHasDoltData == true {
            findings.append(BeadsSetupFinding(
                id: "ambiguous-local-and-remote-history",
                severity: .blocking,
                title: "Local and remote Dolt histories both exist",
                detail: "The wizard will not decide which history wins. Pull, clone, or publish from the CLI after reviewing the two databases."
            ))
        }
        let isAddingRemote = assessment.remotes?.remotes.contains {
            $0.name == draft.remoteName
        } != true
        if wantsRemote,
           isAddingRemote,
           draft.completesRemoteSetup,
           normalizedRemote(draft.remoteURL) == normalizedRemote(assessment.candidateRemoteURL ?? ""),
           assessment.candidateRemoteHasDoltData == nil,
           GitDoltRemoteGenerationProbe.normalizedGitRemoteURL(draft.remoteURL) != nil {
            findings.append(BeadsSetupFinding(
                id: "candidate-remote-unverified",
                severity: .blocking,
                title: "The remote history could not be verified",
                detail: "Beadazzle will not publish a local database to a newly added Git-backed remote until its Dolt data reference can be checked."
            ))
        }

        append(configurationFragment(draft: draft, assessment: assessment), to: &findings, and: &steps)
        append(hooksFragment(assessment: assessment, usesBootstrap: usesBootstrap, wantsHooks: wantsHooks), to: &findings, and: &steps)
        append(backupFragment(draft: draft, assessment: assessment), to: &findings, and: &steps)
        append(publishFragment(draft: draft, assessment: assessment, wantsRemote: wantsRemote), to: &findings, and: &steps)

        if let storageMode, storageMode != .embedded, !steps.isEmpty {
            findings.append(BeadsSetupFinding(
                id: "server-mode-changes-unavailable",
                severity: .blocking,
                title: "Changes are unavailable for server storage",
                detail: "Review this setup without changes, or use bd's server administration workflow outside Beadazzle."
            ))
        }

        return BeadsSetupPlan(profile: draft.profile, findings: findings, steps: steps)
    }

    private struct PlanFragment {
        var findings: [BeadsSetupFinding] = []
        var steps: [BeadsSetupStep] = []
    }

    private static func append(
        _ fragment: PlanFragment,
        to findings: inout [BeadsSetupFinding],
        and steps: inout [BeadsSetupStep]
    ) {
        findings.append(contentsOf: fragment.findings)
        steps.append(contentsOf: fragment.steps)
    }

    private static func configurationFragment(
        draft: BeadsSetupDraft,
        assessment: BeadsSetupAssessment
    ) -> PlanFragment {
        guard draft.profile == .team || draft.profile == .solo else { return PlanFragment() }
        if assessment.isInitialized, assessment.config.value == nil {
            return PlanFragment(findings: [BeadsSetupFinding(
                id: "config-inspection-required",
                severity: .blocking,
                title: "Project configuration could not be inspected",
                detail: "Review the project configuration again before changing its automatic-push policy."
            )])
        }
        let desiredAutoPush = draft.profile == .solo && draft.allowsAutomaticPush
        guard assessment.effectiveBoolConfigValue("dolt.auto-push") != desiredAutoPush else {
            return PlanFragment()
        }
        return PlanFragment(steps: [configStep(key: "dolt.auto-push", value: String(desiredAutoPush))])
    }

    private static func hooksFragment(
        assessment: BeadsSetupAssessment,
        usesBootstrap: Bool,
        wantsHooks: Bool
    ) -> PlanFragment {
        if usesBootstrap, wantsHooks, assessment.hooks?.allInstalled != true {
            return PlanFragment(steps: [BeadsSetupStep(
                id: "install-hooks",
                title: "Install Git hooks",
                detail: "Install bd-managed hooks after the existing tracker is bootstrapped.",
                scopes: [.checkoutLocal],
                operation: .installHooks
            )])
        }
        guard assessment.isInitialized, let hooks = assessment.hooks else { return PlanFragment() }
        if wantsHooks, !hooks.allInstalled {
            return PlanFragment(steps: [BeadsSetupStep(
                id: "install-hooks",
                title: "Install Git hooks",
                detail: "Install bd-managed hooks for this checkout.",
                scopes: [.checkoutLocal],
                operation: .installHooks
            )])
        }
        if !wantsHooks, hooks.anyInstalled {
            return PlanFragment(steps: [BeadsSetupStep(
                id: "uninstall-hooks",
                title: "Remove bd-managed hooks",
                detail: "Uninstall the hooks managed by bd in this checkout.",
                scopes: [.checkoutLocal],
                operation: .uninstallHooks
            )])
        }
        return PlanFragment()
    }

    private static func backupFragment(
        draft: BeadsSetupDraft,
        assessment: BeadsSetupAssessment
    ) -> PlanFragment {
        var fragment = PlanFragment()
        let destination = draft.backupDestination.nilIfBlank
        if let destination {
            if assessment.isInitialized, assessment.backup == nil {
                fragment.findings.append(BeadsSetupFinding(
                    id: "backup-inspection-required",
                    severity: .blocking,
                    title: "Backup status could not be inspected",
                    detail: "Review the backup status again before registering or synchronizing a destination."
                ))
            } else if let current = assessment.backup?.dolt?.backupURL?.nilIfBlank,
                      normalizedRemote(current) != normalizedRemote(destination) {
                fragment.findings.append(BeadsSetupFinding(
                    id: "backup-destination-conflict",
                    severity: .blocking,
                    title: "A different backup is already configured",
                    detail: "The wizard will not replace \(current). Remove or change it explicitly with bd before choosing another destination."
                ))
            } else if assessment.backup?.isConfigured != true {
                fragment.steps.append(BeadsSetupStep(
                    id: "initialize-backup",
                    title: "Configure backup",
                    detail: "Register the selected filesystem path or URL as the backup destination.",
                    scopes: [.checkoutLocal],
                    operation: .initializeBackup(destination: destination)
                ))
            }
        }
        if draft.syncsBackupAfterSetup,
           destination != nil || assessment.backup?.isConfigured == true {
            fragment.steps.append(BeadsSetupStep(
                id: "sync-backup",
                title: "Create backup",
                detail: "Synchronize the full Dolt database to the configured backup destination.",
                scopes: [.remoteOperation],
                operation: .syncBackup
            ))
        }
        return fragment
    }

    private static func publishFragment(
        draft: BeadsSetupDraft,
        assessment: BeadsSetupAssessment,
        wantsRemote: Bool
    ) -> PlanFragment {
        guard wantsRemote, draft.completesRemoteSetup else { return PlanFragment() }
        return PlanFragment(steps: [BeadsSetupStep(
            id: "publish-remote",
            title: assessment.isInitialized ? "Publish local Dolt changes" : "Publish the new tracker",
            detail: "Push the local Dolt database after the preceding setup steps succeed.",
            scopes: [.remoteOperation],
            operation: .pushRemote
        )])
    }

    static func audit(intent: BeadsSetupIntent, assessment: BeadsSetupAssessment) -> [BeadsSetupFinding] {
        var findings = assessment.warnings.enumerated().map { index, warning in
            BeadsSetupFinding(
                id: "inspection-warning-\(index)",
                severity: .warning,
                title: "Inspection was incomplete",
                detail: warning
            )
        }
        let currentRemoteURL = intent.remoteName.flatMap { name in
            assessment.remotes?.remotes.first(where: { $0.name == name })?.url
        }
        let currentBackupDestination = assessment.backup?.dolt?.backupURL?.nilIfBlank

        if intent.remoteName != nil, assessment.remotes == nil {
            findings.append(BeadsSetupFinding(
                id: "remote-inspection-required",
                severity: .warning,
                title: "Dolt remotes could not be inspected",
                detail: "Beadazzle could not verify the shared task database configured for this checkout."
            ))
        }
        if assessment.remotes != nil,
           let intended = intent.remoteURLFingerprint,
           currentRemoteURL.map(configurationFingerprint) != intended {
            findings.append(BeadsSetupFinding(
                id: "intended-remote-changed",
                severity: .warning,
                title: "The intended Dolt remote changed",
                detail: "The configured remote no longer matches the remote reviewed when setup was saved."
            ))
        }
        if assessment.backup != nil,
           let intended = intent.backupDestinationFingerprint,
           currentBackupDestination.map(configurationFingerprint) != intended {
            findings.append(BeadsSetupFinding(
                id: "intended-backup-changed",
                severity: .warning,
                title: "The intended backup changed",
                detail: "The configured backup no longer matches the destination reviewed when setup was saved."
            ))
        }

        if let hooks = assessment.hooks {
            if intent.installsHooks && !hooks.allInstalled {
                findings.append(pendingAuditFinding(
                    id: "install-hooks",
                    title: "Install Git hooks",
                    detail: "The intended bd-managed hooks are not fully installed in this checkout."
                ))
            } else if !intent.installsHooks && hooks.anyInstalled {
                findings.append(pendingAuditFinding(
                    id: "uninstall-hooks",
                    title: "Remove bd-managed hooks",
                    detail: "This checkout has bd-managed hooks that are not part of its saved setup."
                ))
            }
        }

        if (intent.profile == .team || intent.profile == .solo),
           assessment.config.value != nil {
            let desiredAutoPush = intent.profile == .solo && intent.allowsAutomaticPush
            if assessment.effectiveBoolConfigValue("dolt.auto-push") != desiredAutoPush {
                findings.append(pendingAuditFinding(
                    id: "config-dolt.auto-push",
                    title: "Update automatic push",
                    detail: "The current automatic-push setting differs from the saved \(intent.profile.title) setup."
                ))
            }
        }
        return findings
    }

    private static func pendingAuditFinding(
        id: String,
        title: String,
        detail: String
    ) -> BeadsSetupFinding {
        BeadsSetupFinding(
            id: "pending-\(id)",
            severity: .warning,
            title: title,
            detail: detail
        )
    }

    static func configurationFingerprint(_ value: String) -> String {
        StableFingerprint.sha256(normalizedRemote(value))
    }

    static func findingsFingerprint(_ findings: [BeadsSetupFinding]) -> String? {
        let actionable = findings
            .filter(\.isActionable)
            .map { "\($0.id)|\($0.severity.rawValue)|\($0.detail)" }
            .sorted()
        guard !actionable.isEmpty else { return nil }
        return StableFingerprint.sha256(actionable.joined(separator: "\n"))
    }

    private static func configStep(key: String, value: String) -> BeadsSetupStep {
        BeadsSetupStep(
            id: "config-\(key)",
            title: "Set \(key)",
            detail: "Set the project configuration to \(value).",
            scopes: [.gitTracked],
            operation: .setConfig(key: key, value: value)
        )
    }

    static func normalizedRemote(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func requestedRemoteHasDoltData(
        draft: BeadsSetupDraft,
        assessment: BeadsSetupAssessment
    ) -> Bool? {
        let requestedURL = normalizedRemote(draft.remoteURL)
        if requestedURL == normalizedRemote(assessment.candidateRemoteURL ?? "") {
            return assessment.candidateRemoteHasDoltData
        }
        if requestedURL == normalizedRemote(assessment.gitOriginURL ?? "") {
            return assessment.gitOriginHasDoltData
        }
        if requestedURL == normalizedRemote(assessment.gitUpstreamURL ?? "") {
            return assessment.gitUpstreamHasDoltData
        }
        return nil
    }

}
