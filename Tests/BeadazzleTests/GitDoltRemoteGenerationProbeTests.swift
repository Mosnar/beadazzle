import XCTest
@testable import Beadazzle

final class GitDoltRemoteGenerationProbeTests: XCTestCase {
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
}
