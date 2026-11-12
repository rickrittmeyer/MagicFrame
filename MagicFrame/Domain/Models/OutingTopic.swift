import Foundation

/// Hub tile + Picture Search topic for Outings (mirrors Milestones).
struct OutingTopic: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let filter: EventListFilter
    let systemImage: String
    /// `event_tags.tagValue` written when scoring candidates (`eventType`).
    let pictureSearchTargetTag: String
    let visionObjectKeys: [String]

    var pictureSearchName: String {
        OutingPictureSearchDefaults.pictureSearchName(for: self)
    }
}

enum OutingTopicCatalog {

    static let all: [OutingTopic] = [
        OutingTopic(
            id: "sporting-events",
            title: "Sporting Events",
            filter: .sportingEvents,
            systemImage: "sportscourt.fill",
            pictureSearchTargetTag: "Sporting event",
            /// Apple Vision classification id stored in `photo_object_tags.objectKey`.
            visionObjectKeys: ["stadium"]
        ),
        OutingTopic(
            id: "plays",
            title: "Plays",
            filter: .plays,
            systemImage: "theatermasks.fill",
            pictureSearchTargetTag: "Play",
            visionObjectKeys: []
        ),
        OutingTopic(
            id: "concerts",
            title: "Concerts",
            filter: .concerts,
            systemImage: "music.mic",
            pictureSearchTargetTag: "Concert",
            visionObjectKeys: []
        ),
    ]

    static func topic(id: String) -> OutingTopic? {
        all.first { $0.id == id }
    }

    static func topic(forFilter filter: EventListFilter) -> OutingTopic? {
        all.first { $0.filter == filter }
    }
}
