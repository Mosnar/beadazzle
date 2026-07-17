import XCTest
@testable import Beadazzle

final class BeadsProjectEnvironmentTests: XCTestCase {
    func testRedirectedEnvironmentUsesContextDirectory() throws {
        let projectURL = URL(fileURLWithPath: "/tmp/worktree", isDirectory: true)
        let trackerURL = URL(fileURLWithPath: "/tmp/main/.beads", isDirectory: true)
        let context = BeadsProjectContext.testContext(
            projectURL: projectURL,
            beadsDirectoryURL: trackerURL,
            isRedirected: true,
            isWorktree: true
        )

        let environment = try BeadsProjectEnvironment(context: context, projectURL: projectURL)

        XCTAssertEqual(environment.beadsDirectoryURL, trackerURL.standardizedFileURL)
        XCTAssertTrue(environment.isRedirected)
        XCTAssertEqual(environment.storageMode, .embedded)
    }

    func testRelativeTrackerDirectoryResolvesFromProjectRoot() throws {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        var context = BeadsProjectContext.testContext(projectURL: projectURL)
        context.beadsDirectory = "../shared-tracker"

        let environment = try BeadsProjectEnvironment(context: context, projectURL: projectURL)

        XCTAssertEqual(
            environment.beadsDirectoryURL,
            URL(fileURLWithPath: "/tmp/shared-tracker", isDirectory: true).standardizedFileURL
        )
        XCTAssertTrue(environment.isRedirected)
    }

    func testServerModesRequestActivationRefresh() throws {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let server = try BeadsProjectEnvironment(
            context: .testContext(projectURL: projectURL, doltMode: "server"),
            projectURL: projectURL
        )
        let shared = try BeadsProjectEnvironment(
            context: .testContext(projectURL: projectURL, doltMode: "shared-server"),
            projectURL: projectURL
        )

        XCTAssertTrue(server.storageMode.refreshesWhenAppActivates)
        XCTAssertTrue(shared.storageMode.refreshesWhenAppActivates)
    }

    func testContributorEnvironmentPreservesRoutingRole() throws {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let environment = try BeadsProjectEnvironment(
            context: .testContext(projectURL: projectURL, role: "contributor"),
            projectURL: projectURL
        )

        XCTAssertEqual(environment.role, .contributor)
        XCTAssertEqual(environment.role.displayName, "Contributor")
    }

    func testStealthConfigDisablesGitIntegration() throws {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let environment = try BeadsProjectEnvironment(
            context: .testContext(projectURL: projectURL),
            projectURL: projectURL
        )
        let config = ProjectStorageConfig(
            exportAuto: true,
            exportPath: "issues.jsonl",
            exportInterval: "60s",
            exportGitAdd: true,
            importAuto: false,
            federationRemote: nil,
            noGitOperations: true
        )

        XCTAssertEqual(environment.applying(storageConfig: config).gitIntegration, .disabled)
    }

    func testUnsetNoGitOperationsUsesNormalGitIntegration() throws {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let environment = try BeadsProjectEnvironment(
            context: .testContext(projectURL: projectURL),
            projectURL: projectURL
        )
        let config = ProjectStorageConfig(
            exportAuto: true,
            exportPath: "issues.jsonl",
            exportInterval: "60s",
            exportGitAdd: true,
            importAuto: false,
            federationRemote: nil
        )

        XCTAssertEqual(environment.applying(storageConfig: config).gitIntegration, .enabled)
    }

    func testUnavailableNoGitOperationsKeepsGitIntegrationUnknown() throws {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let environment = try BeadsProjectEnvironment(
            context: .testContext(projectURL: projectURL),
            projectURL: projectURL
        )
        let config = ProjectStorageConfig(
            exportAutoStatus: .available(true),
            exportPathStatus: .available("issues.jsonl"),
            exportIntervalStatus: .available("60s"),
            exportGitAddStatus: .available(true),
            importAutoStatus: .available(false),
            federationRemoteStatus: .available(nil),
            noGitOperationsStatus: .unavailable("configuration read failed")
        )

        XCTAssertEqual(environment.applying(storageConfig: config).gitIntegration, .unknown)
    }

    func testLegacyBackendIsRejected() {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        var context = BeadsProjectContext.testContext(projectURL: projectURL)
        context.backend = "sqlite"

        XCTAssertThrowsError(try BeadsProjectEnvironment(context: context, projectURL: projectURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("sqlite backend"))
        }
    }
}

extension BeadsProjectContext {
    static func testContext(
        projectURL: URL,
        beadsDirectoryURL: URL? = nil,
        doltMode: String = "embedded",
        role: String = "maintainer",
        isRedirected: Bool = false,
        isWorktree: Bool = false
    ) -> BeadsProjectContext {
        BeadsProjectContext(
            backend: "dolt",
            bdVersion: "1.0.4",
            beadsDirectory: (beadsDirectoryURL
                ?? projectURL.appendingPathComponent(".beads", isDirectory: true)).path,
            cwdRepoRoot: projectURL.path,
            database: projectURL.lastPathComponent,
            doltMode: doltMode,
            isRedirected: isRedirected,
            isWorktree: isWorktree,
            projectID: "project-id",
            repoRoot: projectURL.path,
            role: role,
            schemaVersion: 1
        )
    }
}
