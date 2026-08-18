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
        let payload = try JSONDecoder().decode(StatusPayload.self, from: data)
        let builtIn = try statusDefinitions(
            from: payload.builtInStatuses ?? [],
            isBuiltIn: true,
            source: .builtIn
        )
        let custom = try statusDefinitions(
            from: payload.customStatuses ?? [],
            isBuiltIn: false,
            source: .custom
        )
        return (builtIn + custom).sorted { $0.name < $1.name }
    }

    static func decodeTypes(from data: Data) throws -> [BeadTypeDefinition] {
        let payload = try JSONDecoder().decode(TypePayload.self, from: data)
        var definitions = try typeDefinitions(from: payload.coreTypes ?? [], source: .core)
        definitions += try typeDefinitions(from: payload.customTypes ?? [], source: .custom)
        return definitions.sorted { $0.name < $1.name }
    }

    private static func statusDefinitions(
        from records: [StatusRecord],
        isBuiltIn: Bool,
        source: BeadDefinitionSource
    ) throws -> [BeadStatusDefinition] {
        try records.map { record in
            guard let name = record.name.nilIfBlank else {
                throw invalidMetadata("A status definition is missing a name.")
            }
            return BeadStatusDefinition(
                name: name,
                category: BeadStatusCategory(rawValue: record.category ?? "") ?? .uncategorized,
                icon: record.icon,
                description: record.description,
                isBuiltIn: isBuiltIn,
                source: source
            )
        }
    }

    private static func typeDefinitions(
        from values: [TypeValue],
        source: BeadDefinitionSource
    ) throws -> [BeadTypeDefinition] {
        try values.map { value in
            let name: String
            let description: String?
            switch value {
            case .name(let value):
                name = value
                description = nil
            case .record(let record):
                name = record.name
                description = record.description
            }
            guard let name = name.nilIfBlank else {
                throw invalidMetadata("A type definition is missing a name.")
            }
            return BeadTypeDefinition(name: name, description: description, source: source)
        }
    }

    private static func invalidMetadata(_ description: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: description))
    }

    private struct StatusPayload: Decodable {
        let builtInStatuses: [StatusRecord]?
        let customStatuses: [StatusRecord]?

        enum CodingKeys: String, CodingKey {
            case builtInStatuses = "built_in_statuses"
            case customStatuses = "custom_statuses"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.builtInStatuses) || container.contains(.customStatuses) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .builtInStatuses,
                    in: container,
                    debugDescription: "The status response did not include status definitions."
                )
            }
            builtInStatuses = try container.decodeIfPresent([StatusRecord].self, forKey: .builtInStatuses)
            customStatuses = try container.decodeIfPresent([StatusRecord].self, forKey: .customStatuses)
        }
    }

    private struct StatusRecord: Decodable {
        let name: String
        let category: String?
        let icon: String?
        let description: String?
    }

    private struct TypePayload: Decodable {
        let coreTypes: [TypeValue]?
        let customTypes: [TypeValue]?

        enum CodingKeys: String, CodingKey {
            case coreTypes = "core_types"
            case customTypes = "custom_types"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.coreTypes) || container.contains(.customTypes) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .coreTypes,
                    in: container,
                    debugDescription: "The type response did not include type definitions."
                )
            }
            coreTypes = try container.decodeIfPresent([TypeValue].self, forKey: .coreTypes)
            customTypes = try container.decodeIfPresent([TypeValue].self, forKey: .customTypes)
        }
    }

    private enum TypeValue: Decodable {
        case name(String)
        case record(TypeRecord)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let name = try? container.decode(String.self) {
                self = .name(name)
            } else {
                self = .record(try container.decode(TypeRecord.self))
            }
        }
    }

    private struct TypeRecord: Decodable {
        let name: String
        let description: String?
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
