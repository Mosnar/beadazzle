import XCTest
@testable import Beadazzle

final class BeadProjectLoaderTests: XCTestCase {
    func testLoadProjectUsesCommandStatusAndTypeMetadata() async throws {
        let projectURL = try makeProject(
            issueLine(id: "bd-custom", title: "Custom", status: "qa", type: "incident")
        )
        let commands = MetadataTestCommands(
            statusDefinitions: .success([
                BeadStatusDefinition(name: "qa", category: .wip, icon: nil, description: "Quality review")
            ]),
            typeDefinitions: .success([
                BeadTypeDefinition(name: "incident", description: "Production incident")
            ])
        )

        let loadedProject = try await BeadProjectLoader(commands: commands).loadProject(projectURL: projectURL)

        XCTAssertEqual(loadedProject.index.semantics.category(forStatus: "qa"), .wip)
        XCTAssertEqual(loadedProject.index.count(for: .inProgress), 1)
        XCTAssertTrue(loadedProject.index.semantics.typeNames.contains("incident"))
    }

    func testLoadProjectReturnsLoadedDefinitionsForCaching() async throws {
        let projectURL = try makeProject(
            issueLine(id: "bd-1", title: "One", status: "qa", type: "incident")
        )
        let commands = MetadataTestCommands(
            statusDefinitions: .success([BeadStatusDefinition(name: "qa", category: .wip, icon: nil, description: nil)]),
            typeDefinitions: .success([BeadTypeDefinition(name: "incident", description: nil)])
        )

        let loaded = try await BeadProjectLoader(commands: commands).loadProject(projectURL: projectURL)

        let definitions = try XCTUnwrap(loaded.definitions)
        XCTAssertEqual(definitions.statuses.map(\.name), ["qa"])
        XCTAssertEqual(definitions.types.map(\.name), ["incident"])
    }

    func testLoadProjectWithCachedDefinitionsSkipsCommandReads() async throws {
        let projectURL = try makeProject(
            issueLine(id: "bd-1", title: "One", status: "qa", type: "incident")
        )
        let counter = CommandCallCounter()
        let commands = MetadataTestCommands(
            statusDefinitions: .success([]),
            typeDefinitions: .success([]),
            callCounter: counter
        )
        let cached = BeadSemanticDefinitions(
            statuses: [BeadStatusDefinition(name: "qa", category: .wip, icon: nil, description: nil)],
            types: [BeadTypeDefinition(name: "incident", description: nil)]
        )

        let loaded = try await BeadProjectLoader(commands: commands)
            .loadProject(projectURL: projectURL, cachedDefinitions: cached)

        XCTAssertEqual(counter.definitionReads, 0, "cached definitions must not spawn any bd reads")
        // Cached definitions are still merged with the live snapshot's semantics.
        XCTAssertEqual(loaded.index.semantics.category(forStatus: "qa"), .wip)
        XCTAssertTrue(loaded.index.semantics.typeNames.contains("incident"))
        XCTAssertEqual(loaded.definitions, cached)
    }

    func testLoadProjectReadsCommandMetadataSequentially() async throws {
        let projectURL = try makeProject(
            issueLine(id: "bd-1", title: "One", status: "qa", type: "incident")
        )
        let counter = CommandCallCounter()
        let commands = MetadataTestCommands(
            statusDefinitions: .success([BeadStatusDefinition(name: "qa", category: .wip, icon: nil, description: nil)]),
            typeDefinitions: .success([BeadTypeDefinition(name: "incident", description: nil)]),
            callCounter: counter,
            definitionReadDelay: .milliseconds(20)
        )

        _ = try await BeadProjectLoader(commands: commands).loadProject(projectURL: projectURL)

        XCTAssertEqual(counter.definitionReadNames, ["statuses", "types"])
        XCTAssertEqual(counter.maxConcurrentDefinitionReads, 1)
    }

    func testLoadProjectDoesNotCacheDefinitionsWhenCommandsFail() async throws {
        let projectURL = try makeProject(
            issueLine(id: "bd-open", title: "Open", status: "open", type: "task")
        )
        let commands = MetadataTestCommands(
            statusDefinitions: .failure(MetadataTestError.failed),
            typeDefinitions: .failure(MetadataTestError.failed)
        )

        let loaded = try await BeadProjectLoader(commands: commands).loadProject(projectURL: projectURL)

        XCTAssertNil(loaded.definitions, "a failed read must not be cached")
    }

    func testLoadProjectFallsBackWhenMetadataCommandsFail() async throws {
        let projectURL = try makeProject(
            issueLine(id: "bd-open", title: "Open", status: "open", type: "custom")
        )
        let commands = MetadataTestCommands(
            statusDefinitions: .failure(MetadataTestError.failed),
            typeDefinitions: .failure(MetadataTestError.failed)
        )

        let loadedProject = try await BeadProjectLoader(commands: commands).loadProject(projectURL: projectURL)

        XCTAssertEqual(loadedProject.index.semantics.category(forStatus: "open"), .active)
        XCTAssertTrue(loadedProject.index.semantics.typeNames.contains("custom"))
    }

    private func makeProject(_ issuesJSONL: String) throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadProjectLoaderTests-\(UUID().uuidString)", isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        try issuesJSONL.write(
            to: beadsURL.appendingPathComponent("issues.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL)
        }
        return projectURL
    }

    private func issueLine(id: String, title: String, status: String, type: String) -> String {
        """
        {"_type":"issue","id":"\(id)","title":"\(title)","status":"\(status)","priority":1,"issue_type":"\(type)","updated_at":"2026-07-03T20:58:35Z"}
        """
    }
}

private final class CommandCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _definitionReads = 0
    private var _definitionReadNames: [String] = []
    private var activeDefinitionReads = 0
    private var _maxConcurrentDefinitionReads = 0

    func beginDefinitionRead(_ name: String) {
        lock.lock()
        _definitionReads += 1
        _definitionReadNames.append(name)
        activeDefinitionReads += 1
        _maxConcurrentDefinitionReads = max(_maxConcurrentDefinitionReads, activeDefinitionReads)
        lock.unlock()
    }

    func endDefinitionRead() {
        lock.lock()
        activeDefinitionReads -= 1
        lock.unlock()
    }

    var definitionReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return _definitionReads
    }

    var definitionReadNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _definitionReadNames
    }

    var maxConcurrentDefinitionReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return _maxConcurrentDefinitionReads
    }
}

private struct MetadataTestCommands: BeadsCommanding {
    var statusDefinitions: Result<[BeadStatusDefinition], Error> = .success([])
    var typeDefinitions: Result<[BeadTypeDefinition], Error> = .success([])
    var callCounter: CommandCallCounter? = nil
    var definitionReadDelay: Duration? = nil

    func initialize(projectURL: URL, options: BeadsInitOptions) async throws {}

    func exportReadableSnapshot(projectURL: URL) async throws {}

    func create(projectURL: URL, draft: IssueDraft) async throws -> String { "bd-created" }

    func update(projectURL: URL, draft: IssueDraft, originalIssue: BeadIssue?) async throws {}

    func close(projectURL: URL, ids: [String], reason: String?) async throws {}

    func delete(projectURL: URL, ids: [String]) async throws {}

    func bulkUpdate(projectURL: URL, ids: [String], status: String?, type: String?, priority: Int?) async throws {}

    func addDependency(projectURL: URL, issueID: String, dependsOnID: String, type: String) async throws {}

    func removeDependency(projectURL: URL, issueID: String, dependsOnID: String) async throws {}

    func addComment(projectURL: URL, issueID: String, text: String) async throws {}

    func loadStatusDefinitions(projectURL: URL) async throws -> [BeadStatusDefinition] {
        callCounter?.beginDefinitionRead("statuses")
        defer { callCounter?.endDefinitionRead() }
        if let definitionReadDelay {
            try await Task.sleep(for: definitionReadDelay)
        }
        return try statusDefinitions.get()
    }

    func loadTypeDefinitions(projectURL: URL) async throws -> [BeadTypeDefinition] {
        callCounter?.beginDefinitionRead("types")
        defer { callCounter?.endDefinitionRead() }
        if let definitionReadDelay {
            try await Task.sleep(for: definitionReadDelay)
        }
        return try typeDefinitions.get()
    }

    func saveCustomStatuses(projectURL: URL, statuses: [BeadStatusDefinition]) async throws {}

    func saveCustomTypes(projectURL: URL, types: [BeadTypeDefinition]) async throws {}
}

private enum MetadataTestError: Error {
    case failed
}
