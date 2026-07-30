import Foundation

struct OccasionFrameLandingSnapshot: Sendable {
    let occasionKey: String
    let name: String
    let tagValue: String
    let nextOccurrence: Date
    let collectionCount: Int
    let onFramePhotoIds: [String]
}
