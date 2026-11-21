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

    func importPeopleFromAlbums() {
        peopleImportService.importPeopleFromAlbums()
    }

    // MARK: - Event clustering forwards

    func clusterEventsByTime() {
        eventClustering.clusterEventsByTime()
    }

    func syncEventsIncrementally() {
        eventClustering.syncEventsIncrementally()
    }

    @discardableResult
    func syncEventsAssignmentBatch() -> Bool {
        eventClustering.syncEventsAssignmentBatch()
    }

    func countUnassignedPhotosForEvents() -> Int {
        eventClustering.countUnassignedPhotosForEvents()
    }

    func rebuildAllEvents() {
        eventClustering.rebuildAllEvents()
    }

    @discardableResult
    func prepareEventRebuild() -> Int {
        eventClustering.prepareEventRebuild()
    }

    func finishEventRebuild() {
        eventClustering.finishEventRebuild()
    }

    func finishEventSyncMaintenance() {
        eventClustering.finishEventSyncMaintenance()
    }

    func clearAllEventDataPreservingLocations() {
        eventClustering.clearAllEventDataPreservingLocations()
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

    func clearAllCropFocuses() {
        photoRepository.clearAllCropFocuses()
    }

    func clearCropFocus(photoId: String) {
        photoRepository.clearCropFocus(photoId: photoId)
    }

    func clearCropFocuses(photoIds: [String]) {
        photoRepository.clearCropFocuses(photoIds: photoIds)
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
    }

    func setEventShowOnFrame(eventId: Int, show: Bool) {
        eventRepository.setEventShowOnFrame(eventId: eventId, show: show)
    }

    func setEventUserHidden(eventId: Int, hidden: Bool) {
        eventRepository.setEventUserHidden(eventId: eventId, hidden: hidden)
    }

    func getEventAttributeOptions(for field: EventAttributeField) -> [String] {
        eventRepository.getEventAttributeOptions(for: field)
    }

    func addCustomEventAttributeOption(_ value: String, for field: EventAttributeField) {
        eventRepository.addCustomEventAttributeOption(value, for: field)
    }

    func updateEventAttribute(eventId: Int, field: EventAttributeField, value: String?) {
        eventRepository.updateEventAttribute(eventId: eventId, field: field, value: value)
    }

    func getEventsForLocation(locationId: Int) -> [IndexedEvent] {
        eventRepository.getEventsForLocation(locationId: locationId)
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

    func getEvents(includeHidden: Bool = false) -> [IndexedEvent] {
        eventRepository.getEvents(includeHidden: includeHidden)
    }

    func getEvent(eventId: Int) -> IndexedEvent? {
        eventRepository.getEvent(eventId: eventId)
    }

    func getSlideshowPhotoIds(for events: [IndexedEvent]) -> [Int: [String]] {
        eventRepository.getSlideshowPhotoIds(for: events)
    }

    func setPhotoShowOnFrame(photoId: String, eventId: Int, show: Bool) {
        eventRepository.setPhotoShowOnFrame(photoId: photoId, eventId: eventId, show: show)
    }

    func removePhotoFromEvent(photoId: String, eventId: Int) {
        eventRepository.removePhotoFromEvent(photoId: photoId, eventId: eventId)
    }

    func getPhotosForEvent(eventId: Int, includeHidden: Bool = false) -> [IndexedPhoto] {
        eventRepository.getPhotosForEvent(eventId: eventId, includeHidden: includeHidden)
    }

    func setSimilarGroupPicks(groupPhotoIds: [String], pickedPhotoIds: Set<String>) {
        eventRepository.setSimilarGroupPicks(groupPhotoIds: groupPhotoIds, pickedPhotoIds: pickedPhotoIds)
    }

    func setPhotosShowOnFrame(photoIds: [String], show: Bool) {
        eventRepository.setPhotosShowOnFrame(photoIds: photoIds, show: show)
    }

    func setPhotosShowOnFrame(updates: [String: Bool]) {
        eventRepository.setPhotosShowOnFrame(updates: updates)
    }

    func setPhotosHiddenInEvent(photoIds: [String], hidden: Bool) {
        eventRepository.setPhotosHiddenInEvent(photoIds: photoIds, hidden: hidden)
    }

    func getEventIdForPhoto(photoId: String) -> Int? {
        eventRepository.getEventIdForPhoto(photoId: photoId)
    }

    func getSubEvents(parentEventId: Int) -> [IndexedEvent] {
        eventRepository.getSubEvents(parentEventId: parentEventId)
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
}
