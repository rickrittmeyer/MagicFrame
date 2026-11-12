import Foundation

enum HolidayKind: String, Sendable, Codable, CaseIterable {
    case fixed
    case floating
    case computed
}

/// One row from the unified `holidays` catalog (fixed, floating, or computed).
struct HolidayDefinition: Sendable, Equatable, Identifiable {
    var holidayId: Int?
    var name: String
    var kind: HolidayKind
    var fixedMonth: Int?
    var fixedDay: Int?
    /// `nthWeekdayOfMonth` or algorithm key (`easter`).
    var ruleKind: String?
    var month: Int?
    var weekday: Int?
    var weekOrdinal: Int?
    var includeWeekendsBefore: Bool
    var isBuiltIn: Bool
    var isEnabled: Bool
    var sortIndex: Int

    var id: Int { holidayId ?? -1 }

    var isFixed: Bool { kind == .fixed }

    /// MM-DD for fixed holidays (Picture Search `sameDateEveryYear`).
    var fixedMonthDay: String? {
        guard kind == .fixed,
              let month = fixedMonth,
              let day = fixedDay else {
            return nil
        }
        return String(format: "%02d-%02d", month, day)
    }

    func toFloatingHolidayDefinition() -> FloatingHolidayDefinition? {
        guard kind == .floating,
              let ruleKind,
              let month,
              let weekday,
              let weekOrdinal else {
            return nil
        }
        return FloatingHolidayDefinition(
            floatingHolidayId: holidayId,
            name: name,
            ruleKind: ruleKind,
            month: month,
            weekday: weekday,
            weekOrdinal: weekOrdinal,
            isEnabled: isEnabled
        )
    }
}

enum HolidayDateResolver {

    /// Years precomputed into `holiday_dates` (photo libraries span far past/future).
    static let seededYearRange: ClosedRange<Int> = 1900...2050

    /// Computes the anchor date for a holiday definition in a given year (no DB).
    static func date(
        for holiday: HolidayDefinition,
        year: Int,
        calendar: Calendar = .current
    ) -> Date? {
        switch holiday.kind {
        case .fixed:
            guard let month = holiday.fixedMonth, let day = holiday.fixedDay else { return nil }
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        case .floating:
            return dateForFloating(holiday: holiday, year: year, calendar: calendar)
        case .computed:
            return dateForComputed(holiday: holiday, year: year, calendar: calendar)
        }
    }

    static func dateISO(
        for holiday: HolidayDefinition,
        year: Int,
        calendar: Calendar = .current
    ) -> String? {
        guard let date = date(for: holiday, year: year, calendar: calendar) else { return nil }
        return EventDateParser.dateOnlyISO(from: date, calendar: calendar)
    }

    private static func dateForFloating(
        holiday: HolidayDefinition,
        year: Int,
        calendar: Calendar
    ) -> Date? {
        guard holiday.ruleKind == "nthWeekdayOfMonth",
              let month = holiday.month,
              let weekday = holiday.weekday,
              let weekOrdinal = holiday.weekOrdinal else {
            return nil
        }
        var components = DateComponents()
        components.calendar = calendar
        components.year = year
        components.month = month
        components.weekday = weekday
        components.weekdayOrdinal = weekOrdinal
        return components.date
    }

    private static func dateForComputed(
        holiday: HolidayDefinition,
        year: Int,
        calendar: Calendar
    ) -> Date? {
        switch holiday.ruleKind {
        case "easter":
            return EasterDate.date(forYear: year, calendar: calendar)
        default:
            return nil
        }
    }
}
