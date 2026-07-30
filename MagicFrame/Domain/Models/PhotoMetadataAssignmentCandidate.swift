import Foundation

/// Unassigned photo eligible for metadata-based (no-GPS) event attachment.
struct PhotoMetadataAssignmentCandidate: Equatable {
    let id: String
    let date: Date
}

struct PhotoMetadataAssignmentMatch: Equatable {
    let eventId: Int
    let confidence: Double
    let method: PhotoEventAssignmentMethod
    let sharedAlbums: Int
    let sharedPeople: Int
    let needsReview: Bool
}

struct PhotoMetadataAssignmentBatchResult: Sendable {
    let processed: Int
    let attached: Int
    let skipped: Int
    let remaining: Int
}
