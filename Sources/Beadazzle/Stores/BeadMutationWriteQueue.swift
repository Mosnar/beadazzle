import Foundation

/// Serializes `bd` writes while allowing optimistic UI state to be applied immediately.
/// A failed write does not poison the queue; later user operations still run in order.
@MainActor
final class BeadMutationWriteQueue {
    private var chain: Task<Void, Never>?
    private var generation = 0
    private var lifecycleGeneration = 0

    /// Prevents writes that are still waiting behind an earlier operation from starting
    /// after the store switches projects. An operation that has already begun is allowed
    /// to finish because interrupting a database write may leave the tracker inconsistent.
    func invalidatePending() {
        lifecycleGeneration &+= 1
    }

    func enqueue<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let previousWrite = chain
        let expectedLifecycleGeneration = lifecycleGeneration
        generation += 1
        let operationGeneration = generation
        let resultTask = Task { () -> Result<Value, any Error> in
            await previousWrite?.value
            guard self.lifecycleGeneration == expectedLifecycleGeneration else {
                return .failure(CancellationError())
            }
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
