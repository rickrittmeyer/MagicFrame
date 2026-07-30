import Foundation

enum EventAttributeField: String, CaseIterable, Identifiable {
    case eventType
    case activityType
    case tripType
    case milestoneType
    case holidayType
    case mainPerson
    case secondaryMainPerson

    var id: String { rawValue }

    /// Categories shown in the event detail Tags menu.
    static let tagMenuCases: [EventAttributeField] = [
        .eventType,
        .activityType,
        .tripType,
        .milestoneType,
        .holidayType,
        .mainPerson,
    ]

    /// Event columns mirrored into `event_tags` for library chips.
    static let columnBackedTagFields: [EventAttributeField] = [
        .eventType,
        .activityType,
        .tripType,
        .milestoneType,
        .holidayType,
        .mainPerson,
        .secondaryMainPerson,
    ]

    var menuTitle: String {
        switch self {
        case .eventType: return "Event Type"
        case .activityType: return "Activity"
        case .tripType: return "Trip"
        case .milestoneType: return "Milestone"
        case .holidayType: return "Holiday"
        case .mainPerson, .secondaryMainPerson: return "Person"
        }
    }

    var unsetLabel: String {
        switch self {
        case .eventType: return "Event Type"
        case .activityType: return "Activity"
        case .tripType: return "Trip"
        case .milestoneType: return "Milestone"
        case .holidayType: return "Holiday"
        case .mainPerson, .secondaryMainPerson: return "Person"
        }
    }

    var sqlColumn: String {
        switch self {
        case .eventType: return "eventType"
        case .activityType: return "activityType"
        case .tripType: return "tripType"
        case .milestoneType: return "milestoneType"
        case .holidayType: return "holidayType"
        case .mainPerson: return "eventMainPerson"
        case .secondaryMainPerson: return "eventMainPerson2"
        }
    }

    /// `event_tags.tagCategory` value (holiday uses legacy `"holiday"`).
    var tagCategory: String {
        switch self {
        case .holidayType: return "holiday"
        default: return sqlColumn
        }
    }

    static let libraryChipDisplayOrder: [EventAttributeField] = [
        .holidayType,
        .milestoneType,
        .mainPerson,
        .secondaryMainPerson,
        .tripType,
        .eventType,
        .activityType,
    ]

    static func fromTagCategory(_ category: String) -> EventAttributeField? {
        if category == "holiday" {
            return .holidayType
        }
        if category == "eventMainPerson" {
            return .mainPerson
        }
        if category == "eventMainPerson2" {
            return .secondaryMainPerson
        }
        return allCases.first { $0.tagCategory == category }
    }

    var customOptionsMetadataKey: String? {
        switch self {
        case .eventType: return "customEventTypes"
        case .activityType: return "customActivityTypes"
        case .tripType: return nil
        case .milestoneType: return "customMilestoneTypes"
        case .holidayType: return "customHolidayTypes"
        case .mainPerson, .secondaryMainPerson: return nil
        }
    }

    var allowsCustomOptions: Bool {
        customOptionsMetadataKey != nil
    }

    var iconName: String {
        switch self {
        case .eventType: return "ticket"
        case .activityType: return "figure.run"
        case .tripType: return "suitcase.fill"
        case .milestoneType: return "star"
        case .holidayType: return "gift"
        case .mainPerson, .secondaryMainPerson: return "person"
        }
    }

    var builtInOptions: [String] {
        switch self {
        case .eventType:
            return ["Concert", "Dinner", "Party", "Play", "Sporting event"]
        case .activityType:
            return ["Dance", "Hiking", "Cornhole"]
        case .tripType:
            return []
        case .milestoneType:
            return ["Birthday", "Wedding", "Anniversary", "Graduation", "Baptism"]
        case .holidayType:
            return [
                "Christmas",
                "Halloween",
                "Thanksgiving",
                "Easter",
                "July 4th",
                "New Years",
                "Valentine's Day",
                "St. Patty's Day",
                "Mother's Day",
                "Father's Day",
            ]
        case .mainPerson, .secondaryMainPerson:
            return []
        }
    }

    var addCustomPrompt: String {
        switch self {
        case .eventType: return "Enter a new event type."
        case .activityType: return "Enter a new activity type."
        case .tripType: return "Enter a new trip type."
        case .milestoneType: return "Enter a new milestone type."
        case .holidayType: return "Enter a new holiday type."
        case .mainPerson, .secondaryMainPerson: return ""
        }
    }
}
