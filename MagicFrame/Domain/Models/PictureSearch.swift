import Foundation

enum PictureDateSearchType: String, Codable, CaseIterable, Identifiable, Sendable {
    case sameDateEveryYear
    case movingHoliday
    case sameDateRangeEveryYear
    case absoluteRange
    case allDates

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sameDateEveryYear: return "Search by Same Date every Year"
        case .movingHoliday: return "Search by Moving Holiday"
        case .sameDateRangeEveryYear: return "Search by Same Date Range Every Year"
        case .absoluteRange: return "Absolute Search Range"
        case .allDates: return "Search All Dates"
        }
    }
}

enum PictureMovingHolidayKey: String, Codable, CaseIterable, Identifiable, Sendable {
    case thanksgiving
    case easter
    case mothers_day
    case fathers_day
    case labor_day
    case memorial_day
    case veterans_day

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thanksgiving: return "Thanksgiving"
        case .easter: return "Easter"
        case .mothers_day: return "Mother's Day"
        case .fathers_day: return "Father's Day"
        case .labor_day: return "Labor Day"
        case .memorial_day: return "Memorial Day"
        case .veterans_day: return "Veteran's Day"
        }
    }
}

struct DateSearchDefinition: Sendable, Equatable, Identifiable {
    var dateSearchId: Int?
    var name: String?
    var dateSearchType: PictureDateSearchType
    var sameDateSearchDate: String?
    var movingHolidayKey: String?
    var floatingHolidayId: Int?
    /// Unified `holidays.holidayId` when the search is anchored to the holiday catalog.
    var holidayId: Int?
    var rangeStartMonthDay: String?
    var rangeEndMonthDay: String?
    var absoluteStartDate: String?
    var absoluteEndDate: String?
    var includeWeekendsBefore: Bool
    var includeWeekendsAfter: Bool
    var includeDaysBefore: Bool
    var includeDaysAfter: Bool
    var includeXDaysBefore: Int?
    var includeYDaysAfter: Int?

    var id: Int { dateSearchId ?? -1 }

    static func weddingDefault() -> DateSearchDefinition {
        DateSearchDefinition(
            dateSearchId: nil,
            name: nil,
            dateSearchType: .allDates,
            sameDateSearchDate: nil,
            movingHolidayKey: nil,
            floatingHolidayId: nil,
            holidayId: nil,
            rangeStartMonthDay: nil,
            rangeEndMonthDay: nil,
            absoluteStartDate: nil,
            absoluteEndDate: nil,
            includeWeekendsBefore: false,
            includeWeekendsAfter: false,
            includeDaysBefore: false,
            includeDaysAfter: false,
            includeXDaysBefore: nil,
            includeYDaysAfter: nil
        )
    }

    /// Christmas anchor day (Dec 25) plus Fri/Sat before when enabled on the search.
    static func christmasDefault() -> DateSearchDefinition {
        HolidayPictureSearchDefaults.dateSearch(forTagValue: "Christmas")
            ?? DateSearchDefinition(
                dateSearchId: nil,
                name: nil,
                dateSearchType: .sameDateEveryYear,
                sameDateSearchDate: "12-25",
                movingHolidayKey: nil,
                floatingHolidayId: nil,
                holidayId: nil,
                rangeStartMonthDay: nil,
                rangeEndMonthDay: nil,
                absoluteStartDate: nil,
                absoluteEndDate: nil,
                includeWeekendsBefore: true,
                includeWeekendsAfter: false,
                includeDaysBefore: false,
                includeDaysAfter: false,
                includeXDaysBefore: nil,
                includeYDaysAfter: nil
            )
    }
}

struct FloatingHolidayDefinition: Sendable, Equatable, Identifiable {
    var floatingHolidayId: Int?
    var name: String
    var ruleKind: String
    var month: Int
    var weekday: Int
    var weekOrdinal: Int
    var isEnabled: Bool

    var id: Int { floatingHolidayId ?? -1 }
}

struct VisionTagCriterion: Sendable, Equatable, Identifiable, Hashable {
    var objectKey: String
    /// Minimum stored Vision confidence (0–1). Matches below this are ignored.
    var minConfidence: Double

    var id: String { objectKey }

    static let defaultMinConfidence = 0.12

    init(objectKey: String, minConfidence: Double = Self.defaultMinConfidence) {
        self.objectKey = objectKey
        self.minConfidence = minConfidence
    }
}

struct VisionTagSearchDefinition: Sendable, Equatable {
    var visionTagSearchId: Int?
    var name: String?
    var matchMode: String
    var tags: [VisionTagCriterion]

    var objectKeys: [String] { tags.map(\.objectKey) }

    static func weddingDefault() -> VisionTagSearchDefinition {
        VisionTagSearchDefinition(
            visionTagSearchId: nil,
            name: nil,
            matchMode: "any",
            tags: [
                VisionTagCriterion(objectKey: "wedding_cake"),
                VisionTagCriterion(objectKey: "wedding_dress"),
                VisionTagCriterion(objectKey: "tuxedo"),
                VisionTagCriterion(objectKey: "wedding"),
                VisionTagCriterion(objectKey: "bride"),
            ]
        )
    }

    static func christmasDefault() -> VisionTagSearchDefinition {
        HolidayPictureSearchDefaults.visionTagSearch(forTagValue: "Christmas")
    }

    static func holidayDefault(tagValue: String) -> VisionTagSearchDefinition {
        HolidayPictureSearchDefaults.visionTagSearch(forTagValue: tagValue)
    }
}

struct LocationSearchDefinition: Sendable, Equatable {
    var locationSearchId: Int?
    var name: String?
    var matchMode: String
    var searchTerms: [String]

    static func empty() -> LocationSearchDefinition {
        LocationSearchDefinition(
            locationSearchId: nil,
            name: nil,
            matchMode: "any",
            searchTerms: []
        )
    }
}

struct PeopleSearchDefinition: Sendable, Equatable {
    var peopleSearchId: Int?
    var name: String?
    var matchMode: String
    var personIds: [Int]

    static func empty() -> PeopleSearchDefinition {
        PeopleSearchDefinition(
            peopleSearchId: nil,
            name: nil,
            matchMode: "any",
            personIds: []
        )
    }
}

struct PictureSearchDefinition: Sendable, Equatable, Identifiable {
    var pictureSearchId: Int?
    var name: String
    /// `event_tags.tagCategory` (e.g. `holiday`, `milestoneType`).
    var targetTagCategory: String
    /// `event_tags.tagValue` (e.g. `Christmas`, `Wedding`).
    var targetEventType: String
    var dateSearch: DateSearchDefinition
    var visionTagSearch: VisionTagSearchDefinition
    var locationSearch: LocationSearchDefinition
    var peopleSearch: PeopleSearchDefinition
    var isEnabled: Bool
    /// When true, running this search enqueues face detect+embed for **result** photos only.
    var performFaceDetect: Bool

    var id: Int { pictureSearchId ?? -1 }

    var targetAttributeField: EventAttributeField {
        EventAttributeField.fromTagCategory(targetTagCategory)
            ?? EventAttributeField.pictureSearchCategory(forTargetValue: targetEventType)
    }

    static func weddingDefault() -> PictureSearchDefinition {
        PictureSearchDefinition(
            pictureSearchId: nil,
            name: "Weddings",
            targetTagCategory: EventAttributeField.milestoneType.tagCategory,
            targetEventType: "Wedding",
            dateSearch: .weddingDefault(),
            visionTagSearch: .weddingDefault(),
            locationSearch: .empty(),
            peopleSearch: .empty(),
            isEnabled: true,
            performFaceDetect: false
        )
    }

    static func christmasDefault() -> PictureSearchDefinition {
        holidayDefault(tagValue: "Christmas") ?? PictureSearchDefinition(
            pictureSearchId: nil,
            name: HolidayPictureSearchDefaults.pictureSearchName(forTagValue: "Christmas"),
            targetTagCategory: EventAttributeField.holidayType.tagCategory,
            targetEventType: "Christmas",
            dateSearch: .christmasDefault(),
            visionTagSearch: .christmasDefault(),
            locationSearch: .empty(),
            peopleSearch: .empty(),
            isEnabled: true,
            performFaceDetect: true
        )
    }

    static func holidayDefault(tagValue: String) -> PictureSearchDefinition? {
        HolidayPictureSearchDefaults.defaultDefinition(forTagValue: tagValue)
    }

    var hasUsableVisionTags: Bool {
        visionTagSearch.tags.contains {
            !$0.objectKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct PictureSearchPhotoMatch: Identifiable, Hashable, Sendable {
    let photoId: String
    let eventId: Int?
    let confidence: Double?

    var id: String { photoId }
}

struct PictureSearchRunReport: Sendable {
    let pictureSearchRunId: Int
    let pictureSearchId: Int
    let targetEventType: String
    let photoMatches: [PictureSearchPhotoMatch]
    let eventCandidateCount: Int

    /// Unique `eventId`s from photo matches in this run (nil assignments excluded).
    var candidateEventIds: [Int] {
        Array(Set(photoMatches.compactMap(\.eventId))).sorted()
    }

    var summaryLine: String {
        let uniqueEvents = candidateEventIds.count
        let photoLabel = photoMatches.count == 1 ? "picture" : "pictures"
        let eventLabel = uniqueEvents == 1 ? "event" : "events"
        return "\(photoMatches.count) \(photoLabel) · \(uniqueEvents) candidate \(eventLabel)"
    }
}

/// Editable weights for “Look for Wedding Events” (and similar) score cards.
struct PictureSearchEventScoreCardSettings: Sendable, Equatable {
    struct VisionTagRule: Sendable, Equatable, Identifiable {
        var objectKey: String
        var minConfidence: Double
        /// Multiplier applied to matched tag confidence (`score += points * confidence`).
        var points: Double

        var id: String { objectKey }
    }

    struct PersonRule: Sendable, Equatable, Identifiable {
        var personId: Int
        var name: String
        var points: Double

        var id: Int { personId }
    }

    struct LocationRule: Sendable, Equatable, Identifiable {
        var searchTerm: String
        var points: Double

        var id: String { searchTerm.lowercased() }
    }

    /// Matches the hub tile / Picture Search name (`Weddings`, `Christmas`, …).
    var name: String
    var eventScoreCardId: Int?
    var targetTagCategory: String
    var targetEventType: String
    var visionTags: [VisionTagRule]
    /// Same shape as the picture search date section.
    var dateSearch: DateSearchDefinition
    /// Points when the event midpoint falls on the anchor day.
    var onDatePoints: Double
    /// Added once per day away from the anchor (default −1).
    var pointsPerDayFromAnchor: Double
    /// Minimum total score required before writing AI event / main-person tags.
    var minimumScoreForAI: Double
    var people: [PersonRule]
    var locations: [LocationRule]

    static let defaultMinimumScoreForAI: Double = 0

    static func fromPictureSearch(
        _ definition: PictureSearchDefinition,
        personNamesById: [Int: String] = [:]
    ) -> PictureSearchEventScoreCardSettings {
        let personRules: [PersonRule] = definition.peopleSearch.personIds.map { personId in
            PersonRule(
                personId: personId,
                name: personNamesById[personId] ?? "Person \(personId)",
                points: 5
            )
        }
        let locationRules = definition.locationSearch.searchTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { LocationRule(searchTerm: $0, points: 5) }

        return PictureSearchEventScoreCardSettings(
            name: definition.name,
            eventScoreCardId: nil,
            targetTagCategory: definition.targetTagCategory,
            targetEventType: definition.targetEventType,
            visionTags: definition.visionTagSearch.tags.map {
                VisionTagRule(
                    objectKey: $0.objectKey,
                    minConfidence: $0.minConfidence,
                    points: 1
                )
            },
            dateSearch: definition.dateSearch,
            onDatePoints: 10,
            pointsPerDayFromAnchor: -1,
            minimumScoreForAI: defaultMinimumScoreForAI,
            people: personRules,
            locations: locationRules
        )
    }

    func meetsAIThreshold(totalScore: Double) -> Bool {
        if minimumScoreForAI > 0 {
            return totalScore >= minimumScoreForAI
        }
        // Default (0): preserve legacy “any positive score” behavior.
        return totalScore > 0
    }
}

struct PictureSearchEventTypeScore: Identifiable, Sendable, Equatable {
    let eventId: Int
    let targetEventType: String
    let visionScore: Double
    let dateScore: Double
    let locationScore: Double
    let peopleScore: Double
    let totalScore: Double
    let likelyGroom: String?
    let likelyBride: String?

    var id: Int { eventId }
}

struct HolidayPhotosPipelineResult: Sendable {
    let definition: PictureSearchDefinition
    let report: PictureSearchRunReport
    let visionReport: PhotoVisionTagScanReport?
}

struct HolidayEventsPipelineResult: Sendable {
    let definition: PictureSearchDefinition
    let report: PictureSearchRunReport
    let checkReport: PictureSearchEventTypeCheckReport?
    let summaryLine: String
}

struct PictureSearchEventTypeCheckReport: Sendable {
    let pictureSearchRunId: Int
    let targetEventType: String
    let eventScores: [PictureSearchEventTypeScore]
    let groomTagsWritten: Int
    let brideTagsWritten: Int

    var summaryLine: String {
        let eventLabel = eventScores.count == 1 ? "event" : "events"
        return "Checked \(eventScores.count) \(eventLabel) for \(targetEventType)"
            + " · \(groomTagsWritten) groom · \(brideTagsWritten) bride AI tags"
    }
}
