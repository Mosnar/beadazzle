import XCTest
@testable import Beadazzle

final class BeadsJournalIntegrationTests: XCTestCase {
    @MainActor
    func testRealEmbeddedJournalAcceleratesFieldsAndExportsComments() async throws {
        guard ProcessInfo.processInfo.environment["BEADAZZLE_RUN_JOURNAL_INTEGRATION"] == "1" else {
            throw XCTSkip("Set BEADAZZLE_RUN_JOURNAL_INTEGRATION=1 to test an installed bd in a disposable project.")
        }
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BEADAZZLE_TEST_BD"] ?? "/opt/homebrew/bin/bd")
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("JournalIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        var environment = BeadsCLI.subprocessEnvironment(executableURL: executable)
        let inheritedKeys = environment.keys.filter { $0.hasPrefix("BEADS_") || $0.hasPrefix("BD_") || $0.hasPrefix("DOLT_") }
        for key in inheritedKeys { environment.removeValue(forKey: key) }
        environment["BEADS_DIR"] = project.appendingPathComponent(".beads").path
        environment["BD_NON_INTERACTIVE"] = "1"
        func run(_ executable: URL, _ arguments: [String]) async throws -> String {
            let result = try await CancellableProcessRunner.run(
                executableURL: executable, arguments: arguments, currentDirectoryURL: project,
                environment: environment, outputLimit: 1_024 * 1_024, timeout: .seconds(45)
            )
            guard result.terminationStatus == 0 else {
                throw BeadError.commandFailed(command: arguments.joined(separator: " "), output: result.output)
            }
            return result.output
        }
        let git = URL(fileURLWithPath: "/usr/bin/git")
        _ = try await run(git, ["init", "-b", "main"])
        _ = try await run(git, ["config", "user.name", "Journal Test"])
        _ = try await run(git, ["config", "user.email", "journal@example.invalid"])
        _ = try await run(executable, ["--sandbox", "init", "--prefix", "journal", "--non-interactive", "--skip-agents", "--skip-hooks"])
        let context = try BeadsProjectContext.decode(from: await run(executable, ["--readonly", "context", "--json"]))
        XCTAssertEqual(
            URL(fileURLWithPath: try XCTUnwrap(context.beadsDirectory)).resolvingSymlinksInPath(),
            project.appendingPathComponent(".beads").resolvingSymlinksInPath()
        )
        _ = try await run(executable, ["--sandbox", "create", "--id", "journal-one", "--title", "Before", "--description", "Fixture", "--json"])
        _ = try await run(executable, ["--sandbox", "comment", "journal-one", "Before the journal", "--json"])
        _ = try await run(executable, ["config", "set", "events-journal", "true"])
        let prefix = inheritedKeys.flatMap { ["-u", $0] } + [
            "BEADS_DIR=\(project.appendingPathComponent(".beads").path)", "BD_NON_INTERACTIVE=1", executable.path
        ]
        let commands = BeadsCommandService(executable: { (URL(fileURLWithPath: "/usr/bin/env"), prefix) })
        let loader = BeadProjectLoader(commands: commands)
        let initial = try await loader.refreshSnapshotAndLoadProject(
            projectURL: project, loadsDefinitionsIfMissing: false, usesJournalRefresh: true
        )
        XCTAssertNotNil(initial.journalBaseline)
        _ = try await run(executable, ["--sandbox", "update", "journal-one", "--title", "After", "--json"])
        let fast = try await loader.refreshSnapshotAndLoadProject(
            projectURL: project, loadsDefinitionsIfMissing: false,
            usesJournalRefresh: true, mayApplyJournal: true, journalBaseline: initial.journalBaseline
        )
        XCTAssertTrue(fast.journalRefresh.requiresVerification)
        XCTAssertEqual(fast.index.issue(with: "journal-one")?.title, "After")
        XCTAssertEqual(fast.index.issue(with: "journal-one")?.commentCount, 1)
        let disk = try BeadsSnapshotReader().loadProject(projectURL: project, beadsDirectoryURL: initial.environment.beadsDirectoryURL)
        XCTAssertEqual(disk.snapshot.issues.first?.title, "Before")
        _ = try await run(executable, ["--sandbox", "comment", "journal-one", "After the journal", "--json"])
        let full = try await loader.refreshSnapshotAndLoadProject(
            projectURL: project, loadsDefinitionsIfMissing: false,
            usesJournalRefresh: true, mayApplyJournal: true, journalBaseline: fast.journalBaseline
        )
        XCTAssertFalse(full.journalRefresh.requiresVerification)
        XCTAssertEqual(full.index.issue(with: "journal-one")?.title, "After")
        XCTAssertEqual(full.index.issue(with: "journal-one")?.commentCount, 2)

        let defaults = makeIsolatedUserDefaults()
        defaults.set(true, forKey: BeadazzlePreferenceKeys.usesExperimentalJournalRefresh(projectURL: project))
        let store = BeadStore(userDefaults: defaults, commands: commands)
        defer { store.project.cancelLifecycleWork() }
        store.openProject(project)
        let didLoad = await store.refreshTask?.value
        XCTAssertEqual(didLoad, true)
        XCTAssertNotNil(store.project.journalBaseline)
        _ = try await run(executable, ["update", "journal-one", "--title", "File monitor edit", "--json"])
        try await waitUntil("real CLI file-monitor update", timeout: .seconds(10)) {
            store.index.issue(with: "journal-one")?.title == "File monitor edit"
        }
        XCTAssertEqual(store.index.issue(with: "journal-one")?.title, "File monitor edit")
        XCTAssertTrue(store.snapshotFreshness.isJournalProjection, "A real CLI edit must reach the change feed through the file monitor")
    }
}
