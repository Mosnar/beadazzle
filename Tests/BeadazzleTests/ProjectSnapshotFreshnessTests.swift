import XCTest
@testable import Beadazzle

final class ProjectSnapshotFreshnessTests: XCTestCase {
    func testInitialLoadMarksSnapshotPossiblyStaleWhenMarkerIsNewer() throws {
        let project = try makeProject()
        let newerDate = project.source.modifiedAt.addingTimeInterval(2)
        try FileManager.default.setAttributes(
            [.modificationDate: newerDate],
            ofItemAtPath: project.lastTouchedURL.path
        )

        let freshness = ProjectSnapshotFreshness.loaded(projectURL: project.url, source: project.source)

        XCTAssertEqual(freshness.state, .possiblyStale)
        XCTAssertEqual(freshness.message, "Snapshot may be stale")
    }

    func testMarkerOnlyChangeMarksSnapshotPossiblyStaleWithoutReload() throws {
        let project = try makeProject()
        let freshness = ProjectSnapshotFreshness.loaded(projectURL: project.url, source: project.source)

        try #"{"timestamp":"new","issues":1}"#.write(
            to: project.exportStateURL,
            atomically: true,
            encoding: .utf8
        )

        let evaluation = freshness.evaluatingCurrentFiles(projectURL: project.url, source: project.source)

        XCTAssertFalse(evaluation.requiresReload)
        XCTAssertEqual(evaluation.freshness.state, .possiblyStale)
        XCTAssertEqual(evaluation.freshness.message, "Snapshot may be stale")
    }

    func testActiveSnapshotChangeRequiresReload() throws {
        let project = try makeProject()
        let freshness = ProjectSnapshotFreshness.loaded(projectURL: project.url, source: project.source)

        let handle = try FileHandle(forWritingTo: project.issuesURL)
        handle.seekToEndOfFile()
        handle.write(Data("\n{\"_type\":\"issue\",\"id\":\"bd-2\"}".utf8))
        try handle.close()

        let evaluation = freshness.evaluatingCurrentFiles(projectURL: project.url, source: project.source)

        XCTAssertTrue(evaluation.requiresReload)
        XCTAssertEqual(evaluation.freshness.state, .refreshing)
    }

    func testUnchangedSnapshotStaysCurrent() throws {
        let project = try makeProject()
        let freshness = ProjectSnapshotFreshness.loaded(projectURL: project.url, source: project.source)

        let evaluation = freshness.evaluatingCurrentFiles(projectURL: project.url, source: project.source)

        XCTAssertFalse(evaluation.requiresReload)
        XCTAssertEqual(evaluation.freshness.state, .current)
        XCTAssertEqual(evaluation.freshness.message, "Snapshot current")
    }

    private func makeProject() throws -> FreshnessTestProject {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectSnapshotFreshnessTests-\(UUID().uuidString)", isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL)
        }

        let issuesURL = beadsURL.appendingPathComponent("issues.jsonl")
        try """
        {"_type":"issue","id":"bd-1","title":"One","status":"open","priority":1,"issue_type":"task"}
        """.write(to: issuesURL, atomically: true, encoding: .utf8)

        let exportStateURL = beadsURL.appendingPathComponent("export-state.json")
        try #"{"timestamp":"old"}"#.write(to: exportStateURL, atomically: true, encoding: .utf8)

        let lastTouchedURL = beadsURL.appendingPathComponent("last-touched")
        try "old\n".write(to: lastTouchedURL, atomically: true, encoding: .utf8)

        let attributes = try FileManager.default.attributesOfItem(atPath: issuesURL.path)
        let source = BeadsDataSource(
            kind: .jsonl,
            url: issuesURL,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        )
        let olderMarkerDate = source.modifiedAt.addingTimeInterval(-2)
        try FileManager.default.setAttributes(
            [.modificationDate: olderMarkerDate],
            ofItemAtPath: exportStateURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: olderMarkerDate],
            ofItemAtPath: lastTouchedURL.path
        )
        return FreshnessTestProject(
            url: projectURL,
            issuesURL: issuesURL,
            exportStateURL: exportStateURL,
            lastTouchedURL: lastTouchedURL,
            source: source
        )
    }
}

private struct FreshnessTestProject {
    var url: URL
    var issuesURL: URL
    var exportStateURL: URL
    var lastTouchedURL: URL
    var source: BeadsDataSource
}
