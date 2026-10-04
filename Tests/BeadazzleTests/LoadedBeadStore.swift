import Foundation
import XCTest
@testable import Beadazzle

extension XCTestCase {
    @MainActor
    func makeLoadedBeadStore(
        issuesJSONL: String,
        requiresVisibleRows: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> BeadStore {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadazzleTests-\(UUID().uuidString)", isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: projectURL) }
        try issuesJSONL.write(to: beadsURL.appendingPathComponent("issues.jsonl"), atomically: true, encoding: .utf8)

        let store = BeadStore(userDefaults: makeIsolatedUserDefaults(), commands: CurrentDoltTestCommands())
        store.openProject(projectURL)
        try await waitForStoreToLoad(store, requiresVisibleRows: requiresVisibleRows, file: file, line: line)
        return store
    }

    @MainActor
    func waitForStoreToLoad(
        _ store: BeadStore,
        requiresVisibleRows: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while store.isLoading || (requiresVisibleRows && store.issueListRows.isEmpty) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out loading test project: \(store.lastError ?? "no error")", file: file, line: line)
                throw TestStoreLoadError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.waitForPendingQueryRecompute()
        XCTAssertNil(store.lastError, file: file, line: line)
    }
}

private enum TestStoreLoadError: Error {
    case timedOut
}
