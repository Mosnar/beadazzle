import XCTest
@testable import Beadazzle

final class BeadOwnerIdentityResolverTests: XCTestCase {
    func testBeadsActorOutranksGitConfigurationAndTheProcessUser() {
        XCTAssertEqual(
            BeadOwnerIdentityResolver.identity(
                environment: ["BEADS_ACTOR": "beads-actor", "USER": "login-name"],
                gitUserName: "Git Name"
            ),
            .resolved(value: "beads-actor", source: .beadsActor)
        )
    }

    func testGitConfigurationOutranksTheProcessUser() {
        XCTAssertEqual(
            BeadOwnerIdentityResolver.identity(
                environment: ["USER": "login-name"],
                gitUserName: "  Git Name\n"
            ),
            .resolved(value: "Git Name", source: .gitConfiguration)
        )
    }

    func testProcessUserIsTheLastResort() {
        XCTAssertEqual(
            BeadOwnerIdentityResolver.identity(
                environment: ["USER": "  login-name "],
                gitUserName: nil
            ),
            .resolved(value: "login-name", source: .processUser)
        )
    }

    func testBlankStepsFallThroughToTheNextSource() {
        XCTAssertEqual(
            BeadOwnerIdentityResolver.identity(
                environment: ["BEADS_ACTOR": "   ", "USER": "login-name"],
                gitUserName: " \n "
            ),
            .resolved(value: "login-name", source: .processUser)
        )
    }

    func testEmptyIdentitySourcesRemainUnavailable() {
        XCTAssertNil(BeadOwnerIdentityResolver.identity(environment: [:], gitUserName: " \n "))
    }

    func testGitLookupReadsUserNameRatherThanUserEmail() throws {
        let directoryURL = try makeTemporaryDirectory()
        try writeExecutable(
            named: "git",
            in: directoryURL,
            contents: """
            #!/bin/sh
            if [ "$1 $2" = "config user.name" ]; then
              printf '%s\\n' 'Git Name'
              exit 0
            fi
            printf '%s\\n' 'wrong-key@example.com'
            exit 0
            """
        )

        XCTAssertEqual(
            BeadOwnerIdentityResolver.readGitUserName(
                projectURL: directoryURL,
                environment: ["PATH": directoryURL.path],
                timeout: 2
            ),
            "Git Name"
        )
    }

    func testGitLookupReturnsNilWhenGitCannotBeResolved() {
        XCTAssertNil(
            BeadOwnerIdentityResolver.readGitUserName(
                projectURL: FileManager.default.temporaryDirectory,
                environment: ["PATH": "/path-that-does-not-exist"],
                timeout: 0.1
            )
        )
    }

    func testGitLookupTerminatesAfterTimeout() throws {
        let directoryURL = try makeTemporaryDirectory()
        try writeExecutable(
            named: "git",
            in: directoryURL,
            contents: "#!/bin/sh\nwhile :; do :; done\n"
        )

        let startedAt = Date()
        let userName = BeadOwnerIdentityResolver.readGitUserName(
            projectURL: directoryURL,
            environment: ["PATH": directoryURL.path],
            timeout: 0.05
        )

        XCTAssertNil(userName)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadOwnerIdentityResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return directoryURL
    }

    private func writeExecutable(named name: String, in directoryURL: URL, contents: String) throws {
        let url = directoryURL.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
