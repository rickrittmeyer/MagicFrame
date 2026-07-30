import Foundation

/// Application database facade used by ViewModels (orchestration + repository forwards).
protocol MagicFrameDatabase: AnyObject {
    // MARK: - Developer / tuning

    func getEventTuningSettings() -> EventTuningSettings
    func saveEventTuningSettings(_ settings: EventTuningSettings)
    func resetEventTuningSettings()
    func resetDatabaseForDevelopmentOnly()
    func fetchEditableOccasions() -> [EditableOccasion]
    func saveEditableOccasions(_ occasions: [EditableOccasion])

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
    func christmasObjectKeysForVisionDebug() -> [String]
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
    func ensureCropAlgorithmVersionCurrent()
    func clearAllCropFocuses()
    func clearCropFocus(photoId: String)

    // MARK: - Metadata enrichment

    func runPostIndexMetadataEnrichment()
    func runPostIndexMetadataEnrichmentIfNeeded()
    func metadataEnrichmentCounts() -> MetadataEnrichmentCounts
    func eventDateDiagnosticCounts() -> EventDateDiagnosticCounts
    @discardableResult
    func repairEventDateSummaries() -> EventDateRepairResult

    // MARK: - People

    func importPeopleFromAlbums()
    func rebuildEventPeople()
    func getAllPersonNames() -> [String]

    // MARK: - Events

    func countListEvents(includeHidden: Bool, filter: EventListFilter) -> Int
    func getEvents(includeHidden: Bool) -> [IndexedEvent]
    func getEventsForList(
        includeHidden: Bool,
        limit: Int?,
        filter: EventListFilter
    ) -> [IndexedEvent]
    func getEvent(eventId: Int) -> IndexedEvent?
    func eventMatchesListFilter(eventId: Int, filter: EventListFilter) -> Bool
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
    func getEventIdForPhoto(photoId: String) -> Int?
    func getEventAttributeOptions(for field: EventAttributeField) -> [String]
    func addCustomEventAttributeOption(_ value: String, for field: EventAttributeField)
    func updateEventAttribute(eventId: Int, field: EventAttributeField, value: String?)
    func updateWeddingDate(eventId: Int, weddingDate: String?)
    func propagateAnniversaryTagsFromWedding(
        sourceEventId: Int,
        person1: String,
        person2: String,
        weddingDateISO: String
    ) -> Int
    func fetchAITagScoringDetail(
        eventId: Int,
        field: EventAttributeField,
        includesDescendantPhotos: Bool
    ) -> AITagScoringDetail?
    func fetchHolidayScorecards(
        eventId: Int,
        includesDescendantPhotos: Bool
    ) -> [AITagScoringDetail]
    func updateOccasionDateScoringSettings(
        occasionId: Int,
        edit: OccasionDateScoringEdit
    )
    func fetchObjectScoringRules(occasionId: Int) -> [EditableObjectScoringRule]
    @discardableResult
    func saveObjectScoringRules(occasionId: Int, rules: [EditableObjectScoringRule]) -> Int
    func scoreHolidayEvent(eventId: Int)
    func runEventObjectRecognitionIfNeeded(
        eventId: Int,
        includeHiddenPhotos: Bool,
        progress: (@Sendable (EventObjectRecognitionProgress) -> Void)?
    ) async -> EventObjectRecognitionResult
    func enqueueEventObjectRecognitionJobs(
        eventId: Int,
        includeHiddenPhotos: Bool,
        forceRescan: Bool,
        forcedOccasionKey: String?,
        priority: Int,
        scopeKey: String?
    ) -> VisionJobEnqueueSummary
    func enqueueHolidayYearObjectRecognitionJobs(
        config: HolidayVisionLandingConfig,
        year: Int,
        eventIds: [Int],
        includeHiddenPhotos: Bool,
        priority: Int
    ) -> VisionJobEnqueueSummary
    func visionJobPendingCount(scopeKey: String?, eventId: Int?) -> Int
    func enqueueHolidayTaggedObjectRescan(
        tagValue: String,
        includeHiddenPhotos: Bool,
        priority: Int
    ) -> VisionJobRescanEnqueueResult
    func enqueueChristmasTaggedObjectRescan(
        includeHiddenPhotos: Bool,
        priority: Int
    ) -> VisionJobRescanEnqueueResult
    func confirmAIAttributeTag(eventId: Int, field: EventAttributeField)
    func rejectAIAttributeTag(eventId: Int, field: EventAttributeField)
    func confirmAIHolidayTag(eventId: Int)
    func rejectAIHolidayTag(eventId: Int)
    func fetchOccasionLandingItems() -> [OccasionLandingItem]
    func fetchOccasionLandingCatalogItems() -> [OccasionLandingItem]
    func applyCachedOccasionLandingMetrics(
        to items: [OccasionLandingItem]
    ) -> (items: [OccasionLandingItem], staleTagValues: [String])
    func countOccasionLandingItemMetrics(
        occasionKey: String,
        tagValue: String,
        occasionType: String,
        displayName: String
    ) -> (collections: Int, onFramePhotos: Int)
    func countOccasionLandingMetricsBatch(
        requests: [OccasionLandingMetricsRequest]
    ) -> [String: (collections: Int, onFramePhotos: Int)]
    func fetchOccasionFrameLandingSnapshot(
        occasionKey: String,
        tagValue: String,
        name: String,
        nextOccurrence: Date,
        occasionType: String
    ) -> OccasionFrameLandingSnapshot
    func fetchAllPeople() -> [PeopleRepository.PersonRecord]
    func fetchPeopleWithBirthDates() -> [PeopleRepository.PersonBirthdayRecord]
    func fetchEventPeople(eventId: Int, includeChildEvents: Bool) -> [EventRepository.EventPersonRecord]

    // MARK: - Photo ↔ occasion (per-occasion on-frame)

    func linkPhotoToOccasion(
        photoId: String,
        occasionKey: String,
        source: PhotoOccasionSource,
        personId: Int?,
        isOnFrame: Bool
    )
    func setPhotoOccasionOnFrame(photoId: String, occasionKey: String, isOnFrame: Bool)
    func setPhotosOccasionOnFrame(photoIds: [String], occasionKey: String, isOnFrame: Bool)
    func fetchOnFramePhotoIds(occasionKey: String) -> [String]
    func countOnFramePhotos(occasionKey: String) -> Int
    func fetchPhotoOccasions(photoId: String) -> [PhotoOccasionLink]
    func saveOccasionSubjects(
        occasionKey: String,
        subjects: [(personId: Int, role: OccasionSubjectRole)]
    )
    func fetchOccasionSubjects(occasionKey: String) -> [OccasionSubject]
    func searchPhotosWithPeople(
        requiredPersonId: Int,
        includingAnyOfPersonIds childPersonIds: [Int],
        exactPeopleOnly: Bool
    ) -> [String]
    func searchPhotosWithPerson(personId: Int, exactPeopleOnly: Bool) -> [String]
    func fetchOccasionPersonId(occasionKey: String) -> Int?

    // MARK: - Event pipeline

    func countUnassignedPhotosForEvents() -> Int
    func countUnassignedMetadataPhotosForEvents() -> Int
    func metadataAssignmentCounts() -> MetadataAssignmentCounts
    func syncMetadataAssignmentBatch() -> Bool
    func syncMetadataAssignmentUntilComplete()
    func syncEventsAssignmentBatch() -> Bool
    func finishEventSyncMaintenance()
    func prepareEventRebuild() -> Int
    func finishEventRebuild()
    func updateAllEventCoverPhotos()
    func restoreDeletedTripContainersOnQueue()

    // MARK: - Locations

    func countLocations() -> Int
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
    func debugMetadataCounts()
}

extension PhotoDatabase: MagicFrameDatabase {}
