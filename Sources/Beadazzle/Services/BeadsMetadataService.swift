import Foundation

struct BeadsMetadataService {
    func loadSemantics(
        projectURL _: URL,
        issues: [BeadIssue],
        statusDefinitions: [BeadStatusDefinition]? = nil,
        typeDefinitions: [BeadTypeDefinition]? = nil
    ) -> BeadProjectSemantics {
        let baseStatuses = statusDefinitions?.isEmpty == false ? statusDefinitions ?? [] : Self.builtInStatuses
        let baseTypes = typeDefinitions?.isEmpty == false ? typeDefinitions ?? [] : Self.coreTypes
        return BeadProjectSemantics(
            statuses: mergeStatusDefinitions(baseStatuses, observedIssues: issues),
            types: mergeTypeDefinitions(baseTypes, observedIssues: issues)
        )
    }

    static func decodeStatuses(from data: Data) throws -> [BeadStatusDefinition] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        let builtIn = statusDefinitions(from: object["built_in_statuses"], isBuiltIn: true, source: .builtIn)
        let custom = statusDefinitions(from: object["custom_statuses"], isBuiltIn: false, source: .custom)
        return (builtIn + custom).sorted { $0.name < $1.name }
    }

    static func decodeTypes(from data: Data) throws -> [BeadTypeDefinition] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var definitions = typeDefinitions(from: object["core_types"], source: .core)
        definitions += typeDefinitions(from: object["custom_types"], source: .custom)
        return definitions.sorted { $0.name < $1.name }
    }

    private static func statusDefinitions(from value: Any?, isBuiltIn: Bool, source: BeadDefinitionSource) -> [BeadStatusDefinition] {
        guard let records = value as? [[String: Any]] else { return [] }
        return records.compactMap { record in
            guard let name = record["name"] as? String, !name.isEmpty else { return nil }
            let categoryName = record["category"] as? String
            return BeadStatusDefinition(
                name: name,
                category: BeadStatusCategory(rawValue: categoryName ?? "") ?? .uncategorized,
                icon: record["icon"] as? String,
                description: record["description"] as? String,
                isBuiltIn: isBuiltIn,
                source: source
            )
        }
    }

    private static func typeDefinitions(from value: Any?, source: BeadDefinitionSource) -> [BeadTypeDefinition] {
        if let records = value as? [[String: Any]] {
            return records.compactMap { record in
                guard let name = record["name"] as? String, !name.isEmpty else { return nil }
                return BeadTypeDefinition(name: name, description: record["description"] as? String, source: source)
            }
        }

        if let names = value as? [String] {
            return names
                .filter { !$0.isEmpty }
                .map { BeadTypeDefinition(name: $0, description: nil, source: source) }
        }

        return []
    }

    private func mergeStatusDefinitions(_ definitions: [BeadStatusDefinition], observedIssues: [BeadIssue]) -> [BeadStatusDefinition] {
        var byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
        let observedStatuses = Set(observedIssues.lazy.compactMap { issue in
            !issue.isSystemRecord && !issue.status.isEmpty ? issue.status : nil
        })
        for status in observedStatuses where byName[status] == nil {
            byName[status] = BeadStatusDefinition(name: status, category: .uncategorized, icon: nil, description: nil, source: .observed)
        }
        return byName.values.sorted { lhs, rhs in
            if lhs.category.rawValue == rhs.category.rawValue {
                return lhs.name < rhs.name
            }
            return lhs.category.rawValue < rhs.category.rawValue
        }
    }

    private func mergeTypeDefinitions(_ definitions: [BeadTypeDefinition], observedIssues: [BeadIssue]) -> [BeadTypeDefinition] {
        var byName = Dictionary(uniqueKeysWithValues: definitions
            .filter { !BeadIssueWorkflowPolicy.isSystemRecordIssueType($0.name) }
            .map { ($0.name, $0) })
        let observedTypes = Set(observedIssues.lazy.compactMap { issue in
            let type = issue.issueType
            return !type.isEmpty && !BeadIssueWorkflowPolicy.isSystemRecordIssueType(type) ? type : nil
        })
        for type in observedTypes where byName[type] == nil {
            byName[type] = BeadTypeDefinition(name: type, description: nil, source: .observed)
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    private static let builtInStatuses = [
        BeadStatusDefinition(name: "open", category: .active, icon: nil, description: "Available to work (default)", isBuiltIn: true, source: .builtIn),
        BeadStatusDefinition(name: "in_progress", category: .wip, icon: nil, description: "Actively being worked on", isBuiltIn: true, source: .builtIn),
        BeadStatusDefinition(name: "blocked", category: .wip, icon: nil, description: "Blocked by a dependency", isBuiltIn: true, source: .builtIn),
        BeadStatusDefinition(name: "deferred", category: .frozen, icon: nil, description: "Deliberately put on ice for later", isBuiltIn: true, source: .builtIn),
        BeadStatusDefinition(name: "closed", category: .done, icon: nil, description: "Completed", isBuiltIn: true, source: .builtIn),
        BeadStatusDefinition(name: "pinned", category: .frozen, icon: nil, description: "Persistent, stays open indefinitely", isBuiltIn: true, source: .builtIn),
        BeadStatusDefinition(name: "hooked", category: .wip, icon: nil, description: "Attached to an agent's hook", isBuiltIn: true, source: .builtIn)
    ]

    private static let coreTypes = [
        BeadTypeDefinition(name: "task", description: "General work item (default)", source: .core),
        BeadTypeDefinition(name: "bug", description: "Bug report or defect", source: .core),
        BeadTypeDefinition(name: "feature", description: "New feature or enhancement", source: .core),
        BeadTypeDefinition(name: "chore", description: "Maintenance or housekeeping", source: .core),
        BeadTypeDefinition(name: "epic", description: "Large body of work spanning multiple issues", source: .core),
        BeadTypeDefinition(name: "decision", description: "Architecture decision record (ADR)", source: .core),
        BeadTypeDefinition(name: "spike", description: "Timeboxed investigation to reduce uncertainty before committing to a story", source: .core),
        BeadTypeDefinition(name: "story", description: "User story describing a feature from the user's perspective", source: .core),
        BeadTypeDefinition(name: "milestone", description: "Marks completion of a set of related issues (contains no work itself)", source: .core)
    ]
}
