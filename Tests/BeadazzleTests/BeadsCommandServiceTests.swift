import XCTest
@testable import Beadazzle

final class BeadsCommandServiceTests: XCTestCase {
    func testCreatedIssueIDParsesLastNonEmptyOutputLine() throws {
        let issueID = try BeadsCommandService.createdIssueID(from: "\nbeadazzle-created\n")

        XCTAssertEqual(issueID, "beadazzle-created")
    }

    func testCreatedIssueIDThrowsWhenOutputIsEmpty() {
        XCTAssertThrowsError(try BeadsCommandService.createdIssueID(from: " \n ")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Expected created bead ID"))
        }
    }

    func testEnsureExportedIssuesJSONLExistsCreatesReadableEmptySnapshot() throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let snapshotURL = BeadsCommandService.exportedIssuesJSONLURL(projectURL: projectURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))

        try BeadsCommandService.ensureExportedIssuesJSONLExists(projectURL: projectURL)

        XCTAssertEqual(try String(contentsOf: snapshotURL, encoding: .utf8), "")

        let loadedProject = try BeadsSnapshotReader().loadProject(projectURL: projectURL)
        XCTAssertEqual(loadedProject.source.kind, .jsonl)
        XCTAssertTrue(loadedProject.snapshot.issues.isEmpty)
    }

    func testEnsureExportedIssuesJSONLExistsPreservesExistingSnapshot() throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let snapshotURL = BeadsCommandService.exportedIssuesJSONLURL(projectURL: projectURL)
        let contents = """
        {"_type":"issue","id":"bd-1","title":"Existing","status":"open","priority":1,"issue_type":"task"}
        """
        try contents.write(to: snapshotURL, atomically: true, encoding: .utf8)

        try BeadsCommandService.ensureExportedIssuesJSONLExists(projectURL: projectURL)

        XCTAssertEqual(try String(contentsOf: snapshotURL, encoding: .utf8), contents)
    }

    private func makeProjectWithBeadsDirectory() throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadazzleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".beads", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL)
        }
        return projectURL
    }
}
