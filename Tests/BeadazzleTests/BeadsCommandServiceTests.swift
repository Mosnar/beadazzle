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

    func testExportReadableSnapshotReplacesSnapshotFromValidatedTempFile() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let snapshotURL = BeadsCommandService.exportedIssuesJSONLURL(projectURL: projectURL)
        try """
        {"_type":"issue","id":"bd-existing","title":"Existing","status":"open","priority":1,"issue_type":"task"}
        """.write(to: snapshotURL, atomically: true, encoding: .utf8)
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output" ]; then
            shift
            printf '%s\n' '{"_type":"issue","id":"bd-exported","title":"Exported","status":"open","priority":1,"issue_type":"task"}' > "$1"
            exit 0
          fi
          shift
        done
        exit 2
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        try await service.exportReadableSnapshot(projectURL: projectURL)

        let contents = try String(contentsOf: snapshotURL, encoding: .utf8)
        XCTAssertTrue(contents.contains(#""id":"bd-exported""#))
        XCTAssertFalse(contents.contains("bd-existing"))
        XCTAssertTrue(temporaryExportFiles(in: projectURL).isEmpty)
    }

    func testExportReadableSnapshotPreservesExistingSnapshotWhenExportTimesOut() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let snapshotURL = BeadsCommandService.exportedIssuesJSONLURL(projectURL: projectURL)
        let existing = """
        {"_type":"issue","id":"bd-existing","title":"Existing","status":"open","priority":1,"issue_type":"task"}
        """
        try existing.write(to: snapshotURL, atomically: true, encoding: .utf8)
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        exec /bin/sleep 10
        """)
        let service = BeadsCommandService(
            snapshotExportTimeout: .milliseconds(50),
            executable: { (stubURL, []) }
        )

        do {
            try await service.exportReadableSnapshot(projectURL: projectURL)
            XCTFail("Expected snapshot export to time out.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Timed out waiting for `bd` to finish."))
        }
        XCTAssertEqual(try String(contentsOf: snapshotURL, encoding: .utf8), existing)
        XCTAssertTrue(temporaryExportFiles(in: projectURL).isEmpty)
    }

    func testExportReadableSnapshotPreservesExistingSnapshotWhenExportIsInvalid() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let snapshotURL = BeadsCommandService.exportedIssuesJSONLURL(projectURL: projectURL)
        let existing = """
        {"_type":"issue","id":"bd-existing","title":"Existing","status":"open","priority":1,"issue_type":"task"}
        """
        try existing.write(to: snapshotURL, atomically: true, encoding: .utf8)
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output" ]; then
            shift
            printf '%s\n' '{"_type":"issue","id":"bd-partial"' > "$1"
            exit 0
          fi
          shift
        done
        exit 2
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        do {
            try await service.exportReadableSnapshot(projectURL: projectURL)
            XCTFail("Expected invalid snapshot export to fail validation.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Export produced invalid JSONL"))
        }
        XCTAssertEqual(try String(contentsOf: snapshotURL, encoding: .utf8), existing)
        XCTAssertTrue(temporaryExportFiles(in: projectURL).isEmpty)
    }

    func testReadOnlyMetadataCommandTimesOutInsteadOfHanging() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        exec /bin/sleep 10
        """)

        let service = BeadsCommandService(
            readOnlyCommandTimeout: .milliseconds(50),
            executable: { (stubURL, []) }
        )

        do {
            _ = try await service.loadStatusDefinitions(projectURL: projectURL)
            XCTFail("Expected read-only metadata command to time out.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Timed out waiting for `bd` to finish."))
        }
    }

    private func makeExecutableScript(in projectURL: URL, contents: String) throws -> URL {
        let stubURL = projectURL.appendingPathComponent("bd-stub-\(UUID().uuidString)")
        try contents.write(to: stubURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubURL.path)
        return stubURL
    }

    private func temporaryExportFiles(in projectURL: URL) -> [String] {
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: beadsURL.path))?
            .filter { $0.hasPrefix("issues.jsonl.tmp.") } ?? []
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
