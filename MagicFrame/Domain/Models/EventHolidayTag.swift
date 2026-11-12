import Foundation

enum EventTagSource: String, Sendable, Equatable {
    case ai
    case user
}

struct EventHolidayTag: Sendable, Equatable {
    let tagValue: String
    let source: EventTagSource
    let totalScore: Double?
    /// When a parent list row shows a child's tag, actions target this event id.
    let owningEventId: Int?

    init(
        tagValue: String,
        source: EventTagSource,
        totalScore: Double? = nil,
        owningEventId: Int? = nil
    ) {
        self.tagValue = tagValue
        self.source = source
        self.totalScore = totalScore
        self.owningEventId = owningEventId
    }

    var isAIDerived: Bool { source == .ai }

    func actionEventIds(displayEventId: Int) -> [Int] {
        var ids = [displayEventId]
        if let owningEventId, owningEventId != displayEventId {
            ids.append(owningEventId)
        }
        return ids
    }
}

struct HolidayTagApplyResult: Sendable {
    let applied: Int
    let updated: Int
    let removed: Int
    let skippedUserOwned: Int

    var summaryLine: String {
        "Holiday tags: \(applied.formatted()) applied, \(updated.formatted()) updated,"
            + " \(removed.formatted()) removed"
    }

    var detailLine: String {
        "\(skippedUserOwned.formatted()) skipped (user-defined holiday)"
    }
}
