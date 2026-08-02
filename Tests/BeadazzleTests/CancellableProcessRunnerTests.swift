import Foundation
import XCTest
@testable import Beadazzle

final class CancellableProcessRunnerTests: XCTestCase {
    func testCapturesOutputUpToConfiguredLimit() async throws {
        let result = try await CancellableProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 1234567890"],
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment,
            outputLimit: 5
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.output, "12345")
        XCTAssertTrue(result.outputWasTruncated)
    }

    func testCancellationReturnsWithoutWaitingForChildProcess() async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let task = Task {
            try await CancellableProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                currentDirectoryURL: FileManager.default.temporaryDirectory,
                environment: ProcessInfo.processInfo.environment
            )
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled subprocess should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
    }

    func testTimeoutReturnsWithoutWaitingForChildProcess() async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            _ = try await CancellableProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                currentDirectoryURL: FileManager.default.temporaryDirectory,
                environment: ProcessInfo.processInfo.environment,
                timeout: .milliseconds(50)
            )
            XCTFail("A timed-out subprocess should throw")
        } catch CancellableProcessRunnerError.timedOut {
            // Expected.
        } catch {
            XCTFail("Expected timedOut, received \(error)")
        }
        XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(1))
    }

    func testWaitsForProcessExitAfterOutputPipeCloses() async throws {
        let result = try await CancellableProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 1>&-; exec 2>&-; sleep 0.05; exit 7"],
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            environment: ProcessInfo.processInfo.environment
        )

        XCTAssertEqual(result.terminationStatus, 7)
        XCTAssertEqual(result.output, "")
    }
}
