import Foundation

enum BeadFormatters {
    private static let dateFormatterStore = BeadDateFormatterStore()

    static func displayDate(_ value: Date?) -> String {
        guard let value else { return "None" }
        return value.formatted(date: .abbreviated, time: .shortened)
    }

    static func displayDateOnly(_ value: Date?) -> String {
        guard let value else { return "None" }
        return value.formatted(date: .abbreviated, time: .omitted)
    }

    static func relative(_ value: Date?) -> String {
        guard let value else { return "" }
        return value.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    static func commandDate(_ value: Date?) -> String? {
        guard let value else { return nil }
        return dateFormatterStore.commandDate(value)
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return dateFormatterStore.parseDate(value)
    }
}

private final class BeadDateFormatterStore: @unchecked Sendable {
    private let lock = NSLock()
    private let parseDateFormatters: [DateFormatter]
    private let iso8601DateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    private let iso8601FractionalDateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private let commandDateFormatter: DateFormatter

    init() {
        // Non-ISO legacy values only. ISO timestamps take the lock-free modern path
        // in `parseDate`, which is substantially faster and preserves microseconds.
        parseDateFormatters = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }

        let commandDateFormatter = DateFormatter()
        commandDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        commandDateFormatter.calendar = Calendar(identifier: .gregorian)
        commandDateFormatter.dateFormat = "yyyy-MM-dd"
        self.commandDateFormatter = commandDateFormatter
    }

    func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        if value.contains("T") {
            if value.contains("."), let date = try? iso8601FractionalDateFormat.parse(value) {
                return date
            }
            if let date = try? iso8601DateFormat.parse(value) {
                return date
            }
        }

        lock.lock()
        defer { lock.unlock() }
        for formatter in parseDateFormatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    func commandDate(_ value: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return commandDateFormatter.string(from: value)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
