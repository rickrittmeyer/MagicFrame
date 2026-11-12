import Foundation

struct IndexedEvent {
    let eventId: Int
    let name: String
    let startDate: String
    let endDate: String
    let photoCount: Int
    let videoCount: Int
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let state: String?
    let placeName: String?
    let people: [String]
    let coverPhotoId: String?
    let showOnFrame: Bool
    let isFavorite: Bool
    let userEditedName: Bool
    let locationNickname: String?
    let locationId: Int?
    let parentEventId: Int?
    let isTripEvent: Bool
    let attributeTags: [EventAttributeTag]
    let weddingDate: String?
    let childEventName: String?
    let userEditedChildEventName: Bool
    let isUserHidden: Bool

    /// Classification values live in `attributeTags` / `event_tags` only.
    var eventType: String? { resolvedAttributeValue(for: .eventType) }
    var activityType: String? { resolvedAttributeValue(for: .activityType) }
    var milestoneType: String? { resolvedAttributeValue(for: .milestoneType) }
    var holidayType: String? { resolvedAttributeValue(for: .holidayType) }
    var eventMainPerson: String? { resolvedAttributeValue(for: .mainPerson) }
    var eventMainPerson2: String? { resolvedAttributeValue(for: .secondaryMainPerson) }
    var tripType: String? { resolvedAttributeValue(for: .tripType) }

    /// Ordered main people for name templates (`person1`, `person2`).
    /// Prefers multiple `eventMainPerson` tags (Wedding), else main + secondary columns.
    var orderedMainPersonNames: [String] {
        let mains = attributeTags
            .filter { $0.category == .mainPerson }
            .map { $0.tagValue.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if mains.count >= 2 {
            return Array(mains.prefix(2))
        }
        if let only = mains.first {
            if let second = resolvedAttributeValue(for: .secondaryMainPerson) {
                return [only, second]
            }
            return [only]
        }
        if let first = resolvedAttributeValue(for: .mainPerson) {
            if let second = resolvedAttributeValue(for: .secondaryMainPerson) {
                return [first, second]
            }
            return [first]
        }
        return []
    }

    var holidayTag: EventHolidayTag? {
        attributeTags.first(where: { $0.category == .holidayType })?.asHolidayTag
    }

    /// Milestone tag matching `tagValue` (case-insensitive), preferring a user row when both exist.
    func milestoneTag(matching tagValue: String) -> EventAttributeTag? {
        attributeTag(matching: tagValue, category: .milestoneType)
    }

    /// Holiday tag matching `tagValue` (case-insensitive), preferring a user row when both exist.
    func holidayTag(matching tagValue: String) -> EventAttributeTag? {
        attributeTag(matching: tagValue, category: .holidayType)
    }

    /// Event-type / outing tag matching `tagValue` (case-insensitive), preferring a user row.
    func eventTypeTag(matching tagValue: String) -> EventAttributeTag? {
        attributeTag(matching: tagValue, category: .eventType)
    }

    private func attributeTag(
        matching tagValue: String,
        category: EventAttributeField
    ) -> EventAttributeTag? {
        let matches = attributeTags.filter {
            $0.category == category
                && $0.tagValue.compare(tagValue, options: .caseInsensitive) == .orderedSame
        }
        return matches.first(where: { $0.source == .user }) ?? matches.first
    }

    /// User-defined milestones first, then AI by `totalScore` descending, then newer dates.
    static func compareMilestoneTaggedListOrder(
        _ lhs: IndexedEvent,
        _ rhs: IndexedEvent,
        tagValue: String
    ) -> Bool {
        compareAttributeTaggedListOrder(
            lhs,
            rhs,
            leftTag: lhs.milestoneTag(matching: tagValue),
            rightTag: rhs.milestoneTag(matching: tagValue)
        )
    }

    /// User-confirmed holidays first, then AI “Possible …” by score, then newer dates.
    static func compareHolidayTaggedListOrder(
        _ lhs: IndexedEvent,
        _ rhs: IndexedEvent,
        tagValue: String
    ) -> Bool {
        compareAttributeTaggedListOrder(
            lhs,
            rhs,
            leftTag: lhs.holidayTag(matching: tagValue),
            rightTag: rhs.holidayTag(matching: tagValue)
        )
    }

    /// User-confirmed outing event types first, then AI by score, then newer dates.
    static func compareEventTypeTaggedListOrder(
        _ lhs: IndexedEvent,
        _ rhs: IndexedEvent,
        tagValue: String
    ) -> Bool {
        compareAttributeTaggedListOrder(
            lhs,
            rhs,
            leftTag: lhs.eventTypeTag(matching: tagValue),
            rightTag: rhs.eventTypeTag(matching: tagValue)
        )
    }

    private static func compareAttributeTaggedListOrder(
        _ lhs: IndexedEvent,
        _ rhs: IndexedEvent,
        leftTag: EventAttributeTag?,
        rightTag: EventAttributeTag?
    ) -> Bool {
        let leftIsUser = leftTag?.source == .user
        let rightIsUser = rightTag?.source == .user

        if leftIsUser != rightIsUser {
            return leftIsUser && !rightIsUser
        }

        if !leftIsUser {
            let leftScore = leftTag?.totalScore ?? -Double.greatestFiniteMagnitude
            let rightScore = rightTag?.totalScore ?? -Double.greatestFiniteMagnitude
            if leftScore != rightScore {
                return leftScore > rightScore
            }
        }

        if lhs.startDate != rhs.startDate {
            return lhs.startDate > rhs.startDate
        }
        return lhs.eventId > rhs.eventId
    }

    var displayHolidayLabel: String? {
        resolvedAttributeValue(for: .holidayType)
    }

    /// Attribute chips for the events library row, in display order.
    var libraryAttributeTags: [EventAttributeTag] {
        attributeTags.sorted { lhs, rhs in
            let left = EventAttributeField.libraryChipDisplayOrder.firstIndex(of: lhs.category) ?? 99
            let right = EventAttributeField.libraryChipDisplayOrder.firstIndex(of: rhs.category) ?? 99
            return left < right
        }
    }

    /// Values from `event_tags` (via `attributeTags`). For `secondaryMainPerson`,
    /// also accepts a second `eventMainPerson` tag when AI wrote two people under one category.
    func resolvedAttributeValue(for field: EventAttributeField) -> String? {
        if field == .secondaryMainPerson {
            if let explicit = attributeTags.first(where: { $0.category == .secondaryMainPerson })?.tagValue {
                let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            let mains = attributeTags.filter { $0.category == .mainPerson }
            if mains.count > 1 {
                let trimmed = mains[1].tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }

        if let tagValue = attributeTags.first(where: { $0.category == field })?.tagValue {
            let trimmed = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
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
