import XCTest
@testable import Beadazzle

final class BeadsCLITests: XCTestCase {
    func testExecutableUsesConfiguredPathBeforeEnvironmentOverrideWhenExecutable() {
        let result = BeadsCLI.executable(
            configuredPath: "/tmp/configured-bd",
            environment: ["BEADAZZLE_BD_PATH": "/tmp/env-bd", "PATH": "/bin"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            isExecutable: { $0 == "/tmp/configured-bd" || $0 == "/tmp/env-bd" }
        )

        XCTAssertEqual(result.url.path, "/tmp/configured-bd")
        XCTAssertTrue(result.prefix.isEmpty)
    }

    func testExecutableIgnoresInvalidConfiguredPathAndFallsBackToEnvironmentOverride() {
        let result = BeadsCLI.executable(
            configuredPath: "/tmp/not-executable",
            environment: ["BEADAZZLE_BD_PATH": "/tmp/env-bd", "PATH": "/bin"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            isExecutable: { $0 == "/tmp/env-bd" }
        )

        XCTAssertEqual(result.url.path, "/tmp/env-bd")
        XCTAssertTrue(result.prefix.isEmpty)
    }

    func testExecutableUsesEnvironmentOverrideWhenExecutable() {
        let result = BeadsCLI.executable(
            environment: ["BEADAZZLE_BD_PATH": "/tmp/custom-bd", "PATH": "/bin"],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            isExecutable: { $0 == "/tmp/custom-bd" }
        )

        XCTAssertEqual(result.url.path, "/tmp/custom-bd")
        XCTAssertTrue(result.prefix.isEmpty)
    }

    func testExecutableSearchesHomeLocalBinForGuiLaunches() {
        let result = BeadsCLI.executable(
            environment: ["PATH": ""],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            isExecutable: { $0 == "/tmp/home/.local/bin/bd" }
        )

        XCTAssertEqual(result.url.path, "/tmp/home/.local/bin/bd")
        XCTAssertTrue(result.prefix.isEmpty)
    }

    func testExecutableFallsBackToEnvWhenNoCandidateExists() {
        let result = BeadsCLI.executable(
            environment: ["PATH": ""],
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            isExecutable: { _ in false }
        )

        XCTAssertEqual(result.url.path, "/usr/bin/env")
        XCTAssertEqual(result.prefix, ["bd"])
    }
}
