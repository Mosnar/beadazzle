import CryptoKit
import Foundation

enum ProjectDoltRemoteFreshnessResult: Equatable, Sendable {
    case unknown
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
            "Not established"
        case .unchangedSinceSync:
            "Unchanged since Sync"
        case .remoteChanged:
            "Changed since Sync"
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
            "Sync once in Beadazzle to establish a remote checkpoint."
        case .unchangedSinceSync(let checkedAt):
            "The remote ref is unchanged from the checkpoint Beadazzle recorded after its last successful sync. Checked \(Self.formatted(checkedAt))."
        case .remoteChanged(let checkedAt):
            "The remote ref changed after Beadazzle recorded its last successful-sync checkpoint. Checked \(Self.formatted(checkedAt))."
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
        case .unknown, .unsupported, .notConfigured, .notApplicable:
            nil
        }
    }

    var canCheckAgain: Bool {
        switch self {
        case .unchangedSinceSync, .remoteChanged, .unavailable:
            true
        case .unknown, .unsupported, .notConfigured, .notApplicable:
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
        SHA256.hash(data: Data(remoteURL.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
