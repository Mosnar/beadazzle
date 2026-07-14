import Foundation
import XCTest
@testable import Beadazzle

@MainActor
final class BeadStoreRecentProjectsTests: XCTestCase {
    func testOpenProjectStoresRecentProjectsMostRecentFirstAndCapsList() throws {
        let defaults = makeUserDefaults()
        let store = BeadStore(userDefaults: defaults)
        let projectURLs = try (0..<10).map { try makeProject(named: "Project-\($0)") }

        for projectURL in projectURLs {
            store.openProject(projectURL)
        }

        XCTAssertEqual(store.recentProjects.map(\.path), projectURLs.suffix(8).reversed().map { $0.standardizedFileURL.path })
        XCTAssertEqual(defaults.stringArray(forKey: "RecentProjectPaths"), store.recentProjects.map(\.path))

        store.openProject(projectURLs[4])

        XCTAssertEqual(store.recentProjects.first?.path, projectURLs[4].standardizedFileURL.path)
        XCTAssertEqual(store.recentProjects.count, 8)
        XCTAssertEqual(Set(store.recentProjects.map(\.id)).count, 8)
        XCTAssertEqual(defaults.string(forKey: "LastProjectPath"), projectURLs[4].standardizedFileURL.path)
    }

    func testRemoveRecentProjectForgetsEntryWithoutClosingCurrentProject() throws {
        let defaults = makeUserDefaults()
        let store = BeadStore(userDefaults: defaults)
        let firstProjectURL = try makeProject(named: "First")
        let secondProjectURL = try makeProject(named: "Second")

        store.openProject(firstProjectURL)
        store.openProject(secondProjectURL)

        let secondProject = try XCTUnwrap(store.recentProjects.first)
        store.removeRecentProject(secondProject)

        XCTAssertEqual(store.projectURL?.path, secondProjectURL.standardizedFileURL.path)
        XCTAssertEqual(store.recentProjects.map(\.path), [firstProjectURL.standardizedFileURL.path])
        XCTAssertEqual(defaults.stringArray(forKey: "RecentProjectPaths"), [firstProjectURL.standardizedFileURL.path])
        XCTAssertEqual(defaults.string(forKey: "LastProjectPath"), firstProjectURL.standardizedFileURL.path)
    }

    func testSwitchingProjectsResetsSearchAndFilters() throws {
        let store = BeadStore(userDefaults: makeUserDefaults())
        let firstProjectURL = try makeProject(named: "First")
        let secondProjectURL = try makeProject(named: "Second")

        store.openProject(firstProjectURL)
        store.searchText = "stale query"
        store.statusFilters = ["open"]
        store.typeFilters = ["bug"]
        store.priorityFilters = [1]
        store.labelFilters = ["urgent"]

        store.openProject(secondProjectURL)

        XCTAssertEqual(store.searchText, "")
        XCTAssertTrue(store.statusFilters.isEmpty)
        XCTAssertTrue(store.typeFilters.isEmpty)
        XCTAssertTrue(store.priorityFilters.isEmpty)
        XCTAssertTrue(store.labelFilters.isEmpty)
        XCTAssertFalse(store.hasActiveFilters)
    }

    func testRemoveOnlyRecentProjectClearsLegacyLastProjectPath() throws {
        let defaults = makeUserDefaults()
        let store = BeadStore(userDefaults: defaults)
        let projectURL = try makeProject(named: "Only")

        store.openProject(projectURL)
        let project = try XCTUnwrap(store.recentProjects.first)
        store.removeRecentProject(project)

        XCTAssertEqual(store.projectURL?.path, projectURL.standardizedFileURL.path)
        XCTAssertEqual(store.recentProjects, [])
        XCTAssertEqual(defaults.stringArray(forKey: "RecentProjectPaths"), [])
        XCTAssertNil(defaults.string(forKey: "LastProjectPath"))
    }

    func testInitializesRecentProjectsFromLegacyLastProjectPath() throws {
        let defaults = makeUserDefaults()
        let projectURL = try makeProject(named: "Legacy")
        defaults.set(projectURL.path, forKey: "LastProjectPath")

        let store = BeadStore(userDefaults: defaults)

        XCTAssertEqual(store.recentProjects.map(\.path), [projectURL.standardizedFileURL.path])
        XCTAssertEqual(defaults.stringArray(forKey: "RecentProjectPaths"), [projectURL.standardizedFileURL.path])
    }

    func testInitializesRecentProjectsDeduplicatedAndCappedFromStoredPaths() {
        let defaults = makeUserDefaults()
        let projectURLs = (0..<10).map { index in
            FileManager.default.temporaryDirectory
                .appendingPathComponent("BeadazzleRecentTests-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("Project-\(index)", isDirectory: true)
        }
        defaults.set(
            [projectURLs[0].path, projectURLs[1].path, projectURLs[1].path]
                + projectURLs[2...9].map(\.path),
            forKey: "RecentProjectPaths"
        )

        let store = BeadStore(userDefaults: defaults)

        XCTAssertEqual(store.recentProjects.map(\.path), projectURLs[0...7].map { $0.standardizedFileURL.path })
        XCTAssertEqual(Set(store.recentProjects.map(\.id)).count, 8)
    }

    func testOpenDefaultProjectUsesFirstRecentProjectWithBeadsDirectory() throws {
        let defaults = makeUserDefaults()
        let staleProjectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadazzleRecentTests-\(UUID().uuidString)", isDirectory: true)
        let validProjectURL = try makeProject(named: "Valid")
        defaults.set([staleProjectURL.path, validProjectURL.path], forKey: "RecentProjectPaths")

        let store = BeadStore(userDefaults: defaults)
        store.openDefaultProjectIfAvailable()

        XCTAssertEqual(store.projectURL?.path, validProjectURL.standardizedFileURL.path)
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

    private func makeProject(named name: String) throws -> URL {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadazzleRecentTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let beadsURL = projectURL.appendingPathComponent(".beads", isDirectory: true)
        try FileManager.default.createDirectory(at: beadsURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }
        return projectURL
    }
}
