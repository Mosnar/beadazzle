import XCTest
@testable import Beadazzle

@MainActor
final class BeadSemanticDefinitionsRepositoryTests: XCTestCase {
    private lazy var userDefaults = makeIsolatedUserDefaults()

    func testRoundTripsDefinitionsThroughResolvedTrackerRoute() throws {
        let repository = BeadSemanticDefinitionsRepository(userDefaults: userDefaults)
        let projectURL = URL(fileURLWithPath: "/tmp/definitions-project")
        let trackerDirectoryURL = URL(fileURLWithPath: "/tmp/shared-tracker/.beads")
        let refreshedAt = Date(timeIntervalSince1970: 1_000)
        let definitions = BeadSemanticDefinitions(
            statuses: [
                BeadStatusDefinition(
                    name: "qa",
                    category: .wip,
                    icon: "checkmark",
                    description: "Quality review",
                    source: .custom
                )
            ],
            types: [
                BeadTypeDefinition(
                    name: "incident",
                    description: "Production incident",
                    source: .custom
                )
            ]
        )

        repository.save(
            definitions,
            projectURL: projectURL,
            trackerDirectoryURL: trackerDirectoryURL,
            refreshedAt: refreshedAt
        )

        let loaded = try XCTUnwrap(repository.load(projectURL: projectURL))
        XCTAssertEqual(loaded.entry.definitions, definitions)
        XCTAssertEqual(loaded.entry.refreshedAt, refreshedAt)
        XCTAssertEqual(
            loaded.trackerDirectoryURL.standardizedFileURL.path,
            trackerDirectoryURL.standardizedFileURL.path
        )
    }

    func testResetRemovesSharedTrackerCacheForEveryRoutedProject() {
        let repository = BeadSemanticDefinitionsRepository(userDefaults: userDefaults)
        let firstProjectURL = URL(fileURLWithPath: "/tmp/definitions-project-a")
        let secondProjectURL = URL(fileURLWithPath: "/tmp/definitions-project-b")
        let trackerDirectoryURL = URL(fileURLWithPath: "/tmp/shared-tracker/.beads")
        let definitions = BeadSemanticDefinitions(statuses: [], types: [])
        repository.save(
            definitions,
            projectURL: firstProjectURL,
            trackerDirectoryURL: trackerDirectoryURL
        )
        repository.save(
            definitions,
            projectURL: secondProjectURL,
            trackerDirectoryURL: trackerDirectoryURL
        )

        repository.reset(
            projectURL: firstProjectURL,
            trackerDirectoryURL: trackerDirectoryURL
        )

        XCTAssertNil(repository.load(projectURL: firstProjectURL))
        XCTAssertNil(repository.load(projectURL: secondProjectURL))
    }
}
