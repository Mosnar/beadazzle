import XCTest
@testable import Beadazzle

final class ProjectPreflightHealthTests: XCTestCase {
    func testReadyProjectAllowsOptionalBackupWithoutWarningOverall() {
        let fixture = PreflightFixture()
        let health = fixture.health(
            hooks: BeadsHooksStatus(hooks: [
                BeadsHooksStatus.Hook(name: "pre-commit", state: .installed, detail: "installed")
            ]),
            backup: BeadsBackupStatus(
                backup: nil,
                databaseSize: nil,
                dolt: BeadsBackupStatus.DoltDestination(configured: false)
            )
        )

        let preflight = ProjectPreflightHealth.evaluate(
            projectURL: fixture.projectURL,
            missingDataSourceURL: nil,
            activeDataSource: fixture.jsonlSource,
            snapshotFreshness: fixture.freshness,
            health: health,
            automaticallyRefreshesExternalChanges: true,
            isLoading: false
        )

        XCTAssertEqual(preflight.status, .ready)
        XCTAssertEqual(preflight.check(.bdCLI)?.status, .ready)
        XCTAssertEqual(preflight.check(.readableData)?.status, .ready)
        XCTAssertEqual(preflight.check(.snapshotFreshness)?.status, .ready)
        XCTAssertEqual(preflight.check(.exportConfiguration)?.status, .ready)
        XCTAssertEqual(preflight.check(.gitHooks)?.status, .ready)
        XCTAssertEqual(preflight.check(.backup)?.status, .info)
    }

    func testBdContextFailureBlocksPreflight() {
        let fixture = PreflightFixture()
        var health = fixture.health()
        health.context = .unavailable("bd: command not found")

        let preflight = ProjectPreflightHealth.evaluate(
            projectURL: fixture.projectURL,
            missingDataSourceURL: nil,
            activeDataSource: fixture.jsonlSource,
            snapshotFreshness: fixture.freshness,
            health: health,
            automaticallyRefreshesExternalChanges: true,
            isLoading: false
        )

        XCTAssertEqual(preflight.status, .blocked)
        XCTAssertEqual(preflight.check(.bdCLI)?.status, .blocked)
        XCTAssertEqual(preflight.check(.bdCLI)?.actionHint, "Choose a bd executable in Settings.")
    }

    func testStaleSnapshotAndMissingHooksWarnWithoutBlocking() {
        let fixture = PreflightFixture()
        let freshness = ProjectSnapshotFreshness(
            state: .possiblyStale,
            message: "Snapshot may be stale",
            detail: "A Beads export marker changed before the readable snapshot changed.",
            evaluatedAt: Date(timeIntervalSinceReferenceDate: 0),
            loadedFiles: nil,
            observedFiles: nil
        )
        let health = fixture.health(
            hooks: BeadsHooksStatus(hooks: [
                BeadsHooksStatus.Hook(name: "pre-commit", state: .missing, detail: "not installed")
            ])
        )

        let preflight = ProjectPreflightHealth.evaluate(
            projectURL: fixture.projectURL,
            missingDataSourceURL: nil,
            activeDataSource: fixture.jsonlSource,
            snapshotFreshness: freshness,
            health: health,
            automaticallyRefreshesExternalChanges: true,
            isLoading: false
        )

        XCTAssertEqual(preflight.status, .warning)
        XCTAssertEqual(preflight.check(.snapshotFreshness)?.status, .warning)
        XCTAssertEqual(preflight.check(.snapshotFreshness)?.actionHint, "Export Snapshot")
        XCTAssertEqual(preflight.check(.gitHooks)?.status, .warning)
        XCTAssertEqual(preflight.check(.gitHooks)?.actionHint, "Install Hooks")
    }

    func testMissingBeadsDataBlocksReadiness() {
        let fixture = PreflightFixture()

        let preflight = ProjectPreflightHealth.evaluate(
            projectURL: fixture.projectURL,
            missingDataSourceURL: fixture.projectURL,
            activeDataSource: nil,
            snapshotFreshness: .unknown,
            health: nil,
            automaticallyRefreshesExternalChanges: true,
            isLoading: false
        )

        XCTAssertEqual(preflight.status, .blocked)
        XCTAssertEqual(preflight.check(.readableData)?.status, .blocked)
        XCTAssertEqual(preflight.check(.readableData)?.summary, "Beads is not initialized")
        XCTAssertEqual(preflight.check(.snapshotFreshness)?.status, .blocked)
    }

    func testDisabledBdAutoExportIsReadyWhenBeadazzleRefreshesExternalChanges() {
        let fixture = PreflightFixture()
        let preflight = ProjectPreflightHealth.evaluate(
            projectURL: fixture.projectURL,
            missingDataSourceURL: nil,
            activeDataSource: fixture.jsonlSource,
            snapshotFreshness: fixture.freshness,
            health: fixture.health(exportAuto: false),
            automaticallyRefreshesExternalChanges: true,
            isLoading: false
        )

        XCTAssertEqual(preflight.check(.exportConfiguration)?.status, .ready)
        XCTAssertEqual(
            preflight.check(.exportConfiguration)?.summary,
            "Beadazzle refreshes external changes"
        )
    }

    func testDisabledAutomaticExportsWarnWhenBeadazzleRefreshIsOff() {
        let fixture = PreflightFixture()
        let preflight = ProjectPreflightHealth.evaluate(
            projectURL: fixture.projectURL,
            missingDataSourceURL: nil,
            activeDataSource: fixture.jsonlSource,
            snapshotFreshness: fixture.freshness,
            health: fixture.health(exportAuto: false),
            automaticallyRefreshesExternalChanges: false,
            isLoading: false
        )

        XCTAssertEqual(preflight.check(.exportConfiguration)?.status, .warning)
        XCTAssertEqual(
            preflight.check(.exportConfiguration)?.actionHint,
            "Enable automatic external refresh or export.auto."
        )
    }
}

private extension ProjectPreflightHealth {
    func check(_ id: CheckID) -> Check? {
        checks.first { $0.id == id }
    }
}

private struct PreflightFixture {
    let projectURL = URL(fileURLWithPath: "/tmp/PreflightProject")
    let jsonlSource: BeadsDataSource
    let freshness: ProjectSnapshotFreshness

    init() {
        let sourceURL = projectURL
            .appendingPathComponent(".beads", isDirectory: true)
            .appendingPathComponent("issues.jsonl")
        jsonlSource = BeadsDataSource(
            kind: .jsonl,
            url: sourceURL,
            size: 64,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        freshness = .loaded(projectURL: projectURL, source: jsonlSource)
    }

    func health(
        exportAuto: Bool = true,
        hooks: BeadsHooksStatus = BeadsHooksStatus(hooks: []),
        backup: BeadsBackupStatus = BeadsBackupStatus(
            backup: BeadsBackupStatus.Backup(lastDoltCommit: "commit", timestamp: "2026-07-08T13:35:44.99568Z"),
            databaseSize: BeadsBackupStatus.DatabaseSize(bytes: 10, human: "10 B"),
            dolt: BeadsBackupStatus.DoltDestination(configured: true)
        )
    ) -> ProjectHealthSnapshot {
        ProjectHealthSnapshot(
            loadedAt: Date(timeIntervalSinceReferenceDate: 0),
            context: .available(BeadsProjectContext(
                backend: "dolt",
                bdVersion: "1.0.4",
                beadsDirectory: projectURL.appendingPathComponent(".beads", isDirectory: true).path,
                cwdRepoRoot: projectURL.path,
                database: "PreflightProject",
                doltMode: "embedded",
                isRedirected: false,
                isWorktree: false,
                projectID: "project-id",
                repoRoot: projectURL.path,
                role: "maintainer",
                schemaVersion: 1
            )),
            storageConfig: .available(ProjectStorageConfig(
                exportAuto: exportAuto,
                exportPath: "issues.jsonl",
                exportInterval: "60s",
                exportGitAdd: true,
                importAuto: false,
                federationRemote: nil
            )),
            hooks: .available(hooks),
            backup: .available(backup),
            snapshotFile: ProjectSnapshotFileStatus(
                url: jsonlSource.url,
                exists: true,
                size: jsonlSource.size,
                modifiedAt: jsonlSource.modifiedAt,
                activeDataSource: jsonlSource
            )
        )
    }
}
