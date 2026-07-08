import SwiftUI

enum DateEditorLayout {
    static let contentWidth: CGFloat = 258
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 16
    static let containerWidth = contentWidth + horizontalPadding * 2
}

struct InspectorDateRow: View {
    let title: String
    let systemImage: String
    @Binding var value: Date?
    let includesDeferredShortcuts: Bool

    var body: some View {
        IssueMetadataDateControl(
            title: title,
            systemImage: systemImage,
            value: $value,
            includesDeferredShortcuts: includesDeferredShortcuts,
            presentation: .inspectorRow
        )
    }
}

struct DateEditorPopover: View {
    let title: String
    @Binding var value: Date?
    let includesDeferredShortcuts: Bool
    @State private var visibleMonth: Date

    init(title: String, value: Binding<Date?>, includesDeferredShortcuts: Bool) {
        self.title = title
        self._value = value
        self.includesDeferredShortcuts = includesDeferredShortcuts
        self._visibleMonth = State(initialValue: CalendarMonthPicker.monthStart(for: value.wrappedValue ?? Date()))
    }

    private var selectedDate: Binding<Date?> {
        Binding(
            get: { value.map(normalized) },
            set: { value = $0.map(normalized) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            CalendarMonthPicker(selectedDate: selectedDate, visibleMonth: $visibleMonth)

            DateEditorActionBar(
                includesDeferredShortcuts: includesDeferredShortcuts,
                canClear: value != nil,
                setToday: {
                    value = normalized(Date())
                    visibleMonth = CalendarMonthPicker.monthStart(for: value ?? Date())
                },
                clear: {
                    value = nil
                },
                addDay: {
                    add(.day, value: 1)
                },
                addWeek: {
                    add(.day, value: 7)
                },
                addMonth: {
                    add(.month, value: 1)
                }
            )
        }
        .padding(.horizontal, DateEditorLayout.horizontalPadding)
        .padding(.vertical, DateEditorLayout.verticalPadding)
        .frame(width: DateEditorLayout.containerWidth, alignment: .leading)
    }

    private func add(_ component: Calendar.Component, value amount: Int) {
        let base = normalized(value ?? Date())
        let nextDate = Calendar.current.date(byAdding: component, value: amount, to: base).map(normalized) ?? base
        value = nextDate
        visibleMonth = CalendarMonthPicker.monthStart(for: nextDate)
    }

    private func normalized(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }
}

struct CalendarMonthPicker: View {
    @Binding var selectedDate: Date?
    @Binding var visibleMonth: Date
    @State private var hoveredDate: Date?

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 4), count: 7)

    private var monthTitle: String {
        visibleMonth.formatted(.dateTime.month(.abbreviated).year())
    }

    private var weekdaySymbols: [String] {
        calendar.veryShortStandaloneWeekdaySymbols.shifted(toStartAt: calendar.firstWeekday)
    }

    private var dates: [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth) else { return [] }
        let firstOfMonth = monthInterval.start
        let leadingDays = leadingOffset(for: firstOfMonth)
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: firstOfMonth) ?? firstOfMonth

        return (0..<42).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: dayOffset, to: gridStart)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(monthTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                MonthNavigationButton(systemImage: "chevron.left", accessibilityLabel: "Previous month") {
                    moveMonth(by: -1)
                }
                MonthNavigationButton(systemImage: "chevron.right", accessibilityLabel: "Next month") {
                    moveMonth(by: 1)
                }
            }

            LazyVGrid(columns: columns, alignment: .center, spacing: 5) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 18)
                }

                ForEach(dates, id: \.self) { date in
                    CalendarDayButton(
                        date: date,
                        day: calendar.component(.day, from: date),
                        isInVisibleMonth: calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month),
                        isSelected: selectedDate.map { calendar.isDate(date, inSameDayAs: $0) } ?? false,
                        isToday: calendar.isDateInToday(date),
                        isHovered: hoveredDate.map { calendar.isDate(date, inSameDayAs: $0) } ?? false
                    ) {
                        selectedDate = calendar.startOfDay(for: date)
                        visibleMonth = Self.monthStart(for: date)
                    }
                    .onHover { isHovered in
                        hoveredDate = isHovered ? date : nil
                    }
                }
            }
        }
        .frame(width: DateEditorLayout.contentWidth, alignment: .leading)
    }

    static func monthStart(for date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components).map(calendar.startOfDay(for:)) ?? calendar.startOfDay(for: date)
    }

    private func moveMonth(by amount: Int) {
        visibleMonth = calendar.date(byAdding: .month, value: amount, to: visibleMonth) ?? visibleMonth
    }

    private func leadingOffset(for firstOfMonth: Date) -> Int {
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        return (weekday - calendar.firstWeekday + 7) % 7
    }
}

struct MonthNavigationButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .background(isHovered ? InspectorChrome.rowHoverFill : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
    }
}

struct CalendarDayButton: View {
    let date: Date
    let day: Int
    let isInVisibleMonth: Bool
    let isSelected: Bool
    let isToday: Bool
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(day)")
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(foregroundStyle)
                .frame(width: 30, height: 26)
                .background(backgroundFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isToday && !isSelected ? Color.accentColor.opacity(0.75) : .clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .long, time: .omitted))
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private var foregroundStyle: Color {
        if isSelected {
            return .white
        }
        if isInVisibleMonth {
            return Color(nsColor: .labelColor)
        }
        return Color(nsColor: .tertiaryLabelColor)
    }

    private var backgroundFill: Color {
        if isSelected {
            return .accentColor
        }
        if isHovered {
            return InspectorChrome.rowHoverFill
        }
        return .clear
    }
}

struct DateEditorActionBar: View {
    let includesDeferredShortcuts: Bool
    let canClear: Bool
    let setToday: () -> Void
    let clear: () -> Void
    let addDay: () -> Void
    let addWeek: () -> Void
    let addMonth: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            DateActionButton("Today", accessibilityLabel: "Set date to today", action: setToday)

            if includesDeferredShortcuts {
                DateActionButton("+1d", accessibilityLabel: "Add one day", action: addDay)
                DateActionButton("+1w", accessibilityLabel: "Add one week", action: addWeek)
                DateActionButton("+1m", accessibilityLabel: "Add one month", action: addMonth)
            }

            Spacer(minLength: 8)

            DateActionButton(
                "Clear",
                accessibilityLabel: "Clear date",
                isEnabled: canClear,
                action: clear
            )
        }
        .frame(width: DateEditorLayout.contentWidth, alignment: .leading)
    }
}

struct DateActionButton: View {
    let title: String
    let accessibilityLabel: String
    var isEnabled = true
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, accessibilityLabel: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(isEnabled ? Color(nsColor: .labelColor) : Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(isHovered && isEnabled ? InspectorChrome.rowHoverFill : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

private extension Array {
    func shifted(toStartAt firstIndexOneBased: Int) -> [Element] {
        guard !isEmpty else { return self }
        let start = Swift.max(0, Swift.min(count - 1, firstIndexOneBased - 1))
        return Array(self[start...]) + Array(self[..<start])
    }
}
