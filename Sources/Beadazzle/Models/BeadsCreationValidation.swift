import Foundation

struct BeadsCreateResult: Equatable, Sendable {
    let issueID: String
    let warning: String?
}

enum BeadsCreationValidationMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case warn
    case error

    var id: Self { self }

    var title: String {
        switch self {
        case .none:
            "None"
        case .warn:
            "Warn"
        case .error:
            "Error"
        }
    }
}

struct BeadsCreationValidationSettings: Equatable, Sendable {
    var requiresDescription: Bool
    var mode: BeadsCreationValidationMode

    static let beadsDefault = BeadsCreationValidationSettings(
        requiresDescription: false,
        mode: .none
    )
}

enum BeadsCreationValidationLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}
