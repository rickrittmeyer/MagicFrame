import Foundation

struct EventAttributeTag: Sendable, Equatable, Identifiable {
    let category: EventAttributeField
    let tagValue: String
    let source: EventTagSource
    let appliedPhase: EventTagAppliedPhase?
    let totalScore: Double?
    /// When a parent list row shows a child's tag, actions target this event id.
    let owningEventId: Int?

    var id: String { "\(category.rawValue)-\(tagValue)" }

    init(
        category: EventAttributeField,
        tagValue: String,
        source: EventTagSource,
        appliedPhase: EventTagAppliedPhase? = nil,
        totalScore: Double? = nil,
        owningEventId: Int? = nil
    ) {
        self.category = category
        self.tagValue = tagValue
        self.source = source
        self.appliedPhase = appliedPhase
        self.totalScore = totalScore
        self.owningEventId = owningEventId
    }

    init(
        holidayTag: EventHolidayTag,
        owningEventId: Int? = nil
    ) {
        self.category = .holidayType
        self.tagValue = holidayTag.tagValue
        self.source = holidayTag.source
        self.appliedPhase = holidayTag.appliedPhase
        self.totalScore = holidayTag.totalScore
        self.owningEventId = owningEventId ?? holidayTag.owningEventId
    }

    var isAIDerived: Bool { source == .ai }

    var formattedScore: String? {
        guard let totalScore else { return nil }
        return String(format: "%.2f", totalScore)
    }

    var asHolidayTag: EventHolidayTag {
        EventHolidayTag(
            tagValue: tagValue,
            source: source,
            appliedPhase: appliedPhase,
            owningEventId: owningEventId
        )
    }

    func actionEventIds(displayEventId: Int) -> [Int] {
        var ids = [displayEventId]
        if let owningEventId, owningEventId != displayEventId {
            ids.append(owningEventId)
        }
        return ids
    }
}
