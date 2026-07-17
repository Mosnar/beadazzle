import Foundation

struct BeadStateValuePresentation: Equatable, Identifiable, Sendable {
    let value: String
    let displayName: String
    let isArchived: Bool

    var id: String { value }
}

struct BeadStateValueCatalog: Equatable, Sendable {
    let active: [BeadStateValuePresentation]
    let archived: [BeadStateValuePresentation]

    static let empty = BeadStateValueCatalog(active: [], archived: [])

    var count: Int { active.count + archived.count }
}

enum BeadStateValueQueryMatch: Equatable, Sendable {
    case none
    case unique(BeadStateValuePresentation)
    case ambiguous

    var hasMatch: Bool {
        if case .none = self { return false }
        return true
    }
}

/// Resolves Return-key input without conflating distinct case-sensitive raw
/// values. Raw identifiers outrank display names, while an ambiguous folded
/// match requires the user to click the intended row instead of guessing.
enum BeadStateValuePickerPolicy {
    static func match(
        query: String,
        in values: [BeadStateValuePresentation],
        followedBy additionalValues: [BeadStateValuePresentation] = []
    ) -> BeadStateValueQueryMatch {
        var bestRank: Int?
        var bestValue: BeadStateValuePresentation?
        var isAmbiguous = false

        func consider(_ value: BeadStateValuePresentation) {
            guard let rank = matchRank(query: query, value: value) else { return }
            guard let currentBestRank = bestRank else {
                bestRank = rank
                bestValue = value
                isAmbiguous = false
                return
            }
            if rank < currentBestRank {
                bestRank = rank
                bestValue = value
                isAmbiguous = false
            } else if rank == currentBestRank, bestValue?.value != value.value {
                isAmbiguous = true
            }
        }

        for value in values {
            consider(value)
        }
        for value in additionalValues {
            consider(value)
        }

        guard let bestValue else { return .none }
        return isAmbiguous ? .ambiguous : .unique(bestValue)
    }

    private static func matchRank(
        query: String,
        value: BeadStateValuePresentation
    ) -> Int? {
        if value.value == query { return 0 }
        if value.value.caseInsensitiveCompare(query) == .orderedSame { return 1 }
        if value.displayName == query { return 2 }
        if value.displayName.caseInsensitiveCompare(query) == .orderedSame { return 3 }
        return nil
    }
}
