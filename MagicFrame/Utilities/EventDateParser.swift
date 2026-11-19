import Foundation

enum EventDateParser {

    static func year(from isoDate: String) -> Int? {
        if let date = parseDate(isoDate) {
            return Calendar.current.component(.year, from: date)
        }

        guard isoDate.count >= 4 else { return nil }
        return Int(isoDate.prefix(4))
    }

    static func displayDateRange(startDate: String, endDate: String) -> String? {
        guard let start = parseDate(startDate) else { return nil }

        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .none

        guard let end = parseDate(endDate) else {
            return displayFormatter.string(from: start)
        }

        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) {
            return displayFormatter.string(from: start)
        }

        let startComponents = calendar.dateComponents([.year, .month], from: start)
        let endComponents = calendar.dateComponents([.year, .month], from: end)

        if startComponents.year == endComponents.year,
           startComponents.month == endComponents.month {
            displayFormatter.dateFormat = "MMMM yyyy"
            return displayFormatter.string(from: start)
        }

        if startComponents.year == endComponents.year {
            displayFormatter.dateFormat = "MMM d"
            let startText = displayFormatter.string(from: start)
            let endText = displayFormatter.string(from: end)
            displayFormatter.dateFormat = "yyyy"
            return "\(startText)–\(endText), \(displayFormatter.string(from: start))"
        }

        return "\(displayFormatter.string(from: start)) – \(displayFormatter.string(from: end))"
    }

    /// Event detail: "MMMM d, yyyy" or multi-day "MMMM d - MMMM d, yyyy".
    static func detailDisplayDateRange(startDate: String, endDate: String) -> String? {
        guard let start = parseDate(startDate) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"

        guard let end = parseDate(endDate) else {
            return formatter.string(from: start)
        }

        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) {
            return formatter.string(from: start)
        }

        let startYear = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)

        if startYear == endYear {
            formatter.dateFormat = "MMMM d"
            let startText = formatter.string(from: start)
            let endText = formatter.string(from: end)
            formatter.dateFormat = "yyyy"
            return "\(startText) - \(endText), \(formatter.string(from: start))"
        }

        formatter.dateFormat = "MMMM d, yyyy"
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }

    static func nameIsDateOnly(_ name: String, startDate: String, endDate: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let formatted = displayDateRange(startDate: startDate, endDate: endDate),
           trimmed.compare(formatted, options: .caseInsensitive) == .orderedSame {
            return true
        }

        guard let start = parseDate(startDate) else { return false }

        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .none
        return trimmed.compare(displayFormatter.string(from: start), options: .caseInsensitive) == .orderedSame
    }

    static func parseDate(_ value: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: value) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: value) {
            return date
        }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")

        for format in [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
        ] {
            fallback.dateFormat = format
            if let date = fallback.date(from: value) {
                return date
            }
        }

        return nil
    }

    static func dateOnlyISO(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func eventDayDate(from startDateISO: String, calendar: Calendar = .current) -> Date? {
        guard let parsed = parseDate(startDateISO) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: parsed)
        return calendar.date(from: components)
    }
}
