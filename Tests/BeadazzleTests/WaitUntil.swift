import XCTest

extension XCTestCase {
    @MainActor
    func waitUntil(
        _ label: String = "condition",
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(label)", file: file, line: line)
                throw TestWaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor
    func waitUntil(
        _ label: String = "condition",
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () async -> Bool
    ) async throws {
        try await waitUntil(label, timeout: .seconds(timeout), file: file, line: line, condition: condition)
    }
}

private enum TestWaitError: Error {
    case timedOut
}
