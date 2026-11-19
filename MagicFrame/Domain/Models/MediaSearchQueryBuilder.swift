import Foundation

/// Builds `MediaSearchQuery` values from legacy Picture Search definitions / topic defaults.
enum MediaSearchQueryBuilder {

    static func fromPictureSearch(_ definition: PictureSearchDefinition) -> MediaSearchQuery {
        var criteria: [MediaSearchCriterion] = []

        if let dateCriterion = dateCriterion(from: definition.dateSearch) {
            criteria.append(dateCriterion)
        }

        let visionTags = definition.visionTagSearch.tags
            .map {
                (
                    $0.objectKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    max(0, min(1, $0.minConfidence))
                )
            }
            .filter { !$0.0.isEmpty }
        if !visionTags.isEmpty {
            let joinMode: MediaSearchMatchMode =
                definition.visionTagSearch.matchMode.lowercased() == "all" ? .all : .any
            for (index, tag) in visionTags.enumerated() {
                criteria.append(
                    MediaSearchCriterion(
                        field: .visionTag,
                        op: .is,
                        value: tag.0,
                        minConfidence: tag.1,
                        leadingJoin: index == 0 ? .all : joinMode,
                        openGroups: index == 0 && visionTags.count > 1 ? 1 : 0,
                        closeGroups: index == visionTags.count - 1 && visionTags.count > 1 ? 1 : 0
                    )
                )
            }
        }

        let personIds = definition.peopleSearch.personIds
        if !personIds.isEmpty {
            let joinMode: MediaSearchMatchMode =
                definition.peopleSearch.matchMode.lowercased() == "all" ? .all : .any
            for (index, personId) in personIds.enumerated() {
                criteria.append(
                    MediaSearchCriterion(
                        field: .person,
                        op: .is,
                        value: "",
                        personId: personId,
                        leadingJoin: index == 0 ? .all : joinMode,
                        openGroups: index == 0 && personIds.count > 1 ? 1 : 0,
                        closeGroups: index == personIds.count - 1 && personIds.count > 1 ? 1 : 0
                    )
                )
            }
        }

        let locationTerms = definition.locationSearch.searchTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !locationTerms.isEmpty {
            let joinMode: MediaSearchMatchMode =
                definition.locationSearch.matchMode.lowercased() == "all" ? .all : .any
            for (index, term) in locationTerms.enumerated() {
                criteria.append(
                    MediaSearchCriterion(
                        field: .locationPlaceName,
                        op: .contains,
                        value: term,
                        leadingJoin: index == 0 ? .all : joinMode,
                        openGroups: index == 0 && locationTerms.count > 1 ? 1 : 0,
                        closeGroups: index == locationTerms.count - 1 && locationTerms.count > 1 ? 1 : 0
                    )
                )
            }
        }

        if criteria.isEmpty {
            return .empty()
        }
        return MediaSearchQuery(matchMode: .all, criteria: criteria)
    }

    static func mediaSavedSearch(from definition: PictureSearchDefinition) -> MediaSavedSearch {
        MediaSavedSearch(
            mediaSavedSearchId: nil,
            name: definition.name,
            targetTagCategory: definition.targetTagCategory,
            targetTagValue: definition.targetEventType,
            query: fromPictureSearch(definition),
            isEnabled: definition.isEnabled,
            performFaceDetect: definition.performFaceDetect,
            legacyPictureSearchId: definition.pictureSearchId
        )
    }

    private static func dateCriterion(from dateSearch: DateSearchDefinition) -> MediaSearchCriterion? {
        let before = dateSearch.includeDaysBefore ? (dateSearch.includeXDaysBefore ?? 0) : 0
        let after = dateSearch.includeDaysAfter ? (dateSearch.includeYDaysAfter ?? 0) : 0

        switch dateSearch.dateSearchType {
        case .allDates:
            return nil
        case .sameDateEveryYear:
            guard let monthDay = dateSearch.sameDateSearchDate,
                  MediaSearchCriterion.normalizedMonthDay(monthDay) != nil else {
                return nil
            }
            return MediaSearchCriterion(
                field: .dateTaken,
                op: .anyYear,
                value: monthDay,
                daysBefore: before,
                daysAfter: after,
                includeWeekendsBefore: dateSearch.includeWeekendsBefore,
                includeWeekendsAfter: dateSearch.includeWeekendsAfter,
                holidayId: dateSearch.holidayId
            )
        case .movingHoliday:
            guard let holidayId = dateSearch.holidayId ?? dateSearch.floatingHolidayId else {
                return nil
            }
            return MediaSearchCriterion(
                field: .dateTaken,
                op: .anyYear,
                value: "",
                daysBefore: before,
                daysAfter: after,
                includeWeekendsBefore: dateSearch.includeWeekendsBefore,
                includeWeekendsAfter: dateSearch.includeWeekendsAfter,
                holidayId: holidayId
            )
        case .absoluteRange:
            guard let start = dateSearch.absoluteStartDate,
                  let end = dateSearch.absoluteEndDate else {
                return nil
            }
            return MediaSearchCriterion(
                field: .dateTaken,
                op: .between,
                value: String(start.prefix(10)),
                secondaryValue: String(end.prefix(10))
            )
        case .sameDateRangeEveryYear:
            // Approximate with start month-day any-year window spanning range length is lossy;
            // use start month when available.
            guard let start = dateSearch.rangeStartMonthDay,
                  let month = MediaSearchCriterion.normalizedMonth(String(start.prefix(2))) else {
                return nil
            }
            return MediaSearchCriterion(
                field: .dateTaken,
                op: .inMonth,
                value: month
            )
        }
    }
}
