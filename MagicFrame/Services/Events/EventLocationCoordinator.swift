import Foundation
import SQLite3

/// Assigns event location rows from photo clusters and relinks near-home events.
final class EventLocationCoordinator {

    private let database: DatabaseManager
    private let locations: LocationRepository
    private let events: EventRepository
    private let geocodeQueue: LocationGeocodePendingQueue
    private let eventTuning: () -> EventTuningSettings

    private let iso8601Formatter = ISO8601DateFormatter()

    init(
        database: DatabaseManager,
        locations: LocationRepository,
        events: EventRepository,
        geocodeQueue: LocationGeocodePendingQueue,
        eventTuning: @escaping () -> EventTuningSettings
    ) {
        self.database = database
        self.locations = locations
        self.events = events
        self.geocodeQueue = geocodeQueue
        self.eventTuning = eventTuning
    }

    func snapEventsNearDesignatedHomesUnsafe() {
        guard let home = locations.getCurrentHomeLocation(),
              let homeLatitude = home.latitude,
              let homeLongitude = home.longitude else {
            return
        }

        guard let db = database.connection else { return }

        let sql = """
        SELECT eventId, latitude, longitude, startDate, locationId
        FROM events
        WHERE isDeleted = 0
          AND latitude IS NOT NULL
          AND longitude IS NOT NULL;
        """

        var statement: OpaquePointer?
        var relinked = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let eventId = Int(sqlite3_column_int(statement, 0))
                let storedLatitude = sqlite3_column_double(statement, 1)
                let storedLongitude = sqlite3_column_double(statement, 2)
                let startString = String(cString: sqlite3_column_text(statement, 3))
                let currentLocationId =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(statement, 4))

                guard let eventDate = iso8601Formatter.date(from: startString) else {
                    continue
                }

                let distanceFromHome = locations.distanceInMiles(
                    lat1: storedLatitude,
                    lon1: storedLongitude,
                    lat2: homeLatitude,
                    lon2: homeLongitude
                )

                guard distanceFromHome <= eventTuning().homeEventSnapMiles else { continue }

                guard let homeLocationId = homeLocationIdForEvent(
                    eventId: eventId,
                    storedLatitude: storedLatitude,
                    storedLongitude: storedLongitude,
                    at: eventDate
                ) else {
                    continue
                }

                guard currentLocationId != homeLocationId else { continue }

                events.setEventLocationId(eventId: eventId, locationId: homeLocationId)
                events.clearEventLocationFields(eventId: eventId)
                events.updateEventsFromLocation(locationId: homeLocationId)
                relinked += 1
            }
        }

        sqlite3_finalize(statement)

        if relinked > 0 {
            print("Relinked \(relinked) home events to designated home location")
        }
    }

    func updateEventLocationFromRepresentativePoint(eventId: Int) {
        guard let coordinates = representativeCoordinatesForEvent(eventId: eventId) else {
            return
        }

        let previousLocationId = getEventLocationId(eventId: eventId)
        let eventDate = locations.getEventStartDate(eventId: eventId) ?? Date()
        let locationId = locations.findOrCreateLocation(
            latitude: coordinates.latitude,
            longitude: coordinates.longitude,
            at: eventDate
        )

        guard locationId > 0 else { return }

        events.setEventLocationId(eventId: eventId, locationId: locationId)
        events.setEventCentroid(
            eventId: eventId,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude,
            clearTimeOnlyFlag: true
        )
        events.clearEventLocationFields(eventId: eventId)

        if previousLocationId == locationId,
           locations.isLocationGeocodeComplete(locationId: locationId) {
            return
        }

        if previousLocationId == locationId,
           !locations.isLocationGeocodeComplete(locationId: locationId) {
            geocodeQueue.requestFreshGeocode(
                locationId: locationId,
                latitude: coordinates.latitude,
                longitude: coordinates.longitude
            )
            return
        }

        locations.resetLocationForGeocoding(
            locationId: locationId,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude
        )
        geocodeQueue.requestFreshGeocode(
            locationId: locationId,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude
        )

        syncDefaultChildEventNameIfSubEvent(eventId: eventId)
    }

    /// Sets the event place from its photos. A place that is already geocoded keeps its city, state, and place name.
    func assignEventLocationKeepingCompletedPlace(eventId: Int) {
        guard let coordinates = representativeCoordinatesForEvent(eventId: eventId) else {
            return
        }

        let eventDate = locations.getEventStartDate(eventId: eventId) ?? Date()
        let locationId = locations.findOrCreateLocation(
            latitude: coordinates.latitude,
            longitude: coordinates.longitude,
            at: eventDate
        )
        guard locationId > 0 else { return }

        events.setEventLocationId(eventId: eventId, locationId: locationId)
        events.setEventCentroid(
            eventId: eventId,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude,
            clearTimeOnlyFlag: true
        )
        events.clearEventLocationFields(eventId: eventId)

        guard !locations.isLocationGeocodeComplete(locationId: locationId) else { return }

        locations.resetLocationForGeocoding(
            locationId: locationId,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude
        )
        geocodeQueue.requestFreshGeocode(
            locationId: locationId,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude
        )
    }

    // MARK: - Private

    private struct PhotoCoordinate {
        let latitude: Double
        let longitude: Double
        let qualityScore: Int
    }

    private func representativeCoordinatesForEvent(eventId: Int) -> (latitude: Double, longitude: Double)? {
        if let cluster = getDensestClusterCoordinates(eventId: eventId) {
            return cluster
        }
        return getCoverPhotoCoordinates(eventId: eventId)
    }

    private func getCoverPhotoCoordinates(eventId: Int) -> (latitude: Double, longitude: Double)? {
        guard let db = database.connection else { return nil }

        let sql = """
        SELECT COALESCE(p.userLatitude, p.latitude),
               COALESCE(p.userLongitude, p.longitude)
        FROM events e
        JOIN photos p ON p.id = e.coverPhotoId
        WHERE e.eventId = ?
          AND p.isDeleted = 0
          AND COALESCE(p.userLatitude, p.latitude) IS NOT NULL
          AND COALESCE(p.userLongitude, p.longitude) IS NOT NULL;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))

            if sqlite3_step(statement) == SQLITE_ROW {
                let latitude = sqlite3_column_double(statement, 0)
                let longitude = sqlite3_column_double(statement, 1)
                sqlite3_finalize(statement)
                return (latitude, longitude)
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    private func getPhotoCoordinatesForEvent(eventId: Int) -> [PhotoCoordinate] {
        guard let db = database.connection else { return [] }

        let sql = """
        SELECT COALESCE(p.userLatitude, p.latitude),
               COALESCE(p.userLongitude, p.longitude),
               p.qualityScore
        FROM photos p
        JOIN photo_events pe ON p.id = pe.photoId
        WHERE pe.eventId = ?
          AND p.isDeleted = 0
          AND COALESCE(p.userLatitude, p.latitude) IS NOT NULL
          AND COALESCE(p.userLongitude, p.longitude) IS NOT NULL;
        """

        var statement: OpaquePointer?
        var coordinates: [PhotoCoordinate] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))

            while sqlite3_step(statement) == SQLITE_ROW {
                coordinates.append(
                    PhotoCoordinate(
                        latitude: sqlite3_column_double(statement, 0),
                        longitude: sqlite3_column_double(statement, 1),
                        qualityScore: Int(sqlite3_column_int(statement, 2))
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return coordinates
    }

    private func getDensestClusterCoordinates(eventId: Int) -> (latitude: Double, longitude: Double)? {
        let coordinates = getPhotoCoordinatesForEvent(eventId: eventId)
        guard !coordinates.isEmpty else { return nil }

        var bucketQualityScores: [String: Int] = [:]
        var bucketCounts: [String: Int] = [:]
        var bucketCoordinates: [String: [PhotoCoordinate]] = [:]

        for coordinate in coordinates {
            let latBucket = locations.coordinateBucket(coordinate.latitude)
            let lonBucket = locations.coordinateBucket(coordinate.longitude)
            let key = "\(latBucket),\(lonBucket)"

            bucketQualityScores[key, default: 0] += coordinate.qualityScore
            bucketCounts[key, default: 0] += 1
            bucketCoordinates[key, default: []].append(coordinate)
        }

        guard let winningKey = bucketQualityScores.max(by: {
            if $0.value != $1.value {
                return $0.value < $1.value
            }
            return bucketCounts[$0.key, default: 0] < bucketCounts[$1.key, default: 0]
        })?.key,
              let cluster = bucketCoordinates[winningKey],
              !cluster.isEmpty else {
            return nil
        }

        let latitude = cluster.map(\.latitude).reduce(0, +) / Double(cluster.count)
        let longitude = cluster.map(\.longitude).reduce(0, +) / Double(cluster.count)
        return (latitude, longitude)
    }

    private func getEventLocationId(eventId: Int) -> Int? {
        guard let db = database.connection else { return nil }

        let sql = """
        SELECT locationId
        FROM events
        WHERE eventId = ?
          AND locationId IS NOT NULL;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))

            if sqlite3_step(statement) == SQLITE_ROW {
                let locationId = Int(sqlite3_column_int(statement, 0))
                sqlite3_finalize(statement)
                return locationId
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    private func syncDefaultChildEventNameIfSubEvent(eventId: Int) {
        guard let db = database.connection else { return }

        let sql = """
        SELECT parentEventId
        FROM events
        WHERE eventId = ?;
        """

        var statement: OpaquePointer?
        var parentEventId: Int?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if sqlite3_step(statement) == SQLITE_ROW,
               sqlite3_column_type(statement, 0) != SQLITE_NULL {
                parentEventId = Int(sqlite3_column_int(statement, 0))
            }
        }

        sqlite3_finalize(statement)

        guard parentEventId != nil else { return }
        events.syncDefaultChildEventName(forSubEventId: eventId)
    }

    private func homeLocationIdForEvent(
        eventId: Int,
        storedLatitude: Double,
        storedLongitude: Double,
        at date: Date
    ) -> Int? {
        if let rep = representativeCoordinatesForEvent(eventId: eventId),
           let homeId = locations.findDesignatedHomeLocationId(
               latitude: rep.latitude,
               longitude: rep.longitude,
               at: date
           ) {
            return homeId
        }

        if let homeId = locations.findDesignatedHomeLocationId(
            latitude: storedLatitude,
            longitude: storedLongitude,
            at: date
        ) {
            return homeId
        }

        guard let db = database.connection else { return nil }

        let photoSQL = """
        SELECT COALESCE(p.userLatitude, p.latitude), COALESCE(p.userLongitude, p.longitude)
        FROM photos p
        JOIN photo_events pe ON pe.photoId = p.id
        JOIN events e ON e.eventId = pe.eventId
        WHERE p.isDeleted = 0
          AND COALESCE(p.userLatitude, p.latitude) IS NOT NULL
          AND COALESCE(p.userLongitude, p.longitude) IS NOT NULL
          AND (e.eventId = ? OR e.parentEventId = ?);
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, photoSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_int(statement, 2, Int32(eventId))

            while sqlite3_step(statement) == SQLITE_ROW {
                let latitude = sqlite3_column_double(statement, 0)
                let longitude = sqlite3_column_double(statement, 1)

                if let homeId = locations.findDesignatedHomeLocationId(
                    latitude: latitude,
                    longitude: longitude,
                    at: date
                ) {
                    sqlite3_finalize(statement)
                    return homeId
                }
            }
        }

        sqlite3_finalize(statement)
        return nil
    }
}
