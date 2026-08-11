import XCTest
@testable import Beadazzle

private actor BeadsSetupCommandEventRecorder {
    private(set) var events: [BeadsSetupApplyEvent] = []

    func record(_ event: BeadsSetupApplyEvent) {
        events.append(event)
    }
}

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
            guard case BeadError.createOutcomeUncertain = error else {
                return XCTFail("Expected an uncertain create outcome")
            }
            XCTAssertTrue(error.localizedDescription.contains("Expected created bead ID"))
        }
    }

    func testCreateReportsUncertainOutcomeWhenSuccessfulCommandReturnsNoID() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        exit 0
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })
        var draft = IssueDraft.blank(defaultType: "feature", defaultStatus: "open")
        draft.title = "Created without readable output"

        do {
            _ = try await service.createWithFeedback(projectURL: projectURL, draft: draft)
            XCTFail("Expected an uncertain create outcome")
        } catch {
            guard case BeadError.createOutcomeUncertain = error else {
                return XCTFail("Expected an uncertain create outcome, got \(error)")
            }
        }
    }

    func testCreateReturnsIDFromStandardOutputAndWarningFromStandardError() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        for argument in "$@"; do
          if [ "$argument" = "--id" ]; then
            printf '%s\n' 'Beadazzle must let bd generate issue IDs' >&2
            exit 2
          fi
        done
        printf '%s\n' 'bd-created'
        printf '%s\n' 'description is recommended' >&2
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })
        var draft = IssueDraft.blank(defaultType: "feature", defaultStatus: "open")
        draft.title = "Created with warning"

        let result = try await service.createWithFeedback(projectURL: projectURL, draft: draft)

        XCTAssertEqual(result.issueID, "bd-created")
        XCTAssertEqual(result.warning, "description is recommended")
    }

    func testCreationValidationSettingsLoadFromSharedBeadsConfig() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        case "$*" in
          "--readonly config get create.require-description")
            printf '%s\n' 'true'
            ;;
          "--readonly config get validation.on-create")
            printf '%s\n' 'warn'
            ;;
          *)
            exit 2
            ;;
        esac
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        let settings = try await service.loadCreationValidationSettings(projectURL: projectURL)

        XCTAssertEqual(
            settings,
            BeadsCreationValidationSettings(requiresDescription: true, mode: .warn)
        )
    }

    func testSavingCreationValidationWritesOnlyChangedSharedConfigKey() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let logURL = projectURL.appendingPathComponent("config-writes.log")
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        case "$*" in
          "--readonly config get create.require-description")
            printf '%s\n' 'false'
            ;;
          "--readonly config get validation.on-create")
            printf '%s\n' 'none'
            ;;
          "config set validation.on-create warn")
            printf '%s\n' "$*" >> '\(logURL.path)'
            ;;
          *)
            exit 2
            ;;
        esac
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        try await service.saveCreationValidationSettings(
            projectURL: projectURL,
            settings: BeadsCreationValidationSettings(
                requiresDescription: false,
                mode: .warn
            )
        )

        XCTAssertEqual(
            try String(contentsOf: logURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "config set validation.on-create warn"
        )
    }

    func testProjectContextIncludesAuthoritativeIssuePrefixFromWhere() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        case "$*" in
          "--readonly context --json")
            printf '%s\n' '{"backend":"dolt","database":"database-name","dolt_mode":"embedded"}'
            ;;
          "--readonly where --json")
            printf '%s\n' '{"prefix":"actual-prefix"}'
            ;;
          *)
            exit 2
            ;;
        esac
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        let context = try await service.loadProjectContext(projectURL: projectURL)

        XCTAssertEqual(context.issuePrefix, "actual-prefix")
        XCTAssertEqual(context.database, "database-name")
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

    func testPreparedExportReturnsDecodedSnapshotAndSkipsIdenticalReplacement() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let snapshotURL = BeadsCommandService.exportedIssuesJSONLURL(projectURL: projectURL)
        let contents = """
        {"_type":"issue","id":"bd-existing","title":"Existing","status":"open","priority":1,"issue_type":"task"}
        """ + "\n"
        try contents.write(to: snapshotURL, atomically: true, encoding: .utf8)
        let originalModificationDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: snapshotURL.path
        )
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output" ]; then
            shift
            printf '%s\n' '{"_type":"issue","id":"bd-existing","title":"Existing","status":"open","priority":1,"issue_type":"task"}' > "$1"
            exit 0
          fi
          shift
        done
        exit 2
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        let result = try await service.exportReadableSnapshotWithResult(
            projectURL: projectURL,
            beadsDirectoryURL: projectURL.appendingPathComponent(".beads", isDirectory: true)
        )

        XCTAssertFalse(result.didReplaceSnapshot)
        XCTAssertEqual(result.loadedSnapshot?.snapshot.issues.map(\.id), ["bd-existing"])
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, originalModificationDate)
        XCTAssertTrue(temporaryExportFiles(in: projectURL).isEmpty)
    }

    func testPreparedExportReturnsInstalledSourceAfterReplacement() async throws {
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
            printf '%s\n' '{"_type":"issue","id":"bd-new","title":"New","status":"open","priority":1,"issue_type":"task"}' > "$1"
            exit 0
          fi
          shift
        done
        exit 2
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        let result = try await service.exportReadableSnapshotWithResult(
            projectURL: projectURL,
            beadsDirectoryURL: projectURL.appendingPathComponent(".beads", isDirectory: true)
        )

        XCTAssertTrue(result.didReplaceSnapshot)
        XCTAssertEqual(result.loadedSnapshot?.source.url, snapshotURL)
        XCTAssertEqual(result.loadedSnapshot?.snapshot.issues.map(\.id), ["bd-new"])
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
                .contains(where: isTemporarySnapshotArtifact)
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

    func testCancelledExportCannotRecreateTemporaryFileAfterCleanup() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        let snapshotURL = BeadsCommandService.exportedIssuesJSONLURL(projectURL: projectURL)
        let readyMarkerURL = beadsURL.appendingPathComponent("export-ready")
        let terminationMarkerURL = beadsURL.appendingPathComponent("export-terminated")
        let existing = """
        {"_type":"issue","id":"bd-existing","title":"Existing","status":"open","priority":1,"issue_type":"task"}
        """
        try existing.write(to: snapshotURL, atomically: true, encoding: .utf8)
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        output_path=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output" ]; then
            shift
            output_path="$1"
            break
          fi
          shift
        done
        hidden_path="${output_path%/*}/.~${output_path##*/}.atomic"
        ready_path="${output_path%/*}/export-ready"
        marker_path="${output_path%/*}/export-terminated"
        printf '%s\n' '{"_type":"issue","id":"bd-late","title":"Late","status":"open","priority":1,"issue_type":"task"}' > "$hidden_path"
        trap 'mv "$hidden_path" "$output_path"; printf terminated > "$marker_path"; exit 143' TERM
        printf ready > "$ready_path"
        while :; do :; done
        """)
        let service = BeadsCommandService(
            snapshotExportTimeout: .seconds(10),
            executable: { (stubURL, []) }
        )
        let exportTask = Task {
            try await service.exportReadableSnapshot(projectURL: projectURL)
        }

        let didStart = try await waitForFile(at: readyMarkerURL)
        XCTAssertTrue(didStart)
        exportTask.cancel()
        do {
            try await exportTask.value
            XCTFail("Expected snapshot export to be cancelled.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        let didTerminate = try await waitForFile(at: terminationMarkerURL)
        XCTAssertTrue(didTerminate)
        XCTAssertEqual(try String(contentsOf: snapshotURL, encoding: .utf8), existing)
        XCTAssertTrue(temporaryExportFiles(in: projectURL).isEmpty)
    }

    func testExportReadableSnapshotPrunesOnlyStaleRegularArtifactsFromInterruptedRuns() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        let staleUUID = UUID().uuidString
        let staleExplicitURL = beadsURL.appendingPathComponent("issues.jsonl.tmp.\(staleUUID)")
        let staleNestedURL = beadsURL.appendingPathComponent(".~issues.jsonl.tmp.\(staleUUID).atomic")
        let staleInstalledAtomicURL = beadsURL.appendingPathComponent(".~issues.jsonl.4211240985")
        let recentURL = beadsURL.appendingPathComponent("issues.jsonl.tmp.\(UUID().uuidString)")
        let recentInstalledAtomicURL = beadsURL.appendingPathComponent(".~issues.jsonl.1429845796")
        let unrelatedURL = beadsURL.appendingPathComponent("issues.jsonl.tmp.not-a-uuid")
        let unrelatedAtomicURL = beadsURL.appendingPathComponent(".~issues.jsonl.notes")
        let directoryURL = beadsURL.appendingPathComponent("issues.jsonl.tmp.\(UUID().uuidString)")
        let directoryContentsURL = directoryURL.appendingPathComponent("keep-me")
        let symlinkTargetURL = beadsURL.appendingPathComponent("symlink-target")
        let symlinkURL = beadsURL.appendingPathComponent("issues.jsonl.tmp.\(UUID().uuidString)")
        for url in [
            staleExplicitURL,
            staleNestedURL,
            staleInstalledAtomicURL,
            recentURL,
            recentInstalledAtomicURL,
            unrelatedURL,
            unrelatedAtomicURL
        ] {
            try "temporary".write(to: url, atomically: false, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        try "keep me".write(to: directoryContentsURL, atomically: false, encoding: .utf8)
        try "target".write(to: symlinkTargetURL, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: symlinkTargetURL)
        let staleDate = Date(timeIntervalSinceNow: -3_600)
        for url in [
            staleExplicitURL,
            staleNestedURL,
            staleInstalledAtomicURL,
            unrelatedURL,
            unrelatedAtomicURL,
            directoryURL
        ] {
            try FileManager.default.setAttributes(
                [.modificationDate: staleDate],
                ofItemAtPath: url.path
            )
        }

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

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleExplicitURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleNestedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleInstalledAtomicURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentInstalledAtomicURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedAtomicURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryContentsURL.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path),
            symlinkTargetURL.path
        )
        XCTAssertEqual(try String(contentsOf: symlinkTargetURL, encoding: .utf8), "target")
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

        try await service.pullDoltRemote(projectURL: projectURL, remote: nil)
        try await service.pushDoltRemote(projectURL: projectURL, remote: nil)

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
            try await service.pushDoltRemote(projectURL: projectURL, remote: nil)
            XCTFail("Expected Dolt push to use the remote-sync timeout.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Timed out waiting for `bd` to finish."))
        }
    }

    func testDoltSyncBoundsRetainedVerboseOutput() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        /usr/bin/yes verbose-remote-output | /usr/bin/head -c 700000 >&2
        exit 1
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        do {
            try await service.pushDoltRemote(projectURL: projectURL, remote: nil)
            XCTFail("Expected the verbose remote command to fail.")
        } catch let BeadError.commandFailed(command, output) {
            XCTAssertEqual(command, "bd dolt push")
            XCTAssertTrue(output.hasPrefix("[Earlier command output omitted]"))
            XCTAssertLessThan(output.utf8.count, 513 * 1_024)
            XCTAssertTrue(output.contains("verbose-remote-output"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDoltMaintenancePreviewDecodesCurrentCompactAndFlattenSchemas() throws {
        let compact = try BeadsDoltCompactPreview.decode(from: """
        {"total_commits":160,"old_commits":42,"recent_commits":118,"cutoff_days":30}
        """)
        let flatten = try BeadsDoltFlattenPreview.decode(from: """
        {"commit_count":160,"would_flatten":true,"remote_refs":["remotes/origin/main"],"tags":["release-1"],"size_before_bytes":2048}
        """)
        let flattenWithoutReferenceDetails = try BeadsDoltFlattenPreview.decode(from: """
        {"commit_count":12,"would_flatten":true}
        """)

        XCTAssertEqual(compact.totalCommits, 160)
        XCTAssertEqual(compact.oldCommits, 42)
        XCTAssertEqual(compact.recentCommits, 118)
        XCTAssertEqual(compact.cutoffDays, 30)
        XCTAssertEqual(flatten.commitCount, 160)
        XCTAssertTrue(flatten.wouldFlatten)
        XCTAssertEqual(flatten.remoteRefs, ["remotes/origin/main"])
        XCTAssertEqual(flatten.tags, ["release-1"])
        XCTAssertEqual(flatten.sizeBeforeBytes, 2_048)
        XCTAssertNil(flattenWithoutReferenceDetails.remoteRefs)
        XCTAssertNil(flattenWithoutReferenceDetails.tags)
        XCTAssertNil(flattenWithoutReferenceDetails.sizeBeforeBytes)
    }

    func testDoltMaintenanceUsesDryRunProbesAndExplicitForcedWrites() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let logURL = projectURL.appendingPathComponent("commands.log")
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        printf '%s\n' "$*" >> "$PWD/commands.log"
        case "$*" in
          "--readonly compact --dry-run --json")
            printf '%s\n' '{"total_commits":12,"old_commits":5,"recent_commits":7,"cutoff_days":30}'
            ;;
          "--readonly flatten --dry-run --json")
            printf '%s\n' '{"commit_count":12,"would_flatten":true}'
            ;;
        esac
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        let preview = await service.loadDoltMaintenancePreview(projectURL: projectURL)
        try await service.compactDoltDatabase(projectURL: projectURL, retainingDays: 30)
        try await service.flattenDoltDatabase(projectURL: projectURL)

        XCTAssertEqual(preview.compact.value?.oldCommits, 5)
        XCTAssertEqual(preview.flatten.value?.commitCount, 12)
        let commands = try String(contentsOf: logURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertTrue(commands.contains("--readonly compact --dry-run --json"))
        XCTAssertTrue(commands.contains("--readonly flatten --dry-run --json"))
        XCTAssertTrue(commands.contains("--sandbox compact --days 30 --force --json"))
        XCTAssertTrue(commands.contains("--sandbox flatten --force --json"))
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

    func testSetupInspectionRunsBootstrapInReadonlyMode() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        case "$*" in
          "--readonly bootstrap --dry-run --json")
            printf '%s\n' '{"action":"none","has_existing":false}'
            exit 1
            ;;
          *)
            exit 2
            ;;
        esac
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        let assessment = try await service.inspectSetup(
            projectURL: projectURL,
            scope: .wizard,
            candidateRemote: nil,
            preloadedEnvironment: nil
        )

        XCTAssertFalse(assessment.isInitialized)
    }

    func testSetupInspectionGitProbesUseResolvedBDToolchainDirectory() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let originPathLogURL = projectURL.appendingPathComponent("git-origin-path.log")
        let upstreamPathLogURL = projectURL.appendingPathComponent("git-upstream-path.log")
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        case "$*" in
          "--readonly bootstrap --dry-run --json")
            printf '%s\\n' '{"action":"none","has_existing":false}'
            exit 1
            ;;
          *)
            exit 2
            ;;
        esac
        """)
        let gitURL = projectURL.appendingPathComponent("git")
        try """
        #!/bin/sh
        case "$*" in
          "remote get-url origin")
            printf '%s\\n' "$PATH" > "\(originPathLogURL.path)"
            ;;
          "remote get-url upstream")
            printf '%s\\n' "$PATH" > "\(upstreamPathLogURL.path)"
            ;;
          *)
            exit 2
            ;;
        esac
        printf '%s\\n' 'dolthub://example/project'
        """.write(to: gitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: gitURL.path
        )

        let service = BeadsCommandService(executable: { (stubURL, []) })
        _ = try await service.inspectSetup(
            projectURL: projectURL,
            scope: .wizard,
            candidateRemote: nil,
            preloadedEnvironment: nil
        )

        let paths = try [originPathLogURL, upstreamPathLogURL].map {
            try String(contentsOf: $0, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let expectedToolchainDirectory = stubURL.deletingLastPathComponent().path
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(
            paths.allSatisfy {
                $0.split(separator: ":").first == Substring(expectedToolchainDirectory)
            },
            "Expected the resolved bd directory first in every Git PATH: \(paths)"
        )
    }

    func testSetupInspectionPrefersReadableLocalDatabaseOverBootstrapAdvice() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        case "$*" in
          "--readonly bootstrap --dry-run --json")
            printf '%s\n' '{"action":"sync","has_existing":false,"database":"sales_radar"}'
            ;;
          "--readonly context --json")
            printf '%s\n' '{"backend":"dolt","beads_dir":".beads","database":"sales_radar","dolt_mode":"embedded","role":"maintainer"}'
            ;;
          "--readonly count --json")
            printf '%s\n' '{"count":223}'
            ;;
          "--readonly config show --json")
            printf '%s\n' '[]'
            ;;
          "--readonly dolt remote list --json")
            printf '%s\n' '[]'
            ;;
          "--readonly hooks list")
            printf '%s\n' 'pre-commit: installed'
            ;;
          "--readonly backup status --json")
            printf '%s\n' '{}'
            ;;
          *)
            exit 2
            ;;
        esac
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })

        let assessment = try await service.inspectSetup(
            projectURL: projectURL,
            scope: .wizard,
            candidateRemote: nil,
            preloadedEnvironment: nil
        )
        let plan = BeadsSetupPlanner.plan(
            draft: BeadsSetupDraft(profile: .local),
            assessment: assessment
        )

        XCTAssertTrue(assessment.isInitialized)
        XCTAssertFalse(plan.steps.contains { $0.id == "bootstrap" || $0.id == "initialize" })
    }

    func testReviewedSetupCommandUsesTheExactArgumentsThatRun() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let argumentsURL = projectURL.appendingPathComponent("setup-arguments.txt")
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        printf '%s\n' "$@" > "\(argumentsURL.path)"
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })
        let operation = BeadsSetupOperation.initializeBackup(destination: "/tmp/Team's Backup")
        let step = BeadsSetupStep(
            id: "backup",
            title: "Configure backup",
            detail: "Configure the reviewed destination.",
            scopes: [.checkoutLocal],
            operation: operation
        )

        _ = try await service.applySetup(
            projectURL: projectURL,
            plan: BeadsSetupPlan(profile: .advanced, findings: [], steps: [step]),
            cancellationToken: BeadsSetupCancellationToken()
        )

        let executedArguments = try String(contentsOf: argumentsURL, encoding: .utf8)
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        XCTAssertEqual(executedArguments, operation.arguments)
        XCTAssertEqual(
            step.command,
            ShellCommand.render(executable: "bd", arguments: executedArguments)
        )
    }

    func testSetupFailureReportsStepsThatAlreadyCompleted() async throws {
        let projectURL = try makeProjectWithBeadsDirectory()
        let stubURL = try makeExecutableScript(in: projectURL, contents: """
        #!/bin/sh
        if [ "$*" = "--sandbox hooks install" ]; then
          exit 9
        fi
        """)
        let service = BeadsCommandService(executable: { (stubURL, []) })
        let events = BeadsSetupCommandEventRecorder()
        let steps = [
            BeadsSetupStep(
                id: "config",
                title: "Set configuration",
                detail: "Set configuration.",
                scopes: [.gitTracked],
                operation: .setConfig(key: "dolt.auto-push", value: "false")
            ),
            BeadsSetupStep(
                id: "hooks",
                title: "Install hooks",
                detail: "Install hooks.",
                scopes: [.checkoutLocal],
                operation: .installHooks
            )
        ]

        do {
            _ = try await service.applySetup(
                projectURL: projectURL,
                plan: BeadsSetupPlan(profile: .team, findings: [], steps: steps),
                cancellationToken: BeadsSetupCancellationToken()
            ) { event in
                await events.record(event)
            }
            XCTFail("Expected the second setup step to fail")
        } catch let failure as BeadsSetupApplyFailure {
            XCTAssertEqual(failure.report.completedStepIDs, ["config"])
            XCTAssertTrue(failure.localizedDescription.contains("1 setup change completed"))
        }
        let recordedEvents = await events.events
        XCTAssertEqual(recordedEvents, [
            .stepStarted("config"),
            .stepCompleted("config"),
            .stepStarted("hooks"),
            .stepFailed("hooks")
        ])
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
            .filter(isTemporarySnapshotArtifact) ?? []
    }

    private func isTemporarySnapshotArtifact(_ name: String) -> Bool {
        name.hasPrefix("issues.jsonl.tmp.") || name.hasPrefix(".~issues.jsonl.")
    }

    private func waitForFile(at url: URL, timeout: Duration = .seconds(1)) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !FileManager.default.fileExists(atPath: url.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: url.path)
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
