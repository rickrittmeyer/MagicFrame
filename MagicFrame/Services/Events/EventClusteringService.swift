import Foundation
import SQLite3

protocol EventClusteringHost: AnyObject {
    func eventTuningUnsafe() -> EventTuningSettings
    func findOrCreateLocation(latitude: Double, longitude: Double, at date: Date) -> Int
    func distanceInMiles(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double
    func countRows(_ tableOrQuery: String) -> Int
    @discardableResult
    func mergeDuplicateLocations(
        proximityMiles: Double?,
        samePlaceNameMiles: Double?,
        frequentPlaceMiles: Double?,
        frequentPlaceMinEvents: Int?
    ) -> Int
    func deduplicateLocationsByAddressUnsafe(maxDistanceMiles: Double) -> Int
    func mergeNearbyLocationsIntoCurrentHome()
    func snapEventsNearDesignatedHomesUnsafe()
    func updateEventLocationFromRepresentativePoint(eventId: Int)
    func flushPendingGeocodeEnqueues()
    func updateCoverPhotoForEvent(eventId: Int)
    func getEvent(eventId: Int) -> IndexedEvent?
}

final class EventClusteringService {

    static let eventSyncPhotoBatchSize = 500
    static let eventSyncRebuildBatchSize = 200

    private unowned let host: EventClusteringHost
    private let database: DatabaseManager
    private let events: EventRepository
    private let metadataAssignment: PhotoEventAssignmentService

    private var isRebuildContext = false
    private var lastProgressPost = Date.distantPast
    private var homeCandidatesCache: [CachedHomeCandidate]?
    private var syncSessionTouchedEventIds = Set<Int>()
    private var sameDayLocatedEventCache: [EventRepository.SameDayLocatedEvent]?

    private var db: OpaquePointer? { database.connection }

    private let iso8601Formatter = ISO8601DateFormatter()
    private let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    init(
        host: EventClusteringHost,
        database: DatabaseManager,
        events: EventRepository,
        metadataAssignment: PhotoEventAssignmentService
    ) {
        self.host = host
        self.database = database
        self.events = events
        self.metadataAssignment = metadataAssignment
        metadataAssignment.onBatchTouchedEvents = { [weak self] eventIds in
            self?.recordSyncTouchedEventIds(eventIds)
        }
    }

    private func recordSyncTouchedEventIds(_ eventIds: Set<Int>) {
        guard !eventIds.isEmpty else { return }
        syncSessionTouchedEventIds.formUnion(eventIds)
    }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if database.isOnQueue { return try work() }
        return try database.sync(work)
    }

    private struct CachedHomeCandidate {
    let latitude: Double
    let longitude: Double
    let isCurrentHome: Bool
    let homeStartDate: String?
    let homeEndDate: String?
    }

    private struct EventMergeCandidate {
    let eventId: Int
    let startDate: Date
    let endDate: Date
    let latitude: Double
    let longitude: Double
    let photoCount: Int
    }

    private struct TripPhotoRecord {
    let id: String
    let date: Date
    let latitude: Double?
    let longitude: Double?
    }

    private struct TripMergeCandidate {
    let eventId: Int
    let startDate: Date
    let endDate: Date
    let latitude: Double
    let longitude: Double
    let photoCount: Int
    }

    func clusterEventsByTime() {
    let deleteSQL = """
    DELETE FROM photo_events;
    DELETE FROM events;
    DELETE FROM sqlite_sequence WHERE name = 'events';
    """

    sqlite3_exec(db, deleteSQL, nil, nil, nil)

    let selectSQL = """
    SELECT id, creationDate, latitude, longitude
    FROM photos
    WHERE latitude IS NOT NULL
      AND longitude IS NOT NULL
      AND isScreenshot = 0
      AND isDeleted = 0
    ORDER BY creationDate ASC;
    """

    var statement: OpaquePointer?
    var photos: [(id: String, date: Date, latitude: Double?, longitude: Double?)] = []
    let formatter = ISO8601DateFormatter()

    if sqlite3_prepare_v2(db, selectSQL, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let dateString = String(cString: sqlite3_column_text(statement, 1))

            let latitude: Double? =
                sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 2)

            let longitude: Double? =
                sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 3)

            if let date = formatter.date(from: dateString) {
                photos.append((id: id, date: date, latitude: latitude, longitude: longitude))
            }
        }
    }

    sqlite3_finalize(statement)

    guard !photos.isEmpty else {
        print("No photos found for clustering")
        return
    }

    let maxGapSeconds: TimeInterval = 4 * 60 * 60
    let maxDistanceMiles = host.eventTuningUnsafe().localEventMatchMiles

    var currentEventPhotos: [(id: String, date: Date, latitude: Double?, longitude: Double?)] = []
    var lastPhoto: (id: String, date: Date, latitude: Double?, longitude: Double?)?

    for photo in photos {
        var shouldStartNewEvent = false

        if let lastPhoto = lastPhoto {
            let timeGap = abs(photo.date.timeIntervalSince(lastPhoto.date))

            if timeGap > maxGapSeconds {
                shouldStartNewEvent = true
            }

            if let lat1 = lastPhoto.latitude,
               let lon1 = lastPhoto.longitude,
               let lat2 = photo.latitude,
               let lon2 = photo.longitude {

                let distance = host.distanceInMiles(
                    lat1: lat1,
                    lon1: lon1,
                    lat2: lat2,
                    lon2: lon2
                )

                if distance > maxDistanceMiles {
                    shouldStartNewEvent = true
                }
            }
        }

        if shouldStartNewEvent {
            saveEvent(photos: currentEventPhotos)
            currentEventPhotos = []
        }

        currentEventPhotos.append(photo)
        lastPhoto = photo
    }

    if !currentEventPhotos.isEmpty {
        saveEvent(photos: currentEventPhotos)
    }
    }


    func syncEventsIncrementally() {
    var batches = 0

    while syncEventsAssignmentBatch() {
        batches += 1
    }

    if batches == 0 {
        print("No unassigned GPS photos to process")
    } else {
        print("Assigned GPS photos in \(batches) batch(es)")
    }

    syncMetadataAssignmentPasses()
    finishEventSyncMaintenance()
    print("Incremental event sync complete")
    }

    /// Processes one batch of unassigned photos. Returns `true` if more remain.
    @discardableResult

    func syncEventsAssignmentBatch() -> Bool {
    sync {
        let batchLimit = isRebuildContext
            ? EventClusteringService.eventSyncRebuildBatchSize
            : EventClusteringService.eventSyncPhotoBatchSize
        let remainingBefore = countUnassignedPhotosForEventsUnsafe()
        let photos = events.getUnassignedGPSPhotosForEvents(limit: batchLimit)
        guard !photos.isEmpty else { return false }

        print(
            "Processing event assignment batch: \(photos.count) photos"
            + " (\(remainingBefore.formatted()) unassigned total)"
        )
        assignPhotosToEvents(photos, maxTouchedEvents: nil)

        let remainingAfter = countUnassignedPhotosForEventsUnsafe()
        print(
            "Event assignment batch done: \(remainingAfter.formatted()) photos still unassigned"
        )

        return remainingAfter > 0
    }
    }


    func countUnassignedPhotosForEvents() -> Int {
    sync {
        countUnassignedPhotosForEventsUnsafe()
    }
    }


    func countUnassignedPhotosForEventsUnsafe() -> Int {
        events.countUnassignedGPSPhotosForEvents()
    }


    func rebuildAllEvents() {
        prepareEventRebuild()
        while syncEventsAssignmentBatch() { }
        syncMetadataAssignmentPasses()
        finishEventRebuild()
        print("Event rebuild complete")
    }

    /// Metadata attach to GPS-backed events, then date/time-only events for remaining no-GPS orphans.
    func syncSecondaryPhotoAssignmentPasses() {
        sync {
            metadataAssignment.syncMetadataAssignmentUntilComplete()
            syncTimeOnlyNoGPSAssignmentPasses()
        }
    }

    private func syncMetadataAssignmentPasses() {
        syncSecondaryPhotoAssignmentPasses()
    }

    private func syncTimeOnlyNoGPSAssignmentPasses() {
        var batches = 0
        while syncTimeOnlyNoGPSAssignmentBatch() {
            batches += 1
        }
        if batches > 0 {
            print("Time-only no-GPS assignment finished in \(batches) batch(es)")
        }
    }

    @discardableResult
    private func syncTimeOnlyNoGPSAssignmentBatch() -> Bool {
        let batchLimit = EventClusteringService.eventSyncPhotoBatchSize
        let remainingBefore = events.countUnassignedMetadataPhotosForEvents()
        let metadata = events.getUnassignedMetadataPhotosForEvents(
            limit: batchLimit,
            ascending: true
        )
        guard !metadata.isEmpty else { return false }

        let photos = metadata.map {
            EventCandidatePhoto(id: $0.id, date: $0.date, latitude: nil, longitude: nil)
        }

        print(
            "Time-only no-GPS assignment batch: \(photos.count) photos"
            + " (\(remainingBefore.formatted()) unassigned total)"
        )
        postEventSyncStatus(
            "Assigning no-GPS photos… \(remainingBefore.formatted()) left",
            force: true
        )

        assignPhotosToEvents(photos, maxTouchedEvents: nil, tryGPSMatch: false)

        let remainingAfter = events.countUnassignedMetadataPhotosForEvents()
        print(
            "Time-only assignment batch done:"
            + " \(remainingAfter.formatted()) no-GPS still unassigned"
        )

        return remainingAfter > 0
    }

    @discardableResult
    private func assignPhotoToTimeCluster(
        _ photo: EventCandidatePhoto,
        openEventId: Int?,
        openLastDate: Date?,
        maxGapSeconds: TimeInterval,
        touchedEventIds: inout Set<Int>
    ) -> Int? {
        let eventId: Int?

        if let locatedId = sameDayLocatedEventId(for: photo.date) {
            eventId = locatedId
        } else if let existingId = events.findTimeOnlyMatchingEvent(
            photoDate: photo.date,
            maxGapSeconds: maxGapSeconds
        ) {
            eventId = existingId
        } else if let openEventId,
                  let openLastDate,
                  abs(photo.date.timeIntervalSince(openLastDate)) <= maxGapSeconds {
            eventId = openEventId
        } else {
            eventId = createTimeOnlyEvent(from: photo)
        }

        guard let eventId, eventId > 0 else { return nil }

        events.attachPhotoToEvent(
            photoId: photo.id,
            eventId: eventId,
            assignmentConfidence: 1.0,
            assignmentMethod: .timeMatch
        )
        events.markPhotoEventAssigned(photoId: photo.id)
        events.expandEventDatesAfterAttach(eventId: eventId, photoDate: photo.date)
        touchedEventIds.insert(eventId)
        return eventId
    }

    private func createTimeOnlyEvent(from photo: EventCandidatePhoto) -> Int {
        let dateString = iso8601Formatter.string(from: photo.date)
        let name = displayDateFormatter.string(from: photo.date)

        return events.insertEventRow(
            name: name,
            startDate: dateString,
            endDate: dateString,
            latitude: nil,
            longitude: nil,
            locationId: nil,
            clusteredByTimeOnly: true
        )
    }

    @discardableResult

    func prepareEventRebuild() -> Int {
    sync {
        isRebuildContext = true
        print("Rebuilding all events (preserving locations)")

        postEventSyncStatus("Clearing existing events…", isRebuild: true)
        clearAllEventDataPreservingLocations()
        syncSessionTouchedEventIds.removeAll()

        let total = countUnassignedPhotosForEventsUnsafe()
        print("Reassigning \(total) photos to events")
        postEventSyncProgress(
            processed: 0,
            total: total,
            remainingUnassigned: total,
            isRebuild: true
        )

        return total
    }
    }


    /// Recreates `events.locationId` from photo GPS without rebuilding events.
    func relinkEventLocationsFromPhotos() {
        sync {
            postEventSyncStatus("Linking event locations…")
            refreshAllEventLocationLinks()
            host.snapEventsNearDesignatedHomesUnsafe()

            let linked = host.countRows("events WHERE isDeleted = 0 AND locationId IS NOT NULL")
            let total = host.countRows("events WHERE isDeleted = 0")
            print("Relinked event locations: \(linked)/\(total) events have locationId")
            postEventSyncStatus(
                "Linked locations on \(linked.formatted()) of \(total.formatted()) events"
            )
        }
        host.flushPendingGeocodeEnqueues()
    }

    func finishEventRebuild() {
    sync {
        runPostSyncMaintenance()
        isRebuildContext = false

        let eventCount = host.countRows("events WHERE isDeleted = 0")
        let unassigned = countUnassignedPhotosForEventsUnsafe()
        print(
            "Event rebuild complete: \(eventCount.formatted()) events,"
            + " \(unassigned.formatted()) unassigned photos remaining"
        )
        postEventSyncStatus("Rebuild complete — \(eventCount.formatted()) events", isRebuild: true)
    }
    host.flushPendingGeocodeEnqueues()
    }


    func finishEventSyncMaintenance() {
    sync {
        runPostSyncMaintenance()
    }
    host.flushPendingGeocodeEnqueues()
    }


    func clearAllEventDataPreservingLocations() {
    let sql = """
    DELETE FROM photo_events;
    DELETE FROM events;
    DELETE FROM sqlite_sequence WHERE name = 'events';
    UPDATE photos
    SET eventAssignedAt = NULL,
        eventNeedsReview = 0
    WHERE isDeleted = 0;
    """

    if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
        print("Failed clearing events for rebuild: \(String(cString: sqlite3_errmsg(db)))")
    }
    }


    func assignPhotosToEvents(
    _ photos: [EventCandidatePhoto],
    maxTouchedEvents: Int?,
    tryGPSMatch: Bool = true
    ) {
    let total = photos.count
    print("Event assignment starting (\(total.formatted()) photos in this batch)")

    if tryGPSMatch {
        loadHomeCandidatesCache()
    }
    defer { homeCandidatesCache = nil }

    var touchedEventIds = Set<Int>()
    var openTimeClusterEventId: Int?
    var openTimeClusterLastDate: Date?
    let timeClusterGap = host.eventTuningUnsafe().eventMatchMaxGapSeconds

    for (index, photo) in photos.enumerated() {
        if let maxTouchedEvents, touchedEventIds.count >= maxTouchedEvents {
            break
        }

        if tryGPSMatch, photo.latitude != nil, photo.longitude != nil {
            let eventId: Int?
            if let matchedId = findMatchingEvent(for: photo) {
                eventId = matchedId
            } else {
                let createdId = createEventFromPhoto(photo)
                eventId = createdId > 0 ? createdId : nil
            }

            if let eventId {
                events.attachPhotoToEvent(
                    photoId: photo.id,
                    eventId: eventId,
                    assignmentConfidence: 1.0,
                    assignmentMethod: .gpsMatch
                )
                events.markPhotoEventAssigned(photoId: photo.id)
                events.expandEventDatesAfterAttach(eventId: eventId, photoDate: photo.date)
                touchedEventIds.insert(eventId)
                openTimeClusterEventId = nil
                openTimeClusterLastDate = nil
            }
        } else if let eventId = assignPhotoToTimeCluster(
            photo,
            openEventId: openTimeClusterEventId,
            openLastDate: openTimeClusterLastDate,
            maxGapSeconds: timeClusterGap,
            touchedEventIds: &touchedEventIds
        ) {
            openTimeClusterEventId = eventId
            openTimeClusterLastDate = photo.date
        }

        if index == 0 || (index + 1) % 250 == 0 || index + 1 == total {
            let remainingGlobal = countUnassignedPhotosForEventsUnsafe()
            print(
                "Event assignment progress: \(index + 1)/\(total) in batch,"
                + " \(remainingGlobal.formatted()) unassigned overall"
            )
            postEventSyncProgress(
                processed: index + 1,
                total: total,
                remainingUnassigned: remainingGlobal,
                isRebuild: isRebuildContext
            )
        }
    }

    print("Event assignment batch complete: \(total.formatted()) photos processed")

    for eventId in touchedEventIds {
        events.updateEventSummary(eventId: eventId)
        host.updateCoverPhotoForEvent(eventId: eventId)
    }

    recordSyncTouchedEventIds(touchedEventIds)
    }


    func postEventSyncProgress(
    processed: Int,
    total: Int,
    remainingUnassigned: Int,
    isRebuild: Bool = false
    ) {
    let now = Date()
    let isFinalBatchUpdate = processed == total
    guard isFinalBatchUpdate
        || now.timeIntervalSince(lastProgressPost) >= 1.0 else {
        return
    }
    lastProgressPost = now

    let progress = EventSyncProgress(
        processed: processed,
        total: total,
        remainingUnassigned: remainingUnassigned,
        isRebuild: isRebuild
    )

    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .eventSyncProgressChanged,
            object: nil,
            userInfo: [
                "processed": processed,
                "total": total,
                "remainingUnassigned": remainingUnassigned,
                "isRebuild": isRebuild
            ]
        )
    }
    }


    func postEventSyncStatus(_ message: String, isRebuild: Bool = false, force: Bool = false) {
    let rebuild = isRebuild || isRebuildContext

    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .eventSyncProgressChanged,
            object: nil,
            userInfo: [
                "statusMessage": message,
                "forcePublish": force,
                "isRebuild": rebuild
            ]
        )
    }
    }


    func loadHomeCandidatesCache() {
    guard homeCandidatesCache == nil else { return }

    let sql = """
    SELECT latitude, longitude, isCurrentHome, homeStartDate, homeEndDate
    FROM locations
    WHERE latitude IS NOT NULL
      AND longitude IS NOT NULL
      AND (
            COALESCE(isCurrentHome, 0) = 1
            OR (
                homeStartDate IS NOT NULL
                AND homeEndDate IS NOT NULL
            )
      );
    """

    var statement: OpaquePointer?
    var candidates: [CachedHomeCandidate] = []

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
            let homeStartDate: String? =
                sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(statement, 3))

            let homeEndDate: String? =
                sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(statement, 4))

            candidates.append(
                CachedHomeCandidate(
                    latitude: sqlite3_column_double(statement, 0),
                    longitude: sqlite3_column_double(statement, 1),
                    isCurrentHome: sqlite3_column_int(statement, 2) == 1,
                    homeStartDate: homeStartDate,
                    homeEndDate: homeEndDate
                )
            )
        }
    }

    sqlite3_finalize(statement)
    homeCandidatesCache = candidates
    }


    func runPostSyncMaintenance() {
    refreshAllEventLocationLinks()

    postEventSyncStatus("Joining no-GPS photos to same-day events…")
    mergeTimeOnlyEventsIntoSameDayLocatedEvents()

    postEventSyncStatus("Merging nearby events…")

    mergeNearbyEventsSameDay(maxDistanceMiles: host.eventTuningUnsafe().sameDayEventMergeMiles)

    postEventSyncStatus("Merging trip events…")
    mergeAwayTripEvents()

    postEventSyncStatus("Building trip sub-events…")
    materializeTripSubEventsForAllCandidates()

    postEventSyncStatus("Deduplicating locations…")
    var mergedLocations = 0
    for _ in 0..<4 {
        let passMerged = host.mergeDuplicateLocations(
            proximityMiles: nil,
            samePlaceNameMiles: nil,
            frequentPlaceMiles: nil,
            frequentPlaceMinEvents: nil
        )
        mergedLocations += passMerged
        if passMerged == 0 {
            break
        }
    }

    let addressMerged = host.deduplicateLocationsByAddressUnsafe(
        maxDistanceMiles: host.eventTuningUnsafe().addressDeduplicationMaxMiles
    )
    mergedLocations += addressMerged

    if mergedLocations > 0 {
        print("Merged \(mergedLocations) duplicate location rows")
    }

    host.mergeNearbyLocationsIntoCurrentHome()
    host.snapEventsNearDesignatedHomesUnsafe()

    postEventSyncStatus("Cleaning up events…")
    events.restoreDeletedTripContainers()
    events.cleanupEmptyEvents()

    postEventSyncStatus("Updating cover photos…")
    events.updateAllEventCoverPhotosUnsafe()

    if events.eventDateDiagnosticCounts().needsRepair {
        events.repairEventDateSummaries()
    }

    syncSessionTouchedEventIds.removeAll()
    }


    func refreshAllEventLocationLinks() {
    let sql = """
    SELECT eventId
    FROM events
    WHERE isDeleted = 0
      AND parentEventId IS NULL
    ORDER BY eventId ASC;
    """

    var statement: OpaquePointer?
    var eventIds: [Int] = []

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
            eventIds.append(Int(sqlite3_column_int(statement, 0)))
        }
    }

    sqlite3_finalize(statement)

    guard !eventIds.isEmpty else { return }

    postEventSyncStatus("Linking event locations…")

    for (index, eventId) in eventIds.enumerated() {
        host.updateEventLocationFromRepresentativePoint(eventId: eventId)

        if index == 0 || (index + 1) % 500 == 0 || index + 1 == eventIds.count {
            postEventSyncStatus(
                "Linking event locations… \(index + 1)/\(eventIds.count)"
            )
        }
    }
    }


    func getAllPhotosForEventAssignment() -> [EventCandidatePhoto] {
    let sql = """
    SELECT id,
           COALESCE(captureDateOverride, creationDate) AS effectiveDate,
           COALESCE(userLatitude, latitude) AS effectiveLatitude,
           COALESCE(userLongitude, longitude) AS effectiveLongitude
    FROM photos
    WHERE isDeleted = 0
      AND isScreenshot = 0
      AND COALESCE(userLatitude, latitude) IS NOT NULL
      AND COALESCE(userLongitude, longitude) IS NOT NULL
    ORDER BY effectiveDate ASC;
    """

    var statement: OpaquePointer?
    var photos: [EventCandidatePhoto] = []

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let dateString = String(cString: sqlite3_column_text(statement, 1))
            let latitude = sqlite3_column_double(statement, 2)
            let longitude = sqlite3_column_double(statement, 3)

            if let date = iso8601Formatter.date(from: dateString) {
                photos.append(
                    EventCandidatePhoto(
                        id: id,
                        date: date,
                        latitude: latitude,
                        longitude: longitude
                    )
                )
            }
        }
    } else {
        print("Failed to get photos for rebuild: \(String(cString: sqlite3_errmsg(db)))")
    }

    sqlite3_finalize(statement)
    return photos
    }


    func findMatchingEvent(for photo: EventCandidatePhoto) -> Int? {
    guard let photoLatitude = photo.latitude,
          let photoLongitude = photo.longitude else {
        return nil
    }

    let maxDistanceMiles = matchingDistanceMiles(
        latitude: photoLatitude,
        longitude: photoLongitude,
        at: photo.date
    )

    let latDelta = maxDistanceMiles / 69.0
    let lonDelta = maxDistanceMiles / max(0.2, 69.0 * cos(photoLatitude * .pi / 180.0))

    let windowStart = iso8601Formatter.string(
        from: photo.date.addingTimeInterval(-host.eventTuningUnsafe().eventMatchMaxGapSeconds)
    )
    let windowEnd = iso8601Formatter.string(
        from: photo.date.addingTimeInterval(host.eventTuningUnsafe().eventMatchMaxGapSeconds)
    )

    let sql = """
    SELECT eventId, startDate, endDate, latitude, longitude
    FROM events
    WHERE isDeleted = 0
      AND latitude IS NOT NULL
      AND longitude IS NOT NULL
      AND parentEventId IS NULL
      AND startDate <= ?
      AND endDate >= ?
      AND latitude BETWEEN ? AND ?
      AND longitude BETWEEN ? AND ?;
    """

    var statement: OpaquePointer?
    var bestEventId: Int?
    var bestScore = Double.greatestFiniteMagnitude

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, (windowEnd as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (windowStart as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 3, photoLatitude - latDelta)
        sqlite3_bind_double(statement, 4, photoLatitude + latDelta)
        sqlite3_bind_double(statement, 5, photoLongitude - lonDelta)
        sqlite3_bind_double(statement, 6, photoLongitude + lonDelta)

        while sqlite3_step(statement) == SQLITE_ROW {
            let eventId = Int(sqlite3_column_int(statement, 0))
            let startString = String(cString: sqlite3_column_text(statement, 1))
            let endString = String(cString: sqlite3_column_text(statement, 2))
            let eventLatitude = sqlite3_column_double(statement, 3)
            let eventLongitude = sqlite3_column_double(statement, 4)

            guard let startDate = iso8601Formatter.date(from: startString),
                  let endDate = iso8601Formatter.date(from: endString) else {
                continue
            }

            let timeGap: TimeInterval

            if photo.date >= startDate && photo.date <= endDate {
                timeGap = 0
            } else {
                timeGap = min(
                    abs(photo.date.timeIntervalSince(startDate)),
                    abs(photo.date.timeIntervalSince(endDate))
                )
            }

            guard timeGap <= host.eventTuningUnsafe().eventMatchMaxGapSeconds else { continue }

            let distance = host.distanceInMiles(
                lat1: photoLatitude,
                lon1: photoLongitude,
                lat2: eventLatitude,
                lon2: eventLongitude
            )

            guard distance <= maxDistanceMiles else { continue }

            let score = timeGap + (distance * host.eventTuningUnsafe().eventMatchDistanceWeight)

            if score < bestScore {
                bestScore = score
                bestEventId = eventId
            }
        }
    } else {
        print("Failed to find matching event: \(String(cString: sqlite3_errmsg(db)))")
    }

    sqlite3_finalize(statement)
    return bestEventId
    }


    func createEventFromPhoto(_ photo: EventCandidatePhoto) -> Int {
    let dateString = iso8601Formatter.string(from: photo.date)
    let name = displayDateFormatter.string(from: photo.date)

    let locationId: Int?

    if let latitude = photo.latitude,
       let longitude = photo.longitude {
        locationId = host.findOrCreateLocation(
            latitude: latitude,
            longitude: longitude,
            at: photo.date
        )
    } else {
        locationId = nil
    }

    return events.insertEventRow(
        name: name,
        startDate: dateString,
        endDate: dateString,
        latitude: photo.latitude,
        longitude: photo.longitude,
        locationId: locationId
    )
    }


    func saveEvent(
    photos: [(id: String, date: Date, latitude: Double?, longitude: Double?)]
    ) {
    guard let first = photos.first,
          let last = photos.last else { return }

    let isoFormatter = ISO8601DateFormatter()
    let startDate = isoFormatter.string(from: first.date)
    let endDate = isoFormatter.string(from: last.date)

    let displayFormatter = DateFormatter()
    displayFormatter.dateStyle = .medium

    let startText = displayFormatter.string(from: first.date)
    let endText = displayFormatter.string(from: last.date)

    let name: String =
        Calendar.current.isDate(first.date, inSameDayAs: last.date)
        ? startText
        : "\(startText) - \(endText)"

    let photosWithLocation = photos.filter {
        $0.latitude != nil && $0.longitude != nil
    }

    let eventLatitude: Double?
    let eventLongitude: Double?

    if photosWithLocation.isEmpty {
        eventLatitude = nil
        eventLongitude = nil
    } else {
        eventLatitude =
            photosWithLocation.compactMap { $0.latitude }.reduce(0, +) /
            Double(photosWithLocation.count)

        eventLongitude =
            photosWithLocation.compactMap { $0.longitude }.reduce(0, +) /
            Double(photosWithLocation.count)
    }

    let locationId: Int?

    if let eventLatitude = eventLatitude,
       let eventLongitude = eventLongitude {
        locationId = host.findOrCreateLocation(
            latitude: eventLatitude,
            longitude: eventLongitude,
            at: first.date
        )
        print("Creating location for event lat/lon: \(eventLatitude), \(eventLongitude)")

    } else {
        locationId = nil
    }

    let insertEventSQL = """
    INSERT INTO events
    (
        name, startDate, endDate, latitude, longitude,
        city, state, placeName, locationId
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
    """


    var eventStatement: OpaquePointer?

    if sqlite3_prepare_v2(db, insertEventSQL, -1, &eventStatement, nil) == SQLITE_OK {
        sqlite3_bind_text(eventStatement, 1, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(eventStatement, 2, (startDate as NSString).utf8String, -1, nil)
        sqlite3_bind_text(eventStatement, 3, (endDate as NSString).utf8String, -1, nil)

        if let eventLatitude = eventLatitude {
            sqlite3_bind_double(eventStatement, 4, eventLatitude)
        } else {
            sqlite3_bind_null(eventStatement, 4)
        }

        if let eventLongitude = eventLongitude {
            sqlite3_bind_double(eventStatement, 5, eventLongitude)
        } else {
            sqlite3_bind_null(eventStatement, 5)
        }

        sqlite3_bind_null(eventStatement, 6)
        sqlite3_bind_null(eventStatement, 7)
        sqlite3_bind_null(eventStatement, 8)

        if let locationId = locationId, locationId > 0 {
            sqlite3_bind_int(eventStatement, 9, Int32(locationId))
        } else {
            sqlite3_bind_null(eventStatement, 9)
        }

        if sqlite3_step(eventStatement) != SQLITE_DONE {
            print("Failed to insert event: \(String(cString: sqlite3_errmsg(db)))")
        }
    } else {
        print("Failed to prepare event insert: \(String(cString: sqlite3_errmsg(db)))")
    }

    sqlite3_finalize(eventStatement)

    let eventId = Int(sqlite3_last_insert_rowid(db))

    for photo in photos {
        let insertLinkSQL = """
        INSERT INTO photo_events (photoId, eventId)
        VALUES (?, ?);
        """

        var linkStatement: OpaquePointer?

        if sqlite3_prepare_v2(db, insertLinkSQL, -1, &linkStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(linkStatement, 1, (photo.id as NSString).utf8String, -1, nil)
            sqlite3_bind_int(linkStatement, 2, Int32(eventId))

            if sqlite3_step(linkStatement) != SQLITE_DONE {
                print("Failed to link photo to event: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(linkStatement)
    }


    }


    private func fetchEventsForMerge() -> [EventMergeCandidate] {
    let sql = """
    SELECT eventId, startDate, endDate, latitude, longitude, photoCount
    FROM events
    WHERE isDeleted = 0
      AND latitude IS NOT NULL
      AND longitude IS NOT NULL
      AND photoCount > 0
      AND parentEventId IS NULL
      AND COALESCE(isTripEvent, 0) = 0;
    """

    var statement: OpaquePointer?
    var events: [EventMergeCandidate] = []
    let formatter = ISO8601DateFormatter()

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
            let eventId = Int(sqlite3_column_int(statement, 0))
            let startString = String(cString: sqlite3_column_text(statement, 1))
            let endString = String(cString: sqlite3_column_text(statement, 2))
            let latitude = sqlite3_column_double(statement, 3)
            let longitude = sqlite3_column_double(statement, 4)
            let photoCount = Int(sqlite3_column_int(statement, 5))

            guard let startDate = formatter.date(from: startString),
                  let endDate = formatter.date(from: endString) else { continue }

            events.append(
                EventMergeCandidate(
                    eventId: eventId,
                    startDate: startDate,
                    endDate: endDate,
                    latitude: latitude,
                    longitude: longitude,
                    photoCount: photoCount
                )
            )
        }
    }

    sqlite3_finalize(statement)
    return events
    }


    func mergePhotos(from secondaryEventId: Int, into primaryEventId: Int) {
    let sql = """
    INSERT OR IGNORE INTO photo_events (photoId, eventId)
    SELECT photoId, ?
    FROM photo_events
    WHERE eventId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(primaryEventId))
        sqlite3_bind_int(statement, 2, Int32(secondaryEventId))
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)

    let deleteSQL = """
    DELETE FROM photo_events
    WHERE eventId = ?;
    """

    if sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(secondaryEventId))
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)
    }


    func softDeleteEvent(eventId: Int) {
    let now = ISO8601DateFormatter().string(from: Date())

    let sql = """
    UPDATE events
    SET isDeleted = 1,
        deletedAt = ?,
        updatedAt = ?
    WHERE eventId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 3, Int32(eventId))
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)
    }


    func clearEventLocationFields(eventId: Int) {
    let sql = """
    UPDATE events
    SET city = NULL,
        state = NULL,
        placeName = NULL
    WHERE eventId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(eventId))
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)
    }

    /// Runs the same-day join on its own, so Sync Events can fold existing no-GPS events
    /// without the full trip and location maintenance pass.
    func joinTimeOnlyEventsToSameDayLocatedEvents() {
        sync {
            mergeTimeOnlyEventsIntoSameDayLocatedEvents()
        }
    }

    /// Folds automatic no-GPS events into the GPS event on the same local day.
    /// A renamed time-only event is left as the user arranged it.
    private func mergeTimeOnlyEventsIntoSameDayLocatedEvents() {
        let sql = """
        SELECT eventId, startDate
        FROM events
        WHERE isDeleted = 0
          AND COALESCE(clusteredByTimeOnly, 0) = 1
          AND COALESCE(userEditedName, 0) = 0
          AND COALESCE(isUserHidden, 0) = 0
          AND parentEventId IS NULL
          AND TRIM(COALESCE(startDate, '')) != '';
        """

        var statement: OpaquePointer?
        var sources: [(eventId: Int, startDate: Date)] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let eventId = Int(sqlite3_column_int(statement, 0))
                guard let startCString = sqlite3_column_text(statement, 1) else { continue }
                let startString = String(cString: startCString)
                guard let startDate = iso8601Formatter.date(from: startString) else {
                    continue
                }
                sources.append((eventId, startDate))
            }
        } else {
            print(
                "Failed to list time-only events: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
        sqlite3_finalize(statement)

        let total = sources.count
        guard total > 0 else {
            postEventSyncStatus("No separate no-GPS events to join", force: true)
            return
        }

        postEventSyncStatus(
            "Joining no-GPS events… 0 of \(total.formatted())",
            force: true
        )
        if sameDayLocatedEventCache == nil {
            sameDayLocatedEventCache = events.fetchSameDayLocatedEvents()
        }
        let locatedEvents = sameDayLocatedEventCache ?? []

        var merged = 0
        var touched = Set<Int>()

        for (index, source) in sources.enumerated() {
            let checked = index + 1
            if checked == 1 || checked == total || checked % 25 == 0 {
                postEventSyncStatus(
                    "Joining no-GPS events… \(checked.formatted()) of \(total.formatted())",
                    force: true
                )
            }

            guard let targetId = events.bestSameDayLocatedEvent(
                photoDate: source.startDate,
                in: locatedEvents
            ),
                  targetId != source.eventId else {
                continue
            }

            mergePhotos(from: source.eventId, into: targetId)
            softDeleteEvent(eventId: source.eventId)
            touched.insert(targetId)
            merged += 1
        }

        for (index, eventId) in touched.enumerated() {
            events.updateEventSummary(eventId: eventId)
            let updated = index + 1
            postEventSyncStatus(
                "Updating events… \(updated.formatted()) of \(touched.count.formatted())",
                force: updated == touched.count
            )
        }

        let finished = "Joined \(merged.formatted()) of \(total.formatted()) no-GPS events"
        postEventSyncStatus(finished, force: true)
        print(finished)
    }

    private func sameDayLocatedEventId(for date: Date) -> Int? {
        if sameDayLocatedEventCache == nil {
            sameDayLocatedEventCache = events.fetchSameDayLocatedEvents()
        }
        return events.bestSameDayLocatedEvent(
            photoDate: date,
            in: sameDayLocatedEventCache ?? []
        )
    }


    func mergeNearbyEventsSameDay(maxDistanceMiles: Double) {
    var candidates = fetchEventsForMerge()
    guard candidates.count > 1 else { return }

    candidates.sort { $0.photoCount > $1.photoCount }

    var mergedEventIds = Set<Int>()
    var updatedPrimaryIds = Set<Int>()

    for i in 0..<candidates.count {
        let primary = candidates[i]
        if mergedEventIds.contains(primary.eventId) { continue }

        for j in (i + 1)..<candidates.count {
            let secondary = candidates[j]
            if mergedEventIds.contains(secondary.eventId) { continue }

            guard Calendar.current.isDate(
                primary.startDate,
                inSameDayAs: secondary.startDate
            ) else {
                continue
            }

            let distance = host.distanceInMiles(
                lat1: primary.latitude,
                lon1: primary.longitude,
                lat2: secondary.latitude,
                lon2: secondary.longitude
            )

            guard distance <= maxDistanceMiles else { continue }

            if isAwayFromHome(
                latitude: primary.latitude,
                longitude: primary.longitude,
                at: primary.startDate
            ) || isAwayFromHome(
                latitude: secondary.latitude,
                longitude: secondary.longitude,
                at: secondary.startDate
            ) {
                continue
            }

            mergePhotos(from: secondary.eventId, into: primary.eventId)
            softDeleteEvent(eventId: secondary.eventId)
            mergedEventIds.insert(secondary.eventId)
            updatedPrimaryIds.insert(primary.eventId)

            print(
                "Merged event \(secondary.eventId) into \(primary.eventId) (\(String(format: "%.2f", distance)) mi apart)"
            )
        }
    }

    for eventId in updatedPrimaryIds {
        events.updateEventSummary(eventId: eventId)
        host.updateCoverPhotoForEvent(eventId: eventId)
        host.updateEventLocationFromRepresentativePoint(eventId: eventId)
    }
    }

    /// Collapse rows that geocode to the same street address within `addressDeduplicationMaxMiles`.
    @discardableResult

    private func fetchTripMergeCandidates() -> [TripMergeCandidate] {
    let sql = """
    SELECT eventId, startDate, endDate, latitude, longitude, photoCount
    FROM events
    WHERE isDeleted = 0
      AND latitude IS NOT NULL
      AND longitude IS NOT NULL
      AND photoCount > 0
      AND parentEventId IS NULL
      AND COALESCE(isTripEvent, 0) = 0;
    """

    var statement: OpaquePointer?
    var events: [TripMergeCandidate] = []
    let formatter = ISO8601DateFormatter()

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
            let eventId = Int(sqlite3_column_int(statement, 0))
            let startString = String(cString: sqlite3_column_text(statement, 1))
            let endString = String(cString: sqlite3_column_text(statement, 2))
            let latitude = sqlite3_column_double(statement, 3)
            let longitude = sqlite3_column_double(statement, 4)
            let photoCount = Int(sqlite3_column_int(statement, 5))

            guard let startDate = formatter.date(from: startString) else { continue }

            let endDate = formatter.date(from: endString) ?? startDate

            guard isAwayFromHome(
                latitude: latitude,
                longitude: longitude,
                at: startDate
            ) else {
                continue
            }

            events.append(
                TripMergeCandidate(
                    eventId: eventId,
                    startDate: startDate,
                    endDate: endDate,
                    latitude: latitude,
                    longitude: longitude,
                    photoCount: photoCount
                )
            )
        }
    }

    sqlite3_finalize(statement)
    return events
    }


    /// Future: merge contiguous day events that share the same user-set manual city/state into a trip container.
    func mergeTripsByUserManualLocation() {
        // Requires UI to set events.userManualCity / userManualState, then cluster by date gap + location.
    }

    func mergeAwayTripEvents() {
    var candidates = fetchTripMergeCandidates()
    guard candidates.count > 1 else { return }

    candidates.sort { $0.photoCount > $1.photoCount }

    var parent = Array(0..<candidates.count)

    func find(_ index: Int) -> Int {
        if parent[index] != index {
            parent[index] = find(parent[index])
        }
        return parent[index]
    }

    func union(_ left: Int, _ right: Int) {
        let rootLeft = find(left)
        let rootRight = find(right)
        if rootLeft != rootRight {
            parent[rootRight] = rootLeft
        }
    }

    for left in 0..<candidates.count {
        for right in (left + 1)..<candidates.count {
            let distance = host.distanceInMiles(
                lat1: candidates[left].latitude,
                lon1: candidates[left].longitude,
                lat2: candidates[right].latitude,
                lon2: candidates[right].longitude
            )

            guard distance <= host.eventTuningUnsafe().tripEventMatchMiles,
                  tripDateRangesCanMerge(candidates[left], candidates[right]) else {
                continue
            }

            union(left, right)
        }
    }

    var clusters: [Int: [Int]] = [:]
    for index in candidates.indices {
        clusters[find(index), default: []].append(index)
    }

    for clusterIndices in clusters.values where clusterIndices.count > 1 {
        let canonicalIndex = clusterIndices.max {
            candidates[$0].photoCount < candidates[$1].photoCount
        }!
        let primary = candidates[canonicalIndex]

        for index in clusterIndices where index != canonicalIndex {
            let secondary = candidates[index]
            mergePhotos(from: secondary.eventId, into: primary.eventId)
            softDeleteEvent(eventId: secondary.eventId)
        }

        markEventAsTripContainer(eventId: primary.eventId)
        events.updateEventSummary(eventId: primary.eventId)
        host.updateCoverPhotoForEvent(eventId: primary.eventId)
        host.updateEventLocationFromRepresentativePoint(eventId: primary.eventId)

        print("Merged away trip cluster into event \(primary.eventId)")
    }
    }


    func materializeTripSubEventsForAllCandidates() {
    let sql = """
    SELECT eventId
    FROM events
    WHERE isDeleted = 0
      AND parentEventId IS NULL
      AND COALESCE(isTripEvent, 0) = 1;
    """

    var statement: OpaquePointer?
    var tripEventIds: [Int] = []

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
            tripEventIds.append(Int(sqlite3_column_int(statement, 0)))
        }
    }

    sqlite3_finalize(statement)

    for eventId in tripEventIds {
        materializeTripSubEvents(parentEventId: eventId)
    }

    let candidateSQL = """
    SELECT eventId
    FROM events
    WHERE isDeleted = 0
      AND parentEventId IS NULL
      AND COALESCE(isTripEvent, 0) = 0
      AND photoCount > 0
      AND latitude IS NOT NULL
      AND longitude IS NOT NULL;
    """

    if sqlite3_prepare_v2(db, candidateSQL, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
            let eventId = Int(sqlite3_column_int(statement, 0))
            guard shouldPromoteToTripContainer(eventId: eventId) else { continue }

            markEventAsTripContainer(eventId: eventId)
            materializeTripSubEvents(parentEventId: eventId)
        }
    }

    sqlite3_finalize(statement)
    }


    func shouldPromoteToTripContainer(eventId: Int) -> Bool {
    guard let event = host.getEvent(eventId: eventId),
          let latitude = event.latitude,
          let longitude = event.longitude,
          isAwayFromHome(
            latitude: latitude,
            longitude: longitude,
            at: EventDateParser.parseDate(event.startDate) ?? Date()
          ) else {
        return false
    }

    guard let start = EventDateParser.parseDate(event.startDate),
          let end = EventDateParser.parseDate(event.endDate) else {
        return false
    }

    let spanDays = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
    return spanDays >= 1 && event.photoCount >= 4
    }


    func markEventAsTripContainer(eventId: Int) {
    let sql = """
    UPDATE events
    SET isTripEvent = 1
    WHERE eventId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(eventId))
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)
    }


    func softDeleteTripSubEvents(parentEventId: Int) {
    let sql = """
    SELECT eventId
    FROM events
    WHERE parentEventId = ?
      AND isDeleted = 0;
    """

    var statement: OpaquePointer?
    var subEventIds: [Int] = []

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(parentEventId))

        while sqlite3_step(statement) == SQLITE_ROW {
            subEventIds.append(Int(sqlite3_column_int(statement, 0)))
        }
    }

    sqlite3_finalize(statement)

    for subEventId in subEventIds {
        mergePhotos(from: subEventId, into: parentEventId)
        softDeleteEvent(eventId: subEventId)
    }
    }


    private func collectPhotosForTripSplit(parentEventId: Int) -> [TripPhotoRecord] {
    let sql = """
    SELECT p.id, p.creationDate, p.latitude, p.longitude
    FROM photos p
    JOIN photo_events pe ON p.id = pe.photoId
    JOIN events e ON pe.eventId = e.eventId
    WHERE p.isDeleted = 0
      AND (e.eventId = ? OR e.parentEventId = ?)
    ORDER BY p.creationDate ASC;
    """

    var statement: OpaquePointer?
    var photos: [TripPhotoRecord] = []
    let formatter = ISO8601DateFormatter()

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(parentEventId))
        sqlite3_bind_int(statement, 2, Int32(parentEventId))

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let dateString = String(cString: sqlite3_column_text(statement, 1))

            let latitude: Double? =
                sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 2)

            let longitude: Double? =
                sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 3)

            guard let date = formatter.date(from: dateString) else { continue }

            photos.append(
                TripPhotoRecord(
                    id: id,
                    date: date,
                    latitude: latitude,
                    longitude: longitude
                )
            )
        }
    }

    sqlite3_finalize(statement)
    return photos
    }


    func materializeTripSubEvents(parentEventId: Int) {
    let photos = collectPhotosForTripSplit(parentEventId: parentEventId)
    guard photos.count >= 4 else { return }

    softDeleteTripSubEvents(parentEventId: parentEventId)

    var clusters: [[TripPhotoRecord]] = []
    var currentCluster: [TripPhotoRecord] = []

    for photo in photos {
        if currentCluster.isEmpty {
            currentCluster = [photo]
            continue
        }

        let last = currentCluster.last!
        let timeGap = abs(photo.date.timeIntervalSince(last.date))
        let distance: Double

        if let lat1 = photo.latitude,
           let lon1 = photo.longitude,
           let lat2 = last.latitude,
           let lon2 = last.longitude {
            distance = host.distanceInMiles(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
        } else {
            distance = 0
        }

        let sameDay = Calendar.current.isDate(photo.date, inSameDayAs: last.date)
        let continuesCluster = sameDay
            && timeGap <= host.eventTuningUnsafe().tripSubEventMaxGapSeconds
            && distance <= host.eventTuningUnsafe().tripSubEventMatchMiles

        if continuesCluster {
            currentCluster.append(photo)
        } else {
            clusters.append(currentCluster)
            currentCluster = [photo]
        }
    }

    if !currentCluster.isEmpty {
        clusters.append(currentCluster)
    }

    guard clusters.count >= 2 else { return }

    for cluster in clusters {
        guard let subEventId = createTripSubEvent(
            parentEventId: parentEventId,
            photos: cluster
        ) else {
            continue
        }

        for photo in cluster {
            movePhoto(photoId: photo.id, toEventId: subEventId)
        }

        events.updateEventSummary(eventId: subEventId)
        host.updateCoverPhotoForEvent(eventId: subEventId)
        host.updateEventLocationFromRepresentativePoint(eventId: subEventId)
    }

    events.updateTripParentSummary(parentEventId: parentEventId)
    }


    private func createTripSubEvent(
    parentEventId: Int,
    photos: [TripPhotoRecord]
    ) -> Int? {
    guard let first = photos.first, let last = photos.last else { return nil }

    let formatter = ISO8601DateFormatter()
    let startDate = formatter.string(from: first.date)
    let endDate = formatter.string(from: last.date)
    let now = formatter.string(from: Date())

    let locationId: Int?
    if let latitude = first.latitude, let longitude = first.longitude {
        locationId = host.findOrCreateLocation(
            latitude: latitude,
            longitude: longitude,
            at: first.date
        )
    } else {
        locationId = nil
    }

    let displayFormatter = DateFormatter()
    displayFormatter.dateStyle = .medium
    let name = displayFormatter.string(from: first.date)

    let sql = """
    INSERT INTO events
    (
        name, startDate, endDate, latitude, longitude,
        locationId, parentEventId, isTripEvent,
        isDeleted, updatedAt, photoCount
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, 0);
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (startDate as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (endDate as NSString).utf8String, -1, nil)

        if let latitude = first.latitude {
            sqlite3_bind_double(statement, 4, latitude)
        } else {
            sqlite3_bind_null(statement, 4)
        }

        if let longitude = first.longitude {
            sqlite3_bind_double(statement, 5, longitude)
        } else {
            sqlite3_bind_null(statement, 5)
        }

        if let locationId, locationId > 0 {
            sqlite3_bind_int(statement, 6, Int32(locationId))
        } else {
            sqlite3_bind_null(statement, 6)
        }

        sqlite3_bind_int(statement, 7, Int32(parentEventId))
        sqlite3_bind_text(statement, 8, (now as NSString).utf8String, -1, nil)

        if sqlite3_step(statement) != SQLITE_DONE {
            sqlite3_finalize(statement)
            return nil
        }
    } else {
        sqlite3_finalize(statement)
        return nil
    }

    sqlite3_finalize(statement)
    return Int(sqlite3_last_insert_rowid(db))
    }


    func movePhoto(photoId: String, toEventId: Int) {
    let deleteSQL = """
    DELETE FROM photo_events
    WHERE photoId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)

    events.attachPhotoToEvent(photoId: photoId, eventId: toEventId)
    }


    private func getHomeCoordinates(at date: Date = Date()) -> (latitude: Double, longitude: Double)? {
    if homeCandidatesCache == nil {
        loadHomeCandidatesCache()
    }

    return resolveHomeCoordinates(from: homeCandidatesCache ?? [], at: date)
    }


    private func resolveHomeCoordinates(
    from candidates: [CachedHomeCandidate],
    at date: Date
    ) -> (latitude: Double, longitude: Double)? {
    let day = Calendar.current.startOfDay(for: date)

    let formerMatches = candidates.filter { candidate in
        guard !candidate.isCurrentHome,
              let start = EventDateParser.parseDate(candidate.homeStartDate ?? ""),
              let end = EventDateParser.parseDate(candidate.homeEndDate ?? "") else {
            return false
        }

        let startDay = Calendar.current.startOfDay(for: start)
        let endDay = Calendar.current.startOfDay(for: end)
        return day >= startDay && day <= endDay
    }

    if let former = formerMatches.sorted(by: {
        let leftStart = EventDateParser.parseDate($0.homeStartDate ?? "") ?? .distantPast
        let rightStart = EventDateParser.parseDate($1.homeStartDate ?? "") ?? .distantPast
        return leftStart > rightStart
    }).first {
        return (former.latitude, former.longitude)
    }

    if let current = candidates.first(where: { $0.isCurrentHome }) {
        if let startISO = current.homeStartDate,
           let start = EventDateParser.parseDate(startISO) {
            let startDay = Calendar.current.startOfDay(for: start)
            guard day >= startDay else { return nil }
        }
        return (current.latitude, current.longitude)
    }

    return nil
    }


    func isAwayFromHome(
    latitude: Double,
    longitude: Double,
    at date: Date = Date()
    ) -> Bool {
    guard let home = getHomeCoordinates(at: date) else { return false }

    return host.distanceInMiles(
        lat1: latitude,
        lon1: longitude,
        lat2: home.latitude,
        lon2: home.longitude
    ) >= host.eventTuningUnsafe().awayFromHomeMiles
    }


    func matchingDistanceMiles(
    latitude: Double,
    longitude: Double,
    at date: Date = Date()
    ) -> Double {
    isAwayFromHome(latitude: latitude, longitude: longitude, at: date)
        ? host.eventTuningUnsafe().tripEventMatchMiles
        : host.eventTuningUnsafe().localEventMatchMiles
    }


    private func tripDateRangesCanMerge(_ left: TripMergeCandidate, _ right: TripMergeCandidate) -> Bool {
    let gap = min(
        abs(left.endDate.timeIntervalSince(right.startDate)),
        abs(right.endDate.timeIntervalSince(left.startDate))
    )
    return gap <= host.eventTuningUnsafe().tripMergeMaxGapSeconds
    }

}

extension PhotoDatabase: EventClusteringHost {}
