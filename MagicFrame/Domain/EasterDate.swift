import Foundation

/// Western (Gregorian) Easter Sunday via the Anonymous Gregorian algorithm.
enum EasterDate {

    static func date(forYear year: Int, calendar: Calendar = .current) -> Date? {
        let parts = westernEasterMonthDay(forYear: year)
        var components = DateComponents()
        components.calendar = calendar
        components.year = year
        components.month = parts.month
        components.day = parts.day
        return components.date
    }

    static func dateISO(forYear year: Int, calendar: Calendar = .current) -> String? {
        guard let date = date(forYear: year, calendar: calendar) else { return nil }
        return EventDateParser.dateOnlyISO(from: date, calendar: calendar)
    }

    /// Valid for Gregorian calendar years typically used in photo libraries (1583+).
    static func westernEasterMonthDay(forYear year: Int) -> (month: Int, day: Int) {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return (month, day)
    }
}
