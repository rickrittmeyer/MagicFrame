import Foundation

protocol PhotoRepositoryProtocol: AnyObject {
    func upsertPhoto(
        id: String,
        creationDate: String,
        modificationDate: String,
        mediaType: Int,
        mediaSubtype: Int,
        width: Int,
        height: Int,
        isFavorite: Bool,
        isHidden: Bool,
        latitude: Double?,
        longitude: Double?,
        isScreenshot: Bool,
        aspectRatio: Double,
        orientation: String,
        qualityScore: Int
    )
    func markPhotosDeletedIfMissing(currentIds: Set<String>)
    func getRecentPhotos(limit: Int) -> [IndexedPhoto]
    func updateFaceMetrics(photoId: String, eyesOpenScore: Double, smileScore: Double)
    func clearFaceMetrics(forPhotoIds photoIds: [String])
    func getPhotoCropData(photoId: String) -> PhotoCropFocusRecord?
    func updateCropFocuses(photoId: String, list: PhotoCropFocus?, frame: PhotoCropFocus?)
    func clearAllCropFocuses()
    func clearCropFocus(photoId: String)
    func clearCropFocuses(photoIds: [String])
}

extension PhotoRepository: PhotoRepositoryProtocol {}
