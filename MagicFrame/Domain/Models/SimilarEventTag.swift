import Foundation

/// Alternative classification offered after rejecting an AI tag (e.g. Wedding → Senior Prom).
struct SimilarEventTagAlternative: Identifiable, Sendable, Equatable {
    let similarEventTagId: Int
    let tagCategory: String
    let tagValue: String
    let possibleTagCategory: String
    let possibleTagValue: String
    let possibleNumberOfEventMainPeople: Int

    var id: Int { similarEventTagId }

    var possibleField: EventAttributeField? {
        EventAttributeField.fromTagCategory(possibleTagCategory)
    }
}

struct SimilarEventAlternativesRequest: Identifiable {
    let displayEventId: Int
    let event: IndexedEvent
    let rejectedTag: EventAttributeTag
    let alternatives: [SimilarEventTagAlternative]

    var id: Int { displayEventId }
}
