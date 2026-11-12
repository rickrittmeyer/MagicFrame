import Foundation
import Photos

enum PictureBrowserSort: String, CaseIterable, Identifiable, Sendable {
    case dateTaken
    case dateImported
    case confidence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dateTaken: return "Date Captured"
        case .dateImported: return "Date Imported"
        case .confidence: return "Confidence"
        }
    }
}

enum PictureBrowserFilter: String, CaseIterable, Identifiable, Sendable {
    case allItems
    case onFrame
    case offFrame
    case favorites
    case photos
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allItems: return "All Photos"
        case .onFrame: return "On Frame"
        case .offFrame: return "Off Frame"
        case .favorites: return "Favorites"
        case .photos: return "Photos"
        case .video: return "Videos"
        }
    }

    /// Video is available when the landing page enables it (All Media + topic Photos).
    var isAvailable: Bool {
        true
    }
}

struct PictureBrowserPhotoRecord: Identifiable, Sendable {
    let photo: IndexedPhoto
    /// `PHAssetMediaType` raw value from `photos.mediaType`.
    let mediaType: Int
    /// Match confidence from the driving picture search, when available.
    let matchConfidence: Double?

    var id: String { photo.id }

    var isVideo: Bool {
        mediaType == PHAssetMediaType.video.rawValue
    }

    var isImage: Bool {
        mediaType == PHAssetMediaType.image.rawValue || mediaType == 0
    }
}
