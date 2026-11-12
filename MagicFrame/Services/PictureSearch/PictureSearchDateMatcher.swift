import Foundation

enum PictureSearchDateMatcher {

    static func matches(
        photoDateISO: String,
        dateSearch: DateSearchDefinition,
        floatingHoliday: FloatingHolidayDefinition?,
        catalogHoliday: HolidayDefinition? = nil,
        calendar: Calendar = .current
    ) -> Bool {
        switch dateSearch.dateSearchType {
        case .allDates:
            return true
        case .sameDateRangeEveryYear:
            guard let start = dateSearch.rangeStartMonthDay,
                  let end = dateSearch.rangeEndMonthDay,
                  let monthDay = monthDay(from: photoDateISO) else {
                return false
            }
            if start <= end {
                return monthDay >= start && monthDay <= end
            }
            return monthDay >= start || monthDay <= end
        case .absoluteRange:
            guard let start = dateSearch.absoluteStartDate,
                  let end = dateSearch.absoluteEndDate,
                  let photoDay = dateOnlyISO(from: photoDateISO) else {
                return false
            }
            return photoDay >= start && photoDay <= end
        case .sameDateEveryYear, .movingHoliday:
            guard let photoDate = EventDateParser.parseDate(photoDateISO) else { return false }
            let year = calendar.component(.year, from: photoDate)
            guard let anchor = anchorDate(
                year: year,
                dateSearch: dateSearch,
                floatingHoliday: floatingHoliday,
                catalogHoliday: catalogHoliday,
                calendar: calendar
            ) else {
                return false
            }
            let allowed = allowedDates(
                around: anchor,
                dateSearch: dateSearch,
                calendar: calendar
            )
            let photoDay = calendar.startOfDay(for: photoDate)
            return allowed.contains(photoDay)
        }
    }

    static func anchorDate(
        year: Int,
        dateSearch: DateSearchDefinition,
        floatingHoliday: FloatingHolidayDefinition?,
        catalogHoliday: HolidayDefinition? = nil,
        calendar: Calendar = .current
    ) -> Date? {
        switch dateSearch.dateSearchType {
        case .sameDateEveryYear:
            if let catalogHoliday, catalogHoliday.kind == .fixed {
                return HolidayDateResolver.date(for: catalogHoliday, year: year, calendar: calendar)
            }
            guard let mmdd = dateSearch.sameDateSearchDate else { return nil }
            let parts = mmdd.split(separator: "-")
            guard parts.count == 2,
                  let month = Int(parts[0]),
                  let day = Int(parts[1]) else {
                return nil
            }
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        case .movingHoliday:
            if let catalogHoliday {
                return HolidayDateResolver.date(for: catalogHoliday, year: year, calendar: calendar)
            }
            if let floatingHoliday {
                return dateForFloatingHoliday(year: year, holiday: floatingHoliday, calendar: calendar)
            }
            guard let key = dateSearch.movingHolidayKey else { return nil }
            // Prefer catalog-style keys (`easter`) and legacy PictureMovingHolidayKey values.
            if key == "easter" {
                return EasterDate.date(forYear: year, calendar: calendar)
            }
            return dateForMovingHoliday(year: year, key: key, calendar: calendar)
        default:
            return nil
        }
    }

    /// `YYYY-MM-DD` day strings allowed for the given years (anchor + weekend/day expansions).
    static func allowedDayISOStrings(
        years: [Int],
        dateSearch: DateSearchDefinition,
        floatingHoliday: FloatingHolidayDefinition?,
        catalogHoliday: HolidayDefinition? = nil,
        calendar: Calendar = .current
    ) -> Set<String> {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var days: Set<String> = []
        for year in years {
            guard let anchor = anchorDate(
                year: year,
                dateSearch: dateSearch,
                floatingHoliday: floatingHoliday,
                catalogHoliday: catalogHoliday,
                calendar: calendar
            ) else {
                continue
            }
            for date in allowedDates(around: anchor, dateSearch: dateSearch, calendar: calendar) {
                days.insert(formatter.string(from: date))
            }
        }
        return days
    }

    static func allowedDates(
        around anchor: Date,
        dateSearch: DateSearchDefinition,
        calendar: Calendar
    ) -> Set<Date> {
        var dates: Set<Date> = [calendar.startOfDay(for: anchor)]

        if dateSearch.includeDaysBefore, let days = dateSearch.includeXDaysBefore, days > 0 {
            for offset in 1...days {
                if let date = calendar.date(byAdding: .day, value: -offset, to: anchor) {
                    dates.insert(calendar.startOfDay(for: date))
                }
            }
        }

        if dateSearch.includeDaysAfter, let days = dateSearch.includeYDaysAfter, days > 0 {
            for offset in 1...days {
                if let date = calendar.date(byAdding: .day, value: offset, to: anchor) {
                    dates.insert(calendar.startOfDay(for: date))
                }
            }
        }

        if dateSearch.includeWeekendsBefore {
            for weekday in [6, 7] {
                if let date = previousWeekday(weekday, before: anchor, calendar: calendar) {
                    dates.insert(calendar.startOfDay(for: date))
                }
            }
        }

        if dateSearch.includeWeekendsAfter {
            for weekday in [6, 7] {
                if let date = nextWeekday(weekday, after: anchor, calendar: calendar) {
                    dates.insert(calendar.startOfDay(for: date))
                }
            }
        }

        return dates
    }

    /// Gregorian: 1 = Sunday … 7 = Saturday. Friday = 6, Saturday = 7.
    private static func previousWeekday(
        _ weekday: Int,
        before date: Date,
        calendar: Calendar
    ) -> Date? {
        var candidate = calendar.date(byAdding: .day, value: -1, to: date)
        for _ in 0..<7 {
            guard let day = candidate else { return nil }
            if calendar.component(.weekday, from: day) == weekday {
                return day
            }
            candidate = calendar.date(byAdding: .day, value: -1, to: day)
        }
        return nil
    }

    private static func nextWeekday(
        _ weekday: Int,
        after date: Date,
        calendar: Calendar
    ) -> Date? {
        var candidate = calendar.date(byAdding: .day, value: 1, to: date)
        for _ in 0..<7 {
            guard let day = candidate else { return nil }
            if calendar.component(.weekday, from: day) == weekday {
                return day
            }
            candidate = calendar.date(byAdding: .day, value: 1, to: day)
        }
        return nil
    }

    static func dateForMovingHoliday(
        year: Int,
        key: String,
        calendar: Calendar = .current
    ) -> Date? {
        switch key {
        case PictureMovingHolidayKey.thanksgiving.rawValue:
            return USThanksgivingDate.date(forYear: year, calendar: calendar)
        case PictureMovingHolidayKey.easter.rawValue:
            return EasterDate.date(forYear: year)
        case PictureMovingHolidayKey.mothers_day.rawValue:
            return nthWeekday(2, weekday: 1, month: 5, year: year, calendar: calendar)
        case PictureMovingHolidayKey.fathers_day.rawValue:
            return nthWeekday(3, weekday: 1, month: 6, year: year, calendar: calendar)
        case PictureMovingHolidayKey.labor_day.rawValue:
            return nthWeekday(1, weekday: 2, month: 9, year: year, calendar: calendar)
        case PictureMovingHolidayKey.memorial_day.rawValue:
            return lastWeekday(2, month: 5, year: year, calendar: calendar)
        case PictureMovingHolidayKey.veterans_day.rawValue:
            return calendar.date(from: DateComponents(year: year, month: 11, day: 11))
        default:
            return nil
        }
    }

    static func dateForFloatingHoliday(
        year: Int,
        holiday: FloatingHolidayDefinition,
        calendar: Calendar = .current
    ) -> Date? {
        guard holiday.ruleKind == "nthWeekdayOfMonth" else { return nil }
        if holiday.weekOrdinal < 0 {
            return lastWeekday(holiday.weekday, month: holiday.month, year: year, calendar: calendar)
        }
        return nthWeekday(
            holiday.weekOrdinal,
            weekday: holiday.weekday,
            month: holiday.month,
            year: year,
            calendar: calendar
        )
    }

    private static func nthWeekday(
        _ ordinal: Int,
        weekday: Int,
        month: Int,
        year: Int,
        calendar: Calendar
    ) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.year = year
        components.month = month
        components.weekday = weekday
        components.weekdayOrdinal = ordinal
        return components.date
    }

    private static func lastWeekday(
        _ weekday: Int,
        month: Int,
        year: Int,
        calendar: Calendar
    ) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.year = year
        components.month = month
        components.weekday = weekday
        components.weekdayOrdinal = -1
        return components.date
    }

    private static func monthDay(from iso: String) -> String? {
        guard iso.count >= 10 else { return nil }
        let start = iso.index(iso.startIndex, offsetBy: 5)
        let end = iso.index(iso.startIndex, offsetBy: 10)
        return String(iso[start..<end])
    }

    private static func dateOnlyISO(from iso: String) -> String? {
        guard iso.count >= 10 else { return nil }
        return String(iso.prefix(10))
    }
}
