import Foundation

struct IndexedPhoto {
    let id: String
    let creationDate: String
    let isFavorite: Bool
    let width: Int
    let height: Int
    let mediaSubtype: Int
    let latitude: Double?
    let longitude: Double?
    let isScreenshot: Bool
    let aspectRatio: Double
    let orientation: String
    let qualityScore: Int
    let faceEyesOpenScore: Double?
    let faceSmileScore: Double?
    let showOnFrame: Bool
    let isHiddenInEvent: Bool
    let isSimilarGroupPick: Bool

    init(
        id: String,
        creationDate: String,
        isFavorite: Bool,
        width: Int,
        height: Int,
        mediaSubtype: Int,
        latitude: Double?,
        longitude: Double?,
        isScreenshot: Bool,
        aspectRatio: Double,
        orientation: String,
        qualityScore: Int,
        faceEyesOpenScore: Double? = nil,
        faceSmileScore: Double? = nil,
        showOnFrame: Bool = false,
        isHiddenInEvent: Bool = false,
        isSimilarGroupPick: Bool = false
    ) {
        self.id = id
        self.creationDate = creationDate
        self.isFavorite = isFavorite
        self.width = width
        self.height = height
        self.mediaSubtype = mediaSubtype
        self.latitude = latitude
        self.longitude = longitude
        self.isScreenshot = isScreenshot
        self.aspectRatio = aspectRatio
        self.orientation = orientation
        self.qualityScore = qualityScore
        self.faceEyesOpenScore = faceEyesOpenScore
        self.faceSmileScore = faceSmileScore
        self.showOnFrame = showOnFrame
        self.isHiddenInEvent = isHiddenInEvent
        self.isSimilarGroupPick = isSimilarGroupPick
    }
}
