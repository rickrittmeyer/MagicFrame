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
    let attributeTags: [EventAttributeTag]
    let eventMainPerson: String?
    let eventMainPerson2: String?
    let weddingDate: String?
    let tripType: String?
    let childEventName: String?
    let userEditedChildEventName: Bool
    let isUserHidden: Bool

    var holidayTag: EventHolidayTag? {
        attributeTags.first(where: { $0.category == .holidayType })?.asHolidayTag
    }

    /// Holiday label for UI: structured tag first, then legacy column.
    var displayHolidayLabel: String? {
        if let holidayTag {
            return holidayTag.tagValue
        }
        let trimmed = holidayType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Attribute chips for the events library row, in display order.
    var libraryAttributeTags: [EventAttributeTag] {
        var tags = attributeTags
        if holidayTag == nil,
           let label = displayHolidayLabel,
           !tags.contains(where: { $0.category == .holidayType }) {
            tags.append(
                EventAttributeTag(
                    category: .holidayType,
                    tagValue: label,
                    source: .user
                )
            )
        }

        return tags.sorted { lhs, rhs in
            let left = EventAttributeField.libraryChipDisplayOrder.firstIndex(of: lhs.category) ?? 99
            let right = EventAttributeField.libraryChipDisplayOrder.firstIndex(of: rhs.category) ?? 99
            return left < right
        }
    }

    func attributeColumnValue(for field: EventAttributeField) -> String? {
        switch field {
        case .eventType: return eventType
        case .activityType: return activityType
        case .tripType: return tripType
        case .milestoneType: return milestoneType
        case .holidayType: return holidayType
        case .mainPerson: return eventMainPerson
        case .secondaryMainPerson: return eventMainPerson2
        }
    }

    /// Prefer structured `event_tags`, then legacy column values.
    func resolvedAttributeValue(for field: EventAttributeField) -> String? {
        if let tagValue = attributeTags.first(where: { $0.category == field })?.tagValue {
            let trimmed = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return attributeColumnValue(for: field)
    }

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
        EventDateParser.year(from: startDate) ?? EventDateParser.year(from: endDate)
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
