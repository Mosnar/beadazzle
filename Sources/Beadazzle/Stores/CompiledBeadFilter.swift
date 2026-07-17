import Foundation

/// An immutable, allocation-light form of an advanced saved-view predicate.
///
/// User-entered constants and calendar boundaries are normalized once at compile time.
/// `EvaluationContext` then lazily normalizes each issue field once while any number of
/// compiled predicates inspect that issue.
struct CompiledBeadFilter: Sendable {
    private let root: Node

    init?(
        _ storedGroup: BeadFilterGroup,
        now: Date,
        calendar: Calendar,
        locale: Locale
    ) {
        guard let group = storedGroup.validatedNormalized else { return nil }
        root = Node(group: group, now: now, calendar: calendar, locale: locale)
    }

    func matches(
        context: inout EvaluationContext,
        index: BeadProjectIndex,
        shouldCancel: @Sendable () -> Bool
    ) -> Bool {
        root.matches(context: &context, index: index, shouldCancel: shouldCancel)
    }

    struct EvaluationContext: Sendable {
        let issue: BeadIssue
        private let locale: Locale

        private var id = StringCache()
        private var title = StringCache()
        private var summaryText = StringCache()
        private var externalReference = StringCache()
        private var status = StringCache()
        private var type = StringCache()
        private var owner = StringCache()
        private var assignee = StringCache()
        private var parent = StringCache()
        private var foldedLabels: Set<String>?
        private var activeBlockerCount: Int?
        private var activelyBlockedCount: Int?
        private var hasChildren: Bool?
        private var priorityString: String?

        init(issue: BeadIssue, locale: Locale) {
            self.issue = issue
            self.locale = locale
        }

        private mutating func text(_ field: TextField, index: BeadProjectIndex) -> String? {
            switch field {
            case .id:
                if !id.isLoaded { id.load(issue.id, trimmingWhitespace: true) }
                return id.value
            case .title:
                if !title.isLoaded { title.load(issue.title, trimmingWhitespace: true) }
                return title.value
            case .summaryText:
                if !summaryText.isLoaded { summaryText.load(issue.summaryText, trimmingWhitespace: true) }
                return summaryText.value
            case .externalReference:
                if !externalReference.isLoaded {
                    externalReference.load(issue.externalRef, trimmingWhitespace: true)
                }
                return externalReference.value
            case .parent:
                if !parent.isLoaded {
                    parent.load(index.parentID(for: issue.id), trimmingWhitespace: true)
                }
                return parent.value
            }
        }

        fileprivate mutating func foldedText(_ field: TextField, index: BeadProjectIndex) -> String? {
            _ = text(field, index: index)
            switch field {
            case .id: return id.folded(locale: locale)
            case .title: return title.folded(locale: locale)
            case .summaryText: return summaryText.folded(locale: locale)
            case .externalReference: return externalReference.folded(locale: locale)
            case .parent: return parent.folded(locale: locale)
            }
        }

        fileprivate mutating func textIsEmpty(_ field: TextField, index: BeadProjectIndex) -> Bool {
            text(field, index: index)?.isEmpty != false
        }

        private mutating func choice(_ field: ChoiceField) -> String? {
            switch field {
            case .status:
                if !status.isLoaded { status.load(issue.status, trimmingWhitespace: false) }
                return status.value
            case .type:
                if !type.isLoaded { type.load(issue.issueType, trimmingWhitespace: false) }
                return type.value
            case .owner:
                if !owner.isLoaded { owner.load(issue.owner, trimmingWhitespace: false) }
                return owner.value
            case .assignee:
                if !assignee.isLoaded { assignee.load(issue.assignee, trimmingWhitespace: false) }
                return assignee.value
            }
        }

        fileprivate mutating func foldedChoice(_ field: ChoiceField) -> String? {
            _ = choice(field)
            switch field {
            case .status: return status.folded(locale: locale)
            case .type: return type.folded(locale: locale)
            case .owner: return owner.folded(locale: locale)
            case .assignee: return assignee.folded(locale: locale)
            }
        }

        fileprivate mutating func choiceIsEmpty(_ field: ChoiceField) -> Bool {
            choice(field)?.isEmpty != false
        }

        fileprivate mutating func labels() -> Set<String> {
            if let foldedLabels { return foldedLabels }
            var result: Set<String> = []
            result.reserveCapacity(issue.labels.count)
            for label in issue.labels {
                result.insert(Self.folded(label, locale: locale))
            }
            foldedLabels = result
            return result
        }

        fileprivate mutating func parentIsPresent(index: BeadProjectIndex) -> Bool {
            if !parent.isLoaded {
                parent.load(index.parentID(for: issue.id), trimmingWhitespace: true)
            }
            return parent.value != nil
        }

        fileprivate mutating func childrenArePresent(index: BeadProjectIndex) -> Bool {
            if let hasChildren { return hasChildren }
            let result = index.childProgress(for: issue.id) != nil
            hasChildren = result
            return result
        }

        fileprivate mutating func number(_ field: NumberField, index: BeadProjectIndex) -> Int {
            switch field {
            case .priority:
                return issue.priority
            case .activeBlockers:
                if let activeBlockerCount { return activeBlockerCount }
                let count = index.activeBlockingIssueCount(for: issue.id)
                activeBlockerCount = count
                return count
            case .activelyBlocked:
                if let activelyBlockedCount { return activelyBlockedCount }
                let count = index.activelyBlockedIssueCount(by: issue.id)
                activelyBlockedCount = count
                return count
            case .dependencies:
                return index.dependenciesByIssueID[issue.id, default: []].count
            case .dependents:
                return index.dependentsByIssueID[issue.id, default: []].count
            case .comments:
                return issue.commentCount
            }
        }

        fileprivate mutating func numberString(_ field: NumberField, index: BeadProjectIndex) -> String {
            if field == .priority {
                if let priorityString { return priorityString }
                let result = String(issue.priority)
                priorityString = result
                return result
            }
            return String(number(field, index: index))
        }

        fileprivate func date(_ field: DateField) -> Date? {
            switch field {
            case .created: issue.createdAt
            case .updated: issue.updatedAt
            case .closed: issue.closedAt
            case .due: issue.dueAt
            case .deferredUntil: issue.deferUntil
            }
        }

        fileprivate func flag(_ field: FlagField) -> Bool {
            switch field {
            case .pinned: issue.pinned
            case .ephemeral: issue.ephemeral
            case .template: issue.isTemplate
            case .gate: issue.isGate
            }
        }

        private static func folded(_ text: String, locale: Locale) -> String {
            text.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
        }
    }

    private struct StringCache: Sendable {
        private(set) var isLoaded = false
        private(set) var value: String?
        private var hasFolded = false
        private var foldedValue: String?

        mutating func load(_ source: String?, trimmingWhitespace: Bool) {
            guard !isLoaded else { return }
            value = trimmingWhitespace
                ? source?.trimmingCharacters(in: .whitespacesAndNewlines)
                : source
            isLoaded = true
        }

        mutating func folded(locale: Locale) -> String? {
            guard !hasFolded else { return foldedValue }
            foldedValue = value?.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            hasFolded = true
            return foldedValue
        }
    }

    private indirect enum Node: Sendable {
        case condition(Condition)
        case group(match: BeadFilterGroupMatch, children: [Node])

        init(group: BeadFilterGroup, now: Date, calendar: Calendar, locale: Locale) {
            self = .group(
                match: group.match,
                children: group.children.map { node in
                    switch node {
                    case .condition(let condition):
                        return .condition(Condition(condition, now: now, calendar: calendar, locale: locale))
                    case .group(let child):
                        return Node(group: child, now: now, calendar: calendar, locale: locale)
                    }
                }
            )
        }

        func matches(
            context: inout EvaluationContext,
            index: BeadProjectIndex,
            shouldCancel: @Sendable () -> Bool
        ) -> Bool {
            guard !shouldCancel() else { return false }
            switch self {
            case .condition(let condition):
                return condition.matches(context: &context, index: index)
            case .group(let match, let children):
                for child in children {
                    guard !shouldCancel() else { return false }
                    let result = child.matches(context: &context, index: index, shouldCancel: shouldCancel)
                    if match == .all, !result { return false }
                    if match == .any, result { return true }
                }
                return match == .all
            }
        }
    }

    private enum Condition: Sendable {
        case text(TextField, TextOperation)
        case choice(ChoiceField, ChoiceOperation)
        case labels(LabelOperation)
        case number(NumberField, NumberOperation)
        case date(DateField, DateOperation)
        case flag(FlagField, expected: Bool)
        case parentPresence(expected: Bool)
        case childrenPresence(expected: Bool)

        init(_ condition: BeadFilterCondition, now: Date, calendar: Calendar, locale: Locale) {
            switch condition.field {
            case .id:
                self = .text(.id, Self.textOperation(condition, locale: locale))
            case .title:
                self = .text(.title, Self.textOperation(condition, locale: locale))
            case .text:
                self = .text(.summaryText, Self.textOperation(condition, locale: locale))
            case .externalReference:
                self = .text(.externalReference, Self.textOperation(condition, locale: locale))
            case .status:
                self = .choice(.status, Self.choiceOperation(condition, locale: locale))
            case .type:
                self = .choice(.type, Self.choiceOperation(condition, locale: locale))
            case .owner:
                self = .choice(.owner, Self.choiceOperation(condition, locale: locale))
            case .assignee:
                self = .choice(.assignee, Self.choiceOperation(condition, locale: locale))
            case .priority:
                self = .number(.priority, Self.numberOperation(condition))
            case .labels:
                self = .labels(Self.labelOperation(condition, locale: locale))
            case .created:
                self = .date(.created, Self.dateOperation(condition, now: now, calendar: calendar))
            case .updated:
                self = .date(.updated, Self.dateOperation(condition, now: now, calendar: calendar))
            case .closed:
                self = .date(.closed, Self.dateOperation(condition, now: now, calendar: calendar))
            case .due:
                self = .date(.due, Self.dateOperation(condition, now: now, calendar: calendar))
            case .deferredUntil:
                self = .date(.deferredUntil, Self.dateOperation(condition, now: now, calendar: calendar))
            case .pinned:
                self = .flag(.pinned, expected: condition.operation == .isTrue)
            case .ephemeral:
                self = .flag(.ephemeral, expected: condition.operation == .isTrue)
            case .template:
                self = .flag(.template, expected: condition.operation == .isTrue)
            case .gate:
                self = .flag(.gate, expected: condition.operation == .isTrue)
            case .parent:
                if condition.operation == .hasAny || condition.operation == .hasNone {
                    self = .parentPresence(expected: condition.operation == .hasAny)
                } else {
                    self = .text(.parent, Self.textOperation(condition, locale: locale))
                }
            case .children:
                self = .childrenPresence(expected: condition.operation == .hasAny)
            case .activeBlockers:
                self = .number(.activeBlockers, Self.numberOperation(condition))
            case .activelyBlocked:
                self = .number(.activelyBlocked, Self.numberOperation(condition))
            case .dependencies:
                self = .number(.dependencies, Self.numberOperation(condition))
            case .dependents:
                self = .number(.dependents, Self.numberOperation(condition))
            case .comments:
                self = .number(.comments, Self.numberOperation(condition))
            }
        }

        func matches(context: inout EvaluationContext, index: BeadProjectIndex) -> Bool {
            switch self {
            case .text(let field, let operation):
                return operation.matches(field: field, context: &context, index: index)
            case .choice(let field, let operation):
                return operation.matches(field: field, context: &context)
            case .labels(let operation):
                return operation.matches(context: &context)
            case .number(let field, let operation):
                return operation.matches(field: field, context: &context, index: index)
            case .date(let field, let operation):
                return operation.matches(context.date(field))
            case .flag(let field, let expected):
                return context.flag(field) == expected
            case .parentPresence(let expected):
                return context.parentIsPresent(index: index) == expected
            case .childrenPresence(let expected):
                return context.childrenArePresent(index: index) == expected
            }
        }

        private static func textOperation(_ condition: BeadFilterCondition, locale: Locale) -> TextOperation {
            let value = folded(condition.value.text, locale: locale)
            return switch condition.operation {
            case .isEqual: .isEqual(value)
            case .isNot: .isNot(value)
            case .contains: .contains(value)
            case .doesNotContain: .doesNotContain(value)
            case .startsWith: .startsWith(value)
            case .isEmpty: .isEmpty
            case .isNotEmpty: .isNotEmpty
            default: preconditionFailure("Unsupported text operation")
            }
        }

        private static func choiceOperation(_ condition: BeadFilterCondition, locale: Locale) -> ChoiceOperation {
            return switch condition.operation {
            case .isAnyOf: .isAnyOf(Set(condition.value.strings.map { folded($0, locale: locale) }))
            case .isNoneOf: .isNoneOf(Set(condition.value.strings.map { folded($0, locale: locale) }))
            case .contains: .contains(folded(condition.value.text, locale: locale))
            case .isEmpty: .isEmpty
            case .isNotEmpty: .isNotEmpty
            default: preconditionFailure("Unsupported choice operation")
            }
        }

        private static func labelOperation(_ condition: BeadFilterCondition, locale: Locale) -> LabelOperation {
            let values = Set(condition.value.strings.map { folded($0, locale: locale) })
            return switch condition.operation {
            case .containsAny: .containsAny(values)
            case .containsAll: .containsAll(values)
            case .containsNone: .containsNone(values)
            case .isEmpty: .isEmpty
            case .isNotEmpty: .isNotEmpty
            default: preconditionFailure("Unsupported label operation")
            }
        }

        private static func numberOperation(_ condition: BeadFilterCondition) -> NumberOperation {
            return switch condition.operation {
            case .hasAny: .hasAny
            case .hasNone: .hasNone
            case .isAnyOf: .isAnyOf(condition.value.strings)
            case .isNoneOf: .isNoneOf(condition.value.strings)
            case .equals: .equals(condition.value.number)
            case .greaterThan: .greaterThan(condition.value.number)
            case .lessThan: .lessThan(condition.value.number)
            default: preconditionFailure("Unsupported number operation")
            }
        }

        private static func dateOperation(
            _ condition: BeadFilterCondition,
            now: Date,
            calendar: Calendar
        ) -> DateOperation {
            switch condition.operation {
            case .before:
                return .before(calendar.startOfDay(for: condition.value.date))
            case .after:
                let start = calendar.startOfDay(for: condition.value.date)
                return .after(calendar.date(byAdding: .day, value: 1, to: start) ?? condition.value.date)
            case .on:
                let start = calendar.startOfDay(for: condition.value.date)
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? .distantFuture
                return .on(start: start, end: end)
            case .inTheLast, .notInTheLast:
                let component: Calendar.Component = switch condition.value.relativeUnit {
                case .days: .day
                case .weeks: .weekOfYear
                case .months: .month
                }
                let startOfToday = calendar.startOfDay(for: now)
                let threshold = calendar.date(
                    byAdding: component,
                    value: -condition.value.relativeAmount,
                    to: startOfToday
                ) ?? .distantPast
                return .recent(
                    threshold: threshold,
                    now: now,
                    negated: condition.operation == .notInTheLast
                )
            case .isEmpty:
                return .isEmpty
            case .isNotEmpty:
                return .isNotEmpty
            default:
                preconditionFailure("Unsupported date operation")
            }
        }

        private static func folded(_ text: String, locale: Locale) -> String {
            text.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
        }
    }

    fileprivate enum TextField: Sendable { case id, title, summaryText, externalReference, parent }
    fileprivate enum ChoiceField: Sendable { case status, type, owner, assignee }
    fileprivate enum NumberField: Sendable, Equatable {
        case priority, activeBlockers, activelyBlocked, dependencies, dependents, comments
    }
    fileprivate enum DateField: Sendable { case created, updated, closed, due, deferredUntil }
    fileprivate enum FlagField: Sendable { case pinned, ephemeral, template, gate }

    private enum TextOperation: Sendable {
        case isEqual(String), isNot(String), contains(String), doesNotContain(String), startsWith(String)
        case isEmpty, isNotEmpty

        func matches(
            field: TextField,
            context: inout EvaluationContext,
            index: BeadProjectIndex
        ) -> Bool {
            switch self {
            case .isEmpty:
                return context.textIsEmpty(field, index: index)
            case .isNotEmpty:
                return !context.textIsEmpty(field, index: index)
            default:
                guard let value = context.foldedText(field, index: index) else { return false }
                return switch self {
                case .isEqual(let expected): value == expected
                case .isNot(let expected): value != expected
                case .contains(let expected): value.contains(expected)
                case .doesNotContain(let expected): !value.contains(expected)
                case .startsWith(let expected): value.hasPrefix(expected)
                case .isEmpty, .isNotEmpty: false
                }
            }
        }
    }

    private enum ChoiceOperation: Sendable {
        case isAnyOf(Set<String>), isNoneOf(Set<String>), contains(String)
        case isEmpty, isNotEmpty

        func matches(field: ChoiceField, context: inout EvaluationContext) -> Bool {
            switch self {
            case .isEmpty:
                return context.choiceIsEmpty(field)
            case .isNotEmpty:
                return !context.choiceIsEmpty(field)
            case .isAnyOf(let choices):
                guard let value = context.foldedChoice(field) else { return false }
                return choices.contains(value)
            case .isNoneOf(let choices):
                guard let value = context.foldedChoice(field) else { return true }
                return !choices.contains(value)
            case .contains(let expected):
                guard let value = context.foldedChoice(field) else { return false }
                return value.contains(expected)
            }
        }
    }

    private enum LabelOperation: Sendable {
        case containsAny(Set<String>), containsAll(Set<String>), containsNone(Set<String>)
        case isEmpty, isNotEmpty

        func matches(context: inout EvaluationContext) -> Bool {
            switch self {
            case .isEmpty:
                return context.issue.labels.isEmpty
            case .isNotEmpty:
                return !context.issue.labels.isEmpty
            case .containsAny(let wanted):
                return !context.labels().isDisjoint(with: wanted)
            case .containsAll(let wanted):
                return wanted.isSubset(of: context.labels())
            case .containsNone(let wanted):
                return context.labels().isDisjoint(with: wanted)
            }
        }
    }

    private enum NumberOperation: Sendable {
        case hasAny, hasNone, isAnyOf(Set<String>), isNoneOf(Set<String>)
        case equals(Int), greaterThan(Int), lessThan(Int)

        func matches(
            field: NumberField,
            context: inout EvaluationContext,
            index: BeadProjectIndex
        ) -> Bool {
            let value = context.number(field, index: index)
            return switch self {
            case .hasAny: value > 0
            case .hasNone: value == 0
            case .isAnyOf(let choices): choices.contains(context.numberString(field, index: index))
            case .isNoneOf(let choices): !choices.contains(context.numberString(field, index: index))
            case .equals(let expected): value == expected
            case .greaterThan(let expected): value > expected
            case .lessThan(let expected): value < expected
            }
        }
    }

    private enum DateOperation: Sendable {
        case before(Date), after(Date), on(start: Date, end: Date)
        case recent(threshold: Date, now: Date, negated: Bool)
        case isEmpty, isNotEmpty

        func matches(_ value: Date?) -> Bool {
            switch self {
            case .isEmpty:
                return value == nil
            case .isNotEmpty:
                return value != nil
            default:
                guard let value else { return false }
                return switch self {
                case .before(let threshold): value < threshold
                case .after(let threshold): value >= threshold
                case .on(let start, let end): value >= start && value < end
                case .recent(let threshold, let now, let negated):
                    negated != (value >= threshold && value <= now)
                case .isEmpty, .isNotEmpty: false
                }
            }
        }
    }
}
