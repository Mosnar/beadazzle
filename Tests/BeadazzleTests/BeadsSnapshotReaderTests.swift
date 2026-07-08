import CSQLite
import XCTest
@testable import Beadazzle

final class BeadsSnapshotReaderTests: XCTestCase {
    func testJSONLIssueParsingReadsParentID() {
        let reader = BeadsSnapshotReader()

        let issues = reader.loadJSONLIssuesForTesting(records: [
            [
                "_type": "issue",
                "id": "bd-child",
                "title": "Child",
                "status": "open",
                "issue_type": "task",
                "parent_id": "bd-parent"
            ]
        ])

        XCTAssertEqual(issues.first?.parentID, "bd-parent")
    }

    func testJSONLIssueParsingFallsBackToParentField() {
        let reader = BeadsSnapshotReader()

        let issues = reader.loadJSONLIssuesForTesting(records: [
            [
                "_type": "issue",
                "id": "bd-child",
                "title": "Child",
                "status": "open",
                "issue_type": "task",
                "parent": "bd-parent"
            ]
        ])

        XCTAssertEqual(issues.first?.parentID, "bd-parent")
    }

    func testJSONLIssueParsingReadsGateFields() throws {
        let reader = BeadsSnapshotReader()

        let issues = reader.loadJSONLIssuesForTesting(records: [
            [
                "_type": "issue",
                "id": "bd-gate",
                "title": "Release gate",
                "description": "Ad-hoc gate blocking bd-target\n\nReason: Ship review",
                "status": "open",
                "issue_type": "gate",
                "await_type": "timer",
                "await_id": "run-42",
                "timeout": 3_600_000_000_000,
                "created_at": "2026-07-03T20:58:35Z",
                "updated_at": "2026-07-03T21:58:35Z"
            ]
        ])

        let issue = try XCTUnwrap(issues.first)
        XCTAssertTrue(issue.isGate)
        XCTAssertEqual(issue.gateAwaitType, .timer)
        XCTAssertEqual(issue.gateAwaitID, "run-42")
        XCTAssertEqual(issue.gateTimeoutNanoseconds, 3_600_000_000_000)

        let gate = try XCTUnwrap(BeadGate(issue: issue))
        XCTAssertEqual(gate.awaitType, .timer)
        XCTAssertEqual(gate.awaitID, "run-42")
        XCTAssertEqual(gate.timeoutNanoseconds, 3_600_000_000_000)
        XCTAssertEqual(gate.reason, "Ship review")
        XCTAssertEqual(gate.blocksIssueID, "bd-target")
    }

    func testPopulatedSQLiteWinsOverJSONL() throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": issueLine(id: "bd-jsonl", title: "From JSONL")
        ])
        try createSQLiteDatabase(at: projectURL.appendingPathComponent(".beads/beads.db"), issueID: "bd-sqlite")

        let loaded = try BeadsSnapshotReader().loadProject(projectURL: projectURL)

        XCTAssertEqual(loaded.source.kind, .sqlite)
        XCTAssertEqual(loaded.snapshot.issues.map(\.id), ["bd-sqlite"])
    }

    func testEmptySQLiteFallsBackToJSONL() throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": issueLine(id: "bd-jsonl", title: "From JSONL")
        ])
        FileManager.default.createFile(
            atPath: projectURL.appendingPathComponent(".beads/beads.db").path,
            contents: nil
        )

        let loaded = try BeadsSnapshotReader().loadProject(projectURL: projectURL)

        XCTAssertEqual(loaded.source.kind, .jsonl)
        XCTAssertEqual(loaded.source.url.lastPathComponent, "issues.jsonl")
        XCTAssertEqual(loaded.snapshot.issues.map(\.id), ["bd-jsonl"])
    }

    func testJSONLFilenamePriorityIsDeterministic() throws {
        let projectURL = try makeProject(jsonlFiles: [
            "beads.base.jsonl": issueLine(id: "bd-base", title: "Base"),
            "beads.jsonl": issueLine(id: "bd-legacy", title: "Legacy"),
            "issues.jsonl": issueLine(id: "bd-current", title: "Current")
        ])

        let source = try BeadsDataSourceDiscovery().discover(projectURL: projectURL)

        XCTAssertEqual(source.kind, .jsonl)
        XCTAssertEqual(source.url.lastPathComponent, "issues.jsonl")
    }

    func testMissingSourcesReturnClearError() throws {
        let projectURL = try makeProject(jsonlFiles: [:])

        XCTAssertThrowsError(try BeadsDataSourceDiscovery().discover(projectURL: projectURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("No readable Beads snapshot"))
        }
    }

    func testEmptyJSONLLoadsAsEmptySnapshot() throws {
        let projectURL = try makeProject(jsonlFiles: ["issues.jsonl": ""])

        let loaded = try BeadsSnapshotReader().loadProject(projectURL: projectURL)

        XCTAssertEqual(loaded.source.kind, .jsonl)
        XCTAssertEqual(loaded.source.url.lastPathComponent, "issues.jsonl")
        XCTAssertTrue(loaded.snapshot.issues.isEmpty)
        XCTAssertTrue(loaded.snapshot.dependencies.isEmpty)
        XCTAssertTrue(loaded.snapshot.commentsByIssueID.isEmpty)
    }

    func testJSONLSnapshotParsesNestedDataAndSkipsNonIssueRecords() throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": """
            {"_type":"memory","id":"memory-1","content":"ignore me"}
            {"id":"bd-jsonl","title":"JSONL issue","status":"open","priority":1,"issue_type":"task","parent":"bd-parent","due_at":"2026-07-09","defer_until":"2026-07-10T12:00:00Z","labels":["ui","reader"],"dependencies":[{"issue_id":"bd-jsonl","depends_on_id":"bd-parent","type":"parent-child","created_at":"2026-07-03T20:58:35Z"}],"comments":[{"id":"comment-1","issueId":"bd-jsonl","author":"Riley","body":"Body field","createdAt":"2026-07-03T20:58:35.123Z","updatedAt":"2026-07-03T21:01:00Z"}]}
            """
        ])

        let loaded = try BeadsSnapshotReader().loadProject(projectURL: projectURL)
        let issue = try XCTUnwrap(loaded.snapshot.issues.first)

        XCTAssertEqual(loaded.source.kind, .jsonl)
        XCTAssertEqual(loaded.snapshot.issues.count, 1)
        XCTAssertEqual(issue.id, "bd-jsonl")
        XCTAssertEqual(issue.parentID, "bd-parent")
        XCTAssertEqual(issue.labels, ["reader", "ui"])
        XCTAssertEqual(BeadFormatters.commandDate(issue.dueAt), "2026-07-09")
        XCTAssertNotNil(issue.deferUntil)
        XCTAssertEqual(loaded.snapshot.dependencies.map(\.type), ["parent-child"])
        XCTAssertEqual(loaded.snapshot.commentsByIssueID["bd-jsonl"]?.first?.text, "Body field")
    }

    func testJSONLSnapshotSkipsMalformedLines() throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": """
            not-json
            {"_type":"issue","id":"bd-good","title":"Good","status":"open","priority":1,"issue_type":"task"}
            """
        ])

        let loaded = try BeadsSnapshotReader().loadProject(projectURL: projectURL)

        XCTAssertEqual(loaded.snapshot.issues.map(\.id), ["bd-good"])
    }

    func testJSONLStreamingHandlesFinalLineWithoutTrailingNewline() throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": [
                issueLine(id: "bd-first", title: "First"),
                """
                {"_type":"issue","id":"bd-final","title":"Final","status":"open","priority":1,"issue_type":"task","dependencies":[{"depends_on_id":"bd-first","type":"blocks"}],"comments":[{"body":"final comment"}]}
                """
            ].joined(separator: "\n")
        ])

        let loaded = try BeadsSnapshotReader().loadProject(projectURL: projectURL)

        XCTAssertEqual(loaded.snapshot.issues.map(\.id), ["bd-first", "bd-final"])
        XCTAssertEqual(loaded.snapshot.dependencies.first?.issueID, "bd-final")
        XCTAssertEqual(loaded.snapshot.dependencies.first?.dependsOnID, "bd-first")
        XCTAssertEqual(loaded.snapshot.commentsByIssueID["bd-final"]?.first?.text, "final comment")
    }

    func testJSONLStreamingReadsLargeFilesLineByLine() throws {
        let contents = (0..<2_000)
            .map { issueLine(id: "bd-\($0)", title: "Issue \($0)") }
            .joined(separator: "\n")
        let projectURL = try makeProject(jsonlFiles: ["issues.jsonl": contents])

        let loaded = try BeadsSnapshotReader().loadProject(projectURL: projectURL)

        XCTAssertEqual(loaded.snapshot.issues.count, 2_000)
        XCTAssertEqual(loaded.snapshot.issues.last?.id, "bd-1999")
    }

    func testJSONLSnapshotSkipsIssueRecordsWithoutIDs() throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": """
            {"_type":"issue","title":"Missing ID","status":"open","priority":1,"issue_type":"task"}
            {"_type":"issue","id":"bd-good","title":"Good","status":"open","priority":1,"issue_type":"task"}
            """
        ])

        let loaded = try BeadsSnapshotReader().loadProject(projectURL: projectURL)

        XCTAssertEqual(loaded.snapshot.issues.map(\.id), ["bd-good"])
    }

    func testSQLiteSnapshotLoadsDependenciesCommentsAndLabels() throws {
        let projectURL = try makeProject(jsonlFiles: [:])
        try createSQLiteDatabase(
            at: projectURL.appendingPathComponent(".beads/beads.db"),
            issueID: "bd-sqlite",
            includeRelatedRecords: true
        )

        let loaded = try BeadsSnapshotReader().loadProject(projectURL: projectURL)
        let issue = try XCTUnwrap(loaded.snapshot.issues.first { $0.id == "bd-sqlite" })

        XCTAssertEqual(loaded.source.kind, .sqlite)
        XCTAssertEqual(issue.labels, ["reader", "sqlite"])
        XCTAssertEqual(issue.dependencyCount, 1)
        XCTAssertEqual(issue.commentCount, 1)
        XCTAssertEqual(loaded.snapshot.dependencies.first?.dependsOnID, "bd-blocker")
        XCTAssertEqual(loaded.snapshot.commentsByIssueID["bd-sqlite"]?.first?.text, "SQLite comment")
    }

    func testSourceDiscoverySwitchesFromJSONLToPopulatedSQLite() throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": issueLine(id: "bd-jsonl", title: "From JSONL")
        ])
        let discovery = BeadsDataSourceDiscovery()

        XCTAssertEqual(try discovery.discover(projectURL: projectURL).kind, .jsonl)

        try createSQLiteDatabase(at: projectURL.appendingPathComponent(".beads/beads.db"), issueID: "bd-sqlite")

        XCTAssertEqual(try discovery.discover(projectURL: projectURL).kind, .sqlite)
    }

    func testDataSourceMonitorDebouncesRapidFileEvents() async throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": issueLine(id: "bd-1", title: "One")
        ])
        let source = try BeadsDataSourceDiscovery().discover(projectURL: projectURL)
        let callbackExpectation = expectation(description: "debounced callback")
        callbackExpectation.expectedFulfillmentCount = 1
        callbackExpectation.assertForOverFulfill = true

        let monitor = BeadsDataSourceMonitor(projectURL: projectURL, source: source, debounce: 0.15) { _ in
            callbackExpectation.fulfill()
        }
        monitor.start()
        try await Task.sleep(nanoseconds: 100_000_000)

        try writeJSONL(
            issueLine(id: "bd-1", title: "One updated"),
            to: source.url
        )
        try writeJSONL(
            issueLine(id: "bd-1", title: "One updated again"),
            to: source.url
        )

        await fulfillment(of: [callbackExpectation], timeout: 2.0)
        try await Task.sleep(nanoseconds: 250_000_000)
        monitor.stop()
    }

    @MainActor
    func testStoreManualRefreshPrunesDeletedSelectionAndPreservesFilters() async throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": [
                issueLine(id: "bd-keep", title: "Keep"),
                issueLine(id: "bd-delete", title: "Delete")
            ].joined(separator: "\n")
        ])
        let store = BeadStore(userDefaults: makeUserDefaults())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.count(for: .all) == 2 }

        store.applyBookmark(.all)
        store.setStatusFilter("open", isOn: true)
        store.select(["bd-delete"])

        try writeJSONL(issueLine(id: "bd-keep", title: "Keep"), to: projectURL.appendingPathComponent(".beads/issues.jsonl"))
        store.refresh()
        try await waitUntil { !store.isLoading && store.count(for: .all) == 1 }

        XCTAssertEqual(store.selectedIDs, [])
        XCTAssertEqual(store.statusFilters, ["open"])
    }

    @MainActor
    func testStoreMarksMissingDataSourceWithoutAlert() throws {
        let projectURL = try makeDirectoryWithoutBeads()
        let store = BeadStore(userDefaults: makeUserDefaults())

        store.openProject(projectURL)

        XCTAssertEqual(store.projectReadiness, .missingDataSource(projectURL.standardizedFileURL))
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.currentDataSource, nil)
        XCTAssertEqual(store.recentProjects.first?.path, projectURL.standardizedFileURL.path)
    }

    @MainActor
    func testStoreRecoversInitializedProjectMissingSnapshotByExportingJSONL() async throws {
        let projectURL = try makeProject(jsonlFiles: [:])
        let store = BeadStore(
            userDefaults: makeUserDefaults(),
            commands: TestBeadsCommands { projectURL in
                try "".write(
                    to: projectURL.appendingPathComponent(".beads/issues.jsonl"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        )

        store.openProject(projectURL)

        try await waitUntil {
            !store.isLoading && store.projectReadiness == .ready && store.currentDataSource?.kind == .jsonl
        }
        XCTAssertTrue(store.issues.isEmpty)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testStoreReportsSnapshotRecoveryFailure() async throws {
        let projectURL = try makeProject(jsonlFiles: [:])
        let store = BeadStore(
            userDefaults: makeUserDefaults(),
            commands: TestBeadsCommands { _ in
                throw TestProjectCommandError.exportFailed
            }
        )

        store.openProject(projectURL)

        try await waitUntil {
            !store.isLoading && store.lastError == TestProjectCommandError.exportFailed.localizedDescription
        }
        XCTAssertEqual(store.projectReadiness, .missingDataSource(projectURL.standardizedFileURL))
        XCTAssertNil(store.currentDataSource)
    }

    @MainActor
    func testStoreReloadsWhenJSONLChanges() async throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": issueLine(id: "bd-1", title: "One")
        ])
        let store = BeadStore(userDefaults: makeUserDefaults())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.currentDataSource != nil && store.count(for: .all) == 1 }

        try writeJSONL(
            [
                issueLine(id: "bd-1", title: "One"),
                issueLine(id: "bd-2", title: "Two")
            ].joined(separator: "\n"),
            to: projectURL.appendingPathComponent(".beads/issues.jsonl")
        )

        try await waitUntil(timeout: 4.0) { store.count(for: .all) == 2 }
    }

    @MainActor
    func testStoreMarksSnapshotPossiblyStaleWhenOnlyExportMarkerChanges() async throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": issueLine(id: "bd-1", title: "One")
        ])
        let exportStateURL = projectURL.appendingPathComponent(".beads/export-state.json")
        try #"{"timestamp":"old"}"#.write(to: exportStateURL, atomically: true, encoding: .utf8)
        let store = BeadStore(userDefaults: makeUserDefaults(), commands: TestBeadsCommands { _ in })
        store.openProject(projectURL)
        try await waitUntil {
            !store.isLoading && store.snapshotFreshness.state == .current && store.count(for: .all) == 1
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        try #"{"timestamp":"new","issues":1}"#.write(to: exportStateURL, atomically: true, encoding: .utf8)

        try await waitUntil(timeout: 4.0) {
            store.snapshotFreshness.state == .possiblyStale
        }
        XCTAssertEqual(store.count(for: .all), 1)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testStoreAutoRefreshSwitchesWhenPreferredJSONLSnapshotAppears() async throws {
        let projectURL = try makeProject(jsonlFiles: [
            "beads.jsonl": issueLine(id: "bd-legacy", title: "Legacy")
        ])
        let store = BeadStore(userDefaults: makeUserDefaults())
        store.openProject(projectURL)
        try await waitUntil {
            !store.isLoading
                && store.currentDataSource?.url.lastPathComponent == "beads.jsonl"
                && store.issue(with: "bd-legacy") != nil
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        try writeJSONL(
            issueLine(id: "bd-current", title: "Current"),
            to: projectURL.appendingPathComponent(".beads/issues.jsonl")
        )

        try await waitUntil(timeout: 4.0) {
            store.currentDataSource?.url.lastPathComponent == "issues.jsonl"
                && store.issue(with: "bd-current")?.title == "Current"
        }
    }

    @MainActor
    func testStoreAutoRefreshSwitchesFromJSONLToPopulatedSQLite() async throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": issueLine(id: "bd-jsonl", title: "From JSONL")
        ])
        let store = BeadStore(userDefaults: makeUserDefaults())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.currentDataSource?.kind == .jsonl }

        try createSQLiteDatabase(at: projectURL.appendingPathComponent(".beads/beads.db"), issueID: "bd-sqlite")

        try await waitUntil(timeout: 4.0) {
            store.currentDataSource?.kind == .sqlite && store.count(for: .all) == 1
        }
        XCTAssertEqual(store.issue(with: "bd-sqlite")?.title, "From SQLite")
    }

    @MainActor
    func testStoreAutoRefreshSwitchesWhenExistingSQLiteBecomesPopulated() async throws {
        let projectURL = try makeProject(jsonlFiles: [
            "issues.jsonl": issueLine(id: "bd-jsonl", title: "From JSONL")
        ])
        let sqliteURL = projectURL.appendingPathComponent(".beads/beads.db")
        try createEmptySQLiteDatabase(at: sqliteURL)

        let store = BeadStore(userDefaults: makeUserDefaults())
        store.openProject(projectURL)
        try await waitUntil { !store.isLoading && store.currentDataSource?.kind == .jsonl }

        try insertSQLiteIssue(at: sqliteURL, issueID: "bd-sqlite")

        try await waitUntil(timeout: 4.0) {
            store.currentDataSource?.kind == .sqlite && store.issue(with: "bd-sqlite")?.title == "From SQLite"
        }
    }

    private func makeProject(jsonlFiles: [String: String]) throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadazzleTests-\(UUID().uuidString)", isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)

        for (fileName, contents) in jsonlFiles {
            try writeJSONL(contents, to: beadsURL.appendingPathComponent(fileName))
        }
        return projectURL
    }

    private func makeDirectoryWithoutBeads() throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadazzleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL)
        }
        return projectURL
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "BeadazzleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func issueLine(id: String, title: String) -> String {
        """
        {"_type":"issue","id":"\(id)","title":"\(title)","status":"open","priority":1,"issue_type":"task","updated_at":"2026-07-03T20:58:35Z"}
        """
    }

    private func writeJSONL(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func createEmptySQLiteDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw TestSQLiteError.openFailed
        }
        defer { sqlite3_close(database) }

        try executeSQL(
            """
            CREATE TABLE issues (
                id TEXT PRIMARY KEY,
                title TEXT,
                description TEXT,
                design TEXT,
                acceptance_criteria TEXT,
                notes TEXT,
                status TEXT,
                priority INTEGER,
                issue_type TEXT,
                assignee TEXT,
                owner TEXT,
                created_at TEXT,
                updated_at TEXT,
                closed_at TEXT,
                due_at TEXT,
                defer_until TEXT,
                external_ref TEXT,
                parent_id TEXT,
                pinned INTEGER,
                ephemeral INTEGER,
                is_template INTEGER,
                deleted_at TEXT
            );
            CREATE TABLE labels (issue_id TEXT, label TEXT);
            CREATE TABLE dependencies (issue_id TEXT, depends_on_id TEXT, type TEXT, created_at TEXT);
            CREATE TABLE comments (id TEXT, issue_id TEXT, author TEXT, text TEXT, created_at TEXT, updated_at TEXT);
            """,
            database: database
        )
    }

    private func createSQLiteDatabase(
        at url: URL,
        issueID: String,
        includeRelatedRecords: Bool = false
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw TestSQLiteError.openFailed
        }
        defer { sqlite3_close(database) }

        try executeSQL(
            """
            CREATE TABLE issues (
                id TEXT PRIMARY KEY,
                title TEXT,
                description TEXT,
                design TEXT,
                acceptance_criteria TEXT,
                notes TEXT,
                status TEXT,
                priority INTEGER,
                issue_type TEXT,
                assignee TEXT,
                owner TEXT,
                created_at TEXT,
                updated_at TEXT,
                closed_at TEXT,
                due_at TEXT,
                defer_until TEXT,
                external_ref TEXT,
                parent_id TEXT,
                pinned INTEGER,
                ephemeral INTEGER,
                is_template INTEGER,
                deleted_at TEXT
            );
            CREATE TABLE labels (issue_id TEXT, label TEXT);
            CREATE TABLE dependencies (issue_id TEXT, depends_on_id TEXT, type TEXT, created_at TEXT);
            CREATE TABLE comments (id TEXT, issue_id TEXT, author TEXT, text TEXT, created_at TEXT, updated_at TEXT);
            """,
            database: database
        )
        try insertSQLiteIssue(issueID: issueID, database: database)

        guard includeRelatedRecords else { return }
        try executeSQL(
            """
            INSERT INTO issues (
                id, title, description, design, acceptance_criteria, notes, status, priority,
                issue_type, assignee, owner, created_at, updated_at, closed_at, due_at,
                defer_until, external_ref, parent_id, pinned, ephemeral, is_template, deleted_at
            ) VALUES (
                'bd-blocker', 'Blocker', '', '', '', '', 'open', 1,
                'task', NULL, NULL, '2026-07-03T20:58:35Z', '2026-07-03T20:58:35Z', NULL, NULL,
                NULL, NULL, NULL, 0, 0, 0, NULL
            );
            INSERT INTO labels (issue_id, label) VALUES ('\(issueID)', 'reader');
            INSERT INTO labels (issue_id, label) VALUES ('\(issueID)', 'sqlite');
            INSERT INTO dependencies (issue_id, depends_on_id, type, created_at)
            VALUES ('\(issueID)', 'bd-blocker', 'blocks', '2026-07-03T20:58:35Z');
            INSERT INTO comments (id, issue_id, author, text, created_at, updated_at)
            VALUES ('comment-1', '\(issueID)', 'Riley', 'SQLite comment', '2026-07-03T20:58:35Z', NULL);
            """,
            database: database
        )
    }

    private func insertSQLiteIssue(at url: URL, issueID: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw TestSQLiteError.openFailed
        }
        defer { sqlite3_close(database) }

        try insertSQLiteIssue(issueID: issueID, database: database)
    }

    private func insertSQLiteIssue(issueID: String, database: OpaquePointer?) throws {
        try executeSQL(
            """
            INSERT INTO issues (
                id, title, description, design, acceptance_criteria, notes, status, priority,
                issue_type, assignee, owner, created_at, updated_at, closed_at, due_at,
                defer_until, external_ref, parent_id, pinned, ephemeral, is_template, deleted_at
            ) VALUES (
                '\(issueID)', 'From SQLite', '', '', '', '', 'open', 1,
                'task', NULL, NULL, '2026-07-03T20:58:35Z', '2026-07-03T20:58:35Z', NULL, NULL,
                NULL, NULL, NULL, 0, 0, 0, NULL
            );
            """,
            database: database
        )
    }

    private func executeSQL(_ sql: String, database: OpaquePointer?) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
            throw TestSQLiteError.execFailed(message)
        }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3.0,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

private enum TestSQLiteError: Error {
    case openFailed
    case execFailed(String)
}

private struct TestBeadsCommands: BeadsCommanding {
    var exportReadableSnapshotHandler: @Sendable (URL) async throws -> Void

    init(_ exportReadableSnapshotHandler: @escaping @Sendable (URL) async throws -> Void) {
        self.exportReadableSnapshotHandler = exportReadableSnapshotHandler
    }

    func initialize(projectURL: URL, options: BeadsInitOptions) async throws {}

    func exportReadableSnapshot(projectURL: URL) async throws {
        try await exportReadableSnapshotHandler(projectURL)
    }

    func create(projectURL: URL, draft: IssueDraft) async throws -> String { "bd-created" }

    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws {}

    func updateMetadata(
        projectURL: URL,
        issueID: String,
        labels: [String]?,
        originalLabels: [String]?,
        dueAt: IssueMetadataDateUpdate,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {}

    func close(projectURL: URL, ids: [String], reason: String?) async throws {}

    func delete(projectURL: URL, ids: [String]) async throws {}

    func bulkUpdate(
        projectURL: URL,
        ids: [String],
        status: String?,
        type: String?,
        priority: Int?,
        deferUntil: IssueMetadataDateUpdate
    ) async throws {}

    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {}

    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {}

    func addComment(projectURL: URL, issueID: String, text: String) async throws {}

    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition] {
        []
    }

    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] {
        []
    }

    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws {}

    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws {}
}

private enum TestProjectCommandError: LocalizedError {
    case exportFailed

    var errorDescription: String? {
        "Test export failed"
    }
}
