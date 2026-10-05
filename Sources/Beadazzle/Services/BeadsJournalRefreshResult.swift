import Foundation

enum BeadsJournalRefreshResult: Sendable {
    case none
    case projected(observedFiles: ProjectSnapshotFreshnessFiles)
    case heldAfterFailedVerification

    var requiresVerification: Bool {
        switch self {
        case .none: false
        case .projected, .heldAfterFailedVerification: true
        }
    }
}
