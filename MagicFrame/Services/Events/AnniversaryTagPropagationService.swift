import Foundation

/// After a wedding date is saved, tags future same-month/day events as anniversaries.
struct AnniversaryTagPropagationService {

    let events: EventRepository
    let eventTags: EventTagRepository

    /// Caller must already be on the database queue.
    @discardableResult
    func propagateUnsafe(
        sourceEventId: Int,
        person1: String,
        person2: String,
        weddingDateISO: String
    ) -> Int {
        guard let weddingDate = EventDateParser.parseDate(weddingDateISO) else { return 0 }

        let trimmedPerson1 = person1.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPerson2 = person2.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPerson1.isEmpty, !trimmedPerson2.isEmpty else { return 0 }

        let calendar = Calendar.current
        let weddingYear = calendar.component(.year, from: weddingDate)
        let weddingMonthDay = calendar.dateComponents([.month, .day], from: weddingDate)

        let candidates = events.fetchAnniversaryCandidateEventsUnsafe(
            weddingDateISO: weddingDateISO,
            excludingEventId: sourceEventId
        )

        var taggedCount = 0

        for candidate in candidates {
            guard let eventDate = EventDateParser.parseDate(candidate.startDate) else { continue }

            let eventComponents = calendar.dateComponents([.year, .month, .day], from: eventDate)
            guard eventComponents.month == weddingMonthDay.month,
                  eventComponents.day == weddingMonthDay.day,
                  let eventYear = eventComponents.year,
                  eventYear > weddingYear else {
                continue
            }

            guard applyAnniversaryTagsUnsafe(
                eventId: candidate.eventId,
                person1: trimmedPerson1,
                person2: trimmedPerson2,
                weddingDateISO: weddingDateISO
            ) else {
                continue
            }

            taggedCount += 1
        }

        return taggedCount
    }

    @discardableResult
    private func applyAnniversaryTagsUnsafe(
        eventId: Int,
        person1: String,
        person2: String,
        weddingDateISO: String
    ) -> Bool {
        let fields: [(EventAttributeField, String)] = [
            (.milestoneType, "Anniversary"),
            (.mainPerson, person1),
            (.secondaryMainPerson, person2),
        ]

        var appliedAny = false

        for (field, value) in fields {
            guard !eventTags.isAIAttributeTagRejectedUnsafe(eventId: eventId, field: field) else {
                continue
            }

            if let existing = eventTags.fetchAttributeTagRowUnsafe(eventId: eventId, field: field),
               existing.source == .user {
                continue
            }

            eventTags.upsertAIAttributeTagUnsafe(
                eventId: eventId,
                field: field,
                tagValue: value
            )
            appliedAny = true
        }

        events.updateWeddingDate(eventId: eventId, weddingDate: weddingDateISO)
        return appliedAny
    }
}
