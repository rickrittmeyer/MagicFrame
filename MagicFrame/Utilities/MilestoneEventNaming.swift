import Foundation

enum MilestoneEventNaming {

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        return formatter
    }()

    static func birthMonthDayDisplay(birthDateISO: String) -> String? {
        guard let date = EventDateParser.parseDate(birthDateISO) else { return nil }
        return monthDayFormatter.string(from: date)
    }

    static func isPersonMilestone(_ milestoneType: String?) -> Bool {
        MilestonePersonPickerKind.from(milestoneType: milestoneType) != nil
    }

    static func isCoupleMilestone(_ milestoneType: String?) -> Bool {
        MilestonePersonPickerKind.from(milestoneType: milestoneType)?.isCoupleMilestone == true
    }

    static func suggestEventName(
        personName: String,
        milestoneType: String?,
        birthDateISO: String?,
        eventStartDate: String
    ) -> String? {
        guard let kind = MilestonePersonPickerKind.from(milestoneType: milestoneType),
              !kind.isCoupleMilestone else {
            return nil
        }

        let trimmed = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let possessive = "\(trimmed)'s"

        switch kind {
        case .birthday:
            guard let birthDateISO,
                  let birthDate = EventDateParser.parseDate(birthDateISO),
                  let eventDate = EventDateParser.parseDate(eventStartDate),
                  let ordinal = yearsBetween(startDate: birthDate, endDate: eventDate) else {
                return "\(possessive) Birthday"
            }
            return "\(possessive) \(ordinalSuffix(ordinal)) Birthday"
        case .graduation:
            return "\(possessive) Graduation"
        case .baptism:
            return "\(possessive) Baptism"
        case .wedding, .anniversary:
            return nil
        }
    }

    /// Fills `{person1}`, `{person2}`, and `{tagValue}` in an `event_name_templates` row.
    /// Wedding seeds use bride=`person1`, groom=`person2` → `{person2} and {person1}'s Wedding`.
    static func applyNameTemplate(
        _ template: String,
        person1: String?,
        person2: String?,
        tagValue: String
    ) -> String? {
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTemplate.isEmpty else { return nil }

        let first = person1?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let second = person2?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmedTemplate.contains("{person1}"), first.isEmpty { return nil }
        if trimmedTemplate.contains("{person2}"), second.isEmpty { return nil }

        let tag = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTemplate
            .replacingOccurrences(of: "{person1}", with: first)
            .replacingOccurrences(of: "{person2}", with: second)
            .replacingOccurrences(of: "{tagValue}", with: tag)
    }

    static func suggestCoupleEventName(
        person1: String,
        person2: String,
        milestoneType: String?,
        weddingDateISO: String?,
        eventStartDate: String,
        nameTemplate: EventNameTemplate? = nil
    ) -> String? {
        let first = person1.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = person2.trimmingCharacters(in: .whitespacesAndNewlines)

        if let nameTemplate,
           let named = applyNameTemplate(
               nameTemplate.nameTemplate,
               person1: first,
               person2: second.isEmpty ? nil : second,
               tagValue: nameTemplate.tagValue
           ) {
            return named
        }

        guard let kind = MilestonePersonPickerKind.from(milestoneType: milestoneType),
              kind.isCoupleMilestone else {
            return nil
        }

        guard !first.isEmpty, !second.isEmpty else { return nil }

        switch kind {
        case .wedding:
            // Fallback if template row missing: bride=person1, groom=person2.
            return applyNameTemplate(
                "{person2} and {person1}'s Wedding",
                person1: first,
                person2: second,
                tagValue: "Wedding"
            )
        case .anniversary:
            let coupleName = "\(first) & \(second)'s"
            guard let weddingDateISO,
                  let weddingDate = EventDateParser.parseDate(weddingDateISO),
                  let eventDate = EventDateParser.parseDate(eventStartDate),
                  let ordinal = yearsBetween(startDate: weddingDate, endDate: eventDate) else {
                return "\(coupleName) Anniversary"
            }
            return "\(coupleName) \(ordinalSuffix(ordinal)) Anniversary"
        default:
            return nil
        }
    }

    static func suggestTemplatedEventName(
        nameTemplate: EventNameTemplate,
        person1: String?,
        person2: String?
    ) -> String? {
        applyNameTemplate(
            nameTemplate.nameTemplate,
            person1: person1,
            person2: person2,
            tagValue: nameTemplate.tagValue
        )
    }

    private static func yearsBetween(
        startDate: Date,
        endDate: Date,
        calendar: Calendar = .current
    ) -> Int? {
        let startYear = calendar.component(.year, from: startDate)
        let endYear = calendar.component(.year, from: endDate)
        guard endYear >= startYear else { return nil }
        return max(1, endYear - startYear)
    }

    private static func ordinalSuffix(_ value: Int) -> String {
        let ones = value % 10
        let tens = (value / 10) % 10

        let suffix: String
        if tens == 1 {
            suffix = "th"
        } else {
            switch ones {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }

        return "\(value)\(suffix)"
    }
}
