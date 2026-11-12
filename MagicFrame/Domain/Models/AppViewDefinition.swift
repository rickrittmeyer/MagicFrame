import Foundation

enum AppViewKind: String, Sendable {
    case hub
    case landing
    case landingGrid
    case eventList
    case photoGrid
    case candidateEventList
    case placeholder
}

enum AppContentMode: String, Sendable {
    case events
    case photos
    case mixed
}

enum AppAccordionGroup: String, Sendable {
    case none
    case year
}

enum AppSortOrder: String, Sendable {
    case dateDesc
    case scoreDesc
    case name
    case nextOccurrence
}

/// Declarative catalog row for a navigable screen (hub, landing, list, photo grid).
struct AppViewDefinition: Identifiable, Equatable, Sendable {
    let viewId: String
    let parentViewId: String?
    let title: String
    let viewKind: AppViewKind
    /// Shared family key for photo + events + possible siblings (e.g. `christmas`).
    let topicKey: String?
    /// When opening this landing/topic, push or select this child first.
    let defaultChildViewId: String?
    let contentMode: AppContentMode?
    let hasAccordion: Bool
    let accordionGroupBy: AppAccordionGroup
    let sortOrder: AppSortOrder?
    /// Serialized `EventListFilter` key when this view loads events.
    let entryEventFilterKey: String?
    /// Saved picture search name / key to run on entry.
    let entryPictureSearchKey: String?
    /// When scoring possibles, tag category/value written on confirm/AI apply.
    let confirmTagCategory: String?
    let confirmTagValue: String?
    let entryVisionConfigKey: String?
    let isEnabled: Bool
    let sortIndex: Int
    let emptyHint: String?

    var id: String { viewId }

    var runsPictureSearchThenScoreOnEntry: Bool {
        viewKind == .candidateEventList
            || (viewKind == .eventList && entryPictureSearchKey != nil && confirmTagValue != nil)
    }
}

enum AppViewCatalog {

    static let home = "home"
    static let holidaysLanding = "holidays_landing"
    static let holidayChristmas = holidayTopicViewId(tagValue: "Christmas")
    static let holidayChristmasPhotos = holidayPhotosViewId(tagValue: "Christmas")
    static let holidayChristmasEvents = holidayEventsViewId(tagValue: "Christmas")
    static let holidayChristmasPossibleEvents = holidayPossibleEventsViewId(tagValue: "Christmas")

    static let christmasPictureSearchName =
        HolidayPictureSearchDefaults.pictureSearchName(forTagValue: "Christmas")

    static func holidayTopicViewId(tagValue: String) -> String {
        "holiday_\(slug(tagValue))"
    }

    static func holidayPhotosViewId(tagValue: String) -> String {
        "holiday_\(slug(tagValue))_photos"
    }

    static func holidayEventsViewId(tagValue: String) -> String {
        "holiday_\(slug(tagValue))_events"
    }

    static func holidayPossibleEventsViewId(tagValue: String) -> String {
        "holiday_\(slug(tagValue))_possible_events"
    }

    static func holidayTopicKey(tagValue: String) -> String {
        slug(tagValue)
    }

    private static func slug(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
    }

    static let all: [AppViewDefinition] = {
        var rows: [AppViewDefinition] = [
            AppViewDefinition(
                viewId: home,
                parentViewId: nil,
                title: "Home",
                viewKind: .hub,
                topicKey: nil,
                defaultChildViewId: nil,
                contentMode: .mixed,
                hasAccordion: false,
                accordionGroupBy: .none,
                sortOrder: nil,
                entryEventFilterKey: nil,
                entryPictureSearchKey: nil,
                confirmTagCategory: nil,
                confirmTagValue: nil,
                entryVisionConfigKey: nil,
                isEnabled: true,
                sortIndex: 0,
                emptyHint: nil
            ),
            homeChild(
                viewId: "all_photos",
                title: "All Photos",
                viewKind: .eventList,
                contentMode: .events,
                hasAccordion: true,
                accordion: .year,
                sort: .dateDesc,
                filterKey: "allEvents",
                sortIndex: 1
            ),
            homeChild(
                viewId: holidaysLanding,
                title: "Holidays",
                viewKind: .landingGrid,
                contentMode: .mixed,
                hasAccordion: false,
                accordion: .none,
                sort: .nextOccurrence,
                filterKey: nil,
                sortIndex: 2
            ),
            homeChild(
                viewId: "milestones_landing",
                title: "Milestones",
                viewKind: .landingGrid,
                contentMode: .events,
                hasAccordion: false,
                accordion: .none,
                sort: .name,
                filterKey: nil,
                sortIndex: 3
            ),
            homeChild(
                viewId: "trips",
                title: "Trips",
                viewKind: .eventList,
                contentMode: .events,
                hasAccordion: true,
                accordion: .year,
                sort: .dateDesc,
                filterKey: "trips",
                sortIndex: 4
            ),
            homeChild(
                viewId: "activities_landing",
                title: "Activities",
                viewKind: .landingGrid,
                contentMode: .events,
                hasAccordion: false,
                accordion: .none,
                sort: .name,
                filterKey: nil,
                sortIndex: 5
            ),
            homeChild(
                viewId: "vibes",
                title: "Vibes",
                viewKind: .placeholder,
                contentMode: nil,
                hasAccordion: false,
                accordion: .none,
                sort: nil,
                filterKey: nil,
                sortIndex: 6,
                enabled: false
            ),
            homeChild(
                viewId: "people_landing",
                title: "People",
                viewKind: .landingGrid,
                contentMode: .mixed,
                hasAccordion: false,
                accordion: .none,
                sort: .name,
                filterKey: nil,
                sortIndex: 7
            ),
            homeChild(
                viewId: "locations",
                title: "Locations",
                viewKind: .landingGrid,
                contentMode: .mixed,
                hasAccordion: false,
                accordion: .none,
                sort: .name,
                filterKey: nil,
                sortIndex: 8
            ),
        ]

        rows.append(contentsOf: holidayTopicRows)
        return rows
    }()

    private static var holidayTopicRows: [AppViewDefinition] {
        HolidayPictureSearchDefaults.allBuiltInTagValues.enumerated().flatMap { index, tagValue in
            topicRows(forHolidayTag: tagValue, sortIndex: index)
        }
    }

    private static func topicRows(forHolidayTag tagValue: String, sortIndex: Int) -> [AppViewDefinition] {
        let topicId = holidayTopicViewId(tagValue: tagValue)
        let photosId = holidayPhotosViewId(tagValue: tagValue)
        let eventsId = holidayEventsViewId(tagValue: tagValue)
        let possibleId = holidayPossibleEventsViewId(tagValue: tagValue)
        let topicKey = holidayTopicKey(tagValue: tagValue)
        let pictureSearchName = HolidayPictureSearchDefaults.pictureSearchName(forTagValue: tagValue)
        let visionKey = HolidayPictureSearchDefaults.hasUsableVisionTags(forTagValue: tagValue)
            ? tagValue
            : nil

        return [
            AppViewDefinition(
                viewId: topicId,
                parentViewId: holidaysLanding,
                title: tagValue,
                viewKind: .landing,
                topicKey: topicKey,
                defaultChildViewId: photosId,
                contentMode: .mixed,
                hasAccordion: false,
                accordionGroupBy: .none,
                sortOrder: nil,
                entryEventFilterKey: nil,
                entryPictureSearchKey: nil,
                confirmTagCategory: nil,
                confirmTagValue: nil,
                entryVisionConfigKey: visionKey,
                isEnabled: true,
                sortIndex: sortIndex,
                emptyHint: nil
            ),
            AppViewDefinition(
                viewId: photosId,
                parentViewId: topicId,
                title: "\(tagValue) Photos",
                viewKind: .photoGrid,
                topicKey: topicKey,
                defaultChildViewId: nil,
                contentMode: .photos,
                hasAccordion: true,
                accordionGroupBy: .year,
                sortOrder: .dateDesc,
                entryEventFilterKey: nil,
                entryPictureSearchKey: pictureSearchName,
                confirmTagCategory: nil,
                confirmTagValue: nil,
                entryVisionConfigKey: visionKey,
                isEnabled: true,
                sortIndex: 0,
                emptyHint: "No \(tagValue) pictures matched yet."
            ),
            AppViewDefinition(
                viewId: eventsId,
                parentViewId: topicId,
                title: "\(tagValue) Events",
                viewKind: .eventList,
                topicKey: topicKey,
                defaultChildViewId: nil,
                contentMode: .events,
                hasAccordion: false,
                accordionGroupBy: .none,
                sortOrder: .scoreDesc,
                entryEventFilterKey: "holidayTag:\(tagValue)",
                entryPictureSearchKey: pictureSearchName,
                confirmTagCategory: EventAttributeField.holidayType.tagCategory,
                confirmTagValue: tagValue,
                entryVisionConfigKey: visionKey,
                isEnabled: true,
                sortIndex: 1,
                emptyHint: "No \(tagValue) events yet."
            ),
            AppViewDefinition(
                viewId: possibleId,
                parentViewId: topicId,
                title: "Possible \(tagValue) Events",
                viewKind: .candidateEventList,
                topicKey: topicKey,
                defaultChildViewId: nil,
                contentMode: .events,
                hasAccordion: false,
                accordionGroupBy: .none,
                sortOrder: .scoreDesc,
                entryEventFilterKey: "holidayTag:\(tagValue)",
                entryPictureSearchKey: pictureSearchName,
                confirmTagCategory: EventAttributeField.holidayType.tagCategory,
                confirmTagValue: tagValue,
                entryVisionConfigKey: visionKey,
                isEnabled: true,
                sortIndex: 2,
                emptyHint: "No possible \(tagValue) events yet."
            ),
        ]
    }

    static func view(id: String) -> AppViewDefinition? {
        all.first { $0.viewId == id }
    }

    static func children(of parentId: String) -> [AppViewDefinition] {
        all.filter { $0.parentViewId == parentId }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    static func defaultChild(for viewId: String) -> AppViewDefinition? {
        guard let parent = view(id: viewId),
              let childId = parent.defaultChildViewId else { return nil }
        return view(id: childId)
    }

    private static func homeChild(
        viewId: String,
        title: String,
        viewKind: AppViewKind,
        contentMode: AppContentMode?,
        hasAccordion: Bool,
        accordion: AppAccordionGroup,
        sort: AppSortOrder?,
        filterKey: String?,
        sortIndex: Int,
        enabled: Bool = true
    ) -> AppViewDefinition {
        AppViewDefinition(
            viewId: viewId,
            parentViewId: home,
            title: title,
            viewKind: viewKind,
            topicKey: nil,
            defaultChildViewId: nil,
            contentMode: contentMode,
            hasAccordion: hasAccordion,
            accordionGroupBy: accordion,
            sortOrder: sort,
            entryEventFilterKey: filterKey,
            entryPictureSearchKey: nil,
            confirmTagCategory: nil,
            confirmTagValue: nil,
            entryVisionConfigKey: nil,
            isEnabled: enabled,
            sortIndex: sortIndex,
            emptyHint: enabled ? nil : "Coming soon"
        )
    }
}
