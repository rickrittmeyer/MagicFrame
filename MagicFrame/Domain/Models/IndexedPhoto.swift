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
    let isVideo: Bool

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
        isSimilarGroupPick: Bool = false,
        isVideo: Bool = false
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
        self.isVideo = isVideo
    }

    func withShowOnFrame(
        _ showOnFrame: Bool,
        isSimilarGroupPick: Bool? = nil
    ) -> IndexedPhoto {
        copy(
            isFavorite: isFavorite,
            showOnFrame: showOnFrame,
            isHiddenInEvent: isHiddenInEvent,
            isSimilarGroupPick: isSimilarGroupPick ?? self.isSimilarGroupPick
        )
    }

    func withFavorite(_ isFavorite: Bool) -> IndexedPhoto {
        copy(
            isFavorite: isFavorite,
            showOnFrame: showOnFrame,
            isHiddenInEvent: isHiddenInEvent,
            isSimilarGroupPick: isSimilarGroupPick
        )
    }

    func withHiddenInEvent(_ isHiddenInEvent: Bool) -> IndexedPhoto {
        copy(
            isFavorite: isFavorite,
            showOnFrame: isHiddenInEvent ? false : showOnFrame,
            isHiddenInEvent: isHiddenInEvent,
            isSimilarGroupPick: isSimilarGroupPick
        )
    }

    private func copy(
        isFavorite: Bool,
        showOnFrame: Bool,
        isHiddenInEvent: Bool,
        isSimilarGroupPick: Bool
    ) -> IndexedPhoto {
        IndexedPhoto(
            id: id,
            creationDate: creationDate,
            isFavorite: isFavorite,
            width: width,
            height: height,
            mediaSubtype: mediaSubtype,
            latitude: latitude,
            longitude: longitude,
            isScreenshot: isScreenshot,
            aspectRatio: aspectRatio,
            orientation: orientation,
            qualityScore: qualityScore,
            faceEyesOpenScore: faceEyesOpenScore,
            faceSmileScore: faceSmileScore,
            showOnFrame: showOnFrame,
            isHiddenInEvent: isHiddenInEvent,
            isSimilarGroupPick: isSimilarGroupPick
        )
    }
}
