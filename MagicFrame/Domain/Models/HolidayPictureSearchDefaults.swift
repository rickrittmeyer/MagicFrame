import Foundation

/// Seeded Picture Search definitions for built-in holiday tiles.
enum HolidayPictureSearchDefaults {

    /// Matches the Holidays tile title (`Christmas`, `Halloween`, …) for programmatic lookup.
    static func pictureSearchName(forTagValue tagValue: String) -> String {
        tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Older saved names we still resolve to the canonical tile title.
    static func legacyPictureSearchNames(forTagValue tagValue: String) -> [String] {
        let canonical = pictureSearchName(forTagValue: tagValue)
        guard !canonical.isEmpty else { return [] }
        return [
            canonical,
            "\(canonical) Picture Search",
        ]
    }

    static func defaultDefinition(for holiday: HolidayDefinition) -> PictureSearchDefinition {
        PictureSearchDefinition(
            pictureSearchId: nil,
            name: pictureSearchName(forTagValue: holiday.name),
            targetTagCategory: EventAttributeField.holidayType.tagCategory,
            targetEventType: holiday.name,
            dateSearch: dateSearch(for: holiday),
            visionTagSearch: visionTagSearch(forTagValue: holiday.name),
            locationSearch: .empty(),
            peopleSearch: .empty(),
            isEnabled: true,
            performFaceDetect: true
        )
    }

    /// Fallback when DB holiday row is unavailable (matches seeded built-ins).
    static func defaultDefinition(forTagValue tagValue: String) -> PictureSearchDefinition? {
        guard let dateSearch = legacyDateSearch(forTagValue: tagValue) else { return nil }
        return PictureSearchDefinition(
            pictureSearchId: nil,
            name: pictureSearchName(forTagValue: tagValue),
            targetTagCategory: EventAttributeField.holidayType.tagCategory,
            targetEventType: tagValue,
            dateSearch: dateSearch,
            visionTagSearch: visionTagSearch(forTagValue: tagValue),
            locationSearch: .empty(),
            peopleSearch: .empty(),
            isEnabled: true,
            performFaceDetect: true
        )
    }

    static var allBuiltInTagValues: [String] {
        EventAttributeField.holidayType.builtInOptions
    }

    static func dateSearch(for holiday: HolidayDefinition) -> DateSearchDefinition {
        switch holiday.kind {
        case .fixed:
            return DateSearchDefinition(
                dateSearchId: nil,
                name: nil,
                dateSearchType: .sameDateEveryYear,
                sameDateSearchDate: holiday.fixedMonthDay,
                movingHolidayKey: nil,
                floatingHolidayId: nil,
                holidayId: holiday.holidayId,
                rangeStartMonthDay: nil,
                rangeEndMonthDay: nil,
                absoluteStartDate: nil,
                absoluteEndDate: nil,
                includeWeekendsBefore: holiday.includeWeekendsBefore,
                includeWeekendsAfter: false,
                includeDaysBefore: false,
                includeDaysAfter: false,
                includeXDaysBefore: nil,
                includeYDaysAfter: nil
            )
        case .floating, .computed:
            return DateSearchDefinition(
                dateSearchId: nil,
                name: nil,
                dateSearchType: .movingHoliday,
                sameDateSearchDate: nil,
                movingHolidayKey: holiday.kind == .computed ? holiday.ruleKind : nil,
                floatingHolidayId: nil,
                holidayId: holiday.holidayId,
                rangeStartMonthDay: nil,
                rangeEndMonthDay: nil,
                absoluteStartDate: nil,
                absoluteEndDate: nil,
                includeWeekendsBefore: holiday.includeWeekendsBefore,
                includeWeekendsAfter: false,
                includeDaysBefore: false,
                includeDaysAfter: false,
                includeXDaysBefore: nil,
                includeYDaysAfter: nil
            )
        }
    }

    static func dateSearch(forTagValue tagValue: String) -> DateSearchDefinition? {
        legacyDateSearch(forTagValue: tagValue)
    }

    static func visionTagSearch(forTagValue tagValue: String) -> VisionTagSearchDefinition {
        guard let category = ObjectDetectionCategory(holidayTagValue: tagValue),
              !category.objectKeys.isEmpty else {
            return VisionTagSearchDefinition(
                visionTagSearchId: nil,
                name: nil,
                matchMode: "any",
                tags: []
            )
        }
        return VisionTagSearchDefinition(
            visionTagSearchId: nil,
            name: nil,
            matchMode: "any",
            tags: category.objectKeys.map { VisionTagCriterion(objectKey: $0) }
        )
    }

    static func hasUsableVisionTags(forTagValue tagValue: String) -> Bool {
        !(ObjectDetectionCategory(holidayTagValue: tagValue)?.objectKeys.isEmpty ?? true)
    }

    private static func legacyDateSearch(forTagValue tagValue: String) -> DateSearchDefinition? {
        switch tagValue {
        case "Christmas":
            return fixedDateSearch(monthDay: "12-25")
        case "Halloween":
            return fixedDateSearch(monthDay: "10-31")
        case "July 4th":
            return fixedDateSearch(monthDay: "07-04")
        case "New Years":
            return fixedDateSearch(monthDay: "01-01")
        case "Valentine's Day":
            return fixedDateSearch(monthDay: "02-14")
        case "St. Patty's Day":
            return fixedDateSearch(monthDay: "03-17")
        case "Thanksgiving":
            return movingDateSearch(key: .thanksgiving)
        case "Easter":
            return movingDateSearch(key: .easter)
        case "Mother's Day":
            return movingDateSearch(key: .mothers_day)
        case "Father's Day":
            return movingDateSearch(key: .fathers_day)
        default:
            return nil
        }
    }

    private static func fixedDateSearch(monthDay: String) -> DateSearchDefinition {
        DateSearchDefinition(
            dateSearchId: nil,
            name: nil,
            dateSearchType: .sameDateEveryYear,
            sameDateSearchDate: monthDay,
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

    private static func movingDateSearch(key: PictureMovingHolidayKey) -> DateSearchDefinition {
        DateSearchDefinition(
            dateSearchId: nil,
            name: nil,
            dateSearchType: .movingHoliday,
            sameDateSearchDate: nil,
            movingHolidayKey: key.rawValue,
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
