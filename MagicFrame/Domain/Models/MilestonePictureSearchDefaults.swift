import Foundation

/// Seeded Picture Search definitions for milestone hub tiles.
enum MilestonePictureSearchDefaults {

    /// Days before/after the birthday anchor (± matches birthday event list overlap).
    static let birthdayWindowDays = 3

    /// Matches the Milestones tile title (`Weddings`, `Graduations`, …) for programmatic lookup.
    static func pictureSearchName(for topic: MilestoneTopic) -> String {
        topic.title
    }

    /// Matches the birthday person tile style (`Alex Birthday`).
    static func pictureSearchName(forPersonBirthday person: PeopleRepository.PersonBirthdayRecord) -> String {
        "\(person.name) Birthday"
    }

    /// Older saved names we still resolve to the canonical tile title.
    static func legacyPictureSearchNames(for topic: MilestoneTopic) -> [String] {
        var names = [
            "\(topic.title) Picture Search",
            "\(topic.pictureSearchTargetTag) Picture Search",
            topic.pictureSearchTargetTag,
        ]
        switch topic.id {
        case "weddings":
            names.append(contentsOf: ["Wedding Picture Search", "Wedding"])
        case "proms":
            names.append(contentsOf: ["Senior Prom Picture Search", "Senior Prom"])
        default:
            break
        }
        return Array(Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
    }

    static func legacyPictureSearchNames(forPersonBirthday person: PeopleRepository.PersonBirthdayRecord) -> [String] {
        let canonical = pictureSearchName(forPersonBirthday: person)
        return [
            canonical,
            "\(canonical) Picture Search",
            "\(person.name) Birthday Picture Search",
        ]
    }

    static func defaultDefinition(for topic: MilestoneTopic) -> PictureSearchDefinition {
        PictureSearchDefinition(
            pictureSearchId: nil,
            name: pictureSearchName(for: topic),
            targetTagCategory: EventAttributeField.milestoneType.tagCategory,
            targetEventType: topic.pictureSearchTargetTag,
            dateSearch: .weddingDefault(),
            visionTagSearch: visionTagSearch(for: topic),
            locationSearch: .empty(),
            peopleSearch: .empty(),
            isEnabled: true,
            performFaceDetect: false
        )
    }

    static let birthdayVisionObjectKeys = [
        "birthday_cake",
        "balloon",
        "decoration",
    ]

    /// Stored Vision label ids (see `photo_object_tags.objectKey`).
    static let graduationVisionObjectKeys = [
        "graduation",
    ]

    /// Person-specific birthday search: photos of that person near birth month/day every year.
    /// Default Vision match mode is `any` (cake / balloon / decoration).
    static func personBirthdayDefinition(
        for person: PeopleRepository.PersonBirthdayRecord
    ) -> PictureSearchDefinition? {
        guard let monthDay = monthDay(fromBirthDateISO: person.birthDateISO) else {
            return nil
        }
        return PictureSearchDefinition(
            pictureSearchId: nil,
            name: pictureSearchName(forPersonBirthday: person),
            targetTagCategory: EventAttributeField.milestoneType.tagCategory,
            targetEventType: "Birthday",
            dateSearch: birthdayDateSearch(monthDay: monthDay),
            visionTagSearch: birthdayVisionTagSearch(),
            locationSearch: .empty(),
            peopleSearch: PeopleSearchDefinition(
                peopleSearchId: nil,
                name: nil,
                matchMode: "any",
                personIds: [person.personId]
            ),
            isEnabled: true,
            performFaceDetect: true
        )
    }

    static func birthdayVisionTagSearch() -> VisionTagSearchDefinition {
        VisionTagSearchDefinition(
            visionTagSearchId: nil,
            name: nil,
            matchMode: "any",
            tags: birthdayVisionObjectKeys.map { VisionTagCriterion(objectKey: $0) }
        )
    }

    static func birthdayDateSearch(monthDay: String) -> DateSearchDefinition {
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
            includeWeekendsAfter: true,
            includeDaysBefore: true,
            includeDaysAfter: true,
            includeXDaysBefore: birthdayWindowDays,
            includeYDaysAfter: birthdayWindowDays
        )
    }

    /// `MM-DD` from a stored `YYYY-MM-DD…` birth date.
    static func monthDay(fromBirthDateISO iso: String) -> String? {
        let trimmed = iso.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return nil }
        let monthDay = String(trimmed.dropFirst(5).prefix(5))
        let parts = monthDay.split(separator: "-")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        return String(format: "%02d-%02d", month, day)
    }

    static func visionTagSearch(for topic: MilestoneTopic) -> VisionTagSearchDefinition {
        VisionTagSearchDefinition(
            visionTagSearchId: nil,
            name: nil,
            matchMode: "any",
            tags: topic.visionObjectKeys.map { VisionTagCriterion(objectKey: $0) }
        )
    }
}
