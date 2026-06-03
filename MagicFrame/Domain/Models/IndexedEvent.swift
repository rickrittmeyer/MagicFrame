import Foundation

struct IndexedEvent {
    let eventId: Int
    let name: String
    let startDate: String
    let endDate: String
    let photoCount: Int
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let state: String?
    let placeName: String?
    let people: [String]
    let coverPhotoId: String?
    let showOnFrame: Bool
    let userEditedName: Bool
    let locationNickname: String?
    let locationId: Int?
    let parentEventId: Int?
    let isTripEvent: Bool
    let eventType: String?
    let activityType: String?
    let milestoneType: String?
    let holidayType: String?
    let eventMainPerson: String?
    let tripType: String?
    let childEventName: String?
    let userEditedChildEventName: Bool
    let isUserHidden: Bool

    var isTripSubEvent: Bool {
        parentEventId != nil
    }

    var isTripContainer: Bool {
        isTripEvent && parentEventId == nil
    }

    var usesSuggestedName: Bool {
        !userEditedName
    }

    var locationTitleLine: String? {
        if let locationNickname, !locationNickname.isEmpty {
            return locationNickname
        }
        if let placeName, !placeName.isEmpty {
            return placeName
        }
        return nil
    }

    var cityStateLine: String? {
        switch (city, state) {
        case let (city?, state?):
            return "\(city), \(state)"
        case let (city?, nil):
            return city
        case let (nil, state?):
            return state
        default:
            return nil
        }
    }

    var eventYear: Int? {
        EventDateParser.year(from: startDate)
    }

    var displayDateText: String? {
        EventDateParser.displayDateRange(startDate: startDate, endDate: endDate)
    }

    var listTitleText: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if EventDateParser.nameIsDateOnly(name, startDate: startDate, endDate: endDate) {
            return nil
        }

        return trimmed
    }

    /// Default label for a trip day segment (location nickname, place, or city/state).
    var defaultChildEventName: String {
        locationTitleLine ?? cityStateLine ?? "Photos"
    }

    func resolvedChildEventName() -> String {
        let trimmed = childEventName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return defaultChildEventName
    }

    var locationDisplayText: String? {
        if let locationNickname, !locationNickname.isEmpty {
            return locationNickname
        }
        if let placeName, !placeName.isEmpty {
            return placeName
        }
        if let city, let state {
            return "\(city), \(state)"
        }
        if let city {
            return city
        }
        if let state {
            return state
        }
        return nil
    }
}
