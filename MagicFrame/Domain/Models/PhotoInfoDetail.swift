import Foundation

/// Everything MagicFrame knows about one photo for the full-screen Info sheet.
struct PhotoInfoDetail: Sendable, Identifiable {
    let photoId: String

    // Capture
    let effectiveCreationDate: String?
    let libraryCreationDate: String?
    let captureDateOverride: String?
    let indexedAt: String?

    // Location
    let locationLine: String
    let nickname: String?
    let placeName: String?
    let city: String?
    let state: String?
    let locationType: String?
    let latitude: Double?
    let longitude: Double?

    // Media
    let isVideo: Bool
    let isScreenshot: Bool
    let width: Int
    let height: Int
    let orientation: String?
    let qualityScore: Int?
    let duration: Double?

    // Library flags
    let isFavorite: Bool
    let showOnFrame: Bool
    let isHiddenInEvent: Bool
    let isSimilarGroupPick: Bool

    // Camera / EXIF
    let cameraMake: String?
    let cameraModel: String?
    let lensModel: String?

    // Filename & albums
    let originalFilename: String?
    let albumTitles: [String]

    // People & faces
    let peopleNames: [String]
    let faceCount: Int
    let faceEyesOpenScore: Double?
    let faceSmileScore: Double?

    // Vision
    let visionAnalyzed: Bool
    let visionTags: [PhotoInfoVisionTag]

    // OCR
    let ocrScanned: Bool
    let ocrFullText: String?
    let ocrObservationCount: Int

    // Events
    let events: [PhotoInfoEventLink]

    // Technical
    let faceRecognitionVersion: Int
    let textRecognitionVersion: Int

    var id: String { photoId }
}

struct PhotoInfoVisionTag: Sendable, Identifiable, Hashable {
    let objectKey: String
    let confidence: Double

    var id: String { objectKey }

    var confidencePercent: Int {
        Int((confidence * 100).rounded())
    }
}

struct PhotoInfoEventLink: Sendable, Identifiable, Hashable {
    let eventId: Int
    let title: String
    let tags: [PhotoInfoEventTag]

    var id: Int { eventId }
}

struct PhotoInfoEventTag: Sendable, Hashable {
    let category: String
    let value: String
}
