import Foundation

struct BeadsSnapshotReader {
    private let discovery: BeadsDataSourceDiscovery
    private let sqliteReader: BeadsSQLiteSnapshotReader
    private let jsonlReader: BeadsJSONLSnapshotReader

    init(
        discovery: BeadsDataSourceDiscovery = BeadsDataSourceDiscovery(),
        sqliteReader: BeadsSQLiteSnapshotReader = BeadsSQLiteSnapshotReader(),
        jsonlReader: BeadsJSONLSnapshotReader = BeadsJSONLSnapshotReader()
    ) {
        self.discovery = discovery
        self.sqliteReader = sqliteReader
        self.jsonlReader = jsonlReader
    }

    func loadProject(projectURL: URL) throws -> LoadedBeadsSnapshot {
        let source = try discovery.discover(projectURL: projectURL)
        return LoadedBeadsSnapshot(source: source, snapshot: try loadSnapshot(from: source))
    }

    func loadSnapshot(projectURL: URL) throws -> BeadsSnapshot {
        try loadProject(projectURL: projectURL).snapshot
    }

    func loadSnapshot(from source: BeadsDataSource) throws -> BeadsSnapshot {
        switch source.kind {
        case .sqlite:
            try sqliteReader.loadSnapshot(from: source)
        case .jsonl:
            try jsonlReader.loadSnapshot(from: source)
        }
    }

    func loadIssues(projectURL: URL) throws -> [BeadIssue] {
        try loadSnapshot(projectURL: projectURL).issues
    }

    func loadDependencies(projectURL: URL, issueID: String) throws -> [BeadDependency] {
        try loadSnapshot(projectURL: projectURL).dependencies.filter { dependency in
            dependency.issueID == issueID || dependency.dependsOnID == issueID
        }
    }

    func loadComments(projectURL: URL, issueID: String) throws -> [BeadComment] {
        try loadSnapshot(projectURL: projectURL).commentsByIssueID[issueID] ?? []
    }

    func loadJSONLIssuesForTesting(records: [[String: Any]]) -> [BeadIssue] {
        jsonlReader.loadIssuesForTesting(records: records)
    }
}
