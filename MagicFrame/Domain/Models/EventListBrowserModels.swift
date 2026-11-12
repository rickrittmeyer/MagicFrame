import Foundation

enum EventListSort: String, CaseIterable, Identifiable, Sendable {
    case date
    case confidence
    case sport
    case team

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: return "Date"
        case .confidence: return "Confidence"
        case .sport: return "Sport"
        case .team: return "Team"
        }
    }

    /// Date + Confidence everywhere; Sport / Team only on Sporting Events.
    static func options(for filter: EventListFilter) -> [EventListSort] {
        if filter.isSportingEventsCollection {
            return [.date, .confidence, .sport, .team]
        }
        return [.date, .confidence]
    }
}

/// Filter menu for All Events and topic event landing pages.
enum EventListBrowserFilter: String, CaseIterable, Identifiable, Sendable {
    case allEvents
    case eventsOnFrame
    case eventsOffFrame
    case favoriteEvents
    case hiddenEvents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allEvents: return "All Events"
        case .eventsOnFrame: return "On Frame"
        case .eventsOffFrame: return "Off Frame"
        case .favoriteEvents: return "Favorites"
        case .hiddenEvents: return "Show Hidden Events"
        }
    }
}
