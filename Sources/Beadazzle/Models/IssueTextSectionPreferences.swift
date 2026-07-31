import Foundation

enum IssueTextSectionVisibilityMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case suggestedForType
    case descriptionOnly
    case allSections

    var id: Self { self }

    var title: String {
        switch self {
        case .suggestedForType:
            "Suggested for Type"
        case .descriptionOnly:
            "Description Only"
        case .allSections:
            "All Sections"
        }
    }
}

struct IssueTextSectionSuggestionMatrix: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let otherTypesKey = "*"

    var version = currentVersion
    var sectionsByType: [String: [IssueTextSection]]

    static let beadsDefault = IssueTextSectionSuggestionMatrix(sectionsByType: [
        "bug": [.description, .acceptanceCriteria],
        "feature": [.description, .acceptanceCriteria],
        "task": [.description, .acceptanceCriteria],
        "epic": [.description],
        "chore": [.description],
        "decision": [.description],
        otherTypesKey: [.description]
    ])

    static let builtInTypeNames = [
        "bug",
        "feature",
        "task",
        "epic",
        "chore",
        "decision"
    ]

    func sections(for issueType: String) -> Set<IssueTextSection> {
        let key = Self.normalizedTypeName(issueType)
        return Set(sectionsByType[key] ?? sectionsByType[Self.otherTypesKey] ?? [.description])
    }

    mutating func setSections(_ sections: Set<IssueTextSection>, for issueType: String) {
        let key = issueType == Self.otherTypesKey
            ? Self.otherTypesKey
            : Self.normalizedTypeName(issueType)
        sectionsByType[key] = IssueTextSection.canonicalOrder.filter(sections.contains)
    }

    func normalized() -> Self {
        var normalizedRows: [String: [IssueTextSection]] = [:]
        for (rawType, rawSections) in sectionsByType {
            let type = rawType == Self.otherTypesKey
                ? Self.otherTypesKey
                : Self.normalizedTypeName(rawType)
            guard !type.isEmpty else { continue }
            let sectionSet = Set(rawSections)
            normalizedRows[type] = IssueTextSection.canonicalOrder.filter(sectionSet.contains)
        }
        if normalizedRows[Self.otherTypesKey] == nil {
            normalizedRows[Self.otherTypesKey] = [.description]
        }
        return Self(version: Self.currentVersion, sectionsByType: normalizedRows)
    }

    static func normalizedTypeName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct IssueTextSectionPreferences: Equatable, Sendable {
    var visibilityMode: IssueTextSectionVisibilityMode
    var order: [IssueTextSection]
    var suggestions: IssueTextSectionSuggestionMatrix

    static let beadsDefault = IssueTextSectionPreferences(
        visibilityMode: .suggestedForType,
        order: IssueTextSection.canonicalOrder,
        suggestions: .beadsDefault
    )

    func normalized() -> Self {
        Self(
            visibilityMode: visibilityMode,
            order: Self.normalizedOrder(order),
            suggestions: suggestions.normalized()
        )
    }

    static func normalizedOrder(_ order: [IssueTextSection]) -> [IssueTextSection] {
        var seen: Set<IssueTextSection> = []
        let known = order.filter { seen.insert($0).inserted }
        return known + IssueTextSection.canonicalOrder.filter { !seen.contains($0) }
    }
}

struct ProjectIssueTextSectionOverrides: Equatable, Sendable {
    var visibilityMode: IssueTextSectionVisibilityMode?
    var order: [IssueTextSection]?
    /// Sparse map: a missing type inherits the app row.
    var suggestionsByType: [String: [IssueTextSection]]

    static let inherited = ProjectIssueTextSectionOverrides(
        visibilityMode: nil,
        order: nil,
        suggestionsByType: [:]
    )

    var isEmpty: Bool {
        visibilityMode == nil && order == nil && suggestionsByType.isEmpty
    }

    func normalized() -> Self {
        var rows: [String: [IssueTextSection]] = [:]
        for (rawType, rawSections) in suggestionsByType {
            let type = IssueTextSectionSuggestionMatrix.normalizedTypeName(rawType)
            guard !type.isEmpty else { continue }
            let sectionSet = Set(rawSections)
            rows[type] = IssueTextSection.canonicalOrder.filter(sectionSet.contains)
        }
        return Self(
            visibilityMode: visibilityMode,
            order: order.map(IssueTextSectionPreferences.normalizedOrder),
            suggestionsByType: rows
        )
    }
}
