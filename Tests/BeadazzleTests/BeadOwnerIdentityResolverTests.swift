import XCTest
@testable import Beadazzle

final class BeadOwnerIdentityResolverTests: XCTestCase {
    func testEnvironmentIdentityTakesPrecedenceOverGitConfiguration() {
        XCTAssertEqual(
            BeadOwnerIdentityResolver.identity(
                environment: ["GIT_AUTHOR_EMAIL": "environment@example.com"],
                gitEmail: "git@example.com"
            ),
            .resolved(value: "environment@example.com", source: .environment)
        )
    }

    func testGitIdentityIsTrimmedWhenEnvironmentIsUnavailable() {
        XCTAssertEqual(
            BeadOwnerIdentityResolver.identity(
                environment: [:],
                gitEmail: "  git@example.com\n"
            ),
            .resolved(value: "git@example.com", source: .gitConfiguration)
        )
    }

    func testEmptyIdentitySourcesRemainUnavailable() {
        XCTAssertNil(BeadOwnerIdentityResolver.identity(environment: [:], gitEmail: " \n "))
    }

    func testGitLookupReturnsNilWhenGitCannotBeResolved() {
        XCTAssertNil(
            BeadOwnerIdentityResolver.readGitEmail(
                projectURL: FileManager.default.temporaryDirectory,
                environment: ["PATH": "/path-that-does-not-exist"],
                timeout: 0.1
            )
        )
    }

    func testGitLookupTerminatesAfterTimeout() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeadOwnerIdentityResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let gitURL = directoryURL.appendingPathComponent("git")
        try "#!/bin/sh\nwhile :; do :; done\n".write(
            to: gitURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: gitURL.path
        )

        let startedAt = Date()
        let email = BeadOwnerIdentityResolver.readGitEmail(
            projectURL: directoryURL,
            environment: ["PATH": directoryURL.path],
            timeout: 0.05
        )

        XCTAssertNil(email)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }
}
