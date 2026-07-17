import Foundation

/// A relative-time boundary inserted into the Activity feed before a cluster of
/// items. Its identity follows the first item in the cluster so SwiftUI keeps the
/// boundary stable when relative labels are recomputed.
struct IssueActivityDateBoundary: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let isToday: Bool
}

/// The flattened presentation sequence consumed by Activity's lazy stack.
/// Keeping boundaries and activity items at the same level preserves per-row
/// laziness even when one relative-time bucket contains many events.
enum IssueActivityFeedElement: Identifiable, Hashable, Sendable {
    case boundary(IssueActivityDateBoundary)
    case item(IssueActivityItem)

    var id: String {
        switch self {
        case .boundary(let boundary):
            "boundary-\(boundary.id)"
        case .item(let item):
            item.id
        }
    }
}

enum IssueActivityDateGrouping {
    static func elements(
        for items: [IssueActivityItem],
        relativeTo referenceDate: Date,
        calendar: Calendar,
        locale: Locale
    ) -> [IssueActivityFeedElement] {
        guard !items.isEmpty else { return [] }

        let referenceDay = calendar.startOfDay(for: referenceDate)
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.locale = locale
        relativeFormatter.unitsStyle = .full
        relativeFormatter.dateTimeStyle = .numeric

        var elements: [IssueActivityFeedElement] = []
        elements.reserveCapacity(items.count + min(items.count, 32))
        var currentBucket: BucketKey?

        for item in items {
            let descriptor = bucket(
                for: item.date,
                relativeTo: referenceDay,
                calendar: calendar,
                locale: locale,
                relativeFormatter: relativeFormatter
            )

            if descriptor.key != currentBucket {
                elements.append(.boundary(IssueActivityDateBoundary(
                    id: item.id,
                    label: descriptor.label,
                    isToday: descriptor.isToday
                )))
                currentBucket = descriptor.key
            }
            elements.append(.item(item))
        }

        return elements
    }

    private static func bucket(
        for date: Date?,
        relativeTo referenceDay: Date,
        calendar: Calendar,
        locale: Locale,
        relativeFormatter: RelativeDateTimeFormatter
    ) -> BucketDescriptor {
        guard let date else {
            let label = String(
                localized: "Date unavailable",
                locale: locale,
                comment: "Activity timeline heading for entries without a timestamp."
            )
            return BucketDescriptor(key: .dateUnavailable, label: label, isToday: false)
        }

        let itemDay = calendar.startOfDay(for: date)
        let dayDistance = calendar.dateComponents([.day], from: itemDay, to: referenceDay).day

        if dayDistance == 0 {
            let label = String(
                localized: "Today",
                locale: locale,
                comment: "Activity timeline heading for entries from the current day."
            )
            return BucketDescriptor(key: .today, label: label, isToday: true)
        }

        if let dayDistance, (1...6).contains(dayDistance) {
            let weekdayStyle = Date.FormatStyle(
                date: .omitted,
                time: .omitted,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            ).weekday(.wide)
            let label = itemDay.formatted(weekdayStyle)
            return BucketDescriptor(key: .recentDay(itemDay), label: label, isToday: false)
        }

        let label = relativeFormatter.localizedString(for: itemDay, relativeTo: referenceDay)
        return BucketDescriptor(key: .relative(label), label: label, isToday: false)
    }
}

private struct BucketDescriptor {
    let key: BucketKey
    let label: String
    let isToday: Bool
}

private enum BucketKey: Hashable {
    case today
    case recentDay(Date)
    case relative(String)
    case dateUnavailable
}
