import XCTest
@testable import Beadazzle

final class BeadsCLIVersionProbeTests: XCTestCase {
    func testInterpretParsesVersionBanner() {
        let result = BeadsCLIVersionProbe.interpret(
            terminationStatus: 0,
            output: "bd version 1.0.4 (ce242a879: main@ce242a879678)",
            timedOut: false
        )

        XCTAssertEqual(result, .valid(version: "1.0.4 (ce242a879: main@ce242a879678)"))
    }

    func testInterpretUsesFirstNonEmptyLineOfOutput() {
        let result = BeadsCLIVersionProbe.interpret(
            terminationStatus: 0,
            output: "\n  bd version 2.1.0  \nextra diagnostics",
            timedOut: false
        )

        XCTAssertEqual(result, .valid(version: "2.1.0"))
    }

    func testInterpretRejectsSuccessfulRunWithoutBeadsBanner() {
        let result = BeadsCLIVersionProbe.interpret(
            terminationStatus: 0,
            output: "git version 2.44.0",
            timedOut: false
        )

        XCTAssertEqual(result, .invalid(message: "This executable doesn't look like the Beads CLI."))
    }

    func testInterpretReportsMissingExecutableForEnvFallbackExitCode() {
        let result = BeadsCLIVersionProbe.interpret(
            terminationStatus: 127,
            output: "env: bd: No such file or directory",
            timedOut: false
        )

        XCTAssertEqual(result, .invalid(message: "bd was not found. Install Beads or choose its path above."))
    }

    func testInterpretReportsInvalidExecutableForOtherFailures() {
        let result = BeadsCLIVersionProbe.interpret(
            terminationStatus: 1,
            output: "ls: version: No such file or directory",
            timedOut: false
        )

        XCTAssertEqual(result, .invalid(message: "This executable doesn't look like the Beads CLI."))
    }

    func testInterpretReportsTimeoutBeforeExitStatus() {
        let result = BeadsCLIVersionProbe.interpret(
            terminationStatus: 15,
            output: "",
            timedOut: true
        )

        XCTAssertEqual(result, .invalid(message: "bd did not respond to `bd version`."))
    }

    func testVersionRequiresBeadsBannerPrefix() {
        XCTAssertNil(BeadsCLIVersionProbe.version(from: ""))
        XCTAssertNil(BeadsCLIVersionProbe.version(from: "version 1.0.0"))
        XCTAssertNil(BeadsCLIVersionProbe.version(from: "bd version"))
        XCTAssertEqual(BeadsCLIVersionProbe.version(from: "BD Version 1.2.3"), "1.2.3")
    }

    func testCheckAgainstRealNonBeadsExecutable() async {
        let result = await BeadsCLIVersionProbe.check(
            executable: (url: URL(fileURLWithPath: "/usr/bin/true"), prefix: [])
        )

        XCTAssertEqual(result, .invalid(message: "This executable doesn't look like the Beads CLI."))
    }
}
