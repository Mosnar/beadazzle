import Foundation

enum ProjectDoltRemoteAction: Equatable, Sendable {
    case synchronizingIssues
    case pullingIssues
    case pushingIssues

    var healthAction: ProjectHealthAction {
        switch self {
        case .synchronizingIssues: .synchronizingIssues
        case .pullingIssues: .pullingIssues
        case .pushingIssues: .pushingIssues
        }
    }

    var failureTitle: String {
        switch self {
        case .synchronizingIssues: "Couldn't sync beads with remote"
        case .pullingIssues: "Couldn't pull beads from remote"
        case .pushingIssues: "Couldn't push beads to remote"
        }
    }

    var completionAnnouncement: String {
        switch self {
        case .synchronizingIssues: "Synced beads with remote"
        case .pullingIssues: "Pulled beads from remote"
        case .pushingIssues: "Pushed beads to remote"
        }
    }

    fileprivate var successCopy: (title: String, detail: String) {
        switch self {
        case .synchronizingIssues:
            ("Beads are up to date", "Pull, push, and issue list refresh completed.")
        case .pullingIssues:
            ("Beads pulled from remote", "Remote history was pulled and the issue list was refreshed.")
        case .pushingIssues:
            ("Beads pushed to remote", "Local Dolt history was published to the remote.")
        }
    }

    fileprivate var cancelledTitle: String {
        switch self {
        case .synchronizingIssues: "Sync stopped"
        case .pullingIssues: "Pull stopped"
        case .pushingIssues: "Push stopped"
        }
    }
}

enum ProjectDoltSyncPhase: Equatable, Sendable {
    case waitingForWriteQueue
    case checkingRemoteAccess(remoteName: String)
    case pulling(remoteName: String)
    case pushing(remoteName: String)
    case exportingSnapshot
    case waitingForLocalChanges
    case reloadingIssueList(includesNewExport: Bool)
    case recordingRemoteCheckpoint(remoteName: String)

    var title: String {
        switch self {
        case .waitingForWriteQueue:
            "Waiting to start"
        case .checkingRemoteAccess(let remoteName):
            "Checking access to \(remoteName)"
        case .pulling(let remoteName):
            "Pulling from \(remoteName)"
        case .pushing(let remoteName):
            "Pushing to \(remoteName)"
        case .exportingSnapshot:
            "Exporting the readable snapshot"
        case .waitingForLocalChanges:
            "Waiting for local changes"
        case .reloadingIssueList:
            "Reloading the issue list"
        case .recordingRemoteCheckpoint:
            "Recording the remote checkpoint"
        }
    }

    var command: String? {
        switch self {
        case .pulling:
            "bd dolt pull"
        case .pushing:
            "bd dolt push"
        case .exportingSnapshot:
            "bd export"
        case .checkingRemoteAccess, .recordingRemoteCheckpoint:
            "git ls-remote"
        case .waitingForWriteQueue, .waitingForLocalChanges, .reloadingIssueList:
            nil
        }
    }

    var detail: String {
        switch self {
        case .waitingForWriteQueue:
            "Another Beadazzle database write is finishing before this sync can begin."
        case .checkingRemoteAccess:
            "Verifying non-interactive remote access before starting the Dolt operation."
        case .pulling:
            "Downloading and merging the remote Dolt history."
        case .pushing:
            "Publishing local Dolt history. Dolt may compact database chunks before uploading them."
        case .exportingSnapshot:
            "Updating the JSONL snapshot Beadazzle reads."
        case .waitingForLocalChanges:
            "Waiting for edits that arrived during sync before refreshing the issue list."
        case .reloadingIssueList(let includesNewExport):
            includesNewExport
                ? "Exporting newer local changes, then loading the resulting snapshot."
                : "Loading the exported snapshot into the workspace."
        case .recordingRemoteCheckpoint(let remoteName):
            "Reading \(remoteName)'s Dolt data ref without pulling so later change checks have a baseline."
        }
    }

    var isRemoteDatabaseCommand: Bool {
        switch self {
        case .pulling, .pushing: true
        default: false
        }
    }
}

struct ProjectDoltSyncOutcome: Identifiable, Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case succeeded
        case failed
        case cancelled
    }

    let id: UUID
    let action: ProjectDoltRemoteAction
    let result: Result
    let title: String
    let detail: String
    let elapsed: TimeInterval?
    let command: String?
    let output: String?

    var automaticDismissDelay: Duration? {
        switch result {
        case .succeeded: .seconds(6)
        case .cancelled: .seconds(8)
        case .failed: nil
        }
    }

    var hasCommandDetails: Bool {
        command?.nilIfBlank != nil || output?.nilIfBlank != nil
    }

    static func succeeded(
        _ action: ProjectDoltRemoteAction,
        elapsed: TimeInterval? = nil
    ) -> Self {
        let copy = action.successCopy
        return Self(
            id: UUID(),
            action: action,
            result: .succeeded,
            title: copy.title,
            detail: timedDetail(copy.detail, elapsed: elapsed, prefix: "Completed in"),
            elapsed: elapsed,
            command: nil,
            output: nil
        )
    }

    static func failed(
        _ action: ProjectDoltRemoteAction,
        failure: ProjectHealthActionFailure,
        elapsed: TimeInterval? = nil
    ) -> Self {
        Self(
            id: UUID(),
            action: action,
            result: .failed,
            title: failure.title == "Last action failed" ? action.failureTitle : failure.title,
            detail: timedDetail(failure.message, elapsed: elapsed, prefix: "Failed after"),
            elapsed: elapsed,
            command: failure.command,
            output: failure.output
        )
    }

    static func cancelled(
        _ action: ProjectDoltRemoteAction,
        elapsed: TimeInterval? = nil
    ) -> Self {
        Self(
            id: UUID(),
            action: action,
            result: .cancelled,
            title: action.cancelledTitle,
            detail: timedDetail(
                "Stopped safely after the current database operation finished. Any completed remote changes were preserved.",
                elapsed: elapsed,
                prefix: "Stopped after"
            ),
            elapsed: elapsed,
            command: nil,
            output: nil
        )
    }

    private static func timedDetail(
        _ detail: String,
        elapsed: TimeInterval?,
        prefix: String
    ) -> String {
        guard let elapsed else { return detail }
        let seconds = max(0, Int(elapsed))
        let formatted = seconds < 60
            ? "\(seconds)s"
            : "\(seconds / 60)m \(seconds % 60)s"
        return "\(detail) \(prefix) \(formatted)."
    }
}
