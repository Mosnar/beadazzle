import Foundation

struct BeadSavedViewQueryEvaluator: Sendable {
    private struct BaseQuery: Hashable {
        let preset: BeadBookmarkToken
        let statuses: Set<String>
        let types: Set<String>
        let priorities: Set<Int>
        let labels: Set<String>
        let searchText: String

        init(_ filter: BeadSavedViewQuery) {
            preset = filter.basePreset
            statuses = filter.statusFilters
            types = filter.typeFilters
            priorities = filter.priorityFilters
            labels = filter.labelFilters
            searchText = filter.searchText
        }
    }

    private struct CountPlan {
        let outputIDs: [UUID]
        let predicate: CompiledBeadFilter
    }

    static func filteredIssueIDs(
        index: BeadProjectIndex,
        filter: BeadSavedViewQuery,
        now: Date = Date(),
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [String] {
        let baseIDs = baseIssueIDs(index: index, filter: filter, shouldCancel: shouldCancel)
        guard let storedPredicate = filter.advancedPredicate else { return baseIDs }

        let locale = Locale.current
        guard let predicate = CompiledBeadFilter(
            storedPredicate,
            now: now,
            calendar: .current,
            locale: locale
        ) else { return [] }

        var matchingIDs: [String] = []
        matchingIDs.reserveCapacity(baseIDs.count)
        for id in baseIDs {
            guard !shouldCancel(), let issue = index.issue(with: id) else { continue }
            var context = CompiledBeadFilter.EvaluationContext(issue: issue, locale: locale)
            if predicate.matches(context: &context, index: index, shouldCancel: shouldCancel) {
                matchingIDs.append(id)
            }
        }
        return shouldCancel() ? [] : matchingIDs
    }

    static func matchingIssueCount(
        index: BeadProjectIndex,
        filter: BeadSavedViewQuery,
        now: Date = Date(),
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> Int? {
        let baseIDs = baseIssueIDs(index: index, filter: filter, shouldCancel: shouldCancel)
        guard !shouldCancel() else { return nil }
        guard let storedPredicate = filter.advancedPredicate else { return baseIDs.count }

        let locale = Locale.current
        guard let predicate = CompiledBeadFilter(
            storedPredicate,
            now: now,
            calendar: .current,
            locale: locale
        ) else { return 0 }

        var count = 0
        for id in baseIDs {
            guard !shouldCancel() else { return nil }
            guard let issue = index.issue(with: id) else { continue }
            var context = CompiledBeadFilter.EvaluationContext(issue: issue, locale: locale)
            if predicate.matches(context: &context, index: index, shouldCancel: shouldCancel) {
                count += 1
            }
        }
        return shouldCancel() ? nil : count
    }

    static func matchingIssueCounts(
        index: BeadProjectIndex,
        filters: [(id: UUID, filter: BeadSavedViewQuery)],
        now: Date = Date(),
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> [UUID: Int]? {
        PerformanceSignposts.query.withIntervalSignpost("SavedViewCounts") {
            matchingIssueCountsWithoutSignpost(
                index: index,
                filters: filters,
                now: now,
                shouldCancel: shouldCancel
            )
        }
    }

    private static func matchingIssueCountsWithoutSignpost(
        index: BeadProjectIndex,
        filters: [(id: UUID, filter: BeadSavedViewQuery)],
        now: Date,
        shouldCancel: @Sendable () -> Bool
    ) -> [UUID: Int]? {
        guard !filters.isEmpty else { return [:] }

        // Deduplicate complete queries first. Duplicating a saved view keeps its query
        // identity, so identical views share both compilation and evaluation.
        var outputIDsByFilter: [BeadSavedViewQuery: [UUID]] = [:]
        var uniqueFilters: [BeadSavedViewQuery] = []
        uniqueFilters.reserveCapacity(filters.count)
        for entry in filters {
            guard !shouldCancel() else { return nil }
            if outputIDsByFilter[entry.filter] == nil {
                uniqueFilters.append(entry.filter)
            }
            outputIDsByFilter[entry.filter, default: []].append(entry.id)
        }

        // Group by the inexpensive base query, but evaluate one group at a time so a
        // project with many distinct saved views never retains every candidate-ID array.
        var filtersByBaseQuery: [BaseQuery: [BeadSavedViewQuery]] = [:]
        var baseQueryOrder: [BaseQuery] = []
        for filter in uniqueFilters {
            let baseQuery = BaseQuery(filter)
            if filtersByBaseQuery[baseQuery] == nil {
                baseQueryOrder.append(baseQuery)
            }
            filtersByBaseQuery[baseQuery, default: []].append(filter)
        }

        let locale = Locale.current
        let calendar = Calendar.current
        var counts: [UUID: Int] = [:]
        counts.reserveCapacity(filters.count)

        for baseQuery in baseQueryOrder {
            guard !shouldCancel(), let groupedFilters = filtersByBaseQuery[baseQuery],
                  let representative = groupedFilters.first else {
                return nil
            }
            let baseIDs = baseIssueIDs(
                index: index,
                filter: representative,
                shouldCancel: shouldCancel
            )
            guard !shouldCancel() else { return nil }

            var plans: [CountPlan] = []
            plans.reserveCapacity(groupedFilters.count)
            for filter in groupedFilters {
                guard !shouldCancel(), let outputIDs = outputIDsByFilter[filter] else { return nil }
                guard let storedPredicate = filter.advancedPredicate else {
                    for id in outputIDs { counts[id] = baseIDs.count }
                    continue
                }
                guard let predicate = CompiledBeadFilter(
                    storedPredicate,
                    now: now,
                    calendar: calendar,
                    locale: locale
                ) else {
                    for id in outputIDs { counts[id] = 0 }
                    continue
                }
                plans.append(CountPlan(outputIDs: outputIDs, predicate: predicate))
            }

            guard !plans.isEmpty else { continue }
            var planCounts = Array(repeating: 0, count: plans.count)
            for id in baseIDs {
                guard !shouldCancel() else { return nil }
                guard let issue = index.issue(with: id) else { continue }
                var context = CompiledBeadFilter.EvaluationContext(issue: issue, locale: locale)
                for planIndex in plans.indices {
                    guard !shouldCancel() else { return nil }
                    if plans[planIndex].predicate.matches(
                        context: &context,
                        index: index,
                        shouldCancel: shouldCancel
                    ) {
                        planCounts[planIndex] += 1
                    }
                }
            }
            guard !shouldCancel() else { return nil }

            for planIndex in plans.indices {
                for id in plans[planIndex].outputIDs {
                    counts[id] = planCounts[planIndex]
                }
            }
        }
        return counts
    }

    private static func baseIssueIDs(
        index: BeadProjectIndex,
        filter: BeadSavedViewQuery,
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
}
