import Foundation

enum ProjectDoltRemoteFreshnessResult: Equatable, Sendable {
    case unknown
    case checkpointRequired(remoteName: String)
    case unchangedSinceSync(checkedAt: Date)
    case remoteChanged(checkedAt: Date)
    case unavailable(checkedAt: Date?, message: String)
    case unsupported
    case notConfigured
    case notApplicable

    var hasRemoteChanges: Bool {
        if case .remoteChanged = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case .unknown:
            "Not checked"
        case .checkpointRequired(let remoteName):
            "\(remoteName) configured"
        case .unchangedSinceSync:
            "No remote changes found"
        case .remoteChanged:
            "Remote changes found"
        case .unavailable:
            "Unavailable"
        case .unsupported:
            "Not supported"
        case .notConfigured:
            "Not configured"
        case .notApplicable:
            "Not applicable"
        }
    }

    var detail: String {
        switch self {
        case .unknown:
            "Beadazzle has not finished checking this project's remote configuration."
        case .checkpointRequired(let remoteName):
            "The \(remoteName) Dolt remote is configured. Sync once in Beadazzle to establish a comparison checkpoint before checking for later remote changes."
        case .unchangedSinceSync(let checkedAt):
            "No remote changes found. The remote ref is unchanged from the checkpoint Beadazzle recorded after its last successful sync. Checked \(Self.formatted(checkedAt))."
        case .remoteChanged(let checkedAt):
            "Remote changes found. The remote ref changed after Beadazzle recorded its last successful-sync checkpoint. Checked \(Self.formatted(checkedAt))."
        case .unavailable(let checkedAt, let message):
            [message, checkedAt.map { "Last attempted \(Self.formatted($0))." }]
                .compactMap(\.self)
                .joined(separator: " ")
        case .unsupported:
            "Lightweight change checks currently support Git-backed Dolt remotes."
        case .notConfigured:
            "This project has no Dolt remote, so Beadazzle will not perform remote checks."
        case .notApplicable:
            "Lightweight remote checks apply to embedded Dolt projects with Git-backed remotes."
        }
    }

    var checkedAt: Date? {
        switch self {
        case .unchangedSinceSync(let checkedAt), .remoteChanged(let checkedAt):
            checkedAt
        case .unavailable(let checkedAt, _):
            checkedAt
        case .unknown, .checkpointRequired, .unsupported, .notConfigured, .notApplicable:
            nil
        }
    }

    var requiresSyncCheckpoint: Bool {
        if case .checkpointRequired = self { return true }
        return false
    }

    var canCheckAgain: Bool {
        switch self {
        case .unchangedSinceSync, .remoteChanged, .unavailable:
            true
        case .unknown, .checkpointRequired, .unsupported, .notConfigured, .notApplicable:
            false
        }
    }

    private static func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct ProjectDoltRemoteFreshnessState: Equatable, Sendable {
    var result: ProjectDoltRemoteFreshnessResult = .unknown
    var isChecking = false

    static let unknown = ProjectDoltRemoteFreshnessState()
}

struct ProjectDoltRemoteFreshnessRecord: Codable, Equatable, Sendable {
    var remoteName: String
    var remoteFingerprint: String
    var syncCheckpointGeneration: String?
    var observedGeneration: String?
    var lastCheckedAt: Date?
    var lastAttemptedAt: Date?

    func matches(_ remote: BeadsDoltRemote) -> Bool {
        remoteName == remote.name && remoteFingerprint == Self.fingerprint(remote.url)
    }

    static func fingerprint(_ remoteURL: String) -> String {
        StableFingerprint.sha256(remoteURL)
    }
}
