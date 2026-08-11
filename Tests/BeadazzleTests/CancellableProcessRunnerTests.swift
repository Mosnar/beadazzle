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

    func testCancellationCanWaitUntilChildProcessHasExited() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CancellableProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let markerURL = directoryURL.appendingPathComponent("terminated")
        let readyURL = directoryURL.appendingPathComponent("ready")
        let task = Task {
            try await CancellableProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap 'printf terminated > \"$1\"; exit 0' TERM; printf ready > \"$2\"; while :; do :; done",
                    "beadazzle-test",
                    markerURL.path,
                    readyURL.path
                ],
                currentDirectoryURL: directoryURL,
                environment: ProcessInfo.processInfo.environment,
                cancellationMode: .waitForProcessExit
            )
        }

        let clock = ContinuousClock()
        let readinessDeadline = clock.now.advanced(by: .seconds(1))
        while !FileManager.default.fileExists(atPath: readyURL.path), clock.now < readinessDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyURL.path))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled subprocess should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
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
