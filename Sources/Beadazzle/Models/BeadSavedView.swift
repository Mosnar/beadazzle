import AppKit
import Foundation

struct BeadSavedView: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var symbolName: String
    var query: BeadSavedViewQuery
    var ordering: BeadSavedViewOrdering

    var hasValidQuery: Bool {
        query.advancedPredicate?.isValid ?? true
    }

    private enum CodingKeys: String, CodingKey { case id, name, symbolName, query, ordering }

    init(
        id: UUID,
        name: String,
        symbolName: String,
        query: BeadSavedViewQuery,
        ordering: BeadSavedViewOrdering
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.query = query
        self.ordering = ordering
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbolName = try container.decode(String.self, forKey: .symbolName)
        query = try container.decode(BeadSavedViewQuery.self, forKey: .query)
        ordering = try container.decode(BeadSavedViewOrdering.self, forKey: .ordering)
        guard hasValidQuery, query.advancedPredicate?.hasUniqueNodeIDs != false else {
            throw DecodingError.dataCorruptedError(
                forKey: .query,
                in: container,
                debugDescription: "Saved view contains an invalid predicate or duplicate node identity"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(symbolName, forKey: .symbolName)
        try container.encode(query, forKey: .query)
        try container.encode(ordering, forKey: .ordering)
    }
}

struct BeadSavedViewQuery: Hashable, Codable, Sendable {
    var basePreset: BeadBookmarkToken
    var statusFilters: Set<String>
    var typeFilters: Set<String>
    var priorityFilters: Set<Int>
    var labelFilters: Set<String>
    var searchText: String
    var advancedPredicate: BeadFilterGroup? = nil
}

struct BeadSavedViewSort: Hashable, Codable, Sendable {
    var field: IssueSort
    var direction: SortDirection
}

struct BeadSavedViewManualOrdering: Hashable, Codable, Sendable {
    var issueIDs: [String]
    var fallback: BeadSavedViewSort
}

enum BeadSavedViewOrdering: Hashable, Codable, Sendable {
    case sorted(BeadSavedViewSort)
    case manual(BeadSavedViewManualOrdering)

    var fallbackSort: BeadSavedViewSort {
        get {
            switch self {
            case .sorted(let sort): sort
            case .manual(let manual): manual.fallback
            }
        }
        set {
            switch self {
            case .sorted:
                self = .sorted(newValue)
            case .manual(var manual):
                manual.fallback = newValue
                self = .manual(manual)
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, sorted, manual }
    private enum Kind: String, Codable { case sorted, manual }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .sorted:
            self = .sorted(try container.decode(BeadSavedViewSort.self, forKey: .sorted))
        case .manual:
            self = .manual(try container.decode(BeadSavedViewManualOrdering.self, forKey: .manual))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sorted(let sort):
            try container.encode(Kind.sorted, forKey: .kind)
            try container.encode(sort, forKey: .sorted)
        case .manual(let manual):
            try container.encode(Kind.manual, forKey: .kind)
            try container.encode(manual, forKey: .manual)
        }
    }
}

enum BeadFilterGroupMatch: String, CaseIterable, Codable, Identifiable, Sendable {
    case all
    case any

    var id: Self { self }
    var title: String { self == .all ? "Match all" : "Match any" }
}

struct BeadFilterGroup: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var match: BeadFilterGroupMatch = .all
    var children: [BeadFilterNode] = []

    var conditionCount: Int {
        children.reduce(0) { count, node in
            switch node {
            case .condition: count + 1
            case .group(let group): count + group.conditionCount
            }
        }
    }

    var normalized: BeadFilterGroup? {
        let children = children.compactMap(\.normalized)
        return children.isEmpty ? nil : BeadFilterGroup(id: id, match: match, children: children)
    }

    /// Normalizes an editor-authored predicate without ever broadening an invalid
    /// persisted query. Invalid persisted groups must be rejected as a whole.
    var validatedNormalized: BeadFilterGroup? {
        guard isValid else { return nil }
        return normalized
    }

    var isValid: Bool {
        !children.isEmpty && children.allSatisfy { node in
            switch node {
            case .condition(let condition): condition.isValid
            case .group(let group): group.isValid
            }
        }
    }

    var containsRelativeDateRule: Bool {
        children.contains { node in
            switch node {
            case .condition(let condition):
                condition.operation == .inTheLast || condition.operation == .notInTheLast
            case .group(let group):
                group.containsRelativeDateRule
            }
        }
    }

    var nodeIDs: [UUID] {
        [id] + children.flatMap { node in
            switch node {
            case .condition(let condition): [condition.id]
            case .group(let group): group.nodeIDs
            }
        }
    }

    var hasUniqueNodeIDs: Bool {
        let ids = nodeIDs
        return Set(ids).count == ids.count
    }

    private enum CodingKeys: String, CodingKey { case id, match, children }

    init(id: UUID = UUID(), match: BeadFilterGroupMatch = .all, children: [BeadFilterNode] = []) {
        self.id = id
        self.match = match
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        match = try container.decode(BeadFilterGroupMatch.self, forKey: .match)
        children = try container.decode([BeadFilterNode].self, forKey: .children)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(match, forKey: .match)
        try container.encode(children, forKey: .children)
    }
}

indirect enum BeadFilterNode: Identifiable, Hashable, Codable, Sendable {
    case condition(BeadFilterCondition)
    case group(BeadFilterGroup)

    var id: UUID {
        switch self {
        case .condition(let condition): condition.id
        case .group(let group): group.id
        }
    }

    var normalized: BeadFilterNode? {
        switch self {
        case .condition(let condition):
            condition.isValid ? self : nil
        case .group(let group):
            group.normalized.map(Self.group)
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, condition, group }
    private enum Kind: String, Codable { case condition, group }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .condition: self = .condition(try container.decode(BeadFilterCondition.self, forKey: .condition))
        case .group: self = .group(try container.decode(BeadFilterGroup.self, forKey: .group))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .condition(let condition):
            try container.encode(Kind.condition, forKey: .kind)
            try container.encode(condition, forKey: .condition)
        case .group(let group):
            try container.encode(Kind.group, forKey: .kind)
            try container.encode(group, forKey: .group)
        }
    }
}

enum BeadFilterField: String, CaseIterable, Codable, Identifiable, Sendable {
    case id, title, text, externalReference
    case status, type, priority, labels, owner, assignee
    case created, updated, closed, due, deferredUntil
    case pinned, ephemeral, template, gate
    case parent, children, activeBlockers, activelyBlocked, dependencies, dependents, comments

    var id: Self { self }

    var title: String {
        switch self {
        case .id: "ID"
        case .title: "Title"
        case .text: "Searchable text"
        case .externalReference: "External reference"
        case .status: "Status"
        case .type: "Type"
        case .priority: "Priority"
        case .labels: "Labels"
        case .owner: "Owner"
        case .assignee: "Assignee"
        case .created: "Created"
        case .updated: "Updated"
        case .closed: "Closed"
        case .due: "Due"
        case .deferredUntil: "Deferred until"
        case .pinned: "Pinned"
        case .ephemeral: "Ephemeral"
        case .template: "Template"
        case .gate: "Gate"
        case .parent: "Parent"
        case .children: "Children"
        case .activeBlockers: "Active blockers"
        case .activelyBlocked: "Actively blocked beads"
        case .dependencies: "Dependencies"
        case .dependents: "Dependents"
        case .comments: "Comments"
        }
    }

    var operations: [BeadFilterOperation] {
        switch self {
        case .id, .title, .text, .externalReference:
            [.isEqual, .isNot, .contains, .doesNotContain, .startsWith, .isEmpty, .isNotEmpty]
        case .status, .type, .owner, .assignee:
            [.isAnyOf, .isNoneOf, .contains, .isEmpty, .isNotEmpty]
        case .priority:
            [.isAnyOf, .isNoneOf, .equals, .greaterThan, .lessThan]
        case .labels:
            [.containsAny, .containsAll, .containsNone, .isEmpty, .isNotEmpty]
        case .created, .updated, .closed, .due, .deferredUntil:
            [.before, .after, .on, .inTheLast, .notInTheLast, .isEmpty, .isNotEmpty]
        case .pinned, .ephemeral, .template, .gate:
            [.isTrue, .isFalse]
        case .parent:
            [.isEqual, .isNot, .hasAny, .hasNone]
        case .children, .activeBlockers, .activelyBlocked:
            [.hasAny, .hasNone]
        case .dependencies, .dependents, .comments:
            [.hasAny, .hasNone, .equals, .greaterThan, .lessThan]
        }
    }
}

enum BeadFilterOperation: String, CaseIterable, Codable, Identifiable, Sendable {
    case isEqual = "is"
    case isNot, contains, doesNotContain, startsWith, isEmpty, isNotEmpty
    case isAnyOf, isNoneOf, containsAny, containsAll, containsNone
    case before, after, on, inTheLast, notInTheLast
    case isTrue, isFalse, hasAny, hasNone
    case equals, greaterThan, lessThan

    var id: Self { self }
    var needsValue: Bool { ![.isEmpty, .isNotEmpty, .isTrue, .isFalse, .hasAny, .hasNone].contains(self) }

    var title: String {
        switch self {
        case .isEqual: "is"
        case .isNot: "is not"
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        case .startsWith: "starts with"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        case .isAnyOf: "is any of"
        case .isNoneOf: "is none of"
        case .containsAny: "contains any"
        case .containsAll: "contains all"
        case .containsNone: "contains none"
        case .before: "is before"
        case .after: "is after"
        case .on: "is on"
        case .inTheLast: "is in the last"
        case .notInTheLast: "is not in the last"
        case .isTrue: "is true"
        case .isFalse: "is false"
        case .hasAny: "has any"
        case .hasNone: "has none"
        case .equals: "equals"
        case .greaterThan: "is greater than"
        case .lessThan: "is less than"
        }
    }
}

enum BeadRelativeDateUnit: String, CaseIterable, Codable, Identifiable, Sendable {
    case days, weeks, months
    var id: Self { self }
}

struct BeadFilterValue: Hashable, Codable, Sendable {
    var text = ""
    var strings: Set<String> = []
    var number = 0
    var date = Date()
    var relativeAmount = 7
    var relativeUnit = BeadRelativeDateUnit.days
}

private struct PersistedFilterValue: Codable, Hashable {
    enum Kind: String, Codable, Hashable { case none, text, strings, number, date, relativeDate }
    var kind: Kind
    var text: String? = nil
    var strings: Set<String>? = nil
    var number: Int? = nil
    var date: Date? = nil
    var relativeAmount: Int? = nil
    var relativeUnit: BeadRelativeDateUnit? = nil
}

struct BeadFilterCondition: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var field: BeadFilterField = .status
    var operation: BeadFilterOperation = .isAnyOf
    var value = BeadFilterValue()

    var isValid: Bool {
        field.operations.contains(operation) && (!operation.needsValue || hasValue)
    }

    private var hasValue: Bool {
        switch operation {
        case .isAnyOf, .isNoneOf, .containsAny, .containsAll, .containsNone:
            !value.strings.isEmpty
        case .inTheLast, .notInTheLast:
            value.relativeAmount > 0
        case .equals, .greaterThan, .lessThan, .before, .after, .on:
            true
        default:
            !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private enum CodingKeys: String, CodingKey { case id, field, operation, value }

    init(
        id: UUID = UUID(),
        field: BeadFilterField = .status,
        operation: BeadFilterOperation = .isAnyOf,
        value: BeadFilterValue = BeadFilterValue()
    ) {
        self.id = id
        self.field = field
        self.operation = operation
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        field = try container.decode(BeadFilterField.self, forKey: .field)
        operation = try container.decode(BeadFilterOperation.self, forKey: .operation)
        let persistedValue = try container.decode(PersistedFilterValue.self, forKey: .value)
        value = try Self.runtimeValue(from: persistedValue, field: field, operation: operation, codingPath: decoder.codingPath)
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .operation,
                in: container,
                debugDescription: "Invalid field, operation, or value combination"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(field, forKey: .field)
        try container.encode(operation, forKey: .operation)
        try container.encode(persistedValue, forKey: .value)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.field == rhs.field
            && lhs.operation == rhs.operation
            && lhs.persistedValue == rhs.persistedValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(field)
        hasher.combine(operation)
        hasher.combine(persistedValue)
    }

    private var persistedValue: PersistedFilterValue {
        if !operation.needsValue {
            return PersistedFilterValue(kind: .none)
        }
        switch operation {
        case .isAnyOf, .isNoneOf, .containsAny, .containsAll, .containsNone:
            return PersistedFilterValue(kind: .strings, strings: value.strings)
        case .inTheLast, .notInTheLast:
            return PersistedFilterValue(
                kind: .relativeDate,
                relativeAmount: value.relativeAmount,
                relativeUnit: value.relativeUnit
            )
        case .before, .after, .on:
            return PersistedFilterValue(kind: .date, date: value.date)
        case .equals, .greaterThan, .lessThan:
            return PersistedFilterValue(kind: .number, number: value.number)
        default:
            return PersistedFilterValue(kind: .text, text: value.text)
        }
    }

    private static func runtimeValue(
        from persisted: PersistedFilterValue,
        field: BeadFilterField,
        operation: BeadFilterOperation,
        codingPath: [CodingKey]
    ) throws -> BeadFilterValue {
        var value = BeadFilterValue()
        let invalid = {
            DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "Persisted value kind does not match \(field.rawValue).\(operation.rawValue)"
            ))
        }
        if !operation.needsValue {
            guard persisted.kind == .none else { throw invalid() }
            return value
        }
        switch operation {
        case .isAnyOf, .isNoneOf, .containsAny, .containsAll, .containsNone:
            guard persisted.kind == .strings, let strings = persisted.strings else { throw invalid() }
            value.strings = strings
        case .inTheLast, .notInTheLast:
            guard persisted.kind == .relativeDate,
                  let amount = persisted.relativeAmount,
                  let unit = persisted.relativeUnit else { throw invalid() }
            value.relativeAmount = amount
            value.relativeUnit = unit
        case .before, .after, .on:
            guard persisted.kind == .date, let date = persisted.date else { throw invalid() }
            value.date = date
        case .equals, .greaterThan, .lessThan:
            guard persisted.kind == .number, let number = persisted.number else { throw invalid() }
            value.number = number
        default:
            guard persisted.kind == .text, let text = persisted.text else { throw invalid() }
            value.text = text
        }
        return value
    }
}

enum BeadBookmarkToken: String, Codable, CaseIterable, Sendable {
    case ready
    case stale
    case open
    case inProgress = "in_progress"
    case blocked
    case closed
    case gates
    case all

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown bookmark preset: \(rawValue)"
            )
        }
        self = value
    }

    var bookmark: BeadBookmark {
        switch self {
        case .ready: .ready
        case .stale: .stale
        case .open: .open
        case .inProgress: .inProgress
        case .blocked: .blocked
        case .closed: .closed
        case .gates: .gates
        case .all: .all
        }
    }

    init(_ bookmark: BeadBookmark) {
        switch bookmark {
        case .ready: self = .ready
        case .stale: self = .stale
        case .open: self = .open
        case .inProgress: self = .inProgress
        case .blocked: self = .blocked
        case .closed: self = .closed
        case .gates: self = .gates
        case .all: self = .all
        }
    }
}

enum BeadSavedViewSymbols {
    static let fallback = "bookmark"
    static let choices = [
        "bookmark", "bookmark.fill", "star", "flag", "tray", "archivebox",
        "checkmark.circle", "clock", "bolt", "flame", "tag", "folder",
        "list.bullet", "line.3.horizontal.decrease.circle", "magnifyingglass",
        "person", "person.2", "calendar", "exclamationmark.triangle", "circle.hexagongrid"
    ].filter(isAvailable)

    static func normalized(_ symbolName: String) -> String {
        isAvailable(symbolName) ? symbolName : fallback
    }

    static func isAvailable(_ symbolName: String) -> Bool {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil
    }

    static func title(for symbolName: String) -> String {
        switch symbolName {
        case "bookmark": "Bookmark"
        case "bookmark.fill": "Filled Bookmark"
        case "star": "Star"
        case "flag": "Flag"
        case "tray": "Tray"
        case "archivebox": "Archive"
        case "checkmark.circle": "Completed"
        case "clock": "Clock"
        case "bolt": "Bolt"
        case "flame": "Flame"
        case "tag": "Tag"
        case "folder": "Folder"
        case "list.bullet": "List"
        case "line.3.horizontal.decrease.circle": "Filter"
        case "magnifyingglass": "Search"
        case "person": "Person"
        case "person.2": "People"
        case "calendar": "Calendar"
        case "exclamationmark.triangle": "Warning"
        case "circle.hexagongrid": "All Beads"
        default: "Bookmark Icon"
        }
    }
}

struct BeadSavedViewsPayload: Codable, Sendable {
    static let currentVersion = 1

    var version = currentVersion
    var rootNodes: [BeadSavedViewNode]
}

struct BeadSavedViewPreview: Equatable, Sendable {
    struct Item: Equatable, Identifiable, Sendable {
        var id: String
        var title: String
    }

    var count: Int
    var sample: [Item]
}

enum BeadSidebarSelection: Hashable, Sendable {
    case preset(BeadBookmark)
    case savedView(UUID)
}
