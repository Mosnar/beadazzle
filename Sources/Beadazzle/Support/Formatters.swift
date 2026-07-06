import Foundation

enum BeadFormatters {
    private static let parseDateFormatterLock = NSLock()
    private static let commandDateFormatterLock = NSLock()
    private static let parseDateFormatters: [DateFormatter] = {
        [
            "yyyy-MM-dd",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd HH:mm:ss"
        ].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()
    private static let iso8601DateFormatter = ISO8601DateFormatter()

    static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static let shortDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let commandDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func displayDate(_ value: Date?) -> String {
        guard let value else { return "None" }
        return shortDateTime.string(from: value)
    }

    static func displayDateOnly(_ value: Date?) -> String {
        guard let value else { return "None" }
        return shortDate.string(from: value)
    }

    static func relative(_ value: Date?) -> String {
        guard let value else { return "" }
        return relativeDate.localizedString(for: value, relativeTo: Date())
    }

    static func commandDate(_ value: Date?) -> String? {
        guard let value else { return nil }
        commandDateFormatterLock.lock()
        defer { commandDateFormatterLock.unlock() }
        return commandDateFormatter.string(from: value)
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        parseDateFormatterLock.lock()
        defer { parseDateFormatterLock.unlock() }

        for formatter in parseDateFormatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return iso8601DateFormatter.date(from: value)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
