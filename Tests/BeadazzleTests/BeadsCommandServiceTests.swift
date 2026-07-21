import XCTest
@testable import Beadazzle

final class BeadsCommandServiceTests: XCTestCase {
    func testContextMissingDirectoryDetectionUsesCurrentCLIError() {
        XCTAssertTrue(BeadsCommandService.contextReportsMissingBeadsDirectory("""
        {
          "error": "cannot resolve repo context: no .beads directory found",
          "schema_version": 1
        }
        """))
        XCTAssertFalse(BeadsCommandService.contextReportsMissingBeadsDirectory("bd context timed out"))
    }

    func testCreatedIssueIDParsesLastNonEmptyOutputLine() throws {
        let issueID = try BeadsCommandService.createdIssueID(from: "\nbeadazzle-created\n")

        XCTAssertEqual(issueID, "beadazzle-created")
    }

    func testCreatedIssueIDThrowsWhenOutputIsEmpty() {
        XCTAssertThrowsError(try BeadsCommandService.createdIssueID(from: " \n ")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Expected created bead ID"))
        }
    }

    func testDecodeCommentsHandlesCurrentAndLegacyFieldNames() throws {
        let data = Data(
            #"[{"id":12,"issue_id":"bd-1","author":"Riley","text":"First","created_at":"2026-07-03T20:58:35Z"},{"issueId":"bd-1","body":"Second","createdAt":"2026-07-03T21:58:35.123Z"}]"#.utf8
        )

        let comments = try BeadsCommandService.decodeComments(from: data, issueID: "bd-fallback")

        XCTAssertEqual(comments.map(\.id), ["12", "bd-1-comment-1"])
        XCTAssertEqual(comments.map(\.issueID), ["bd-1", "bd-1"])
        XCTAssertEqual(comments.map(\.text), ["First", "Second"])
        XCTAssertNotNil(comments[0].createdAt)
        XCTAssertNotNil(comments[1].createdAt)
    }

    func testDecodeCommentsRejectsUnexpectedJSONShape() {
        XCTAssertThrowsError(
            try BeadsCommandService.decodeComments(from: Data(#"{"id":"comment-1"}"#.utf8), issueID: "bd-1")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Expected a JSON array of comments"))
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

    func testExportReadableSnapshotUsesResolvedTrackerDirectory() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let trackerDirectory = projectURL.appendingPathComponent("redirected-tracker", isDirectory: true)
        try FileManager.default.createDirectory(at: trackerDirectory, withIntermediateDirectories: true)
        let localSnapshotURL = BeadsCommandService.exportedIssuesJSONLURL(projectURL: projectURL)
        let redirectedSnapshotURL = trackerDirectory.appendingPathComponent("issues.jsonl")
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output" ]; then
            shift
            printf '%s\n' '{"_type":"issue","id":"bd-redirected","title":"Redirected","status":"open","priority":1,"issue_type":"task"}' > "$1"
            exit 0
          fi
          shift
        done
        exit 2
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        try await service.exportReadableSnapshot(
            projectURL: projectURL,
            beadsDirectoryURL: trackerDirectory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: localSnapshotURL.path))
        XCTAssertTrue(try String(contentsOf: redirectedSnapshotURL, encoding: .utf8).contains("bd-redirected"))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: trackerDirectory.path)
                .contains { $0.hasPrefix("issues.jsonl.tmp.") }
        )
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

    func testProjectContextDecodesEmbeddedDoltAsCurrentStorage() throws {
        let context = try BeadsProjectContext.decode(from: """
        {
          "backend": "dolt",
          "bd_version": "1.0.4",
          "beads_dir": "/tmp/project/.beads",
          "cwd_repo_root": "/tmp/project",
          "database": "project",
          "dolt_mode": "embedded",
          "is_redirected": false,
          "is_worktree": false,
          "project_id": "project-id",
          "repo_root": "/tmp/project",
          "role": "maintainer",
          "schema_version": 1
        }
        """)

        XCTAssertEqual(context.backend, "dolt")
        XCTAssertEqual(context.doltMode, "embedded")
        XCTAssertTrue(context.usesCurrentEmbeddedDolt)
        XCTAssertEqual(context.databasePath(projectURL: URL(fileURLWithPath: "/tmp/project")), "/tmp/project/.beads/embeddeddolt")
    }

    func testDoltRemoteListDecodesOperationalRemotes() throws {
        let remotes = try BeadsDoltRemotes.decode(from: """
        [
          {
            "name": "origin",
            "url": "git+ssh://git@github.com/example/project.git",
            "sql_url": "git+ssh://git@github.com/example/project.git",
            "status": "ok"
          }
        ]
        """)

        XCTAssertEqual(remotes.summary, "origin configured")
        XCTAssertEqual(remotes.primaryRemote?.name, "origin")
        XCTAssertEqual(remotes.primaryRemote?.url, "git+ssh://git@github.com/example/project.git")
        XCTAssertNil(remotes.firstReportedProblem)
    }

    func testDoltPullAndPushUseExplicitBDCommands() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let logURL = projectURL.appendingPathComponent("commands.log")
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        printf '%s\n' "$*" >> "$PWD/commands.log"
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        try await service.pullDoltRemote(projectURL: projectURL)
        try await service.pushDoltRemote(projectURL: projectURL)

        let commands = try String(contentsOf: logURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(commands, ["dolt pull", "dolt push"])
    }

    func testDoltSyncUsesDedicatedNetworkTimeout() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        exec /bin/sleep 10
        """)
        let service = BeadsCommandService(
            writeCommandTimeout: .seconds(5),
            remoteSyncCommandTimeout: .milliseconds(50),
            executable: { (stubURL, []) }
        )

        do {
            try await service.pushDoltRemote(projectURL: projectURL)
            XCTFail("Expected Dolt push to use the remote-sync timeout.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Timed out waiting for `bd` to finish."))
        }
    }

    func testHooksStatusParsesMissingHooksAsActionable() {
        let hooks = BeadsHooksStatus.parse(from: """
        Git hooks status:
          ✗ pre-commit: not installed
          ✗ post-merge: not installed
          ✓ pre-push: installed
        """)

        XCTAssertEqual(hooks.hooks.map(\.name), ["pre-commit", "post-merge", "pre-push"])
        XCTAssertEqual(hooks.missingHooks.map(\.name), ["pre-commit", "post-merge"])
        XCTAssertTrue(hooks.hasMissingHooks)
        XCTAssertEqual(hooks.summary, "2 missing")
    }

    func testBackupStatusDecodesLastBackupAndLocalDestination() throws {
        let backup = try BeadsBackupStatus.decode(from: """
        {
          "backup": {
            "last_dolt_commit": "ilalaudvusuhf22fghtkv04g7g5ekpqo",
            "timestamp": "2026-07-08T13:35:44.99568Z"
          },
          "database_size": {
            "bytes": 0,
            "human": "0 B"
          },
          "dolt": {
            "backup_name": "default",
            "backup_url": "file:///tmp/project/.beads/backup",
            "configured": true,
            "created_at": "2026-07-08T13:30:00Z",
            "last_sync": "2026-07-08T13:35:44Z",
            "sync_duration": "110ms"
          }
        }
        """)

        XCTAssertTrue(backup.isConfigured)
        XCTAssertTrue(backup.hasBackupHistory)
        XCTAssertEqual(backup.backup?.lastDoltCommit, "ilalaudvusuhf22fghtkv04g7g5ekpqo")
        XCTAssertNotNil(backup.lastBackupDate)
        XCTAssertEqual(backup.databaseSize?.human, "0 B")
        XCTAssertNil(backup.databaseSize?.displayValue)
        XCTAssertEqual(backup.dolt?.configured, true)
        XCTAssertEqual(backup.dolt?.backupName, "default")
        XCTAssertEqual(backup.dolt?.destinationSummary, "Local folder")
        XCTAssertNotNil(backup.dolt?.lastSyncDate)
    }

    func testProjectStorageConfigKeepsPerKeyFailures() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        key=""
        for arg in "$@"; do
          key="$arg"
        done
        case "$key" in
          export.auto)
            printf 'true\\n'
            ;;
          export.path)
            printf 'issues.jsonl\\n'
            ;;
          export.interval)
            printf 'failed to read export interval\\n' >&2
            exit 2
            ;;
          export.git-add)
            printf 'false\\n'
            ;;
          import.auto)
            printf 'off\\n'
            ;;
          federation.remote)
            printf 'federation.remote (not set in config.yaml)\\n'
            ;;
          no-git-ops)
            printf 'true\\n'
            ;;
          dolt.auto-push)
            printf 'false\\n'
            ;;
          dolt.auto-push-interval)
            printf '5m\\n'
            ;;
          dolt.auto-push-timeout)
            printf '30s\\n'
            ;;
          *)
            printf 'unexpected key: %s\\n' "$key" >&2
            exit 3
            ;;
        esac
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        let config = try await service.loadProjectStorageConfig(projectURL: projectURL)

        XCTAssertEqual(config.exportAuto, true)
        XCTAssertEqual(config.exportPath, "issues.jsonl")
        XCTAssertNil(config.exportInterval)
        XCTAssertNotNil(config.exportIntervalStatus.errorMessage)
        XCTAssertEqual(config.exportGitAdd, false)
        XCTAssertEqual(config.importAuto, false)
        XCTAssertNil(config.federationRemote)
        XCTAssertNil(config.federationRemoteStatus.errorMessage)
        XCTAssertTrue(config.usesStealthMode)
        XCTAssertEqual(config.doltAutoPush, false)
        XCTAssertEqual(config.doltAutoPushInterval, "5m")
        XCTAssertEqual(config.doltAutoPushTimeout, "30s")
    }

    func testUnsetConfigOutputParsesAsNil() {
        XCTAssertNil(ProjectStorageConfig.configValue(
            from: "federation.remote (not set in config.yaml)",
            key: "federation.remote"
        ))
        XCTAssertEqual(ProjectStorageConfig.configValue(from: "issues.jsonl", key: "export.path"), "issues.jsonl")
        XCTAssertEqual(ProjectStorageConfig.bool(from: "true"), true)
        XCTAssertEqual(ProjectStorageConfig.bool(from: "off"), false)
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
