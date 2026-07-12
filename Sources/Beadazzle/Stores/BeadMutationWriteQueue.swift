import Foundation

/// Serializes `bd` writes while allowing optimistic UI state to be applied immediately.
/// A failed write does not poison the queue; later user operations still run in order.
@MainActor
final class BeadMutationWriteQueue {
    private var chain: Task<Void, Never>?
    private var generation = 0

    func enqueue(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previousWrite = chain
        generation += 1
        let operationGeneration = generation
        let resultTask = Task { () -> Result<Void, any Error> in
            await previousWrite?.value
            do {
                try await operation()
                return .success(())
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
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }
}
