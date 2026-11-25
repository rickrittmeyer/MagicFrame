import Foundation

/// Application database facade used by ViewModels (orchestration + repository forwards).
protocol MagicFrameDatabase: AnyObject {
    // MARK: - Developer / tuning

    func getEventTuningSettings() -> EventTuningSettings
    func saveEventTuningSettings(_ settings: EventTuningSettings)
    func resetEventTuningSettings()
    func resetDatabaseForDevelopmentOnly()

    // MARK: - Photos

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
    func getRecentPhotos(limit: Int) -> [IndexedPhoto]
    func countPhotosMissingLocation() -> Int
    func countActivePhotos() -> Int
    func updateFaceMetrics(photoId: String, eyesOpenScore: Double, smileScore: Double)
    func faceMetricsAlgorithmVersion() -> Int
    func setFaceMetricsAlgorithmVersion(_ version: Int)
    func clearFaceMetrics(forPhotoIds photoIds: [String])
    func getPhotoCropData(photoId: String) -> PhotoCropFocusRecord?
    func updateCropFocuses(photoId: String, list: PhotoCropFocus?, frame: PhotoCropFocus?)
    func cropAlgorithmVersion() -> Int
    func setCropAlgorithmVersion(_ version: Int)
    func clearAllCropFocuses()
    func clearCropFocus(photoId: String)

    // MARK: - People

    func importPeopleFromAlbums()
    func rebuildEventPeople()
    func getAllPersonNames() -> [String]

    // MARK: - Events

    func getEvents(includeHidden: Bool) -> [IndexedEvent]
    func getEvent(eventId: Int) -> IndexedEvent?
    func getSlideshowPhotoIds(for events: [IndexedEvent]) -> [Int: [String]]
    func getEventsForLocation(locationId: Int) -> [IndexedEvent]
    func getTripSections(for parentEventId: Int, includeHidden: Bool) -> [TripEventSection]
    func getPhotosForEvent(eventId: Int, includeHidden: Bool) -> [IndexedPhoto]
    func setEventShowOnFrame(eventId: Int, show: Bool)
    func setEventUserHidden(eventId: Int, hidden: Bool)
    @discardableResult
    func updateEventName(eventId: Int, name: String, userEdited: Bool) -> Bool
    @discardableResult
    func updateChildEventName(eventId: Int, name: String, userEdited: Bool) -> Bool
    func setSimilarGroupPicks(groupPhotoIds: [String], pickedPhotoIds: Set<String>)
    func setPhotosHiddenInEvent(photoIds: [String], hidden: Bool)
    func setPhotosShowOnFrame(photoIds: [String], show: Bool)
    func setPhotoShowOnFrame(photoId: String, eventId: Int, show: Bool)
    func setPhotoFavorite(photoId: String, isFavorite: Bool)
    func softDeletePhotos(photoIds: [String])
    func setEventFavorite(eventId: Int, isFavorite: Bool)
    func softDeleteEvent(eventId: Int)
    func getEventIdForPhoto(photoId: String) -> Int?
    func getEventAttributeOptions(for field: EventAttributeField) -> [String]
    func addCustomEventAttributeOption(_ value: String, for field: EventAttributeField)
    func updateEventAttribute(eventId: Int, field: EventAttributeField, value: String?)

    // MARK: - Event pipeline

    func countUnassignedPhotosForEvents() -> Int
    func syncEventsAssignmentBatch() -> Bool
    func finishEventSyncMaintenance()
    func prepareEventRebuild() -> Int
    func finishEventRebuild()
    func updateAllEventCoverPhotos()
    func restoreDeletedTripContainersOnQueue()

    // MARK: - Locations

    func getLocationsRankedByEventCount() -> [ManagedLocation]
    func getLocation(locationId: Int) -> ManagedLocation?
    func getLocationTypeOptions() -> [String]
    func locationsNeedingGeocodeCount() -> Int
    func startGeocodingEventLocations(limit: Int?)
    func stopGeocoding()
    func updateLocationType(locationId: Int, locationType: String?)
    func setLocationFavorite(locationId: Int, isFavorite: Bool)
    func updateLocationNickname(locationId: Int, nickname: String?)
    func updateLocationHomeDesignation(
        locationId: Int,
        role: LocationHomeRole,
        homeStartDate: Date?,
        homeEndDate: Date?
    )
    func addCustomLocationType(_ type: String)
    func hasCurrentHome() -> Bool
    func createDesignatedCurrentHome(
        latitude: Double,
        longitude: Double,
        nickname: String?,
        homeStartDate: Date?
    ) -> Int
    func deduplicateLocationsByAddress(maxDistanceMiles: Double?) -> Int
    func repairHomeLocations()

    // MARK: - Archive batches

    func getLikelyUploadBatches(
        gapSeconds: TimeInterval,
        minPhotos: Int
    ) -> [PhotoUploadBatch]
    func applyArchiveBatchMetadata(
        photoIds: [String],
        captureDate: Date,
        latitude: Double,
        longitude: Double
    )

    // MARK: - Debug

    func debugEventPipeline()
    func debugLocationCounts()
    func debugSchema()
}

extension PhotoDatabase: MagicFrameDatabase {}
