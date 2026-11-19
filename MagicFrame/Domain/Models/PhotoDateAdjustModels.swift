import Foundation

enum PhotoDateAdjustDestination: Equatable {
    case createNew
    case existing(eventId: Int)
}

struct PhotoDateAdjustPreview: Equatable {
    let updates: [(photoId: String, originalDate: Date, newDate: Date)]
    let rangeStart: Date
    let rangeEnd: Date
    let leavesCurrentEvent: Bool

    var photoIds: [String] { updates.map(\.photoId) }
    var photoDates: [String: Date] {
        Dictionary(uniqueKeysWithValues: updates.map { ($0.photoId, $0.newDate) })
    }

    static func == (lhs: PhotoDateAdjustPreview, rhs: PhotoDateAdjustPreview) -> Bool {
        lhs.leavesCurrentEvent == rhs.leavesCurrentEvent
            && lhs.rangeStart == rhs.rangeStart
            && lhs.rangeEnd == rhs.rangeEnd
            && lhs.updates.map(\.photoId) == rhs.updates.map(\.photoId)
            && lhs.updates.map(\.newDate) == rhs.updates.map(\.newDate)
    }
}

struct PhotoDateAdjustResult {
    enum Kind {
        case datesOnly
        case movedToEvent(IndexedEvent, sourceEmptied: Bool)
    }

    let kind: Kind
    let updatedCount: Int
    let errorMessage: String?

    var destinationEvent: IndexedEvent? {
        if case let .movedToEvent(event, _) = kind {
            return event
        }
        return nil
    }

    var sourceEmptied: Bool {
        if case let .movedToEvent(_, emptied) = kind {
            return emptied
        }
        return false
    }

    static func eventSummaryLine(for event: IndexedEvent) -> String {
        var parts: [String] = []
        let name = event.listTitleText ?? event.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            parts.append(name)
        } else if let date = event.displayDateText {
            parts.append(date)
        }
        if let date = event.displayDateText, parts.first != date {
            parts.append(date)
        }
        if let location = event.locationDisplayText {
            parts.append(location)
        }
        return parts.joined(separator: " — ")
    }
}

struct PhotoLocationAdjustPreview: Equatable {
    let photoIds: [String]
    let latitude: Double
    let longitude: Double
    let locationId: Int
    let locationLabel: String

    static func == (lhs: PhotoLocationAdjustPreview, rhs: PhotoLocationAdjustPreview) -> Bool {
        lhs.photoIds == rhs.photoIds
            && lhs.latitude == rhs.latitude
            && lhs.longitude == rhs.longitude
            && lhs.locationId == rhs.locationId
    }
}

struct PhotoLocationAdjustResult {
    let updatedCount: Int
    let errorMessage: String?
}
