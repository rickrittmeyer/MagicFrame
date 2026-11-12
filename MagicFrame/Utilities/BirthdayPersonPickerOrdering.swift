import Foundation

struct MilestonePersonPickerItem: Identifiable, Sendable, Equatable {
    let personId: Int
    let name: String
    let birthDateISO: String?

    var id: Int { personId }

    var birthMonthDayDisplay: String? {
        guard let birthDateISO else { return nil }
        return MilestoneEventNaming.birthMonthDayDisplay(birthDateISO: birthDateISO)
    }
}

enum BirthdayPersonPickerOrdering {

    static func items(
        peopleWithBirthDates: [PeopleRepository.PersonBirthdayRecord],
        allPeople: [PeopleRepository.PersonRecord],
        eventDate: Date,
        calendar: Calendar = .current
    ) -> [MilestonePersonPickerItem] {
        let withBirthdays = peopleWithBirthDates
            .map { record in
                (
                    item: MilestonePersonPickerItem(
                        personId: record.personId,
                        name: record.name,
                        birthDateISO: record.birthDateISO
                    ),
                    proximity: proximityDays(
                        eventDate: eventDate,
                        birthDateISO: record.birthDateISO,
                        calendar: calendar
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.proximity != rhs.proximity {
                    return lhs.proximity < rhs.proximity
                }
                return lhs.item.name.localizedCaseInsensitiveCompare(rhs.item.name) == .orderedAscending
            }
            .map(\.item)

        let peopleWithBirthdayIds = Set(peopleWithBirthDates.map(\.personId))
        let withoutBirthdays = allPeople
            .filter { !peopleWithBirthdayIds.contains($0.personId) }
            .map {
                MilestonePersonPickerItem(
                    personId: $0.personId,
                    name: $0.name,
                    birthDateISO: nil
                )
            }

        return withBirthdays + withoutBirthdays
    }

    private static func proximityDays(
        eventDate: Date,
        birthDateISO: String,
        calendar: Calendar
    ) -> Int {
        guard let birthDate = EventDateParser.parseDate(birthDateISO) else {
            return Int.max
        }

        let eventYear = calendar.component(.year, from: eventDate)
        let birthMonth = calendar.component(.month, from: birthDate)
        let birthDay = calendar.component(.day, from: birthDate)

        guard let birthdayThisYear = calendar.date(
            from: DateComponents(year: eventYear, month: birthMonth, day: birthDay)
        ) else {
            return Int.max
        }

        let eventDayOfYear = calendar.ordinality(of: .day, in: .year, for: eventDate) ?? 0
        let birthdayDayOfYear = calendar.ordinality(of: .day, in: .year, for: birthdayThisYear) ?? 0
        let linearDistance = abs(eventDayOfYear - birthdayDayOfYear)
        return min(linearDistance, 365 - linearDistance)
    }
}

enum EventMilestonePersonPickerOrdering {

    /// People in the event only, most photo appearances first.
    static func eventPeopleByPhotoCount(
        eventPeople: [EventRepository.EventPersonRecord]
    ) -> [MilestonePersonPickerItem] {
        eventPeople
            .sorted { lhs, rhs in
                if lhs.photoCount != rhs.photoCount {
                    return lhs.photoCount > rhs.photoCount
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map {
                MilestonePersonPickerItem(
                    personId: $0.personId,
                    name: $0.name,
                    birthDateISO: nil
                )
            }
    }

    static func items(
        eventPeople: [EventRepository.EventPersonRecord],
        allPeople: [PeopleRepository.PersonRecord]
    ) -> [MilestonePersonPickerItem] {
        let eventPersonIds = Set(eventPeople.map(\.personId))
        let inEvent = eventPeopleByPhotoCount(eventPeople: eventPeople)

        let notInEvent = allPeople
            .filter { !eventPersonIds.contains($0.personId) }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map {
                MilestonePersonPickerItem(
                    personId: $0.personId,
                    name: $0.name,
                    birthDateISO: nil
                )
            }

        return inEvent + notInEvent
    }
}
