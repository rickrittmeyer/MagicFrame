import Foundation

/// Hub tile + Picture Search topic for Milestones (mirrors holiday topics).
struct MilestoneTopic: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let filter: EventListFilter
    let systemImage: String
    /// `event_tags.tagValue` written when scoring candidates.
    let pictureSearchTargetTag: String
    let visionObjectKeys: [String]

    var pictureSearchName: String {
        MilestonePictureSearchDefaults.pictureSearchName(for: self)
    }
}

enum MilestoneTopicCatalog {

    static let all: [MilestoneTopic] = [
        MilestoneTopic(
            id: "birthdays",
            title: "Birthdays",
            filter: .milestoneTag(value: "Birthday"),
            systemImage: "birthday.cake.fill",
            pictureSearchTargetTag: "Birthday",
            visionObjectKeys: MilestonePictureSearchDefaults.birthdayVisionObjectKeys
        ),
        MilestoneTopic(
            id: "weddings",
            title: "Weddings",
            filter: .weddings,
            systemImage: "heart.fill",
            pictureSearchTargetTag: "Wedding",
            visionObjectKeys: [
                "wedding_cake",
                "wedding_dress",
                "tuxedo",
                "wedding",
                "bride",
            ]
        ),
        MilestoneTopic(
            id: "graduations",
            title: "Graduations",
            filter: .graduations,
            systemImage: "graduationcap.fill",
            pictureSearchTargetTag: "Graduation",
            // Keys must match `photo_object_tags.objectKey` (snake / Vision label ids).
            visionObjectKeys: MilestonePictureSearchDefaults.graduationVisionObjectKeys
        ),
        MilestoneTopic(
            id: "proms",
            title: "Proms",
            filter: .proms,
            systemImage: "sparkles",
            pictureSearchTargetTag: "Senior Prom",
            visionObjectKeys: ["tuxedo", "wedding_dress", "corsage"]
        ),
        MilestoneTopic(
            id: "christening",
            title: "Christening",
            filter: .christening,
            systemImage: "cross.fill",
            pictureSearchTargetTag: "Christening",
            visionObjectKeys: ["cross", "baptismal_font"]
        ),
        MilestoneTopic(
            id: "baptism",
            title: "Baptism",
            filter: .baptism,
            systemImage: "drop.fill",
            pictureSearchTargetTag: "Baptism",
            visionObjectKeys: ["cross", "baptismal_font"]
        ),
        MilestoneTopic(
            id: "celebration-of-life",
            title: "Celebration of Life",
            filter: .celebrationOfLife,
            systemImage: "sun.max.fill",
            pictureSearchTargetTag: "Celebration of Life",
            visionObjectKeys: []
        ),
    ]

    static func topic(id: String) -> MilestoneTopic? {
        all.first { $0.id == id }
    }

    static func topic(forFilter filter: EventListFilter) -> MilestoneTopic? {
        all.first { $0.filter == filter }
    }
}
