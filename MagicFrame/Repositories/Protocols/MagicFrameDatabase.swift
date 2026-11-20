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
        qualityScore: Int,
        duration: Double?
    )
    func getRecentPhotos(limit: Int) -> [IndexedPhoto]
    func fetchUnanalyzedPhotoIdsMatchingMonthDayRange(
        start: String,
        end: String
    ) -> PhotoVisionTagMonthDaySelection
    func scanPhotosWithVisionTags(
        photoIds: [String],
        progress: (@Sendable (Int, Int) -> Void)?
    ) async -> PhotoVisionTagScanReport
    /// Event-open full classify: skip `visionAnalyzed=1`, write `photo_object_tags`, rebuild `event_object_tags`.
    func scanEventPhotosWithVisionTags(
        eventId: Int,
        includeHiddenPhotos: Bool,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async -> PhotoVisionTagScanReport
    /// AI Assist OCR: recognize text in event photos, store in `photo_ocr_text`, skip already-scanned versions.
    func scanEventPhotosForText(
        eventId: Int,
        includeHiddenPhotos: Bool,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async -> PhotoTextRecognitionScanReport
    /// Ad-hoc All Media picture search (filename / album / OCR / vision / location / people / events).
    func searchPhotos(matching query: MediaSearchQuery) -> MediaPhotoSearchReport
    func mediaSearchSuggestionValues(
        field: MediaSearchField,
        query: String,
        limit: Int
    ) -> [String]
    func fetchAllMediaSavedSearches(enabledOnly: Bool) -> [MediaSavedSearch]
    func fetchMediaSavedSearch(id: Int) -> MediaSavedSearch?
    func saveMediaSavedSearch(_ search: MediaSavedSearch) -> Int
    func deleteMediaSavedSearch(id: Int)
    func upsertMediaSavedSearch(from definition: PictureSearchDefinition) -> MediaSavedSearch
    func migratePictureSearchesToMediaSavedSearchesIfNeeded()
    func runMediaSavedSearch(_ search: MediaSavedSearch) -> PictureSearchRunReport
    func searchPhotosByVisionTag(_ query: String, limit: Int) -> [VisionTagPhotoMatch]
    func searchPhotosByExactVisionTag(_ objectKey: String, limit: Int) -> [VisionTagPhotoMatch]
    func fetchDistinctVisionTagNames() -> [VisionTagName]
    func savePictureSearch(_ definition: PictureSearchDefinition) -> Int
    func fetchPictureSearch(pictureSearchId: Int) -> PictureSearchDefinition?
    func fetchAllPictureSearches() -> [PictureSearchDefinition]
    func fetchFloatingHolidays() -> [FloatingHolidayDefinition]
    func upsertFloatingHoliday(_ holiday: FloatingHolidayDefinition) -> Int
    func fetchAllEnabledHolidays() -> [HolidayDefinition]
    func upsertHoliday(_ holiday: HolidayDefinition) -> Int
    func runPictureSearch(_ definition: PictureSearchDefinition) -> PictureSearchRunReport
    func runPictureSearch(pictureSearchId: Int) -> PictureSearchRunReport?
    func fetchLatestPictureSearchRun(pictureSearchId: Int) -> PictureSearchRunReport?
    func ensureWeddingPictureSearch() -> PictureSearchDefinition
    func runWeddingPictureSearch() -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)
    func ensureChristmasPictureSearch() -> PictureSearchDefinition
    func runChristmasPictureSearch() -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)
    func ensureHolidayPictureSearch(tagValue: String) -> PictureSearchDefinition?
    func runHolidayPictureSearch(
        tagValue: String
    ) -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)?
    func fetchUnanalyzedPhotoIdsMatchingDateSearch(
        dateSearch: DateSearchDefinition,
        floatingHoliday: FloatingHolidayDefinition?,
        catalogHoliday: HolidayDefinition?
    ) -> PhotoVisionTagMonthDaySelection
    func prepareHolidayVisionTagsIfNeeded(
        definition: PictureSearchDefinition,
        visionDateSearch: DateSearchDefinition?,
        catalogHoliday: HolidayDefinition?,
        progress: (@Sendable (Int, Int) -> Void)?
    ) async -> PhotoVisionTagScanReport?
    func runHolidayPhotosPipeline(
        tagValue: String,
        status: (@Sendable (String) -> Void)?
    ) async -> HolidayPhotosPipelineResult?
    func runHolidayEventsPipeline(
        tagValue: String,
        status: (@Sendable (String) -> Void)?
    ) async -> HolidayEventsPipelineResult?
    func ensureMilestonePictureSearch(topicId: String) -> PictureSearchDefinition?
    func runMilestonePictureSearch(
        topicId: String
    ) -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)?
    func runMilestonePhotosPipeline(
        topicId: String,
        status: (@Sendable (String) -> Void)?
    ) async -> HolidayPhotosPipelineResult?
    func runMilestoneEventsPipeline(
        topicId: String,
        status: (@Sendable (String) -> Void)?
    ) async -> HolidayEventsPipelineResult?
    func ensureOutingPictureSearch(topicId: String) -> PictureSearchDefinition?
    func runOutingPictureSearch(
        topicId: String
    ) -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)?
    func runOutingPhotosPipeline(
        topicId: String,
        status: (@Sendable (String) -> Void)?
    ) async -> HolidayPhotosPipelineResult?
    func runOutingEventsPipeline(
        topicId: String,
        status: (@Sendable (String) -> Void)?
    ) async -> HolidayEventsPipelineResult?
    func ensurePersonBirthdayPictureSearch(
        person: PeopleRepository.PersonBirthdayRecord
    ) -> PictureSearchDefinition?
    func runPersonBirthdayPictureSearch(
        person: PeopleRepository.PersonBirthdayRecord
    ) -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)?
    func fetchPersonBirthdayRecord(personId: Int) -> PeopleRepository.PersonBirthdayRecord?
    func runPersonBirthdayPhotosPipeline(
        personId: Int,
        status: (@Sendable (String) -> Void)?
    ) async -> HolidayPhotosPipelineResult?
    func runPersonBirthdayEventsPipeline(
        personId: Int,
        status: (@Sendable (String) -> Void)?
    ) async -> HolidayEventsPipelineResult?
    func ensureEventScoreCardSettings(
        for definition: PictureSearchDefinition,
        personNamesById: [Int: String]
    ) -> PictureSearchEventScoreCardSettings
    func ensureEventScoreCardSettings(
        tagCategory: String,
        tagValue: String,
        personNamesById: [Int: String]
    ) -> PictureSearchEventScoreCardSettings
    func fetchEventScoreCardSettings(
        tagCategory: String,
        tagValue: String
    ) -> PictureSearchEventScoreCardSettings?
    func fetchAllEventScoreCardSettings() -> [PictureSearchEventScoreCardSettings]
    @discardableResult
    func saveEventScoreCardSettings(
        _ settings: PictureSearchEventScoreCardSettings
    ) -> PictureSearchEventScoreCardSettings
    func checkPictureSearchEventTypes(
        runReport: PictureSearchRunReport,
        definition: PictureSearchDefinition,
        scoreCard: PictureSearchEventScoreCardSettings,
        progress: (@Sendable (Int, Int) -> Void)?
    ) -> PictureSearchEventTypeCheckReport
    /// Scores one event against a scorecard using all event photos (not a Picture Search run).
    @discardableResult
    func scoreEventAgainstScoreCard(
        eventId: Int,
        scoreCard: PictureSearchEventScoreCardSettings
    ) -> PictureSearchEventTypeScore
    /// AI Assist / Wedding: couple photo + bride/groom resolve; writes mainPerson tags when named.
    @discardableResult
    func resolveAndApplyWeddingCouple(eventId: Int) -> WeddingCoupleResolution
    func weddingCouplePhotoId(eventId: Int) -> String?
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

    func getAllPersonNames() -> [String]
    func fetchAllPeople() -> [PeopleRepository.PersonRecord]
    func fetchPeopleWithBirthDates() -> [PeopleRepository.PersonBirthdayRecord]
    func fetchPeopleLandingItems() -> [PeopleRepository.PeopleLandingItem]
    func fetchPersonDetail(personId: Int) -> PeopleRepository.PeopleLandingItem?
    @discardableResult
    func setPersonBirthDate(personId: Int, birthDateISO: String) -> PictureSearchDefinition?
    @discardableResult
    func ensurePersonBirthdaySearchAndScoreCard(personId: Int) -> PictureSearchDefinition?
    func updatePersonProfile(
        personId: Int,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    )
    @discardableResult
    func setPersonProfilePicture(personId: Int, photoId: String) -> Bool
    func fetchRelationships(involvingPersonId personId: Int) -> [PeopleRelationship]
    @discardableResult
    func upsertParentChildRelationship(
        parentPersonId: Int,
        childPersonId: Int,
        parentRole: PeopleRelationshipRole
    ) -> PeopleRelationship?
    @discardableResult
    func upsertSiblingRelationship(personIdA: Int, personIdB: Int) -> PeopleRelationship?
    @discardableResult
    func upsertRomanticRelationship(
        personIdA: Int,
        personIdB: Int,
        relationshipType: PeopleRelationshipType,
        roleA: PeopleRelationshipRole,
        roleB: PeopleRelationshipRole
    ) -> PeopleRelationship?
    func deletePeopleRelationship(relationshipId: Int)
    func fetchEventPeople(eventId: Int, includeChildEvents: Bool) -> [EventRepository.EventPersonRecord]

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
    /// Best on-frame video asset id per list event (for muted inline cover playback).
    func getOnFrameVideoIds(for events: [IndexedEvent]) -> [Int: String]
    func getEventsForLocation(locationId: Int) -> [IndexedEvent]
    func getTripSections(for parentEventId: Int, includeHidden: Bool) -> [TripEventSection]
    func getPhotosForEvent(eventId: Int, includeHidden: Bool) -> [IndexedPhoto]
    /// indexedAt, camera make/model, locationId (+ resolved location labels) for event-detail sort.
    func fetchEventPhotoSortMetadata(photoIds: [String]) -> (
        metadata: [String: EventPhotoSortMetadata],
        locationLabels: [Int: String]
    )
    func setEventShowOnFrame(eventId: Int, show: Bool)
    func setEventFavorite(eventId: Int, isFavorite: Bool)
    func listEventIdsWithOnFramePhotos(among eventIds: [Int]) -> Set<Int>
    func setEventUserHidden(eventId: Int, hidden: Bool)
    @discardableResult
    func updateEventName(eventId: Int, name: String, userEdited: Bool) -> Bool
    @discardableResult
    func updateChildEventName(eventId: Int, name: String, userEdited: Bool) -> Bool
    func setSimilarGroupPicks(groupPhotoIds: [String], pickedPhotoIds: Set<String>)
    /// Returns photo ids that could not be hidden because they have no event link.
    @discardableResult
    func setPhotosHiddenInEvent(photoIds: [String], hidden: Bool) -> [String]
    func setPhotosShowOnFrame(photoIds: [String], show: Bool)
    func setPhotoShowOnFrame(photoId: String, eventId: Int, show: Bool)
    func fetchPhotosForBrowser(photoIds: [String]) -> [(photo: IndexedPhoto, mediaType: Int)]
    /// Matched ids whose capture date (or import date) falls in `year`.
    func fetchPhotosForBrowser(
        photoIds: [String],
        year: Int,
        useImportDate: Bool
    ) -> [(photo: IndexedPhoto, mediaType: Int, indexedAt: String)]
    func fetchAllPhotosForBrowser() -> [(photo: IndexedPhoto, mediaType: Int, indexedAt: String)]
    func fetchPhotosForBrowserYear(_ year: Int) -> [(photo: IndexedPhoto, mediaType: Int, indexedAt: String)]
    func fetchDistinctPhotoYearsForBrowser() -> [Int]
    func countActivePhotosForBrowser() -> Int
    func setPhotosFavorite(photoIds: [String], isFavorite: Bool)
    /// Soft-delete photos in MagicFrame (`isDeleted = 1`). Caller may also delete Apple Photos assets.
    func softDeletePhotos(photoIds: [String])
    func shiftPhotoCaptureDates(updates: [(photoId: String, newCreationDate: Date)])
    /// After Apple Photos sync succeeds, set library `creationDate` and clear `captureDateOverride`.
    func promoteCaptureDatesAfterPhotosSync(updates: [(photoId: String, newCreationDate: Date)])
    /// Stores MF GPS in `userLatitude`/`userLongitude` (and optional `locationId`). Does not move events.
    func shiftPhotoLocations(
        updates: [(photoId: String, latitude: Double, longitude: Double, locationId: Int?)]
    )
    /// After Apple Photos sync succeeds, set library GPS and clear user overrides.
    func promoteLocationsAfterPhotosSync(
        updates: [(photoId: String, latitude: Double, longitude: Double)]
    )
    func findEventsContainingDateRange(
        rangeStart: Date,
        rangeEnd: Date,
        excludingEventId: Int?
    ) -> [IndexedEvent]
    func createEventForShiftedPhotos(
        photoIds: [String],
        fromEventId: Int?,
        rangeStart: Date,
        rangeEnd: Date,
        locationId: Int?,
        latitude: Double?,
        longitude: Double?
    ) -> IndexedEvent?
    func movePhotosToEvent(
        photoIds: [String],
        fromEventId: Int?,
        toEventId: Int,
        photoDates: [String: Date]
    )
    func movePhotosIntoEveryday(
        photoIds: [String],
        fromEventId: Int?,
        photoDates: [String: Date]
    )
    func movePhotosOntoEvent(
        photoIds: [String],
        fromEventId: Int?,
        toEventId: Int,
        photoDates: [String: Date],
        expandDestinationDates: Bool
    )
    func refreshEventPlacesForPhotos(photoIds: [String])
    func persistPhotoOnFrameChanges(
        defaultEventId: Int,
        writes: [(photoId: String, show: Bool)],
        similarGroupPicks: [(groupPhotoIds: [String], pickedPhotoIds: [String])],
        clearCropFocusPhotoIds: [String]
    )
    func getEventIdForPhoto(photoId: String) -> Int?
    func getEventAttributeOptions(for field: EventAttributeField) -> [String]
    func addCustomEventAttributeOption(_ value: String, for field: EventAttributeField)
    func updateEventAttribute(eventId: Int, field: EventAttributeField, value: String?)
    func replaceUserEventMainPeople(eventId: Int, names: [String])
    func updateWeddingDate(eventId: Int, weddingDate: String?)
    func updateWeddingCoverPhotoForEvent(eventId: Int)
    /// Writes/updates a married relationship (bride/groom + wedding date) in `people_relationships`.
    @discardableResult
    func upsertMarriedCoupleRelationship(
        bridePersonId: Int,
        groomPersonId: Int,
        weddingDateISO: String,
        sourceEventId: Int?
    ) -> PeopleRelationship?
    func propagateAnniversaryTagsFromWedding(
        sourceEventId: Int,
        person1: String,
        person2: String,
        weddingDateISO: String
    ) -> Int
    func runEventObjectRecognitionIfNeeded(
        eventId: Int,
        includeHiddenPhotos: Bool,
        progress: (@Sendable (EventObjectRecognitionProgress) -> Void)?
    ) async -> EventObjectRecognitionResult
    func enqueueFaceRecognitionForPhotoIds(_ photoIds: [String]) -> VisionJobEnqueueSummary
    func enqueueFaceRecognitionForEvent(
        eventId: Int,
        includeHidden: Bool
    ) -> VisionJobEnqueueSummary
    func fetchFaceAnnotations(
        forPhotoId photoId: String,
        suggestionEventId: Int?
    ) -> [PhotoFaceAnnotation]
    func ensurePhotoFaceScanned(
        photoId: String,
        suggestionEventId: Int?,
        upgradeToPreviewScan: Bool
    ) async -> [PhotoFaceAnnotation]
    func nameFaceInstance(
        faceInstanceId: Int,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    ) -> Int
    /// Copy a newly named face onto matching faces in sibling similar-stack photos.
    @discardableResult
    func propagateNamedFaceToSimilarPhotos(
        sourceFaceInstanceId: Int,
        siblingPhotoIds: [String]
    ) async -> Int
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
    func holidayVisionLandingConfig(tagValue: String) -> HolidayVisionLandingConfig?
    func fetchAllHolidayVisionLandingConfigs() -> [HolidayVisionLandingConfig]
    func confirmAIAttributeTag(eventId: Int, field: EventAttributeField)
    func rejectAIAttributeTag(eventId: Int, field: EventAttributeField)
    func removeEventAttributeTag(eventId: Int, tag: EventAttributeTag)
    /// Hard-delete user + AI + rejected rows for one category/value (testing).
    @discardableResult
    func purgeEventAttributeTag(eventId: Int, category: String, tagValue: String) -> Int
    @discardableResult
    func purgeRejectedAttributeTags(eventId: Int) -> Int
    func fetchAllAttributeTagRowsForEvent(eventId: Int) -> [(
        category: String,
        tagValue: String,
        source: String,
        isRejected: Bool
    )]
    func confirmAIHolidayTag(eventId: Int)
    func rejectAIHolidayTag(eventId: Int)
    func fetchSimilarEventAlternatives(
        tagCategory: String,
        tagValue: String
    ) -> [SimilarEventTagAlternative]
    func applySimilarEventUserTag(
        eventId: Int,
        tagCategory: String,
        tagValue: String
    )
    func fetchEventNameTemplate(
        tagCategory: String,
        tagValue: String
    ) -> EventNameTemplate?
    func fetchAllEventNameTemplates() -> [EventNameTemplate]
    func upsertEventNameTemplate(
        tagCategory: String,
        tagValue: String,
        nameTemplate: String,
        personCount: Int
    ) -> EventNameTemplate?
    func fetchAllSimilarEventTags() -> [SimilarEventTagAlternative]
    @discardableResult
    func insertSimilarEventTag(
        tagCategory: String,
        tagValue: String,
        possibleTagCategory: String,
        possibleTagValue: String,
        possibleNumberOfEventMainPeople: Int
    ) -> SimilarEventTagAlternative?

    // MARK: - Holidays landing

    func fetchHolidayLandingCatalogItems() -> [HolidayLandingItem]

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
    func relinkEventLocationsFromPhotos()
    func updateAllEventCoverPhotos()
    func restoreDeletedTripContainersOnQueue()

    // MARK: - Stadiums / game scores

    func fetchAllStadiums() -> [Stadium]
    func fetchStadium(stadiumId: Int) -> Stadium?
    @discardableResult
    func upsertStadium(
        stadiumId: Int?,
        name: String,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?
    ) -> Int?
    func deleteStadium(stadiumId: Int)
    func addStadiumAlias(stadiumId: Int, alias: String)
    func deleteStadiumAlias(stadiumId: Int, alias: String)
    @discardableResult
    func upsertStadiumTeam(
        stadiumTeamId: Int?,
        stadiumId: Int,
        league: SportsLeague,
        teamName: String,
        displayName: String?,
        teamAbbreviation: String?,
        isPrimaryHome: Bool
    ) -> Int?
    func deleteStadiumTeam(stadiumTeamId: Int)
    func fetchEventGameResult(eventId: Int) -> EventGameResult?
    func fetchEventGameResults(eventIds: [Int]) -> [Int: EventGameResult]
    func saveEventGameResult(_ result: EventGameResult)
    func clearEventGameResult(eventId: Int)
    func lookupSportsGameCandidates(
        eventDateISO: String,
        placeName: String?,
        city: String?,
        state: String?,
        latitude: Double?,
        longitude: Double?
    ) async throws -> (stadiums: [Stadium], candidates: [SportsGameCandidate])

    // MARK: - Locations

    func countLocations() -> Int
    func getLocationsRankedByEventCount() -> [ManagedLocation]
    func getLocation(locationId: Int) -> ManagedLocation?
    func getLocationTypeOptions() -> [String]
    func locationsNeedingGeocodeCount() -> Int
    func startGeocodingEventLocations(limit: Int?)
    /// Ensures the event has a location row and reverse-geocodes it when incomplete.
    /// Also assign-only snaps member photos to `photos.locationId` (no per-photo Apple geocode).
    /// Returns `true` when location fields were newly filled (caller should refresh the event).
    func ensureEventLocationGeocoded(eventId: Int) async -> Bool
    /// Preview header Line 1: nickname → place → city/state → GPS → "NO GPS data".
    /// Assigns `photos.locationId` locally when GPS exists and id is missing.
    func photoPreviewLocationLine(photoId: String) -> String
    /// Full photo info payload for the full-screen Info sheet.
    func fetchPhotoInfoDetail(photoId: String) -> PhotoInfoDetail?
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

extension MagicFrameDatabase {
    func fetchFaceAnnotations(forPhotoId photoId: String) -> [PhotoFaceAnnotation] {
        fetchFaceAnnotations(forPhotoId: photoId, suggestionEventId: nil)
    }

    func ensurePhotoFaceScanned(photoId: String) async -> [PhotoFaceAnnotation] {
        await ensurePhotoFaceScanned(
            photoId: photoId,
            suggestionEventId: nil,
            upgradeToPreviewScan: false
        )
    }
}

extension PhotoDatabase: MagicFrameDatabase {}
