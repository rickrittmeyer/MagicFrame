import Foundation

enum EventNameSuggester {

    static func suggest(
        locationDisplayText: String?,
        startDate: String,
        endDate: String,
        people: [String]
    ) -> String? {
        if let location = locationDisplayText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !location.isEmpty {
            return location
        }

        if let person = people.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !person.isEmpty {
            return person
        }

        return dateFallback(startDate: startDate, endDate: endDate)
    }

    private static func dateFallback(startDate: String, endDate: String) -> String? {
        formattedDateRange(startDate: startDate, endDate: endDate)
    }

    private static func formattedDateRange(startDate: String, endDate: String) -> String? {
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

    private static func parseDate(_ value: String) -> Date? {
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
