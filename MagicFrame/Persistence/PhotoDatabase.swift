//
//  PhotoDatabase.swift
//  MagicFrame
//

import Foundation
import CoreLocation
import MapKit

final class PhotoDatabase: @unchecked Sendable {

    static let defaultLocationTypes = ["Stadium", "Beach", "Lake"]
    private static let customLocationTypesKey = "customLocationTypes"
    static let faceMetricsAlgorithmVersionKey = PhotoRepository.faceMetricsAlgorithmVersionKey
    static let cropAlgorithmVersionKey = PhotoRepository.cropAlgorithmVersionKey

    private var eventTuningCache: EventTuningSettings?

    private let container: AppContainer

    static var shared: PhotoDatabase { AppContainer.shared.photoDatabase }

    private var databaseManager: DatabaseManager { container.databaseManager }
    private var appMetadata: AppMetadataStore { container.metadata }
    private var photoRepository: PhotoRepository { container.photos }
    private var peopleRepository: PeopleRepository { container.people }
    private var peopleImportService: PeopleImportService { container.peopleImport }
    private var eventRepository: EventRepository { container.events }
    private var occasionRepository: OccasionRepository { container.occasions }
    private var locationRepository: LocationRepository { container.locations }
    private var geocodePendingQueue: LocationGeocodePendingQueue { container.geocodePendingQueue }
    private var eventLocationCoordinator: EventLocationCoordinator { container.eventLocations }
    private var eventClustering: EventClusteringService { container.eventClustering }

    private var dbQueue: DispatchQueue { databaseManager.queue }

    private var dbQueueKey: DispatchSpecificKey<UInt8> { databaseManager.queueKey }

    init(container: AppContainer) {
        self.container = container
    }

    func getEventTuningSettings() -> EventTuningSettings {
        dbQueue.sync {
            eventTuningUnsafe()
        }
    }

    func saveEventTuningSettings(_ settings: EventTuningSettings) {
        dbQueue.sync {
            if let data = try? JSONEncoder().encode(settings),
               let json = String(data: data, encoding: .utf8) {
                appMetadata.set(key: EventTuningSettings.storageKey, value: json)
            }
            eventTuningCache = settings
        }
    }

    func resetEventTuningSettings() {
        dbQueue.sync {
            appMetadata.delete(key: EventTuningSettings.storageKey)
            eventTuningCache = nil
        }
    }

    func eventTuningUnsafe() -> EventTuningSettings {
        if let eventTuningCache {
            return eventTuningCache
        }

        if let json = appMetadata.get(key: EventTuningSettings.storageKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(EventTuningSettings.self, from: data) {
            eventTuningCache = decoded
            return decoded
        }

        return .defaults
    }

    func flushPendingGeocodeEnqueues() {
        geocodePendingQueue.flush()
    }

    func resetDatabaseForDevelopmentOnly() {
        databaseManager.resetDevelopmentTables(legacyHooks: LegacyDataMigrationHooks(
            migrateLegacyTripEventType: eventRepository.migrateLegacyTripEventTypeAttribute,
            migrateLegacyHomeLocations: locationRepository.migrateLegacyHomeLocations,
            migrateTripSubEventChildNames: eventRepository.migrateTripSubEventChildNamesIfNeeded,
            repairStaleGeocodeStatuses: locationRepository.repairStaleGeocodeStatuses
        ))
    }

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
    ) {
        photoRepository.upsertPhoto(
            id: id,
            creationDate: creationDate,
            modificationDate: modificationDate,
            mediaType: mediaType,
            mediaSubtype: mediaSubtype,
            width: width,
            height: height,
            isFavorite: isFavorite,
            isHidden: isHidden,
            latitude: latitude,
            longitude: longitude,
            isScreenshot: isScreenshot,
            aspectRatio: aspectRatio,
            orientation: orientation,
            qualityScore: qualityScore
        )
    }

    func markPhotosDeletedIfMissing(currentIds: Set<String>) {
        photoRepository.markPhotosDeletedIfMissing(currentIds: currentIds)
    }

    
    func christmasObjectKeysForVisionDebug() -> [String] {
        dbQueue.sync {
            guard let occasionId = occasionRepository.fetchOccasionIdForKeyUnsafe(occasionKey: "christmas") else {
                return []
            }
            return occasionRepository.fetchObjectScoringRulesUnsafe(occasionId: occasionId)
                .map(\.objectKey)
        }
    }

    func getRecentPhotos(limit: Int = 100) -> [IndexedPhoto] {
        photoRepository.getRecentPhotos(limit: limit)
    }

    func upsertPerson(name: String) -> Int {
        peopleRepository.upsertPerson(name: name)
    }

    func linkPhotoToPerson(photoId: String, personId: Int, source: String) {
        peopleRepository.linkPhotoToPerson(photoId: photoId, personId: personId, source: source)
    }

    func getAllPersonNames() -> [String] {
        peopleRepository.getAllPersonNames()
    }

    // MARK: - Location repository forwards

    func countPendingGeocodeLocations() -> Int {
        locationRepository.countPendingGeocodeLocations()
    }

    func fetchPendingGeocodeLocations(limit: Int? = nil) -> [PendingLocation] {
        locationRepository.fetchPendingGeocodeLocations(limit: limit)
    }

    func fetchEventLocationsNeedingGeocode(limit: Int? = nil) -> [PendingLocation] {
        locationRepository.fetchEventLocationsNeedingGeocode(limit: limit)
    }

    func tryCopyNearbyGeocode(locationId: Int, latitude: Double, longitude: Double) -> Bool {
        locationRepository.tryCopyNearbyGeocode(locationId: locationId, latitude: latitude, longitude: longitude)
    }

    func startGeocodingAllPending() {
        locationRepository.startGeocodingAllPending()
    }

    func resumeGeocodingIfNeeded() {
        repairHomeLocations()
        restoreDeletedTripContainersOnQueue()
        LocationGeocodeCoordinator.shared.resumeIfNeeded()
    }

    func stopGeocoding() {
        LocationGeocodeCoordinator.shared.stopAll()
    }

    func repairHomeLocations() {
        dbQueue.sync {
            locationRepository.mergeNearbyLocationsIntoCurrentHome()
            eventLocationCoordinator.snapEventsNearDesignatedHomesUnsafe()
            locationRepository.backfillCurrentHomeAddressIfNeeded()
        }
        flushPendingGeocodeEnqueues()
    }

    func restoreDeletedTripContainersOnQueue() {
        dbQueue.sync {
            eventRepository.restoreDeletedTripContainers()
        }
    }

    func startGeocodingEventLocations(limit: Int? = nil) {
        locationRepository.startGeocodingEventLocations(limit: limit)
    }

    func completeLocationGeocode(
        locationId: Int,
        city: String?,
        state: String?,
        placeName: String?
    ) {
        dbQueue.sync {
            locationRepository.completeLocationGeocode(
                locationId: locationId,
                city: city,
                state: state,
                placeName: placeName
            )
        }
    }

    func markLocationGeocodeFailed(locationId: Int) {
        locationRepository.markLocationGeocodeFailed(locationId: locationId)
    }

    func resetLocationGeocodeToPending(locationId: Int) {
        locationRepository.resetLocationGeocodeToPending(locationId: locationId)
    }

    func debugLocationCounts() {
        locationRepository.debugLocationCounts()
    }

    func rebuildLocationsForExistingEventsOnce() {
        locationRepository.rebuildLocationsForExistingEventsOnce()
    }

    func getLocationTypeOptions() -> [String] {
        locationRepository.getLocationTypeOptions()
    }

    func addCustomLocationType(_ type: String) {
        locationRepository.addCustomLocationType(type)
    }

    func geocodeLocationsUsedByEvents(limit: Int = 25) {
        startGeocodingEventLocations(limit: limit)
    }

    func getLocationsRankedByEventCount() -> [ManagedLocation] {
        locationRepository.getLocationsRankedByEventCount()
    }

    func getLocation(locationId: Int) -> ManagedLocation? {
        locationRepository.getLocation(locationId: locationId)
    }

    func locationsNeedingGeocodeCount() -> Int {
        locationRepository.locationsNeedingGeocodeCount()
    }

    func updateLocationNickname(locationId: Int, nickname: String?) {
        locationRepository.updateLocationNickname(locationId: locationId, nickname: nickname)
    }

    func updateLocationType(locationId: Int, locationType: String?) {
        locationRepository.updateLocationType(locationId: locationId, locationType: locationType)
    }

    func setLocationFavorite(locationId: Int, isFavorite: Bool) {
        locationRepository.setLocationFavorite(locationId: locationId, isFavorite: isFavorite)
    }

    func getCurrentHomeLocation() -> ManagedLocation? {
        locationRepository.getCurrentHomeLocation()
    }

    func hasCurrentHome() -> Bool {
        locationRepository.hasCurrentHome()
    }

    func createDesignatedCurrentHome(
        latitude: Double,
        longitude: Double,
        nickname: String?,
        homeStartDate: Date?
    ) -> Int {
        let locationId = locationRepository.createDesignatedCurrentHome(
            latitude: latitude,
            longitude: longitude,
            nickname: nickname,
            homeStartDate: homeStartDate
        )
        guard locationId > 0 else { return locationId }
        geocodePendingQueue.requestFreshGeocode(
            locationId: locationId,
            latitude: latitude,
            longitude: longitude
        )
        flushPendingGeocodeEnqueues()
        return locationId
    }

    func updateLocationHomeDesignation(
        locationId: Int,
        role: LocationHomeRole,
        homeStartDate: Date?,
        homeEndDate: Date?
    ) {
        locationRepository.updateLocationHomeDesignation(
            locationId: locationId,
            role: role,
            homeStartDate: homeStartDate,
            homeEndDate: homeEndDate
        )
    }

    func deduplicateLocationsByAddress(maxDistanceMiles: Double? = nil) -> Int {
        locationRepository.deduplicateLocationsByAddress(maxDistanceMiles: maxDistanceMiles)
    }

    func deduplicateLocationsByAddressUnsafe(maxDistanceMiles: Double) -> Int {
        locationRepository.deduplicateLocationsByAddressUnsafe(maxDistanceMiles: maxDistanceMiles)
    }

    @discardableResult
    func mergeDuplicateLocations(
        proximityMiles: Double? = nil,
        samePlaceNameMiles: Double? = nil,
        frequentPlaceMiles: Double? = nil,
        frequentPlaceMinEvents: Int? = nil
    ) -> Int {
        locationRepository.mergeDuplicateLocations(
            proximityMiles: proximityMiles,
            samePlaceNameMiles: samePlaceNameMiles,
            frequentPlaceMiles: frequentPlaceMiles,
            frequentPlaceMinEvents: frequentPlaceMinEvents
        )
    }

    func mergeNearbyLocationsIntoCurrentHome() {
        locationRepository.mergeNearbyLocationsIntoCurrentHome()
    }

    func findOrCreateLocation(
        latitude: Double,
        longitude: Double,
        at date: Date = Date()
    ) -> Int {
        locationRepository.findOrCreateLocation(latitude: latitude, longitude: longitude, at: date)
    }

    func updateLocationGeocode(
        locationId: Int,
        city: String?,
        state: String?,
        placeName: String?,
        status: String = "complete"
    ) {
        locationRepository.updateLocationGeocode(
            locationId: locationId,
            city: city,
            state: state,
            placeName: placeName,
            status: status
        )
    }

    func distanceInMiles(
        lat1: Double,
        lon1: Double,
        lat2: Double,
        lon2: Double
    ) -> Double {
        locationRepository.distanceInMiles(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
    }

    static func geocodedCity(from mapItem: MKMapItem) -> String? {
        ReverseGeocodeParser.geocodedCity(from: mapItem)
    }

    static func geocodedCityWithContext(from mapItem: MKMapItem) -> String? {
        ReverseGeocodeParser.geocodedCityWithContext(from: mapItem)
    }

    static func administrativeArea(from mapItem: MKMapItem) -> String? {
        ReverseGeocodeParser.administrativeArea(from: mapItem)
    }

    static func coordinate(from mapItem: MKMapItem) -> CLLocationCoordinate2D? {
        ReverseGeocodeParser.coordinate(from: mapItem)
    }

    static func placeLabel(from mapItem: MKMapItem) -> String? {
        ReverseGeocodeParser.placeLabel(from: mapItem)
    }

    static func geocodedFormattedAddress(from mapItem: MKMapItem) -> String {
        ReverseGeocodeParser.geocodedFormattedAddress(from: mapItem)
    }

    func runPostIndexMetadataEnrichment() {
        container.metadataEnrichment.runPostIndexPhase()
    }

    func runPostIndexMetadataEnrichmentIfNeeded() {
        guard container.albums.countAlbums() == 0,
              photoRepository.countActivePhotos() > 0 else {
            return
        }
        runPostIndexMetadataEnrichment()
    }

    func metadataEnrichmentCounts() -> MetadataEnrichmentCounts {
        DevDatabaseTools.metadataEnrichmentCounts(database: databaseManager)
    }

    func eventDateDiagnosticCounts() -> EventDateDiagnosticCounts {
        dbQueue.sync {
            eventRepository.eventDateDiagnosticCounts()
        }
    }

    @discardableResult
    func repairEventDateSummaries() -> EventDateRepairResult {
        dbQueue.sync {
            eventRepository.repairEventDateSummaries()
        }
    }

    func importPeopleFromAlbums() {
        peopleImportService.importPeopleFromAlbums()
    }

    // MARK: - Event clustering forwards

    func clusterEventsByTime() {
        eventClustering.clusterEventsByTime()
        dbQueue.sync { rebuildOccasionLandingMetricsUnsafe() }
    }

    func syncEventsIncrementally() {
        eventClustering.syncEventsIncrementally()
        dbQueue.sync { rebuildOccasionLandingMetricsUnsafe() }
    }

    @discardableResult
    func syncEventsAssignmentBatch() -> Bool {
        let hasMore = eventClustering.syncEventsAssignmentBatch()
        if !hasMore {
            dbQueue.sync { rebuildOccasionLandingMetricsUnsafe() }
        }
        return hasMore
    }

    func countUnassignedPhotosForEvents() -> Int {
        eventClustering.countUnassignedPhotosForEvents()
    }

    func countUnassignedMetadataPhotosForEvents() -> Int {
        dbQueue.sync {
            eventRepository.countUnassignedMetadataPhotosForEvents()
        }
    }

    func metadataAssignmentCounts() -> MetadataAssignmentCounts {
        dbQueue.sync {
            MetadataAssignmentCounts(
                unassignedNoGPS: eventRepository.countUnassignedMetadataPhotosForEvents(),
                attachedViaMetadata: eventRepository.countMetadataAttachedPhotos(),
                attachedNeedingReview: eventRepository.countMetadataAttachedPhotosNeedingReview()
            )
        }
    }

    @discardableResult
    func syncMetadataAssignmentBatch() -> Bool {
        dbQueue.sync {
            container.photoEventAssignment.syncMetadataAssignmentBatch()
        }
    }

    /// Metadata attach, then time-only clustering for remaining no-GPS photos (used by Sync Events).
    func syncMetadataAssignmentUntilComplete() {
        eventClustering.syncSecondaryPhotoAssignmentPasses()
        dbQueue.sync { rebuildOccasionLandingMetricsUnsafe() }
    }

    func rebuildAllEvents() {
        eventClustering.rebuildAllEvents()
        dbQueue.sync { rebuildOccasionLandingMetricsUnsafe() }
    }

    @discardableResult
    func prepareEventRebuild() -> Int {
        eventClustering.prepareEventRebuild()
    }

    func finishEventRebuild() {
        eventClustering.finishEventRebuild()
        dbQueue.sync { rebuildOccasionLandingMetricsUnsafe() }
    }

    func finishEventSyncMaintenance() {
        eventClustering.finishEventSyncMaintenance()
        dbQueue.sync { rebuildOccasionLandingMetricsUnsafe() }
    }

    func clearAllEventDataPreservingLocations() {
        eventClustering.clearAllEventDataPreservingLocations()
        dbQueue.sync { rebuildOccasionLandingMetricsUnsafe() }
    }
    func debugSchema() {
        DevDatabaseTools.debugSchema(database: databaseManager)
    }

    func countPhotosMissingLocation() -> Int {
        photoRepository.countPhotosMissingLocation()
    }

    func countActivePhotos() -> Int {
        photoRepository.countActivePhotos()
    }

    func getLikelyUploadBatches(
        gapSeconds: TimeInterval = 6 * 60 * 60,
        minPhotos: Int = 1
    ) -> [PhotoUploadBatch] {
        photoRepository.getLikelyUploadBatches(
            gapSeconds: gapSeconds,
            minPhotos: minPhotos,
            locationMatchMiles: eventTuningUnsafe().locationMatchMiles
        )
    }

    func applyArchiveBatchMetadata(
        photoIds: [String],
        captureDate: Date,
        latitude: Double,
        longitude: Double
    ) {
        photoRepository.applyArchiveBatchMetadata(
            photoIds: photoIds,
            captureDate: captureDate,
            latitude: latitude,
            longitude: longitude
        )
    }

    func updateFaceMetrics(
        photoId: String,
        eyesOpenScore: Double,
        smileScore: Double
    ) {
        photoRepository.updateFaceMetrics(
            photoId: photoId,
            eyesOpenScore: eyesOpenScore,
            smileScore: smileScore
        )
    }

    func faceMetricsAlgorithmVersion() -> Int {
        photoRepository.faceMetricsAlgorithmVersion()
    }

    func setFaceMetricsAlgorithmVersion(_ version: Int) {
        photoRepository.setFaceMetricsAlgorithmVersion(version)
    }

    func clearFaceMetrics(forPhotoIds photoIds: [String]) {
        photoRepository.clearFaceMetrics(forPhotoIds: photoIds)
    }

    func getPhotoCropData(photoId: String) -> PhotoCropFocusRecord? {
        photoRepository.getPhotoCropData(photoId: photoId)
    }

    func updateCropFocuses(
        photoId: String,
        list: PhotoCropFocus?,
        frame: PhotoCropFocus?
    ) {
        photoRepository.updateCropFocuses(photoId: photoId, list: list, frame: frame)
    }

    func cropAlgorithmVersion() -> Int {
        photoRepository.cropAlgorithmVersion()
    }

    func setCropAlgorithmVersion(_ version: Int) {
        photoRepository.setCropAlgorithmVersion(version)
    }

    func ensureCropAlgorithmVersionCurrent() {
        dbQueue.sync {
            guard photoRepository.cropAlgorithmVersion() < PhotoFaceCropAnalyzer.algorithmVersion else {
                return
            }
            photoRepository.clearAllCropFocuses()
            photoRepository.setCropAlgorithmVersion(PhotoFaceCropAnalyzer.algorithmVersion)
        }
    }

    func clearAllCropFocuses() {
        photoRepository.clearAllCropFocuses()
    }

    func clearCropFocus(photoId: String) {
        photoRepository.clearCropFocus(photoId: photoId)
    }


    // MARK: - Event repository forwards

    func updateCoverPhotoForEvent(eventId: Int) {
        eventRepository.updateCoverPhotoForEvent(eventId: eventId)
    }

    func updateAllEventCoverPhotos() {
        eventRepository.updateAllEventCoverPhotos()
    }

    func backfillEventAssignedAt() {
        eventRepository.backfillEventAssignedAt()
    }

    func rebuildEventPeople() {
        eventRepository.rebuildEventPeople()
        dbQueue.sync { rebuildOccasionLandingMetricsUnsafe() }
    }

    func rescoreHolidayTagsForSyncedEventsUnsafe(eventIds: Set<Int>, scoreAllEvents: Bool) {
        container.occasionScoring.rescoreHolidayEventsAfterEventSyncUnsafe(
            eventIds: eventIds,
            scoreAllEvents: scoreAllEvents
        )
        rebuildOccasionLandingMetricsUnsafe()
    }

    func setEventShowOnFrame(eventId: Int, show: Bool) {
        eventRepository.setEventShowOnFrame(eventId: eventId, show: show)
        dbQueue.sync { reconcileOccasionCollectionCountsUnsafe(forEventId: eventId) }
    }

    func setEventUserHidden(eventId: Int, hidden: Bool) {
        eventRepository.setEventUserHidden(eventId: eventId, hidden: hidden)
        dbQueue.sync { reconcileOccasionCollectionCountsUnsafe(forEventId: eventId) }
    }

    func getEventAttributeOptions(for field: EventAttributeField) -> [String] {
        eventRepository.getEventAttributeOptions(for: field)
    }

    func addCustomEventAttributeOption(_ value: String, for field: EventAttributeField) {
        eventRepository.addCustomEventAttributeOption(value, for: field)
    }

    func updateEventAttribute(eventId: Int, field: EventAttributeField, value: String?) {
        eventRepository.updateEventAttribute(eventId: eventId, field: field, value: value)
        eventTags.syncUserAttributeTag(eventId: eventId, field: field, tagValue: value)
        dbQueue.sync { reconcileOccasionCollectionCountsUnsafe(forEventId: eventId) }
    }

    func updateWeddingDate(eventId: Int, weddingDate: String?) {
        eventRepository.updateWeddingDate(eventId: eventId, weddingDate: weddingDate)
    }

    func propagateAnniversaryTagsFromWedding(
        sourceEventId: Int,
        person1: String,
        person2: String,
        weddingDateISO: String
    ) -> Int {
        dbQueue.sync {
            AnniversaryTagPropagationService(
                events: eventRepository,
                eventTags: eventTags
            )
            .propagateUnsafe(
                sourceEventId: sourceEventId,
                person1: person1,
                person2: person2,
                weddingDateISO: weddingDateISO
            )
        }
    }

    func fetchAITagScoringDetail(
        eventId: Int,
        field: EventAttributeField,
        includesDescendantPhotos: Bool
    ) -> AITagScoringDetail? {
        dbQueue.sync {
            aiTagScoringDetailServiceUnsafe()
                .buildDetailUnsafe(
                    eventId: eventId,
                    field: field,
                    includesDescendantPhotos: includesDescendantPhotos
                )
        }
    }

    func fetchHolidayScorecards(
        eventId: Int,
        includesDescendantPhotos: Bool
    ) -> [AITagScoringDetail] {
        dbQueue.sync {
            aiTagScoringDetailServiceUnsafe()
                .buildHolidayScorecardsForEventUnsafe(
                    eventId: eventId,
                    includesDescendantPhotos: includesDescendantPhotos
                )
        }
    }

    private func aiTagScoringDetailServiceUnsafe() -> AITagScoringDetailService {
        AITagScoringDetailService(
            events: eventRepository,
            occasions: occasionRepository,
            eventTags: eventTags,
            tuning: { [weak self] in
                self?.eventTuningUnsafe() ?? .defaults
            }
        )
    }

    func updateOccasionDateScoringSettings(
        occasionId: Int,
        edit: OccasionDateScoringEdit
    ) {
        occasionRepository.updateOccasionDateScoringSettings(
            occasionId: occasionId,
            edit: edit
        )
    }

    func fetchObjectScoringRules(occasionId: Int) -> [EditableObjectScoringRule] {
        occasionRepository.fetchObjectScoringRules(occasionId: occasionId)
    }

    @discardableResult
    func saveObjectScoringRules(
        occasionId: Int,
        rules: [EditableObjectScoringRule]
    ) -> Int {
        dbQueue.sync {
            occasionRepository.saveObjectScoringRulesUnsafe(
                occasionId: occasionId,
                rules: rules
            )
            return invalidateObjectRecognitionForOccasionCandidatesUnsafe(
                occasionId: occasionId
            )
        }
    }

    /// Clears object-scan completion for holiday candidate events so Vision re-runs with updated object keys.
    private func invalidateObjectRecognitionForOccasionCandidatesUnsafe(
        occasionId: Int
    ) -> Int {
        guard let occasion = occasionRepository.fetchOccasionByIdUnsafe(occasionId: occasionId),
              occasion.scoring.occasionType == "holiday",
              ObjectDetectionCategory(occasionKey: occasion.scoring.occasionKey) != nil else {
            return 0
        }

        let threshold = eventTuningUnsafe().holidayTagPreObjectMinTotalScore
        let eventIds = occasionRepository.fetchEventIdsQualifyingForOccasionUnsafe(
            occasionId: occasionId,
            minimumTotalScore: threshold
        )
        guard !eventIds.isEmpty else { return 0 }

        eventTags.clearObjectRecognitionForEventsUnsafe(eventIds: eventIds)
        container.objectTags.clearPhotoVisionScansForEventsUnsafe(eventIds: eventIds)

        for eventId in eventIds {
            container.occasionScoring.scoreHolidayEventOnDatabaseQueueUnsafe(eventId: eventId)
        }

        return eventIds.count
    }

    func scoreHolidayEvent(eventId: Int) {
        container.occasionScoring.scoreHolidayEvent(eventId: eventId)
        dbQueue.sync { reconcileOccasionCollectionCountsUnsafe(forEventId: eventId) }
    }

    func runEventObjectRecognitionIfNeeded(
        eventId: Int,
        includeHiddenPhotos: Bool,
        progress: (@Sendable (EventObjectRecognitionProgress) -> Void)? = nil
    ) async -> EventObjectRecognitionResult {
        let result = await container.eventObjectRecognition.runIfNeeded(
            eventId: eventId,
            includeHiddenPhotos: includeHiddenPhotos,
            progress: progress
        )
        dbQueue.sync { reconcileOccasionCollectionCountsUnsafe(forEventId: eventId) }
        return result
    }

    func enqueueEventObjectRecognitionJobs(
        eventId: Int,
        includeHiddenPhotos: Bool,
        forceRescan: Bool = false,
        forcedOccasionKey: String? = nil,
        priority: Int = 100,
        scopeKey: String? = nil
    ) -> VisionJobEnqueueSummary {
        let summary = container.visionJobEnqueue.enqueueEventObjectRecognition(
            eventId: eventId,
            includeHiddenPhotos: includeHiddenPhotos,
            forceRescan: forceRescan,
            forcedOccasionKey: forcedOccasionKey,
            priority: priority,
            scopeKey: scopeKey
        )
        Task { @MainActor in
            container.visionJobCoordinator.startIfNeeded()
        }
        return summary
    }

    func enqueueHolidayYearObjectRecognitionJobs(
        config: HolidayVisionLandingConfig,
        year: Int,
        eventIds: [Int],
        includeHiddenPhotos: Bool = false,
        priority: Int = 50
    ) -> VisionJobEnqueueSummary {
        let summary = container.visionJobEnqueue.enqueueHolidayYearObjectRecognition(
            config: config,
            year: year,
            eventIds: eventIds,
            includeHiddenPhotos: includeHiddenPhotos,
            priority: priority
        )
        Task { @MainActor in
            container.visionJobCoordinator.startIfNeeded()
        }
        return summary
    }

    func visionJobPendingCount(scopeKey: String? = nil, eventId: Int? = nil) -> Int {
        dbQueue.sync {
            container.visionJobs.countPendingUnsafe(
                scopeKey: scopeKey,
                eventId: eventId,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )
        }
    }

    private func holidayScanEventLabel(eventId: Int) -> String {
        dbQueue.sync {
            guard let event = eventRepository.getEvent(eventId: eventId) else {
                return "Event \(eventId)"
            }
            let title = event.listTitleText ?? event.name
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let namePart = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
            let datePart = event.displayDateText ?? "—"
            return "\(namePart) · \(datePart)"
        }
    }

    func holidayVisionLandingConfig(tagValue: String) -> HolidayVisionLandingConfig? {
        dbQueue.sync {
            container.occasions.holidayVisionLandingConfigUnsafe(tagValue: tagValue)
        }
    }

    func fetchAllHolidayVisionLandingConfigs() -> [HolidayVisionLandingConfig] {
        dbQueue.sync {
            container.occasions.fetchAllHolidayVisionLandingConfigsUnsafe()
        }
    }

    func holidayYearNeedsVisionScan(
        config: HolidayVisionLandingConfig,
        eventIds: [Int],
        includeHiddenPhotos: Bool
    ) -> Bool {
        dbQueue.sync {
            eventTags.anyAITaggedHolidayEventsNeedObjectRecognitionUnsafe(
                eventIds: eventIds,
                tagValue: config.tagValue,
                includeHidden: includeHiddenPhotos,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )
        }
    }

    /// Scans AI-tagged holiday events in one expanded year section (list events intersected with scan candidates).
    func runHolidayObjectRecognitionForYear(
        config: HolidayVisionLandingConfig,
        year: Int,
        eventIds: [Int],
        eventLabels: [Int: String] = [:],
        includeHiddenPhotos: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> ChristmasLandingVisionScanReport {
        if Task.isCancelled {
            return emptyHolidayVisionScanReport()
        }

        guard !eventIds.isEmpty else {
            return emptyHolidayVisionScanReport()
        }

        let queueWaitStart = CFAbsoluteTimeGetCurrent()
        let yearEventIds = dbQueue.sync {
            eventTags.fetchAITaggedHolidayEventIdsNeedingObjectRecognitionUnsafe(
                eventIds: eventIds,
                tagValue: config.tagValue,
                includeHidden: includeHiddenPhotos,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )
        }
        logHolidayVisionQueueWait(config: config, queueWaitStart: queueWaitStart)

        return await runHolidayObjectRecognitionLoop(
            config: config,
            eventIds: yearEventIds,
            eventLabels: eventLabels,
            scopeLabel: "\(year)",
            includeHiddenPhotos: includeHiddenPhotos,
            progress: progress
        )
    }

    /// Runs incremental Vision scans for AI-tagged Christmas events that have not finished object recognition.
    func runChristmasLandingObjectRecognitionIfNeeded(
        includeHiddenPhotos: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> ChristmasLandingVisionScanReport {
        guard let config = holidayVisionLandingConfig(tagValue: "Christmas") else {
            return emptyHolidayVisionScanReport()
        }
        if Task.isCancelled {
            return emptyHolidayVisionScanReport()
        }

        let queueWaitStart = CFAbsoluteTimeGetCurrent()
        let eventIds = dbQueue.sync {
            eventTags.fetchAITaggedHolidayEventIdsNeedingObjectRecognitionUnsafe(
                tagValue: config.tagValue,
                includeHidden: includeHiddenPhotos,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )
        }
        logHolidayVisionQueueWait(config: config, queueWaitStart: queueWaitStart)

        return await runHolidayObjectRecognitionLoop(
            config: config,
            eventIds: eventIds,
            eventLabels: [:],
            scopeLabel: config.logLabel,
            includeHiddenPhotos: includeHiddenPhotos,
            progress: progress
        )
    }

    func christmasYearNeedsVisionScan(
        eventIds: [Int],
        includeHiddenPhotos: Bool
    ) -> Bool {
        guard let config = holidayVisionLandingConfig(tagValue: "Christmas") else { return false }
        return holidayYearNeedsVisionScan(
            config: config,
            eventIds: eventIds,
            includeHiddenPhotos: includeHiddenPhotos
        )
    }

    func runChristmasObjectRecognitionForYear(
        year: Int,
        eventIds: [Int],
        eventLabels: [Int: String] = [:],
        includeHiddenPhotos: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> ChristmasLandingVisionScanReport {
        guard let config = holidayVisionLandingConfig(tagValue: "Christmas") else {
            return emptyHolidayVisionScanReport()
        }
        return await runHolidayObjectRecognitionForYear(
            config: config,
            year: year,
            eventIds: eventIds,
            eventLabels: eventLabels,
            includeHiddenPhotos: includeHiddenPhotos,
            progress: progress
        )
    }

    private func emptyHolidayVisionScanReport() -> ChristmasLandingVisionScanReport {
        ChristmasLandingVisionScanReport(
            candidateEventCount: 0,
            eventsScanned: 0,
            eventsSkipped: 0,
            photosScanned: 0,
            detectionsWritten: 0,
            earlyExits: 0,
            elapsedSeconds: 0
        )
    }

    private func logHolidayVisionQueueWait(
        config: HolidayVisionLandingConfig,
        queueWaitStart: CFAbsoluteTime
    ) {
        let queueWaitSeconds = CFAbsoluteTimeGetCurrent() - queueWaitStart
        if queueWaitSeconds > 0.5 {
            print(
                String(
                    format: "%@ vision scan: waited %.1fs for database queue before loading candidates",
                    config.logLabel,
                    queueWaitSeconds
                )
            )
        }
    }

    private func runHolidayObjectRecognitionLoop(
        config: HolidayVisionLandingConfig,
        eventIds: [Int],
        eventLabels: [Int: String],
        scopeLabel: String,
        includeHiddenPhotos: Bool,
        progress: (@Sendable (String) -> Void)?
    ) async -> ChristmasLandingVisionScanReport {
        let start = CFAbsoluteTimeGetCurrent()

        let startMessage =
            "\(config.logLabel) vision scan (\(scopeLabel)) starting · \(eventIds.count) AI-tagged event(s) need scanning"
        print(startMessage)
        progress?(startMessage)

        guard !eventIds.isEmpty else {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let doneMessage = String(
                format: "%@ vision scan (\(scopeLabel)) finished · 0/0 events · 0 photos · %.1fs",
                config.logLabel,
                elapsed
            )
            print(doneMessage)
            return ChristmasLandingVisionScanReport(
                candidateEventCount: 0,
                eventsScanned: 0,
                eventsSkipped: 0,
                photosScanned: 0,
                detectionsWritten: 0,
                earlyExits: 0,
                elapsedSeconds: elapsed
            )
        }

        var eventsScanned = 0
        var eventsSkipped = 0
        var photosScanned = 0
        var detectionsWritten = 0
        var earlyExits = 0

        for (index, eventId) in eventIds.enumerated() {
            if Task.isCancelled {
                print(
                    "\(config.logLabel) vision scan (\(scopeLabel)) cancelled before event \(index + 1)/\(eventIds.count)"
                )
                break
            }

            let eventLabel = eventLabels[eventId] ?? holidayScanEventLabel(eventId: eventId)
            progress?("Scanning \(scopeLabel) \(index + 1)/\(eventIds.count): \(eventLabel)")

            let result = await container.eventObjectRecognition.runIfNeeded(
                eventId: eventId,
                includeHiddenPhotos: includeHiddenPhotos,
                forcedOccasionKey: config.occasionKey,
                progress: { scanProgress in
                    if let status = scanProgress.statusText {
                        print("\(scopeLabel) \(index + 1)/\(eventIds.count): \(eventLabel) · \(status)")
                    }
                }
            )

            if let skippedReason = result.skippedReason {
                eventsSkipped += 1
                let message = "Skipped \(scopeLabel) \(index + 1)/\(eventIds.count): \(eventLabel)"
                print(message + " — \(skippedReason)")
                progress?(message)
            } else {
                eventsScanned += 1
                photosScanned += result.photosScanned
                detectionsWritten += result.detectionsWritten
                if result.stoppedEarly {
                    earlyExits += 1
                }

                var message =
                    "Scanned \(scopeLabel) \(index + 1)/\(eventIds.count): \(eventLabel)"
                    + " · \(result.photosScanned) photo\(result.photosScanned == 1 ? "" : "s")"
                if result.detectionsWritten > 0 {
                    message += " · \(result.detectionsWritten) detection\(result.detectionsWritten == 1 ? "" : "s")"
                }
                if result.stoppedEarly {
                    message += " · stopped early"
                }
                print(message)
                progress?(message)
            }

            await Task.yield()
            try? await Task.sleep(for: .milliseconds(120))
        }

        if !eventIds.isEmpty {
            dbQueue.sync {
                for eventId in eventIds {
                    container.occasionScoring.scoreHolidayEventOnDatabaseQueueUnsafe(eventId: eventId)
                    reconcileOccasionCollectionCountsUnsafe(forEventId: eventId)
                }
            }
        }

        let doneMessage = String(
            format: "%@ vision scan (\(scopeLabel)) finished · %d/%d events · %d photos · %.1fs",
            config.logLabel,
            eventsScanned,
            eventIds.count,
            photosScanned,
            CFAbsoluteTimeGetCurrent() - start
        )
        print(doneMessage)
        progress?(doneMessage)

        return ChristmasLandingVisionScanReport(
            candidateEventCount: eventIds.count,
            eventsScanned: eventsScanned,
            eventsSkipped: eventsSkipped,
            photosScanned: photosScanned,
            detectionsWritten: detectionsWritten,
            earlyExits: earlyExits,
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - start
        )
    }

    struct ChristmasObjectRecognitionResetReport: Sendable {
        let taggedEventCount: Int
        let candidatesNeedingScan: Int
    }

    func resetHolidayObjectRecognitionState(
        config: HolidayVisionLandingConfig,
        includeHiddenPhotos: Bool = true
    ) -> ChristmasObjectRecognitionResetReport {
        dbQueue.sync {
            let eventIds = holidayTaggedListEventIdsUnsafe(
                tagValue: config.tagValue,
                includeHiddenPhotos: includeHiddenPhotos
            )
            guard !eventIds.isEmpty else {
                return ChristmasObjectRecognitionResetReport(
                    taggedEventCount: 0,
                    candidatesNeedingScan: 0
                )
            }

            eventTags.clearObjectRecognitionForEventsUnsafe(eventIds: eventIds)
            container.objectTags.clearPhotoVisionScansForEventsUnsafe(eventIds: eventIds)
            container.objectTags.clearObjectDetectionsForEventsUnsafe(eventIds: eventIds)
            container.visionJobs.purgeJobsForEventsUnsafe(eventIds: eventIds)

            for eventId in eventIds {
                container.occasionScoring.scoreHolidayEventOnDatabaseQueueUnsafe(eventId: eventId)
            }

            let candidates = eventTags.fetchAITaggedHolidayEventIdsNeedingObjectRecognitionUnsafe(
                tagValue: config.tagValue,
                includeHidden: includeHiddenPhotos,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )

            return ChristmasObjectRecognitionResetReport(
                taggedEventCount: eventIds.count,
                candidatesNeedingScan: candidates.count
            )
        }
    }

    /// Clears Vision scan state for Christmas-tagged events without running a new scan.
    func resetChristmasObjectRecognitionState(
        includeHiddenPhotos: Bool = true
    ) -> ChristmasObjectRecognitionResetReport {
        guard let config = holidayVisionLandingConfig(tagValue: "Christmas") else {
            return ChristmasObjectRecognitionResetReport(taggedEventCount: 0, candidatesNeedingScan: 0)
        }
        return resetHolidayObjectRecognitionState(
            config: config,
            includeHiddenPhotos: includeHiddenPhotos
        )
    }

    private func holidayTaggedListEventIdsUnsafe(
        tagValue: String,
        includeHiddenPhotos: Bool
    ) -> [Int] {
        let filter = EventListFilter.holidayTag(value: tagValue)
        let visible = eventRepository.fetchListEventIdsForFilterUnsafe(
            filter: filter,
            includeHidden: false
        )
        guard includeHiddenPhotos else {
            return visible
        }
        let hidden = eventRepository.fetchListEventIdsForFilterUnsafe(
            filter: filter,
            includeHidden: true
        )
        return Array(Set(visible + hidden))
    }

    /// Clears object-scan state for holiday-tagged list events and enqueues a full Vision rescan.
    func enqueueHolidayTaggedObjectRescan(
        tagValue: String,
        includeHiddenPhotos: Bool = true,
        priority: Int = 10
    ) -> VisionJobRescanEnqueueResult {
        guard let config = holidayVisionLandingConfig(tagValue: tagValue) else {
            return VisionJobRescanEnqueueResult(
                taggedEventCount: 0,
                enqueuedCount: 0,
                scopeKey: "devRescan:\(tagValue)"
            )
        }

        let eventIds = dbQueue.sync {
            holidayTaggedListEventIdsUnsafe(
                tagValue: tagValue,
                includeHiddenPhotos: includeHiddenPhotos
            )
        }

        guard !eventIds.isEmpty else {
            return VisionJobRescanEnqueueResult(
                taggedEventCount: 0,
                enqueuedCount: 0,
                scopeKey: "devRescan:\(tagValue)"
            )
        }

        _ = resetHolidayObjectRecognitionState(
            config: config,
            includeHiddenPhotos: includeHiddenPhotos
        )

        let result = container.visionJobEnqueue.enqueueHolidayTaggedRescan(
            config: config,
            eventIds: eventIds,
            includeHiddenPhotos: includeHiddenPhotos,
            priority: priority
        )

        Task { @MainActor in
            container.visionJobCoordinator.startIfNeeded()
        }

        return result
    }

    /// Clears and re-queues Vision for every Christmas-tagged list event (developer tool).
    func enqueueChristmasTaggedObjectRescan(
        includeHiddenPhotos: Bool = true,
        priority: Int = 10
    ) -> VisionJobRescanEnqueueResult {
        enqueueHolidayTaggedObjectRescan(
            tagValue: "Christmas",
            includeHiddenPhotos: includeHiddenPhotos,
            priority: priority
        )
    }

    func confirmAIAttributeTag(eventId: Int, field: EventAttributeField) {
        eventTags.confirmAIAttributeTag(eventId: eventId, field: field)
        dbQueue.sync { reconcileOccasionCollectionCountsUnsafe(forEventId: eventId) }
    }

    func rejectAIAttributeTag(eventId: Int, field: EventAttributeField) {
        eventTags.rejectAIAttributeTag(eventId: eventId, field: field)
        dbQueue.sync { reconcileOccasionCollectionCountsUnsafe(forEventId: eventId) }
    }

    func confirmAIHolidayTag(eventId: Int) {
        confirmAIAttributeTag(eventId: eventId, field: .holidayType)
    }

    func rejectAIHolidayTag(eventId: Int) {
        rejectAIAttributeTag(eventId: eventId, field: .holidayType)
    }

    func getEventsForLocation(locationId: Int) -> [IndexedEvent] {
        eventTags.attachAttributeTags(
            to: eventRepository.getEventsForLocation(locationId: locationId)
        )
    }

    @discardableResult
    func updateEventName(eventId: Int, name: String, userEdited: Bool) -> Bool {
        eventRepository.updateEventName(eventId: eventId, name: name, userEdited: userEdited)
    }

    @discardableResult
    func updateChildEventName(eventId: Int, name: String, userEdited: Bool) -> Bool {
        eventRepository.updateChildEventName(eventId: eventId, name: name, userEdited: userEdited)
    }

    func syncDefaultChildEventName(forSubEventId eventId: Int) {
        eventRepository.syncDefaultChildEventName(forSubEventId: eventId)
    }

    func countListEvents(
        includeHidden: Bool = false,
        filter: EventListFilter = .allEvents
    ) -> Int {
        eventRepository.countListEvents(includeHidden: includeHidden, filter: filter)
    }

    func countLocations() -> Int {
        locationRepository.countRows("locations")
    }

    func getEvents(includeHidden: Bool = false) -> [IndexedEvent] {
        eventTags.attachAttributeTags(
            to: eventRepository.getEvents(includeHidden: includeHidden)
        )
    }

    func getEventsForList(
        includeHidden: Bool = false,
        limit: Int? = nil,
        filter: EventListFilter = .allEvents
    ) -> [IndexedEvent] {
        dbQueue.sync {
            let events = eventRepository.getEventsUnsafe(
                includeHidden: includeHidden,
                forList: true,
                limit: limit,
                filter: filter
            )
            return eventTags.attachAttributeTagsUnsafe(to: events)
        }
    }

    func getEvent(eventId: Int) -> IndexedEvent? {
        guard let event = eventRepository.getEvent(eventId: eventId) else { return nil }
        return eventTags.attachHolidayTags(to: [event]).first
    }

    func eventMatchesListFilter(eventId: Int, filter: EventListFilter) -> Bool {
        dbQueue.sync {
            eventRepository.eventMatchesListFilterUnsafe(eventId: eventId, filter: filter)
        }
    }

    private var eventTags: EventTagRepository { container.eventTags }

    func getSlideshowPhotoIds(for events: [IndexedEvent]) -> [Int: [String]] {
        eventRepository.getSlideshowPhotoIds(for: events)
    }

    func setPhotoShowOnFrame(photoId: String, eventId: Int, show: Bool) {
        eventRepository.setPhotoShowOnFrame(photoId: photoId, eventId: eventId, show: show)
        dbQueue.sync {
            syncPhotoOccasionOnFrameFromEventPhotoUnsafe(
                photoId: photoId,
                eventId: eventId,
                isOnFrame: show
            )
            refreshCachedHolidayOnFrameCountsForEventUnsafe(eventId: eventId)
            reconcileOccasionCollectionCountsUnsafe(forEventId: eventId)
        }
    }

    func removePhotoFromEvent(photoId: String, eventId: Int) {
        eventRepository.removePhotoFromEvent(photoId: photoId, eventId: eventId)
        dbQueue.sync { reconcileOccasionCollectionCountsUnsafe(forEventId: eventId) }
    }

    func getPhotosForEvent(eventId: Int, includeHidden: Bool = false) -> [IndexedPhoto] {
        eventRepository.getPhotosForEvent(eventId: eventId, includeHidden: includeHidden)
    }

    func setSimilarGroupPicks(groupPhotoIds: [String], pickedPhotoIds: Set<String>) {
        eventRepository.setSimilarGroupPicks(groupPhotoIds: groupPhotoIds, pickedPhotoIds: pickedPhotoIds)
    }

    func setPhotosShowOnFrame(photoIds: [String], show: Bool) {
        eventRepository.setPhotosShowOnFrame(photoIds: photoIds, show: show)
        dbQueue.sync {
            for photoId in photoIds {
                guard let eventId = eventRepository.getEventIdForPhotoUnsafe(photoId: photoId) else {
                    continue
                }
                syncPhotoOccasionOnFrameFromEventPhotoUnsafe(
                    photoId: photoId,
                    eventId: eventId,
                    isOnFrame: show
                )
            }
            rebuildOccasionLandingOnFrameCountsUnsafe()
        }
    }

    func setPhotosHiddenInEvent(photoIds: [String], hidden: Bool) {
        eventRepository.setPhotosHiddenInEvent(photoIds: photoIds, hidden: hidden)
    }

    func getEventIdForPhoto(photoId: String) -> Int? {
        eventRepository.getEventIdForPhoto(photoId: photoId)
    }

    func getSubEvents(parentEventId: Int) -> [IndexedEvent] {
        eventTags.attachAttributeTags(
            to: eventRepository.getSubEvents(parentEventId: parentEventId)
        )
    }

    func getTripSections(for parentEventId: Int, includeHidden: Bool = false) -> [TripEventSection] {
        eventRepository.getTripSections(for: parentEventId, includeHidden: includeHidden)
    }

    func updateEventsFromLocation(locationId: Int) {
        eventRepository.updateEventsFromLocation(locationId: locationId)
    }
    func geocodePendingLocations(limit: Int = 10) {
        if limit > 0 {
            let pending = locationRepository.fetchPendingGeocodeLocations(limit: limit)
            LocationGeocodeCoordinator.shared.enqueue(pending)
        } else {
            startGeocodingAllPending()
        }
    }
    
    func debugCounts() {
        DevDatabaseTools.debugCounts(database: databaseManager)
    }

    func debugMetadataCounts() {
        DevDatabaseTools.debugMetadataCounts(database: databaseManager)
    }

    func debugPrintFirstEvents() {
        DevDatabaseTools.debugPrintFirstEvents(database: databaseManager)
    }

    func debugPrintAlbumNames() {
        DevDatabaseTools.debugPrintAlbumNames()
    }

    func countRows(_ tableOrQuery: String) -> Int {
        locationRepository.countRows(tableOrQuery)
    }

    func updateEventLocationFromRepresentativePoint(eventId: Int) {
        eventLocationCoordinator.updateEventLocationFromRepresentativePoint(eventId: eventId)
    }

    func snapEventsNearDesignatedHomes() {
        dbQueue.sync {
            eventLocationCoordinator.snapEventsNearDesignatedHomesUnsafe()
        }
    }

    func snapEventsNearDesignatedHomesUnsafe() {
        eventLocationCoordinator.snapEventsNearDesignatedHomesUnsafe()
    }

    func debugEventPipeline() {
        DevDatabaseTools.debugEventPipeline(database: databaseManager)
    }

    func occasionScoringCounts() -> OccasionScoringCounts {
        container.occasionScoring.occasionScoringCounts()
    }

    func scoreAllHolidayOccasions() -> (scoring: OccasionScoringRunResult, tags: HolidayTagApplyResult) {
        let result = container.occasionScoring.scoreAllHolidayEvents()
        dbQueue.sync { rebuildOccasionLandingMetricsUnsafe() }
        return result
    }

    @discardableResult
    func debugPrintTopHolidayOccasionScores(limit: Int = 25) -> [OccasionScoringTopMatch] {
        DevDatabaseTools.debugPrintTopHolidayOccasionScores(
            database: databaseManager,
            limit: limit
        )
    }

    func fetchEditableOccasions() -> [EditableOccasion] {
        container.occasions.fetchEditableOccasions()
    }

    func saveEditableOccasions(_ occasions: [EditableOccasion]) {
        container.occasions.saveEditableOccasions(occasions)
    }

    // MARK: - Photo ↔ occasion (per-occasion on-frame)

    func linkPhotoToOccasion(
        photoId: String,
        occasionKey: String,
        source: PhotoOccasionSource,
        personId: Int? = nil,
        isOnFrame: Bool = false
    ) {
        dbQueue.sync {
            guard let occasionId = container.photoOccasions.occasionIdUnsafe(occasionKey: occasionKey) else {
                return
            }

            let wasOnFrame = container.photoOccasions.isPhotoOnFrameForOccasionUnsafe(
                photoId: photoId,
                occasionId: occasionId
            )

            container.photoOccasions.linkPhotoToOccasionUnsafe(
                photoId: photoId,
                occasionId: occasionId,
                source: source,
                personId: personId,
                isOnFrame: isOnFrame
            )

            if isOnFrame && !wasOnFrame {
                adjustOccasionOnFrameCountUnsafe(occasionKey: occasionKey, delta: 1)
            } else if !isOnFrame && wasOnFrame {
                adjustOccasionOnFrameCountUnsafe(occasionKey: occasionKey, delta: -1)
            }
        }
    }

    func setPhotoOccasionOnFrame(
        photoId: String,
        occasionKey: String,
        isOnFrame: Bool
    ) {
        dbQueue.sync {
            guard let occasionId = container.photoOccasions.occasionIdUnsafe(occasionKey: occasionKey) else {
                return
            }

            let wasOnFrame = container.photoOccasions.isPhotoOnFrameForOccasionUnsafe(
                photoId: photoId,
                occasionId: occasionId
            )

            container.photoOccasions.setPhotoOccasionOnFrameUnsafe(
                photoId: photoId,
                occasionId: occasionId,
                isOnFrame: isOnFrame
            )

            if isOnFrame && !wasOnFrame {
                adjustOccasionOnFrameCountUnsafe(occasionKey: occasionKey, delta: 1)
            } else if !isOnFrame && wasOnFrame {
                adjustOccasionOnFrameCountUnsafe(occasionKey: occasionKey, delta: -1)
            }
        }
    }

    func setPhotosOccasionOnFrame(
        photoIds: [String],
        occasionKey: String,
        isOnFrame: Bool
    ) {
        dbQueue.sync {
            guard let occasionId = container.photoOccasions.occasionIdUnsafe(occasionKey: occasionKey) else {
                return
            }

            var delta = 0

            for photoId in photoIds {
                let wasOnFrame = container.photoOccasions.isPhotoOnFrameForOccasionUnsafe(
                    photoId: photoId,
                    occasionId: occasionId
                )

                container.photoOccasions.setPhotoOccasionOnFrameUnsafe(
                    photoId: photoId,
                    occasionId: occasionId,
                    isOnFrame: isOnFrame
                )

                if isOnFrame && !wasOnFrame {
                    delta += 1
                } else if !isOnFrame && wasOnFrame {
                    delta -= 1
                }
            }

            if delta != 0 {
                adjustOccasionOnFrameCountUnsafe(occasionKey: occasionKey, delta: delta)
            }
        }
    }

    func fetchOnFramePhotoIds(occasionKey: String) -> [String] {
        guard let occasionId = container.photoOccasions.occasionId(forKey: occasionKey) else {
            return []
        }

        return container.photoOccasions.fetchOnFramePhotoIds(occasionId: occasionId)
    }

    func countOnFramePhotos(occasionKey: String) -> Int {
        guard let occasionId = container.photoOccasions.occasionId(forKey: occasionKey) else {
            return 0
        }

        return container.photoOccasions.countOnFramePhotos(occasionId: occasionId)
    }

    func fetchPhotoOccasions(photoId: String) -> [PhotoOccasionLink] {
        container.photoOccasions.fetchPhotoOccasions(photoId: photoId)
    }

    func saveOccasionSubjects(
        occasionKey: String,
        subjects: [(personId: Int, role: OccasionSubjectRole)]
    ) {
        guard let occasionId = container.photoOccasions.occasionId(forKey: occasionKey) else {
            return
        }

        container.photoOccasions.saveOccasionSubjects(
            occasionId: occasionId,
            subjects: subjects
        )
    }

    func fetchOccasionSubjects(occasionKey: String) -> [OccasionSubject] {
        guard let occasionId = container.photoOccasions.occasionId(forKey: occasionKey) else {
            return []
        }

        return container.photoOccasions.fetchOccasionSubjects(occasionId: occasionId)
    }

    func searchPhotosWithPeople(
        requiredPersonId: Int,
        includingAnyOfPersonIds childPersonIds: [Int],
        exactPeopleOnly: Bool = true
    ) -> [String] {
        container.photoOccasions.searchPhotosWithPeople(
            requiredPersonId: requiredPersonId,
            includingAnyOfPersonIds: childPersonIds,
            exactPeopleOnly: exactPeopleOnly
        )
    }

    func searchPhotosWithPerson(personId: Int, exactPeopleOnly: Bool = true) -> [String] {
        container.photoOccasions.searchPhotosWithPerson(
            personId: personId,
            exactPeopleOnly: exactPeopleOnly
        )
    }

    func fetchOccasionPersonId(occasionKey: String) -> Int? {
        container.occasions.fetchOccasionPersonId(occasionKey: occasionKey)
    }

    func fetchOccasionLandingCatalogItems() -> [OccasionLandingItem] {
        dbQueue.sync {
            var catalog = container.occasions.fetchOccasionLandingCatalogUnsafe()
            if catalog.isEmpty {
                container.occasions.ensureDefaultSeedDataUnsafe()
                catalog = container.occasions.fetchOccasionLandingCatalogUnsafe()
            }
            return Self.makeLandingItems(from: catalog, collectionCounts: nil, onFrameCounts: nil)
        }
    }

    func applyCachedOccasionLandingMetrics(
        to items: [OccasionLandingItem]
    ) -> (items: [OccasionLandingItem], staleTagValues: [String]) {
        dbQueue.sync {
            let cache = container.landingMetricsCache
            var staleTagValues: [String] = []

            let updatedItems = items.map { item in
                if let cached = cache.fetchCachedUnsafe(tagValue: item.tagValue) {
                    return item.withCounts(
                        collection: cached.collectionCount,
                        onFrame: cached.onFramePhotoCount
                    )
                }

                staleTagValues.append(item.tagValue)
                return item
            }

            return (updatedItems, staleTagValues)
        }
    }

    func countOccasionLandingItemMetrics(
        occasionKey: String,
        tagValue: String,
        occasionType: String,
        displayName: String
    ) -> (collections: Int, onFramePhotos: Int) {
        dbQueue.sync {
            countOccasionLandingItemMetricsUnsafe(
                occasionKey: occasionKey,
                tagValue: tagValue,
                occasionType: occasionType,
                displayName: displayName
            )
        }
    }

    func countOccasionLandingMetricsBatch(
        requests: [OccasionLandingMetricsRequest]
    ) -> [String: (collections: Int, onFramePhotos: Int)] {
        dbQueue.sync {
            var results: [String: (collections: Int, onFramePhotos: Int)] = [:]
            results.reserveCapacity(requests.count)

            for request in requests {
                results[request.tagValue] = countOccasionLandingItemMetricsUnsafe(
                    occasionKey: request.occasionKey,
                    tagValue: request.tagValue,
                    occasionType: request.occasionType,
                    displayName: request.displayName
                )
            }

            return results
        }
    }

    private func countOccasionLandingItemMetricsUnsafe(
        occasionKey: String,
        tagValue: String,
        occasionType: String,
        displayName: String
    ) -> (collections: Int, onFramePhotos: Int) {
        let cache = container.landingMetricsCache

        if let cached = cache.fetchCachedUnsafe(tagValue: tagValue) {
            return (cached.collectionCount, cached.onFramePhotoCount)
        }

        let filter = occasionEventListFilter(
            occasionKey: occasionKey,
            tagValue: tagValue,
            occasionType: occasionType,
            displayName: displayName
        )
        let listEventIds = eventRepository.fetchListEventIdsForFilterUnsafe(
            filter: filter,
            includeHidden: false
        )
        let onFramePhotos = countOnFramePhotosForOccasionUnsafe(
            occasionKey: occasionKey,
            tagValue: tagValue,
            occasionType: occasionType
        )

        if let occasionId = container.photoOccasions.occasionIdUnsafe(occasionKey: occasionKey) {
            cache.replaceCollectionMembershipForOccasionUnsafe(
                occasionId: occasionId,
                listEventIds: listEventIds,
                tagValue: tagValue
            )
        }

        cache.saveUnsafe(
            tagValue: tagValue,
            collectionCount: listEventIds.count,
            onFramePhotoCount: onFramePhotos
        )

        return (listEventIds.count, onFramePhotos)
    }

    func fetchOccasionFrameLandingSnapshot(
        occasionKey: String,
        tagValue: String,
        name: String,
        nextOccurrence: Date,
        occasionType: String
    ) -> OccasionFrameLandingSnapshot {
        dbQueue.sync {
            let metrics = countOccasionLandingItemMetricsUnsafe(
                occasionKey: occasionKey,
                tagValue: tagValue,
                occasionType: occasionType,
                displayName: name
            )
            let collectionCount = metrics.collections

            syncEventInheritedOnFrameForOccasionUnsafe(
                occasionKey: occasionKey,
                occasionType: occasionType,
                tagValue: tagValue,
                displayName: name
            )

            var photoIds: [String] = []
            if let occasionId = container.photoOccasions.occasionIdUnsafe(occasionKey: occasionKey) {
                photoIds = container.photoOccasions.fetchOnFramePhotoIdsUnsafe(
                    occasionId: occasionId
                )
            }

            if photoIds.isEmpty, occasionType != "birthday" {
                photoIds = eventRepository.fetchOnFramePhotoIdsForHolidayTagUnsafe(
                    tagValue: tagValue,
                    includeHidden: false
                )
            }

            if container.landingMetricsCache.hasMetricsUnsafe(tagValue: tagValue) {
                container.landingMetricsCache.updateOnFrameCountUnsafe(
                    tagValue: tagValue,
                    onFramePhotoCount: photoIds.count
                )
            }

            return OccasionFrameLandingSnapshot(
                occasionKey: occasionKey,
                name: name,
                tagValue: tagValue,
                nextOccurrence: nextOccurrence,
                collectionCount: collectionCount,
                onFramePhotoIds: photoIds
            )
        }
    }

    private func tagValueForOccasionCatalogRow(
        _ row: OccasionLandingCatalogRow
    ) -> String {
        OccasionHolidayTagService.holidayTagValue(
            occasionKey: row.occasionKey,
            displayName: row.name
        )
    }

    private func countOnFramePhotosForOccasionUnsafe(
        occasionKey: String,
        tagValue: String,
        occasionType: String
    ) -> Int {
        if occasionType == "birthday"
            || occasionKey == "mothers_day"
            || occasionKey == "fathers_day",
           let occasionId = container.photoOccasions.occasionIdUnsafe(occasionKey: occasionKey) {
            return container.photoOccasions.countOnFramePhotosUnsafe(occasionId: occasionId)
        }

        return eventRepository.countOnFramePhotosForHolidayTagUnsafe(
            tagValue: tagValue,
            includeHidden: false
        )
    }

    private func usesPhotoOccasionOnFrame(
        occasionKey: String,
        occasionType: String
    ) -> Bool {
        occasionType == "birthday"
            || occasionKey == "mothers_day"
            || occasionKey == "fathers_day"
    }

    private func syncPhotoOccasionOnFrameFromEventPhotoUnsafe(
        photoId: String,
        eventId: Int,
        isOnFrame: Bool
    ) {
        let listEventId = eventRepository.resolveListEventIdUnsafe(eventId: eventId)
        guard listEventId > 0 else { return }

        for row in container.occasions.fetchOccasionLandingCatalogUnsafe() {
            guard usesPhotoOccasionOnFrame(
                occasionKey: row.occasionKey,
                occasionType: row.occasionType
            ) else {
                continue
            }

            let tagValue = tagValueForOccasionCatalogRow(row)
            let filter = occasionEventListFilter(
                occasionKey: row.occasionKey,
                tagValue: tagValue,
                occasionType: row.occasionType,
                displayName: row.name
            )
            guard eventRepository.listEventQualifiesForFilterUnsafe(
                listEventId: listEventId,
                filter: filter,
                includeHidden: false
            ) else {
                continue
            }

            guard let occasionId = container.photoOccasions.occasionIdUnsafe(
                occasionKey: row.occasionKey
            ) else {
                continue
            }

            let wasOnFrame = container.photoOccasions.isPhotoOnFrameForOccasionUnsafe(
                photoId: photoId,
                occasionId: occasionId
            )

            if isOnFrame {
                container.photoOccasions.linkPhotoToOccasionUnsafe(
                    photoId: photoId,
                    occasionId: occasionId,
                    source: .eventInherit,
                    personId: nil,
                    isOnFrame: true
                )
                if !wasOnFrame {
                    adjustOccasionOnFrameCountUnsafe(occasionKey: row.occasionKey, delta: 1)
                }
            } else if wasOnFrame,
                      container.photoOccasions.photoOccasionSourceUnsafe(
                          photoId: photoId,
                          occasionId: occasionId
                      ) == .eventInherit {
                container.photoOccasions.setPhotoOccasionOnFrameUnsafe(
                    photoId: photoId,
                    occasionId: occasionId,
                    isOnFrame: false
                )
                adjustOccasionOnFrameCountUnsafe(occasionKey: row.occasionKey, delta: -1)
            }
        }
    }

    private func syncEventInheritedOnFrameForOccasionUnsafe(
        occasionKey: String,
        occasionType: String,
        tagValue: String,
        displayName: String
    ) {
        guard usesPhotoOccasionOnFrame(
            occasionKey: occasionKey,
            occasionType: occasionType
        ) else {
            return
        }

        guard let occasionId = container.photoOccasions.occasionIdUnsafe(occasionKey: occasionKey) else {
            return
        }

        let filter = occasionEventListFilter(
            occasionKey: occasionKey,
            tagValue: tagValue,
            occasionType: occasionType,
            displayName: displayName
        )
        let listEventIds = eventRepository.fetchListEventIdsForFilterUnsafe(
            filter: filter,
            includeHidden: false
        )

        for listEventId in listEventIds {
            let photoIds = eventRepository.fetchOnFramePhotoIdsForListEventUnsafe(
                listEventId: listEventId
            )
            for photoId in photoIds {
                container.photoOccasions.linkPhotoToOccasionUnsafe(
                    photoId: photoId,
                    occasionId: occasionId,
                    source: .eventInherit,
                    personId: nil,
                    isOnFrame: true
                )
            }
        }
    }

    private func adjustOccasionOnFrameCountUnsafe(occasionKey: String, delta: Int) {
        guard delta != 0,
              let row = container.occasions.fetchOccasionLandingCatalogUnsafe()
                  .first(where: { $0.occasionKey == occasionKey }) else {
            return
        }

        let tagValue = tagValueForOccasionCatalogRow(row)
        guard container.landingMetricsCache.hasMetricsUnsafe(tagValue: tagValue) else {
            return
        }

        container.landingMetricsCache.adjustCountsUnsafe(
            tagValue: tagValue,
            onFrameDelta: delta
        )
    }

    private func reconcileOccasionCollectionCountsUnsafe(forEventId eventId: Int) {
        let listEventId = eventRepository.resolveListEventIdUnsafe(eventId: eventId)
        guard listEventId > 0 else { return }

        let catalog = container.occasions.fetchOccasionLandingCatalogUnsafe()

        for row in catalog {
            let tagValue = tagValueForOccasionCatalogRow(row)
            let filter = occasionEventListFilter(
                occasionKey: row.occasionKey,
                tagValue: tagValue,
                occasionType: row.occasionType,
                displayName: row.name
            )
            let qualifies = eventRepository.listEventQualifiesForFilterUnsafe(
                listEventId: listEventId,
                filter: filter,
                includeHidden: false
            )
            let hadMembership = container.landingMetricsCache.hasCollectionMembershipUnsafe(
                occasionId: row.occasionId,
                listEventId: listEventId
            )

            if qualifies != hadMembership {
                container.landingMetricsCache.setCollectionMembershipUnsafe(
                    occasionId: row.occasionId,
                    listEventId: listEventId,
                    isMember: qualifies,
                    tagValue: tagValue
                )
            }
        }
    }

    private func refreshCachedHolidayOnFrameCountsForEventUnsafe(eventId: Int) {
        let listEventId = eventRepository.resolveListEventIdUnsafe(eventId: eventId)
        guard listEventId > 0 else { return }

        let tagValues = eventTags.fetchHolidayTagValuesForEventUnsafe(eventId: listEventId)
        guard !tagValues.isEmpty else { return }

        for tagValue in tagValues {
            guard container.landingMetricsCache.hasMetricsUnsafe(tagValue: tagValue) else {
                continue
            }

            let onFrame = eventRepository.countOnFramePhotosForHolidayTagUnsafe(
                tagValue: tagValue,
                includeHidden: false
            )
            container.landingMetricsCache.updateOnFrameCountUnsafe(
                tagValue: tagValue,
                onFramePhotoCount: onFrame
            )
        }
    }

    private func rebuildOccasionLandingOnFrameCountsUnsafe() {
        let catalog = container.occasions.fetchOccasionLandingCatalogUnsafe()

        for row in catalog {
            let tagValue = tagValueForOccasionCatalogRow(row)
            guard container.landingMetricsCache.hasMetricsUnsafe(tagValue: tagValue) else {
                continue
            }

            let onFrame = countOnFramePhotosForOccasionUnsafe(
                occasionKey: row.occasionKey,
                tagValue: tagValue,
                occasionType: row.occasionType
            )
            container.landingMetricsCache.updateOnFrameCountUnsafe(
                tagValue: tagValue,
                onFramePhotoCount: onFrame
            )
        }
    }

    private func rebuildOccasionLandingMetricsUnsafe() {
        let catalog = container.occasions.fetchOccasionLandingCatalogUnsafe()
        let cache = container.landingMetricsCache

        cache.clearAllCollectionMembershipUnsafe()

        for row in catalog {
            let tagValue = tagValueForOccasionCatalogRow(row)
            let filter = occasionEventListFilter(
                occasionKey: row.occasionKey,
                tagValue: tagValue,
                occasionType: row.occasionType,
                displayName: row.name
            )
            let listEventIds = eventRepository.fetchListEventIdsForFilterUnsafe(
                filter: filter,
                includeHidden: false
            )
            let onFrame = countOnFramePhotosForOccasionUnsafe(
                occasionKey: row.occasionKey,
                tagValue: tagValue,
                occasionType: row.occasionType
            )

            cache.replaceCollectionMembershipForOccasionUnsafe(
                occasionId: row.occasionId,
                listEventIds: listEventIds,
                tagValue: tagValue
            )
            cache.saveUnsafe(
                tagValue: tagValue,
                collectionCount: listEventIds.count,
                onFramePhotoCount: onFrame
            )
        }
    }

    func fetchOccasionLandingItems() -> [OccasionLandingItem] {
        let catalog = fetchOccasionLandingCatalogItems()
        return catalog.map { item in
            let metrics = countOccasionLandingItemMetrics(
                occasionKey: item.occasionKey,
                tagValue: item.tagValue,
                occasionType: item.occasionType,
                displayName: item.name
            )
            return item.withCounts(
                collection: metrics.collections,
                onFrame: metrics.onFramePhotos
            )
        }
    }

    func fetchAllPeople() -> [PeopleRepository.PersonRecord] {
        peopleRepository.fetchAllPeople()
    }

    func fetchPeopleWithBirthDates() -> [PeopleRepository.PersonBirthdayRecord] {
        peopleRepository.fetchPeopleWithBirthDates()
    }

    func fetchEventPeople(
        eventId: Int,
        includeChildEvents: Bool
    ) -> [EventRepository.EventPersonRecord] {
        eventRepository.fetchEventPeople(
            eventId: eventId,
            includeChildEvents: includeChildEvents
        )
    }

    private static func makeLandingItems(
        from catalog: [OccasionLandingCatalogRow],
        collectionCounts: [String: Int]?,
        onFrameCounts: [String: Int]?
    ) -> [OccasionLandingItem] {
        catalog.map { row in
            let nextOccurrence = parseLandingDate(row.nextOccurrenceISO) ?? Date()
            let tagValue = OccasionHolidayTagService.holidayTagValue(
                occasionKey: row.occasionKey,
                displayName: row.name
            )

            return OccasionLandingItem(
                occasionId: row.occasionId,
                occasionKey: row.occasionKey,
                name: row.name,
                occasionType: row.occasionType,
                tagValue: tagValue,
                nextOccurrence: nextOccurrence,
                collectionCount: collectionCounts?[tagValue],
                onFramePhotoCount: onFrameCounts?[tagValue]
            )
        }
    }

    private func occasionEventListFilter(
        occasionKey: String,
        tagValue: String,
        occasionType: String,
        displayName: String
    ) -> EventListFilter {
        if occasionType == "birthday" {
            return .birthdayOccasion(occasionKey: occasionKey, displayName: displayName)
        }
        return .holidayTag(value: tagValue)
    }

    private static func parseLandingDate(_ iso: String) -> Date? {
        if let date = EventDateParser.parseDate(iso) {
            return date
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: iso)
    }
}
