import Foundation

struct BeadsSnapshotReader {
    private let discovery: BeadsDataSourceDiscovery
    private let jsonlReader: BeadsJSONLSnapshotReader

    init(
        discovery: BeadsDataSourceDiscovery = BeadsDataSourceDiscovery(),
        jsonlReader: BeadsJSONLSnapshotReader = BeadsJSONLSnapshotReader()
    ) {
        self.discovery = discovery
        self.jsonlReader = jsonlReader
    }

    func loadProject(projectURL: URL, beadsDirectoryURL: URL? = nil) throws -> LoadedBeadsSnapshot {
        let source = try discovery.discover(
            projectURL: projectURL,
            beadsDirectoryURL: beadsDirectoryURL
        )
        return LoadedBeadsSnapshot(source: source, snapshot: try loadSnapshot(from: source))
    }

    func loadSnapshot(projectURL: URL) throws -> BeadsSnapshot {
        try loadProject(projectURL: projectURL).snapshot
    }

    func loadSnapshot(from source: BeadsDataSource) throws -> BeadsSnapshot {
        try jsonlReader.loadSnapshot(from: source)
    }

    func loadIssues(projectURL: URL) throws -> [BeadIssue] {
        try loadSnapshot(projectURL: projectURL).issues
    }

    func loadDependencies(projectURL: URL, issueID: String) throws -> [BeadDependency] {
        try loadSnapshot(projectURL: projectURL).dependencies.filter { dependency in
            dependency.issueID == issueID || dependency.dependsOnID == issueID
        }
    }

    func loadJSONLIssuesForTesting(records: [[String: Any]]) -> [BeadIssue] {
        jsonlReader.loadIssuesForTesting(records: records)
    }
}
