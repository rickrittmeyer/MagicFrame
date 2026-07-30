import Foundation

/// How the events library list loads and presents rows.
enum EventListFilter: Equatable, Sendable {
    case allEvents
    /// Top-level events with any `event_tags` holiday row (on self or a trip child).
    case anyHoliday
    case holidayTag(value: String)
    /// Top-level events near a birthday date window with photos of the occasion person.
    case birthdayOccasion(occasionKey: String, displayName: String)
    /// Top-level events assigned to a managed location.
    case location(locationId: Int, displayTitle: String)

    static let holidays = EventListFilter.anyHoliday
    static let christmas = EventListFilter.holidayTag(value: "Christmas")

    /// True for the Christmas holiday collection (AI Vision landing scans).
    var isChristmasHolidayCollection: Bool {
        self == .christmas
    }

    var navigationTitle: String {
        switch self {
        case .allEvents:
            return "Collections"
        case .anyHoliday:
            return "Holidays"
        case .holidayTag(let value):
            return value
        case .birthdayOccasion(_, let displayName):
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
            return "No holiday-tagged events. Run Score Holiday Occasions in Settings."
        case .holidayTag(let value):
            return "No events tagged \(value). Run Score Holiday Occasions in Settings."
        case .birthdayOccasion(_, let displayName):
            return "No collections near \(displayName) with matching photos yet."
        case .location(_, let displayTitle):
            return "No events at \(displayTitle) yet."
        }
    }
}
