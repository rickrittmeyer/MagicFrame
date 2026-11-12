import Foundation

/// How the events library list loads and presents rows.
enum EventListFilter: Equatable, Sendable {
    case allEvents
    /// Top-level events with any `event_tags` holiday row (on self or a trip child).
    case anyHoliday
    case holidayTag(value: String)
    /// Top-level events with any milestone tag (on self or a trip child).
    case anyMilestone
    /// Top-level events with a milestone tag (on self or a trip child).
    case milestoneTag(value: String)
    /// Top-level events matching any of the given milestone tag values.
    case milestoneTags(values: [String])
    /// Top-level trip parent events (`isTripEvent = 1`).
    case trips
    /// Top-level events with any activity tag (on self or a trip child).
    case anyActivity
    case activityTag(value: String)
    /// Top-level events with a curated outing `eventType` tag (Concert / Play / Sporting event).
    case eventTypeTag(value: String)
    /// Top-level events matching any of the given `eventType` tag values.
    case eventTypeTags(values: [String])
    /// Top-level events near a person's birthday (±3 days) with photos of that person.
    case birthdayPerson(personId: Int, displayName: String)
    /// Top-level events assigned to a managed location.
    case location(locationId: Int, displayTitle: String)

    static let holidays = EventListFilter.anyHoliday
    static let christmas = EventListFilter.holidayTag(value: "Christmas")
    static let milestones = EventListFilter.anyMilestone
    static let weddings = EventListFilter.milestoneTag(value: "Wedding")
    static let graduations = EventListFilter.milestoneTag(value: "Graduation")
    static let proms = EventListFilter.milestoneTags(values: ["Senior Prom", "Junior Prom"])
    static let christening = EventListFilter.milestoneTag(value: "Christening")
    static let baptism = EventListFilter.milestoneTag(value: "Baptism")
    static let celebrationOfLife = EventListFilter.milestoneTag(value: "Celebration of Life")
    static let activities = EventListFilter.anyActivity
    static let outings = EventListFilter.eventTypeTags(
        values: ["Concert", "Play", "Sporting event"]
    )
    static let concerts = EventListFilter.eventTypeTag(value: "Concert")
    static let plays = EventListFilter.eventTypeTag(value: "Play")
    static let sportingEvents = EventListFilter.eventTypeTag(value: "Sporting event")

    /// True for any single-holiday collection (AI Vision landing scans / Events tab focus).
    var isHolidayCollection: Bool {
        if case .holidayTag = self { return true }
        return false
    }

    /// True for the Christmas holiday collection.
    var isChristmasHolidayCollection: Bool {
        self == .christmas
    }

    /// Sporting Events outing list (Sport / Team sort apply here only).
    var isSportingEventsCollection: Bool {
        self == .sportingEvents
    }

    var holidayTagValue: String? {
        if case .holidayTag(let value) = self { return value }
        return nil
    }

    var navigationTitle: String {
        switch self {
        case .allEvents:
            return "All Events"
        case .anyHoliday:
            return "Holidays"
        case .holidayTag(let value):
            return value
        case .anyMilestone:
            return "Milestones"
        case .milestoneTag(let value):
            return Self.milestoneDisplayTitle(for: value)
        case .milestoneTags(let values):
            return Self.milestoneTagsDisplayTitle(for: values)
        case .trips:
            return "Trips"
        case .anyActivity:
            return "Activities"
        case .activityTag(let value):
            return value
        case .eventTypeTag(let value):
            return Self.eventTypeDisplayTitle(for: value)
        case .eventTypeTags(let values):
            return Self.eventTypeTagsDisplayTitle(for: values)
        case .birthdayPerson(_, let displayName):
            return displayName
        case .location(_, let displayTitle):
            return displayTitle
        }
    }

    var emptyHint: String {
        switch self {
        case .allEvents:
            return "No events yet. Index photos and sync events from Settings."
        case .anyHoliday:
            return "No holiday-tagged events yet."
        case .holidayTag(let value):
            return "No events tagged \(value) yet."
        case .anyMilestone:
            return "No milestone-tagged events yet."
        case .milestoneTag(let value):
            if value == "Wedding" {
                return "No wedding events yet. Score Wedding candidates from Picture Search."
            }
            return "No events tagged \(value)."
        case .milestoneTags(let values):
            let title = Self.milestoneTagsDisplayTitle(for: values).lowercased()
            return "No \(title) events yet."
        case .trips:
            return "No trip events yet. Trips form when multi-day travel is clustered."
        case .anyActivity:
            return "No activity-tagged events yet."
        case .activityTag(let value):
            return "No events tagged \(value) yet."
        case .eventTypeTag(let value):
            return "No events tagged \(Self.eventTypeDisplayTitle(for: value)) yet."
        case .eventTypeTags:
            return "No outing-tagged events yet."
        case .birthdayPerson(_, let displayName):
            return "No collections near \(displayName) with matching photos yet."
        case .location(_, let displayTitle):
            return "No events at \(displayTitle) yet."
        }
    }

    private static func milestoneDisplayTitle(for value: String) -> String {
        switch value {
        case "Wedding": return "Weddings"
        case "Graduation": return "Graduations"
        case "Birthday": return "Birthdays"
        default: return value
        }
    }

    private static func milestoneTagsDisplayTitle(for values: [String]) -> String {
        let set = Set(values)
        if set.isSubset(of: ["Senior Prom", "Junior Prom"]) && !set.isEmpty {
            return "Proms"
        }
        return values.first.map(milestoneDisplayTitle(for:)) ?? "Milestones"
    }

    private static func eventTypeDisplayTitle(for value: String) -> String {
        switch value {
        case "Concert": return "Concerts"
        case "Play": return "Plays"
        case "Sporting event": return "Sporting Events"
        default: return value
        }
    }

    private static func eventTypeTagsDisplayTitle(for values: [String]) -> String {
        let set = Set(values)
        if set.isSubset(of: ["Concert", "Play", "Sporting event"]) && !set.isEmpty {
            return "Outings"
        }
        return values.first.map(eventTypeDisplayTitle(for:)) ?? "Outings"
    }
}
