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
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return fallback.date(from: value)
    }
}
