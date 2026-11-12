import Foundation

/// Seeded Picture Search definitions for Outings hub tiles.
/// Sporting Events seeds Vision `stadium`; Plays / Concerts stay empty until customized.
enum OutingPictureSearchDefaults {

    /// Matches the Outings tile title (`Sporting Events`, `Plays`, `Concerts`).
    static func pictureSearchName(for topic: OutingTopic) -> String {
        topic.title
    }

    /// Older saved names we still resolve to the canonical tile title.
    static func legacyPictureSearchNames(for topic: OutingTopic) -> [String] {
        [
            "\(topic.title) Picture Search",
            "\(topic.pictureSearchTargetTag) Picture Search",
            topic.pictureSearchTargetTag,
        ]
    }

    static func defaultDefinition(for topic: OutingTopic) -> PictureSearchDefinition {
        PictureSearchDefinition(
            pictureSearchId: nil,
            name: pictureSearchName(for: topic),
            targetTagCategory: EventAttributeField.eventType.tagCategory,
            targetEventType: topic.pictureSearchTargetTag,
            dateSearch: .weddingDefault(),
            visionTagSearch: visionTagSearch(for: topic),
            locationSearch: .empty(),
            peopleSearch: .empty(),
            isEnabled: true,
            performFaceDetect: false
        )
    }

    static func visionTagSearch(for topic: OutingTopic) -> VisionTagSearchDefinition {
        VisionTagSearchDefinition(
            visionTagSearchId: nil,
            name: nil,
            matchMode: "any",
            tags: topic.visionObjectKeys.map { VisionTagCriterion(objectKey: $0) }
        )
    }
}
