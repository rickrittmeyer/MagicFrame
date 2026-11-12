import Foundation
import SwiftUI

/// Grid row for tag-driven landings (Milestones, Outings, Activities).
struct TagCategoryLandingItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let filter: EventListFilter
    let systemImage: String
    /// Optional secondary line (e.g. next birthday month/day).
    let subtitle: String?

    /// Back-compat for callers that keyed tint/icon by tag value.
    var tagValue: String { title }

    init(
        id: String? = nil,
        title: String,
        filter: EventListFilter,
        systemImage: String,
        subtitle: String? = nil
    ) {
        self.id = id ?? title
        self.title = title
        self.filter = filter
        self.systemImage = systemImage
        self.subtitle = subtitle
    }
}

enum TagCategoryLandingCatalog {

    private static let nextOccurrenceFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale.current
        formatter.dateFormat = "MMMM d"
        return formatter
    }()

    /// Fixed milestone hub tiles (not every milestoneType built-in option).
    static func milestones() -> [TagCategoryLandingItem] {
        MilestoneTopicCatalog.all.map { topic in
            TagCategoryLandingItem(
                id: "milestones:\(topic.id)",
                title: topic.title,
                filter: topic.filter,
                systemImage: topic.systemImage
            )
        }
    }

    /// Fixed Outings hub tiles (curated `eventType` subset).
    static func outings() -> [TagCategoryLandingItem] {
        OutingTopicCatalog.all.map { topic in
            TagCategoryLandingItem(
                id: "outings:\(topic.id)",
                title: topic.title,
                filter: topic.filter,
                systemImage: topic.systemImage
            )
        }
    }

    static func birthdayPeople(
        peopleWithBirthDates: [PeopleRepository.PersonBirthdayRecord],
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> [TagCategoryLandingItem] {
        peopleWithBirthDates.compactMap { person in
            guard let next = HolidayLandingCatalog.nextBirthday(
                birthDateISO: person.birthDateISO,
                referenceDate: referenceDate,
                calendar: calendar
            ) else {
                return nil
            }
            let displayName = "\(person.name) Birthday"
            return TagCategoryLandingItem(
                id: "birthday:\(person.personId)",
                title: displayName,
                filter: .birthdayPerson(personId: person.personId, displayName: displayName),
                systemImage: "birthday.cake.fill",
                subtitle: nextOccurrenceFormatter.string(from: next)
            )
        }
    }

    static func activities() -> [TagCategoryLandingItem] {
        EventAttributeField.activityType.builtInOptions.map { value in
            TagCategoryLandingItem(
                title: value,
                filter: .activityTag(value: value),
                systemImage: activityIcon(for: value)
            )
        }
    }

    static func milestoneTint(for value: String) -> Color {
        switch value {
        case "Birthdays", "Birthday":
            return Color(red: 0.9, green: 0.45, blue: 0.55)
        case "Weddings", "Wedding", "Engagement Party":
            return Color(red: 0.78, green: 0.32, blue: 0.48)
        case "Graduations", "Graduation":
            return Color(red: 0.35, green: 0.45, blue: 0.8)
        case "Proms", "Senior Prom", "Junior Prom":
            return Color(red: 0.55, green: 0.35, blue: 0.75)
        case "Christening", "Baptism":
            return Color(red: 0.4, green: 0.55, blue: 0.85)
        case "Celebration of Life":
            return Color(red: 0.55, green: 0.6, blue: 0.45)
        default:
            if value.hasSuffix(" Birthday") {
                return Color(red: 0.9, green: 0.45, blue: 0.55)
            }
            return Color(red: 0.55, green: 0.45, blue: 0.85)
        }
    }

    static func outingTint(for value: String) -> Color {
        switch value {
        case "Sporting Events", "Sporting event":
            return Color(red: 0.2, green: 0.55, blue: 0.4)
        case "Plays", "Play":
            return Color(red: 0.55, green: 0.35, blue: 0.75)
        case "Concerts", "Concert":
            return Color(red: 0.85, green: 0.35, blue: 0.45)
        default:
            return Color(red: 0.45, green: 0.4, blue: 0.7)
        }
    }

    static func activityTint(for value: String) -> Color {
        switch value {
        case "Hiking":
            return Color(red: 0.35, green: 0.68, blue: 0.45)
        case "Dance":
            return Color(red: 0.78, green: 0.32, blue: 0.55)
        case "Cornhole":
            return Color(red: 0.95, green: 0.55, blue: 0.25)
        default:
            return Color(red: 0.95, green: 0.55, blue: 0.25)
        }
    }

    private static func activityIcon(for value: String) -> String {
        switch value {
        case "Hiking":
            return "figure.hiking"
        case "Dance":
            return "figure.dance"
        case "Cornhole":
            return "target"
        default:
            return "figure.run"
        }
    }
}
