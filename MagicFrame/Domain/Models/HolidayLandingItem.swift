import Foundation

struct HolidayLandingItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case holidayTag(value: String)
        case birthdayPerson(personId: Int, displayName: String)
    }

    let kind: Kind
    let name: String
    let nextOccurrence: Date

    var id: String {
        switch kind {
        case .holidayTag(let value):
            return "holiday:\(value)"
        case .birthdayPerson(let personId, _):
            return "birthday:\(personId)"
        }
    }

    var isBirthday: Bool {
        if case .birthdayPerson = kind { return true }
        return false
    }

    /// Convenience for holiday-tag rows (empty for birthdays).
    var tagValue: String {
        if case .holidayTag(let value) = kind { return value }
        return ""
    }

    var eventListFilter: EventListFilter {
        switch kind {
        case .holidayTag(let value):
            return .holidayTag(value: value)
        case .birthdayPerson(let personId, let displayName):
            return .birthdayPerson(personId: personId, displayName: displayName)
        }
    }

    var nextOccurrenceLabel: String {
        Self.nextOccurrenceFormatter.string(from: nextOccurrence)
    }

    private static let nextOccurrenceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale.current
        formatter.dateFormat = "MMMM d"
        return formatter
    }()
}

enum HolidayLandingCatalog {

    static func build(
        holidays: [HolidayDefinition],
        nextOccurrenceForHoliday: (HolidayDefinition) -> Date?,
        peopleWithBirthDates: [PeopleRepository.PersonBirthdayRecord] = [],
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> [HolidayLandingItem] {
        var items: [HolidayLandingItem] = []

        for holiday in holidays {
            guard let next = nextOccurrenceForHoliday(holiday) else { continue }
            items.append(
                HolidayLandingItem(
                    kind: .holidayTag(value: holiday.name),
                    name: holiday.name,
                    nextOccurrence: next
                )
            )
        }

        // Fallback if holidays table is empty.
        if items.isEmpty {
            for tagValue in EventAttributeField.holidayType.builtInOptions {
                guard let next = nextOccurrence(
                    forHolidayTag: tagValue,
                    referenceDate: referenceDate,
                    calendar: calendar
                ) else {
                    continue
                }
                items.append(
                    HolidayLandingItem(
                        kind: .holidayTag(value: tagValue),
                        name: tagValue,
                        nextOccurrence: next
                    )
                )
            }
        }

        for person in peopleWithBirthDates {
            guard let next = nextBirthday(
                birthDateISO: person.birthDateISO,
                referenceDate: referenceDate,
                calendar: calendar
            ) else {
                continue
            }
            let displayName = "\(person.name) Birthday"
            items.append(
                HolidayLandingItem(
                    kind: .birthdayPerson(personId: person.personId, displayName: displayName),
                    name: displayName,
                    nextOccurrence: next
                )
            )
        }

        return items.sorted {
            if calendar.isDate($0.nextOccurrence, inSameDayAs: $1.nextOccurrence) {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.nextOccurrence < $1.nextOccurrence
        }
    }

    static func nextOccurrence(
        forHolidayTag tagValue: String,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        let year = calendar.component(.year, from: referenceDate)
        guard let thisYear = date(forHolidayTag: tagValue, year: year, calendar: calendar) else {
            return nil
        }
        let startOfToday = calendar.startOfDay(for: referenceDate)
        if calendar.startOfDay(for: thisYear) >= startOfToday {
            return thisYear
        }
        return date(forHolidayTag: tagValue, year: year + 1, calendar: calendar)
    }

    static func nextBirthday(
        birthDateISO: String,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard birthDateISO.count >= 10,
              let month = Int(birthDateISO.dropFirst(5).prefix(2)),
              let day = Int(birthDateISO.dropFirst(8).prefix(2)) else {
            return nil
        }
        let year = calendar.component(.year, from: referenceDate)
        let startOfToday = calendar.startOfDay(for: referenceDate)
        if let thisYear = calendar.date(from: DateComponents(year: year, month: month, day: day)),
           calendar.startOfDay(for: thisYear) >= startOfToday {
            return thisYear
        }
        return calendar.date(from: DateComponents(year: year + 1, month: month, day: day))
    }

    private static func date(
        forHolidayTag tagValue: String,
        year: Int,
        calendar: Calendar
    ) -> Date? {
        switch tagValue {
        case "Christmas":
            return calendar.date(from: DateComponents(year: year, month: 12, day: 25))
        case "Halloween":
            return calendar.date(from: DateComponents(year: year, month: 10, day: 31))
        case "July 4th":
            return calendar.date(from: DateComponents(year: year, month: 7, day: 4))
        case "New Years":
            return calendar.date(from: DateComponents(year: year, month: 1, day: 1))
        case "Valentine's Day":
            return calendar.date(from: DateComponents(year: year, month: 2, day: 14))
        case "St. Patty's Day":
            return calendar.date(from: DateComponents(year: year, month: 3, day: 17))
        case "Thanksgiving":
            return PictureSearchDateMatcher.dateForMovingHoliday(
                year: year,
                key: PictureMovingHolidayKey.thanksgiving.rawValue,
                calendar: calendar
            )
        case "Easter":
            return PictureSearchDateMatcher.dateForMovingHoliday(
                year: year,
                key: PictureMovingHolidayKey.easter.rawValue,
                calendar: calendar
            )
        case "Mother's Day":
            return PictureSearchDateMatcher.dateForMovingHoliday(
                year: year,
                key: PictureMovingHolidayKey.mothers_day.rawValue,
                calendar: calendar
            )
        case "Father's Day":
            return PictureSearchDateMatcher.dateForMovingHoliday(
                year: year,
                key: PictureMovingHolidayKey.fathers_day.rawValue,
                calendar: calendar
            )
        default:
            return nil
        }
    }
}
