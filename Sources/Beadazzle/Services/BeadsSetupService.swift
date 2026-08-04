import Foundation

final class BeadsSetupCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.withLock { isCancelled = true }
    }

    func checkCancellation() throws {
        let isCancelled = lock.withLock { self.isCancelled }
        if isCancelled { throw CancellationError() }
    }
}

enum BeadsSetupInspectionScope: Equatable, Sendable {
    case wizard
    case audit
}

protocol BeadsSetupServicing: Sendable {
    func inspect(
        projectURL: URL,
        scope: BeadsSetupInspectionScope,
        candidateRemote: BeadsDoltRemote?,
        preloadedEnvironment: BeadsProjectEnvironment?
    ) async throws -> BeadsSetupAssessment

    func apply(
        projectURL: URL,
        plan: BeadsSetupPlan,
        cancellationToken: BeadsSetupCancellationToken,
        progress: @escaping BeadsSetupApplyProgressHandler
    ) async throws -> BeadsSetupApplyReport
}
