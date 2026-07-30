import Foundation

enum PhotoOccasionSource: String, Sendable {
    case eventInherit = "event_inherit"
    case people
    case user
    case album
    case ai
}

enum OccasionSubjectRole: String, Sendable {
    case mother
    case father
    case child
    case person
}

struct PhotoOccasionLink: Identifiable, Sendable {
    let photoOccasionId: Int
    let photoId: String
    let occasionId: Int
    let occasionKey: String?
    let source: PhotoOccasionSource
    let personId: Int?
    let isOnFrame: Bool
    let isRejected: Bool

    var id: Int { photoOccasionId }
}

struct OccasionSubject: Identifiable, Sendable {
    let occasionSubjectId: Int
    let occasionId: Int
    let personId: Int
    let personName: String?
    let role: OccasionSubjectRole

    var id: Int { occasionSubjectId }
}
