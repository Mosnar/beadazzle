import Foundation

struct BeadsSnapshot: Sendable {
    var issues: [BeadIssue]
    var dependencies: [BeadDependency]
    var commentsByIssueID: [String: [BeadComment]]
}

enum BeadsDataSourceKind: String, Equatable, Sendable {
    case jsonl
}

struct BeadsDataSource: Equatable, Identifiable, Sendable {
    var id: String { "\(kind.rawValue):\(url.path)" }

    let kind: BeadsDataSourceKind
    let url: URL
    let size: Int64
    let modifiedAt: Date

    var watchKey: String {
        "\(kind.rawValue):\(url.path)"
    }

    var fingerprint: String {
        "\(watchKey):\(size):\(modifiedAt.timeIntervalSinceReferenceDate)"
    }

    var displayPath: String {
        url.path
    }
}

struct LoadedBeadsSnapshot: Sendable {
    var source: BeadsDataSource
    var snapshot: BeadsSnapshot
}
