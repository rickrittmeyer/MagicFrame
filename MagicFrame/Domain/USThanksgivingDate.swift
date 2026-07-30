import Foundation

/// US Thanksgiving: fourth Thursday in November.
enum USThanksgivingDate {

    static func date(forYear year: Int, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.year = year
        components.month = 11
        components.weekday = 5
        components.weekdayOrdinal = 4
        return components.date
    }

    static func dateISO(forYear year: Int, calendar: Calendar = .current) -> String? {
        guard let date = date(forYear: year, calendar: calendar) else { return nil }
        return EventDateParser.dateOnlyISO(from: date, calendar: calendar)
    }
}
