import XCTest
@testable import Beadazzle

final class IssueActivityDateGroupingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private let locale = Locale(identifier: "en_US")

    func testUsesTodayWeekdaysAndRelativeWeeks() throws {
        let referenceDate = try date(year: 2026, month: 7, day: 17, hour: 12)
        let items = try [
            item(id: "week", date: date(year: 2026, month: 7, day: 10)),
            item(id: "saturday", date: date(year: 2026, month: 7, day: 11)),
            item(id: "thursday", date: date(year: 2026, month: 7, day: 16)),
            item(id: "today", date: date(year: 2026, month: 7, day: 17, hour: 8))
        ]

        let boundaries = boundaryLabels(in: elements(for: items, relativeTo: referenceDate))

        XCTAssertEqual(boundaries, ["1 week ago", "Saturday", "Thursday", "Today"])
    }

    func testItemsInTheSameRelativeBucketShareOneBoundaryAndKeepTheirOrder() throws {
        let referenceDate = try date(year: 2026, month: 7, day: 17, hour: 12)
        let items = try [
            item(id: "first", date: date(year: 2026, month: 7, day: 4)),
            item(id: "second", date: date(year: 2026, month: 7, day: 9)),
            item(id: "third", date: date(year: 2026, month: 7, day: 17, hour: 9)),
            item(id: "fourth", date: date(year: 2026, month: 7, day: 17, hour: 10))
        ]

        let elements = elements(for: items, relativeTo: referenceDate)

        XCTAssertEqual(boundaryLabels(in: elements), ["1 week ago", "Today"])
        XCTAssertEqual(itemIDs(in: elements), items.map(\.id))
        XCTAssertEqual(
            elements.map(\.id),
            [
                "boundary-event-first",
                "event-first",
                "event-second",
                "boundary-event-third",
                "event-third",
                "event-fourth"
            ]
        )
    }

    func testOlderBucketsProgressFromMonthsToYears() throws {
        let referenceDate = try date(year: 2026, month: 7, day: 17, hour: 12)
        let items = try [
            item(id: "year", date: date(year: 2025, month: 7, day: 17)),
            item(id: "month", date: date(year: 2026, month: 6, day: 2))
        ]

        XCTAssertEqual(
            boundaryLabels(in: elements(for: items, relativeTo: referenceDate)),
            ["1 year ago", "1 month ago"]
        )
    }

    func testMissingAndFutureDatesReceiveDistinctBoundaries() throws {
        let referenceDate = try date(year: 2026, month: 7, day: 17, hour: 12)
        let items = try [
            item(id: "missing", date: nil),
            item(id: "future", date: date(year: 2026, month: 7, day: 25))
        ]

        XCTAssertEqual(
            boundaryLabels(in: elements(for: items, relativeTo: referenceDate)),
            ["Date unavailable", "in 1 week"]
        )
    }

    private func elements(
        for items: [IssueActivityItem],
        relativeTo referenceDate: Date
    ) -> [IssueActivityFeedElement] {
        IssueActivityDateGrouping.elements(
            for: items,
            relativeTo: referenceDate,
            calendar: calendar,
            locale: locale
        )
    }

    private func boundaryLabels(in elements: [IssueActivityFeedElement]) -> [String] {
        elements.compactMap { element in
            guard case .boundary(let boundary) = element else { return nil }
            return boundary.label
        }
    }

    private func itemIDs(in elements: [IssueActivityFeedElement]) -> [String] {
        elements.compactMap { element in
            guard case .item(let item) = element else { return nil }
            return item.id
        }
    }

    private func item(id: String, date: Date?) -> IssueActivityItem {
        .event(IssueActivityEventPresentation(
            id: id,
            date: date,
            actor: nil,
            systemImage: "circle",
            message: "updated this bead"
        ))
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour
        )))
    }
}
