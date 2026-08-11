import Foundation

struct CancellableProcessResult: Sendable {
    var terminationStatus: Int32
    var output: String
    var outputWasTruncated: Bool
}

enum CancellableProcessRunnerError: Error, Equatable, Sendable {
    case timedOut
}

/// Runs read-only subprocesses without occupying Swift's cooperative executor.
/// Cancellation normally returns immediately, terminates the child when it has
/// launched, and closes its pipes so descendants cannot keep the caller waiting.
enum CancellableProcessRunner {
    enum CancellationMode: Sendable {
        case returnImmediately
        case waitForProcessExit
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String],
        outputLimit: Int? = nil,
        timeout: Duration? = nil,
        cancellationMode: CancellationMode = .returnImmediately
    ) async throws -> CancellableProcessResult {
        guard let timeout else {
            return try await runWithoutTimeout(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                environment: environment,
                outputLimit: outputLimit,
                cancellationMode: cancellationMode
            )
        }
        return try await withThrowingTaskGroup(of: CancellableProcessResult.self) { group in
            group.addTask {
                try await runWithoutTimeout(
                    executableURL: executableURL,
                    arguments: arguments,
                    currentDirectoryURL: currentDirectoryURL,
                    environment: environment,
                    outputLimit: outputLimit,
                    cancellationMode: cancellationMode
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CancellableProcessRunnerError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private static func runWithoutTimeout(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String],
        outputLimit: Int?,
        cancellationMode: CancellationMode
    ) async throws -> CancellableProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        let state = CancellableProcessExecutionState(cancellationMode: cancellationMode)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    defer {
                        if process.isRunning {
                            process.waitUntilExit()
                        }
                        state.finishCancellationAfterProcessExit()
                    }
                    do {
                        guard !state.isCancelled else { return }
                        try process.run()
                        if state.markLaunchedAndShouldTerminate() {
                            if process.isRunning {
                                process.terminate()
                            }
                            return
                        }

                        let captured = try readOutput(
                            from: output.fileHandleForReading,
                            limit: outputLimit
                        )
                        // EOF only proves every writer closed the pipe; wait for the
                        // direct child before reading Process termination properties.
                        process.waitUntilExit()
                        guard !state.isCancelled else { return }
                        state.finish(.success(CancellableProcessResult(
                            terminationStatus: process.terminationStatus,
                            output: String(data: captured.data, encoding: .utf8)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                            outputWasTruncated: captured.wasTruncated
                        )))
                    } catch {
                        guard !state.isCancelled else { return }
                        state.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            let shouldTerminate = state.cancel()
            if shouldTerminate, process.isRunning {
                process.terminate()
            }
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
    }

    private static func readOutput(
        from handle: FileHandle,
        limit: Int?
    ) throws -> (data: Data, wasTruncated: Bool) {
        var captured = Data()
        var wasTruncated = false
        while let chunk = try handle.read(upToCount: 8 * 1024), !chunk.isEmpty {
            guard let limit else {
                captured.append(chunk)
                continue
            }
            let remaining = max(0, limit - captured.count)
            if remaining > 0 {
                captured.append(chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                wasTruncated = true
            }
        }
        return (captured, wasTruncated)
    }
}

private final class CancellableProcessExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationMode: CancellableProcessRunner.CancellationMode
    private var continuation: CheckedContinuation<CancellableProcessResult, Error>?
    private var launched = false
    private var cancelled = false
    private var finished = false

    init(cancellationMode: CancellableProcessRunner.CancellationMode) {
        self.cancellationMode = cancellationMode
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func install(_ continuation: CheckedContinuation<CancellableProcessResult, Error>) -> Bool {
        let shouldResumeCancellation = lock.withLock {
            guard !finished else { return true }
            if cancelled {
                finished = true
                return true
            }
            self.continuation = continuation
            return false
        }
        if shouldResumeCancellation {
            continuation.resume(throwing: CancellationError())
            return false
        }
        return true
    }

    func markLaunchedAndShouldTerminate() -> Bool {
        lock.withLock {
            launched = true
            return cancelled
        }
    }

    func cancel() -> Bool {
        let outcome: (Bool, CheckedContinuation<CancellableProcessResult, Error>?) = lock.withLock {
            cancelled = true
            guard !finished else { return (launched, nil) }
            if case .waitForProcessExit = cancellationMode, continuation != nil {
                return (launched, nil)
            }
            finished = true
            let continuation = continuation
            self.continuation = nil
            return (launched, continuation)
        }
        outcome.1?.resume(throwing: CancellationError())
        return outcome.0
    }

    func finishCancellationAfterProcessExit() {
        let continuationToResume = lock.withLock {
            guard cancelled, !finished else {
                return nil as CheckedContinuation<CancellableProcessResult, Error>?
            }
            finished = true
            let storedContinuation = continuation
            continuation = nil
            return storedContinuation
        }
        continuationToResume?.resume(throwing: CancellationError())
    }

    func finish(_ result: Result<CancellableProcessResult, Error>) {
        let continuationToResume = lock.withLock {
            guard !cancelled, !finished else {
                return nil as CheckedContinuation<CancellableProcessResult, Error>?
            }
            finished = true
            let storedContinuation = self.continuation
            self.continuation = nil
            return storedContinuation
        }
        continuationToResume?.resume(with: result)
    }
}
