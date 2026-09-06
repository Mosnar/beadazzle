import XCTest
@testable import Beadazzle

final class BeadOwnerIdentityResolverTests: XCTestCase {
    func testBeadsActorOutranksEveryOtherStep() {
        XCTAssertEqual(
            BeadOwnerIdentityResolver.identity(
                environment: ["BEADS_ACTOR": "beads-actor", "BD_ACTOR": "legacy-actor", "USER": "login-name"],
                configuredActor: "Configured Actor",
                gitUserName: "Git Name"
            ),
            .resolved(value: "beads-actor", source: .beadsActor)
        )
    }

    func testLegacyBdActorStandsInWhenBeadsActorIsUnset() {
        XCTAssertEqual(
            BeadOwnerIdentityResolver.identity(
                environment: ["BD_ACTOR": "legacy-actor", "USER": "login-name"],
                configuredActor: "Configured Actor",
                gitUserName: "Git Name"
            ),
            .resolved(value: "legacy-actor", source: .legacyBeadsActor)
        )
    }

    func testConfiguredActorOutranksGitConfigurationAndTheProcessUser() {
        XCTAssertEqual(
            BeadOwnerIdentityResolver.identity(
                environment: ["USER": "login-name"],
                configuredActor: " Configured Actor\n",
                gitUserName: "Git Name"
            ),
            .resolved(value: "Configured Actor", source: .configuredActor)
        )
    }

    func testGitConfigurationOutranksTheProcessUser() {
        XCTAssertEqual(
            BeadOwnerIdentityResolver.identity(
                environment: ["USER": "login-name"],
                configuredActor: nil,
                gitUserName: "  Git Name\n"
            ),
            .resolved(value: "Git Name", source: .gitConfiguration)
        )
    }

    func testProcessUserIsTheLastResort() {
        XCTAssertEqual(
            BeadOwnerIdentityResolver.identity(
                environment: ["USER": "  login-name "],
                configuredActor: nil,
                gitUserName: nil
            ),
            .resolved(value: "login-name", source: .processUser)
        )
    }

    func testBlankStepsFallThroughToTheNextSource() {
        XCTAssertEqual(
            BeadOwnerIdentityResolver.identity(
                environment: ["BEADS_ACTOR": "   ", "BD_ACTOR": "", "USER": "login-name"],
                configuredActor: " ",
                gitUserName: " \n "
            ),
            .resolved(value: "login-name", source: .processUser)
        )
    }

    func testEmptyIdentitySourcesRemainUnavailable() {
        XCTAssertNil(
            BeadOwnerIdentityResolver.identity(environment: [:], configuredActor: nil, gitUserName: " \n ")
        )
    }

    func testConfiguredActorIsReadFromConfigShowOutput() {
        let output = """
        [
          {"key": "actor", "value": "Configured Actor", "source": "config.yaml"},
          {"key": "backup.enabled", "value": "false", "source": "default"}
        ]
        """

        XCTAssertEqual(
            BeadOwnerIdentityResolver.configuredActor(fromConfigShowOutput: output),
            "Configured Actor"
        )
    }

    func testConfiguredActorIsReadFromEnvelopedConfigShowOutput() {
        let output = #"{"schema_version":1,"data":[{"key":"actor","value":"Configured Actor","source":"config.yaml"}]}"#

        XCTAssertEqual(
            BeadOwnerIdentityResolver.configuredActor(fromConfigShowOutput: output),
            "Configured Actor"
        )
    }

    func testConfiguredActorIsNilWhenTheKeyIsAbsentBlankOrUnparseable() {
        XCTAssertNil(BeadOwnerIdentityResolver.configuredActor(
            fromConfigShowOutput: #"[{"key":"backup.enabled","value":"false","source":"default"}]"#
        ))
        XCTAssertNil(BeadOwnerIdentityResolver.configuredActor(
            fromConfigShowOutput: #"[{"key":"actor","value":"   ","source":"config.yaml"}]"#
        ))
        XCTAssertNil(BeadOwnerIdentityResolver.configuredActor(
            fromConfigShowOutput: "actor (not set in config.yaml)"
        ))
    }

    func testConfiguredActorLookupAsksBdForConfigShow() throws {
        let directoryURL = try makeTemporaryDirectory()
        let stubURL = try writeExecutable(
            named: "bd",
            in: directoryURL,
            contents: """
            #!/bin/sh
            if [ "$*" = "--readonly config show --json" ]; then
              printf '%s\\n' '[{"key":"actor","value":"Configured Actor","source":"config.yaml"}]'
              exit 0
            fi
            exit 2
            """
        )

        XCTAssertEqual(
            BeadOwnerIdentityResolver.readConfiguredActor(
                projectURL: directoryURL,
                executable: (url: stubURL, prefix: []),
                environment: ["PATH": directoryURL.path],
                timeout: 2
            ),
            "Configured Actor"
        )
    }

    func testConfiguredActorLookupReturnsNilWhenBdFails() throws {
        let directoryURL = try makeTemporaryDirectory()
        let stubURL = try writeExecutable(
            named: "bd",
            in: directoryURL,
            contents: "#!/bin/sh\nprintf '%s\\n' 'Error: no .beads directory found' >&2\nexit 1\n"
        )

        XCTAssertNil(
            BeadOwnerIdentityResolver.readConfiguredActor(
                projectURL: directoryURL,
                executable: (url: stubURL, prefix: []),
                environment: ["PATH": directoryURL.path],
                timeout: 2
            )
        )
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

    @discardableResult
    private func writeExecutable(named name: String, in directoryURL: URL, contents: String) throws -> URL {
        let url = directoryURL.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
