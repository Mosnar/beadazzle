import Foundation

/// Serializes `bd` writes while allowing optimistic UI state to be applied immediately.
/// A failed write does not poison the queue; later user operations still run in order.
@MainActor
final class BeadMutationWriteQueue {
    private var chain: Task<Void, Never>?
    private var generation = 0

    func enqueue<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let previousWrite = chain
        generation += 1
        let operationGeneration = generation
        let resultTask = Task { () -> Result<Value, any Error> in
            await previousWrite?.value
            do {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
        chain = Task {
            _ = await resultTask.value
        }

        defer {
            if generation == operationGeneration {
                chain = nil
            }
        }

        switch await resultTask.value {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
final class BeadOptimisticMutationQueue {
    private var isAcquired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isAcquired {
            isAcquired = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isAcquired = false
            return
        }
        waiters.removeFirst().resume()
    }
}
