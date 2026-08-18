import Foundation

enum BeadsTrackerRecoveryCheckStatus: Equatable, Sendable {
    case passed
    case blocked

    var accessibilityDescription: String {
        switch self {
        case .passed: "Passed"
        case .blocked: "Blocked"
        }
    }
}

enum BeadsTrackerRecoveryCheckID: String, Hashable, Sendable {
    case incident
    case activity
    case bdVersion
    case context
    case doltVersion
    case backup
    case schemaCursor
}

struct BeadsTrackerRecoveryCheck: Equatable, Identifiable, Sendable {
    let id: BeadsTrackerRecoveryCheckID
    let title: String
    let detail: String
    let status: BeadsTrackerRecoveryCheckStatus
}

struct BeadsTrackerBackupFingerprint: Equatable, Sendable {
    let regularFileCount: Int
    let directoryCount: Int
    let symbolicLinkCount: Int
    let regularFileBytes: Int64
    /// SHA-256 over relative paths, entry types, symlink destinations, and regular-file
    /// contents. Counts alone can let an incomplete or corrupt copy look plausible.
    let digest: String
}

struct BeadsTrackerRecoveryPlan: Equatable, Sendable {
    let projectURL: URL
    let beadsDirectoryURL: URL
    let databaseDirectoryURL: URL
    let databaseName: String
    let backupURL: URL
    let bdExecutableURL: URL
    let bdArgumentsPrefix: [String]
    let subprocessEnvironment: [String: String]
    let bdVersion: String
    let doltVersion: String
}

struct BeadsTrackerRecoveryAssessment: Equatable, Sendable {
    let skew: BeadsSchemaSkew
    let checks: [BeadsTrackerRecoveryCheck]
    let plan: BeadsTrackerRecoveryPlan?
    let blockingMessage: String?

    var canRecover: Bool {
        plan != nil && blockingMessage == nil && checks.allSatisfy { $0.status == .passed }
    }
}

struct BeadsTrackerRecoveryActivity: Equatable, Sendable {
    let blocker: String?

    static let idle = Self(blocker: nil)
}

enum BeadsTrackerRecoveryPhase: Equatable, Sendable {
    case checkingPrerequisites
    case creatingBackup
    case repairingSchemaCursor
    case restoringEventsTracking
    case validating

    var title: String {
        switch self {
        case .checkingPrerequisites: "Checking prerequisites"
        case .creatingBackup: "Creating recovery backup"
        case .repairingSchemaCursor: "Rolling schema cursor back to v53"
        case .restoringEventsTracking: "Restoring events tracking"
        case .validating: "Validating recovered tracker"
        }
    }

    var finishesCurrentStepBeforeStopping: Bool {
        switch self {
        case .repairingSchemaCursor, .restoringEventsTracking: true
        case .checkingPrerequisites, .creatingBackup, .validating: false
        }
    }
}

struct BeadsTrackerRecoveryProgress: Equatable, Sendable {
    let phase: BeadsTrackerRecoveryPhase
    let log: [String]
}

struct BeadsTrackerRecoveryResult: Equatable, Sendable {
    let backupURL: URL
    let log: [String]

    static let publicationGuidance = """
    Recovery changed only this local tracker. Do not pull first: decide which recovered clone is authoritative, then publish separately with `bd dolt push` if your team uses a remote. Other clones and machines must be coordinated before they resume writing.
    """
}

struct BeadsTrackerRecoveryFailure: LocalizedError, Equatable, Sendable {
    let message: String
    let backupURL: URL?
    let log: [String]

    var errorDescription: String? { message }
}

enum BeadsTrackerRecoveryState: Equatable, Sendable {
    case idle
    case diagnosing
    case review(BeadsTrackerRecoveryAssessment)
    case running(BeadsTrackerRecoveryProgress)
    case succeeded(BeadsTrackerRecoveryResult)
    case failed(BeadsTrackerRecoveryFailure)

    var isRunning: Bool {
        switch self {
        case .diagnosing, .running: true
        case .idle, .review, .succeeded, .failed: false
        }
    }

    var isMutatingTracker: Bool {
        if case .running = self { return true }
        return false
    }
}
