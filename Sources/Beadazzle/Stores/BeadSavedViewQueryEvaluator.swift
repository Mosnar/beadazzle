import Foundation

struct BeadSavedViewQueryEvaluator: Sendable {
    private struct BaseQuery: Hashable {
        var preset: BeadBookmarkToken
        var statuses: Set<String>
        var types: Set<String>
        var priorities: Set<Int>
        var labels: Set<String>
        var searchText: String

        init(_ filter: BeadSavedViewFilter) {
            preset = filter.basePreset
            statuses = filter.statusFilters
            types = filter.typeFilters
            priorities = filter.priorityFilters
            labels = filter.labelFilters
            searchText = filter.searchText
        }
    }

    static func filteredIssueIDs(
        index: BeadProjectIndex,
        filter: BeadSavedViewFilter,
        now: Date = Date(),
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [String] {
        let baseIDs = BeadIssueListQuery.filteredIssueIDs(
            index: index,
            bookmark: filter.basePreset.bookmark,
            statusFilters: filter.statusFilters,
            typeFilters: filter.typeFilters,
            priorityFilters: filter.priorityFilters,
            labelFilters: filter.labelFilters,
            searchText: filter.searchText,
            shouldCancel: shouldCancel
        )
        guard let storedPredicate = filter.advancedPredicate else { return baseIDs }
        guard storedPredicate.isValid, let predicate = storedPredicate.normalized else { return [] }

        return baseIDs.filter { id in
            guard !shouldCancel(), let issue = index.issue(with: id) else { return false }
            return matches(group: predicate, issue: issue, index: index, now: now, shouldCancel: shouldCancel)
        }
    }

    static func matchingIssueCount(
        index: BeadProjectIndex,
        filter: BeadSavedViewFilter,
        now: Date = Date(),
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> Int? {
        let baseIDs = baseIssueIDs(index: index, filter: filter, shouldCancel: shouldCancel)
        guard !shouldCancel() else { return nil }
        return matchingIssueCount(
            index: index,
            baseIDs: baseIDs,
            predicate: filter.advancedPredicate,
            now: now,
            shouldCancel: shouldCancel
        )
    }

    static func matchingIssueCounts(
        index: BeadProjectIndex,
        filters: [(id: UUID, filter: BeadSavedViewFilter)],
        now: Date = Date(),
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [UUID: Int]? {
        var baseCache: [BaseQuery: [String]] = [:]
        var counts: [UUID: Int] = [:]
        counts.reserveCapacity(filters.count)

        for entry in filters {
            guard !shouldCancel() else { return nil }
            let key = BaseQuery(entry.filter)
            let baseIDs: [String]
            if let cached = baseCache[key] {
                baseIDs = cached
            } else {
                baseIDs = baseIssueIDs(index: index, filter: entry.filter, shouldCancel: shouldCancel)
                guard !shouldCancel() else { return nil }
                baseCache[key] = baseIDs
            }
            guard let count = matchingIssueCount(
                index: index,
                baseIDs: baseIDs,
                predicate: entry.filter.advancedPredicate,
                now: now,
                shouldCancel: shouldCancel
            ) else { return nil }
            counts[entry.id] = count
        }
        return counts
    }

    private static func baseIssueIDs(
        index: BeadProjectIndex,
        filter: BeadSavedViewFilter,
        shouldCancel: @Sendable () -> Bool
    ) -> [String] {
        BeadIssueListQuery.filteredIssueIDs(
            index: index,
            bookmark: filter.basePreset.bookmark,
            statusFilters: filter.statusFilters,
            typeFilters: filter.typeFilters,
            priorityFilters: filter.priorityFilters,
            labelFilters: filter.labelFilters,
            searchText: filter.searchText,
            shouldCancel: shouldCancel
        )
    }

    private static func matchingIssueCount(
        index: BeadProjectIndex,
        baseIDs: [String],
        predicate storedPredicate: BeadFilterGroup?,
        now: Date,
        shouldCancel: @Sendable () -> Bool
    ) -> Int? {
        guard let storedPredicate else { return baseIDs.count }
        guard storedPredicate.isValid, let predicate = storedPredicate.normalized else { return 0 }
        var count = 0
        for id in baseIDs {
            guard !shouldCancel() else { return nil }
            if let issue = index.issue(with: id),
               matches(group: predicate, issue: issue, index: index, now: now, shouldCancel: shouldCancel) {
                count += 1
            }
        }
        return count
    }

    private static func matches(
        group: BeadFilterGroup,
        issue: BeadIssue,
        index: BeadProjectIndex,
        now: Date,
        shouldCancel: @Sendable () -> Bool
    ) -> Bool {
        for node in group.children {
            guard !shouldCancel() else { return false }
            let result: Bool
            switch node {
            case .condition(let condition):
                result = matches(condition: condition, issue: issue, index: index, now: now)
            case .group(let child):
                result = matches(group: child, issue: issue, index: index, now: now, shouldCancel: shouldCancel)
            }
            if group.match == .all, !result { return false }
            if group.match == .any, result { return true }
        }
        return group.match == .all
    }

    private static func matches(
        condition: BeadFilterCondition,
        issue: BeadIssue,
        index: BeadProjectIndex,
        now: Date
    ) -> Bool {
        switch condition.field {
        case .id: return matches(text: issue.id, condition: condition)
        case .title: return matches(text: issue.title, condition: condition)
        case .text: return matches(text: issue.summaryText, condition: condition)
        case .externalReference: return matches(text: issue.externalRef, condition: condition)
        case .status: return matches(choice: issue.status, condition: condition)
        case .type: return matches(choice: issue.issueType, condition: condition)
        case .priority: return matches(number: issue.priority, condition: condition)
        case .labels: return matches(values: Set(issue.labels), condition: condition)
        case .owner: return matches(choice: issue.owner, condition: condition)
        case .assignee: return matches(choice: issue.assignee, condition: condition)
        case .created: return matches(date: issue.createdAt, condition: condition, now: now)
        case .updated: return matches(date: issue.updatedAt, condition: condition, now: now)
        case .closed: return matches(date: issue.closedAt, condition: condition, now: now)
        case .due: return matches(date: issue.dueAt, condition: condition, now: now)
        case .deferredUntil: return matches(date: issue.deferUntil, condition: condition, now: now)
        case .pinned: return matches(flag: issue.pinned, operation: condition.operation)
        case .ephemeral: return matches(flag: issue.ephemeral, operation: condition.operation)
        case .template: return matches(flag: issue.isTemplate, operation: condition.operation)
        case .gate: return matches(flag: issue.isGate, operation: condition.operation)
        case .parent:
            let parent = index.parentID(for: issue.id)
            if condition.operation == .hasAny { return parent != nil }
            if condition.operation == .hasNone { return parent == nil }
            return matches(text: parent, condition: condition)
        case .children:
            return matches(presence: index.childProgress(for: issue.id) != nil, operation: condition.operation)
        case .activeBlockers:
            let count = index.activeBlockingIssueCount(for: issue.id)
            return matches(number: count, condition: condition)
        case .activelyBlocked:
            let count = index.activelyBlockedIssueCount(by: issue.id)
            return matches(number: count, condition: condition)
        case .dependencies:
            return matches(number: index.dependenciesByIssueID[issue.id, default: []].count, condition: condition)
        case .dependents:
            return matches(number: index.dependentsByIssueID[issue.id, default: []].count, condition: condition)
        case .comments:
            return matches(number: issue.commentCount, condition: condition)
        }
    }

    private static func matches(text: String?, condition: BeadFilterCondition) -> Bool {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if condition.operation == .isEmpty { return text?.isEmpty != false }
        if condition.operation == .isNotEmpty { return text?.isEmpty == false }
        guard let text else { return false }
        let lhs = folded(text)
        let rhs = folded(condition.value.text)
        switch condition.operation {
        case .isEqual: return lhs == rhs
        case .isNot: return lhs != rhs
        case .contains: return lhs.contains(rhs)
        case .doesNotContain: return !lhs.contains(rhs)
        case .startsWith: return lhs.hasPrefix(rhs)
        default: return false
        }
    }

    private static func matches(choice: String?, condition: BeadFilterCondition) -> Bool {
        if condition.operation == .isEmpty { return choice?.isEmpty != false }
        if condition.operation == .isNotEmpty { return choice?.isEmpty == false }
        guard let choice else { return condition.operation == .isNoneOf }
        let foldedChoice = folded(choice)
        let choices = Set(condition.value.strings.map(folded))
        switch condition.operation {
        case .isAnyOf: return choices.contains(foldedChoice)
        case .isNoneOf: return !choices.contains(foldedChoice)
        case .contains: return foldedChoice.contains(folded(condition.value.text))
        default: return matches(text: choice, condition: condition)
        }
    }

    private static func matches(values: Set<String>, condition: BeadFilterCondition) -> Bool {
        let values = Set(values.map(folded))
        let wanted = Set(condition.value.strings.map(folded))
        switch condition.operation {
        case .containsAny: return !values.isDisjoint(with: wanted)
        case .containsAll: return wanted.isSubset(of: values)
        case .containsNone: return values.isDisjoint(with: wanted)
        case .isEmpty: return values.isEmpty
        case .isNotEmpty: return !values.isEmpty
        default: return false
        }
    }

    private static func matches(number: Int, condition: BeadFilterCondition) -> Bool {
        switch condition.operation {
        case .hasAny: return number > 0
        case .hasNone: return number == 0
        case .isAnyOf: return condition.value.strings.contains(String(number))
        case .isNoneOf: return !condition.value.strings.contains(String(number))
        case .equals: return number == condition.value.number
        case .greaterThan: return number > condition.value.number
        case .lessThan: return number < condition.value.number
        default: return false
        }
    }

    private static func matches(date: Date?, condition: BeadFilterCondition, now: Date) -> Bool {
        if condition.operation == .isEmpty { return date == nil }
        if condition.operation == .isNotEmpty { return date != nil }
        guard let date else { return false }
        let calendar = Calendar.current
        switch condition.operation {
        case .before: return date < calendar.startOfDay(for: condition.value.date)
        case .after:
            let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: condition.value.date))
                ?? condition.value.date
            return date >= startOfNextDay
        case .on: return calendar.isDate(date, inSameDayAs: condition.value.date)
        case .inTheLast, .notInTheLast:
            let component: Calendar.Component = switch condition.value.relativeUnit {
            case .days: .day
            case .weeks: .weekOfYear
            case .months: .month
            }
            // Relative periods are calendar based. This keeps membership stable
            // throughout the day and gives the UI one precise midnight boundary.
            let startOfToday = calendar.startOfDay(for: now)
            let threshold = calendar.date(
                byAdding: component,
                value: -condition.value.relativeAmount,
                to: startOfToday
            ) ?? .distantPast
            let isRecent = date >= threshold && date <= now
            return condition.operation == .inTheLast ? isRecent : !isRecent
        default: return false
        }
    }

    private static func matches(flag: Bool, operation: BeadFilterOperation) -> Bool {
        operation == .isTrue ? flag : operation == .isFalse ? !flag : false
    }

    private static func matches(presence: Bool, operation: BeadFilterOperation) -> Bool {
        operation == .hasAny ? presence : operation == .hasNone ? !presence : false
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}
