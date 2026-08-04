import XCTest
@testable import Beadazzle

final class GitDoltRemoteGenerationProbeTests: XCTestCase {
    func testGitSubprocessEnvironmentPrefersResolvedBDToolchainDirectory() {
        let bdExecutableURL = URL(fileURLWithPath: "/tmp/beadazzle-toolchain/bin/bd")

        let environment = GitDoltRemoteGenerationProbe.gitSubprocessEnvironment(
            for: bdExecutableURL
        )

        XCTAssertEqual(
            environment["PATH"]?.split(separator: ":").first,
            Substring("/tmp/beadazzle-toolchain/bin")
        )
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertNotNil(environment["GIT_SSH_COMMAND"])
    }

    func testNormalizesSupportedGitRemoteURLs() {
        XCTAssertEqual(
            GitDoltRemoteGenerationProbe.normalizedGitRemoteURL(
                "git+ssh://git@github.com/example/project.git"
            ),
            "ssh://git@github.com/example/project.git"
        )
        XCTAssertEqual(
            GitDoltRemoteGenerationProbe.normalizedGitRemoteURL(
                "git+https://github.com/example/project.git"
            ),
            "https://github.com/example/project.git"
        )
        XCTAssertEqual(
            GitDoltRemoteGenerationProbe.normalizedGitRemoteURL(
                "GIT+SSH://git@github.com/example/project.git"
            ),
            "SSH://git@github.com/example/project.git"
        )
        XCTAssertEqual(
            GitDoltRemoteGenerationProbe.normalizedGitRemoteURL(
                "git@github.com:example/project.git"
            ),
            "git@github.com:example/project.git"
        )
        XCTAssertEqual(
            GitDoltRemoteGenerationProbe.normalizedGitRemoteURL(
                "github.com:example/project.git"
            ),
            "github.com:example/project.git"
        )
        XCTAssertEqual(
            GitDoltRemoteGenerationProbe.normalizedGitRemoteURL("../project.git"),
            "../project.git"
        )
        XCTAssertEqual(
            GitDoltRemoteGenerationProbe.normalizedGitRemoteURL("/tmp/project.git"),
            "/tmp/project.git"
        )
        XCTAssertEqual(
            GitDoltRemoteGenerationProbe.normalizedGitRemoteURL("project.git"),
            "project.git"
        )
    }

    func testRejectsNonGitRemoteURLs() {
        XCTAssertNil(GitDoltRemoteGenerationProbe.normalizedGitRemoteURL(""))
        XCTAssertNil(GitDoltRemoteGenerationProbe.normalizedGitRemoteURL("dolthub://example/project"))
        XCTAssertNil(GitDoltRemoteGenerationProbe.normalizedGitRemoteURL("mysql://localhost:3306/project"))
    }

    func testParsesDoltGenerationFromLSRemoteOutput() throws {
        let generation = String(repeating: "a", count: 40)

        XCTAssertEqual(
            try GitDoltRemoteGenerationProbe.generation(
                from: "\(generation)\trefs/dolt/data\n"
            ),
            generation
        )
    }

    func testRejectsMissingOrMalformedDoltGeneration() {
        XCTAssertThrowsError(try GitDoltRemoteGenerationProbe.generation(from: "")) { error in
            XCTAssertEqual(error as? DoltRemoteGenerationProbeError, .missingDoltReference)
        }
        XCTAssertThrowsError(
            try GitDoltRemoteGenerationProbe.generation(
                from: "not-a-generation\trefs/dolt/data\n"
            )
        ) { error in
            XCTAssertEqual(
                error as? DoltRemoteGenerationProbeError,
                .failed("The remote returned an invalid Dolt data reference.")
            )
        }
    }

    func testAccessProbeAcceptsReachableRemoteWithoutDoltReference() async throws {
        let toolchainURL = try makeToolchain(gitScript: """
        #!/bin/sh
        exit 0
        """)

        try await GitDoltRemoteGenerationProbe.verifyAccess(
            remote: testRemote,
            projectURL: toolchainURL.deletingLastPathComponent(),
            toolchainExecutableURL: toolchainURL
        )
    }

    func testAccessProbeReturnsCopyableRedactedGitFailure() async throws {
        let toolchainURL = try makeToolchain(gitScript: """
        #!/bin/sh
        printf '%s\n' "git@github.com: Permission denied (publickey)." >&2
        printf '%s\n' "fatal: Could not read from $2" >&2
        exit 128
        """)

        do {
            try await GitDoltRemoteGenerationProbe.verifyAccess(
                remote: testRemote,
                projectURL: toolchainURL.deletingLastPathComponent(),
                toolchainExecutableURL: toolchainURL
            )
            XCTFail("Expected the access probe to fail")
        } catch let BeadError.commandFailed(command, output) {
            XCTAssertEqual(command, "git ls-remote <Dolt remote> refs/dolt/data")
            XCTAssertTrue(output.contains("Permission denied (publickey)"))
            XCTAssertTrue(output.contains("fatal: Could not read from <Dolt remote>"))
            XCTAssertFalse(output.contains(testRemote.url))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private var testRemote: BeadsDoltRemote {
        BeadsDoltRemote(
            name: "origin",
            url: "git+ssh://git@github.com/example/project.git",
            sqlURL: nil,
            status: nil
        )
    }

    private func makeToolchain(gitScript: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let gitURL = directoryURL.appendingPathComponent("git")
        try gitScript.write(to: gitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: gitURL.path
        )
        return directoryURL.appendingPathComponent("bd")
    }
}
