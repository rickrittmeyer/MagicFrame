import Foundation

/// Weekend boost when an event's date range includes Friday, Saturday, or Sunday.
enum OccasionWeekendScoring {

    /// Returns the configured boost amount when the event touches a weekend day, else 0.
    static func score(
        eventStart: Date,
        eventEnd: Date,
        boost: Double,
        calendar: Calendar = .current
    ) -> Double {
        guard boost > 0 else { return 0 }
        guard eventTouchesWeekend(
            start: eventStart,
            end: eventEnd,
            calendar: calendar
        ) else {
            return 0
        }
        return min(1.0, boost)
    }

    static func eventTouchesWeekend(
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let rangeStart = calendar.startOfDay(for: min(start, end))
        let rangeEnd = calendar.startOfDay(for: max(start, end))

        var day = rangeStart
        while day <= rangeEnd {
            let weekday = calendar.component(.weekday, from: day)
            // Gregorian: 1 = Sunday, 6 = Friday, 7 = Saturday
            if weekday == 1 || weekday == 6 || weekday == 7 {
                return true
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else {
                break
            }
            day = next
        }
        return false
    }
}
