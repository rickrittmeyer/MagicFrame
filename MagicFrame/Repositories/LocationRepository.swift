import Foundation
import SQLite3

/// SQLite access for `locations` and location geocode/home workflows.
final class LocationRepository {

    static let shared = LocationRepository()

    static let defaultLocationTypes = ["Stadium", "Beach", "Lake"]
    private static let customLocationTypesKey = "customLocationTypes"

    private let database: DatabaseManager
    private let events: EventRepository
    private var eventTuningCache: EventTuningSettings?

    init(database: DatabaseManager = .shared, events: EventRepository = .shared) {
        self.database = database
        self.events = events
    }

    private var db: OpaquePointer? { database.connection }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if database.isOnQueue { return try work() }
        return try database.sync(work)
    }

    private let iso8601Formatter = ISO8601DateFormatter()

    private func getAppMetadata(key: String) -> String? {
        let sql = """
        SELECT value
        FROM app_metadata
        WHERE key = ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                let value = String(cString: sqlite3_column_text(statement, 0))
                sqlite3_finalize(statement)
                return value
            }
        }
        sqlite3_finalize(statement)
        return nil
    }

    private func setAppMetadata(key: String, value: String) {
        let sql = """
        INSERT INTO app_metadata (key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (value as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func countRows(_ tableOrQuery: String) -> Int {
        let sql = "SELECT COUNT(*) FROM \(tableOrQuery);"
        var statement: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        } else {
            print("Count failed for \(tableOrQuery): \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(statement)
        return count
    }

    func eventTuningUnsafe() -> EventTuningSettings {
        if let eventTuningCache { return eventTuningCache }
        if let json = getAppMetadata(key: EventTuningSettings.storageKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(EventTuningSettings.self, from: data) {
            eventTuningCache = decoded
            return decoded
        }
        let defaults = EventTuningSettings()
        eventTuningCache = defaults
        return defaults
    }

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func isoDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Calendar.current.startOfDay(for: date))
    }

    private func getPendingLocations(limit: Int?) -> [PendingLocation] {
        var sql = """
        SELECT l.locationId, l.latitude, l.longitude
        FROM locations l
        LEFT JOIN events e
            ON e.locationId = l.locationId
           AND e.isDeleted = 0
        WHERE l.latitude IS NOT NULL
          AND l.longitude IS NOT NULL
          AND (
                l.geocodeStatus IS NULL
                OR l.geocodeStatus IN ('pending', 'failed')
          )
        GROUP BY l.locationId, l.latitude, l.longitude
        ORDER BY MAX(e.startDate) DESC, l.locationId DESC
        """

        if limit != nil {
            sql += "\nLIMIT ?;"
        } else {
            sql += ";"
        }

        var statement: OpaquePointer?
        var locations: [PendingLocation] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if let limit {
                sqlite3_bind_int(statement, 1, Int32(limit))
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                let locationId = Int(sqlite3_column_int(statement, 0))
                let latitude = sqlite3_column_double(statement, 1)
                let longitude = sqlite3_column_double(statement, 2)

                locations.append(
                    PendingLocation(
                        locationId: locationId,
                        latitude: latitude,
                        longitude: longitude
                    )
                )
            }
        } else {
            print("Failed to get pending locations: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
        return locations
    }

    func countPendingGeocodeLocations() -> Int {
        return countRows(
            "locations WHERE latitude IS NOT NULL AND longitude IS NOT NULL AND (geocodeStatus IS NULL OR geocodeStatus IN ('pending', 'failed'))"
        )
    }

    func fetchPendingGeocodeLocations(limit: Int? = nil) -> [PendingLocation] {
        getPendingLocations(limit: limit)
    }

    func fetchEventLocationsNeedingGeocode(limit: Int? = nil) -> [PendingLocation] {
        var sql = """
        SELECT l.locationId, l.latitude, l.longitude
        FROM locations l
        JOIN events e
            ON e.locationId = l.locationId
           AND e.isDeleted = 0
        WHERE l.latitude IS NOT NULL
          AND l.longitude IS NOT NULL
          AND (
                l.geocodeStatus IS NULL
                OR l.geocodeStatus IN ('pending', 'failed')
                OR l.placeName IS NULL OR TRIM(l.placeName) = ''
                OR l.city IS NULL OR TRIM(l.city) = ''
          )
        GROUP BY l.locationId, l.latitude, l.longitude
        ORDER BY MAX(e.startDate) DESC, l.locationId DESC
        """

        if limit != nil {
            sql += "\nLIMIT ?;"
        } else {
            sql += ";"
        }

        var statement: OpaquePointer?
        var targets: [PendingLocation] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if let limit {
                sqlite3_bind_int(statement, 1, Int32(limit))
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                targets.append(
                    PendingLocation(
                        locationId: Int(sqlite3_column_int(statement, 0)),
                        latitude: sqlite3_column_double(statement, 1),
                        longitude: sqlite3_column_double(statement, 2)
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return targets
    }

    func tryCopyNearbyGeocode(locationId: Int, latitude: Double, longitude: Double) -> Bool {
        copyNearbyCompletedLocationIfPossible(
            locationId: locationId,
            latitude: latitude,
            longitude: longitude
        )
    }

    func startGeocodingAllPending() {
        LocationGeocodeCoordinator.shared.enqueueAllPendingFromDatabase()
    }

    func startGeocodingEventLocations(limit: Int? = nil) {
        LocationGeocodeCoordinator.shared.enqueueEventLocationsMissingDetails(limit: limit)
    }

    func completeLocationGeocode(
        locationId: Int,
        city: String?,
        state: String?,
        placeName: String?
    ) {
        sync {
            updateLocationGeocode(
                locationId: locationId,
                city: city,
                state: state,
                placeName: placeName,
                status: "complete"
            )
            events.updateEventsFromLocation(locationId: locationId)
            mergeLocationAfterGeocodeUnsafe(locationId: locationId)
        }
    }

    func markLocationGeocodeFailed(locationId: Int) {
        sync {
            markLocationGeocodeFailedUnsafe(locationId: locationId)
        }
    }

    private func markLocationGeocodeFailedUnsafe(locationId: Int) {
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        UPDATE locations
        SET geocodeStatus = 'failed',
            lastGeocodedAt = ?,
            updatedAt = ?
        WHERE locationId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(locationId))

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed marking geocode failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
    }

    func resetLocationGeocodeToPending(locationId: Int) {
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        UPDATE locations
        SET geocodeStatus = 'pending',
            updatedAt = ?
        WHERE locationId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(locationId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    func isLocationGeocodeComplete(locationId: Int) -> Bool {
        let sql = """
        SELECT geocodeStatus, placeName, city
        FROM locations
        WHERE locationId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(locationId))

            if sqlite3_step(statement) == SQLITE_ROW {
                let status =
                    sqlite3_column_type(statement, 0) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 0))

                let placeName: String? =
                    sqlite3_column_type(statement, 1) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 1))

                let city: String? =
                    sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 2))

                sqlite3_finalize(statement)

                if status == "complete" {
                    return true
                }

                let hasPlace = !(placeName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let hasCity = !(city?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                return hasPlace || hasCity
            }
        }

        sqlite3_finalize(statement)
        return false
    }

    func resetLocationForGeocoding(
        locationId: Int,
        latitude: Double,
        longitude: Double
    ) {
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        UPDATE locations
        SET latitude = ?,
            longitude = ?,
            city = NULL,
            state = NULL,
            placeName = NULL,
            geocodeStatus = 'pending',
            updatedAt = ?
        WHERE locationId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, latitude)
            sqlite3_bind_double(statement, 2, longitude)
            sqlite3_bind_text(statement, 3, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 4, Int32(locationId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    func repairStaleGeocodeStatuses() {
        sqlite3_exec(
            db,
            """
            UPDATE locations
            SET geocodeStatus = 'pending'
            WHERE geocodeStatus = 'complete'
              AND (city IS NULL OR TRIM(city) = '')
              AND (state IS NULL OR TRIM(state) = '')
              AND (placeName IS NULL OR TRIM(placeName) = '');
            """,
            nil,
            nil,
            nil
        )
    }
    func debugLocationCounts() {
        print("---- LOCATION DEBUG ----")
        print("locations rows: \(countRows("locations"))")
        print("pending locations: \(countRows("locations WHERE geocodeStatus = 'pending'"))")
        print("complete locations: \(countRows("locations WHERE geocodeStatus = 'complete'"))")
        print("events with locationId: \(countRows("events WHERE locationId IS NOT NULL"))")
        print("events without locationId: \(countRows("events WHERE locationId IS NULL"))")
        print("------------------------")
    }
    private func copyNearbyCompletedLocationIfPossible(locationId: Int, latitude: Double, longitude: Double) -> Bool {
        let targetIsCurrentHome = isLocationCurrentHome(locationId: locationId)

        if targetIsCurrentHome, isLocationGeocodeComplete(locationId: locationId) {
            return false
        }

        if !targetIsCurrentHome,
           let homeLocationId = findDesignatedHomeLocationId(
               latitude: latitude,
               longitude: longitude,
               at: Date()
           ),
           homeLocationId != locationId,
           isLocationGeocodeComplete(locationId: homeLocationId),
           copyGeocode(fromLocationId: homeLocationId, toLocationId: locationId) {
            return true
        }

        let sql = """
        SELECT locationId, latitude, longitude, city, state, placeName,
               COALESCE(isCurrentHome, 0) as isCurrentHome
        FROM locations
        WHERE geocodeStatus = 'complete'
          AND city IS NOT NULL
          AND state IS NOT NULL
          AND latitude IS NOT NULL
          AND longitude IS NOT NULL
          AND locationId != ?;
        """

        var statement: OpaquePointer?
        var bestMatch: (city: String?, state: String?, placeName: String?)?
        var bestDistance = Double.greatestFiniteMagnitude
        var bestIsHome = false

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(locationId))

            while sqlite3_step(statement) == SQLITE_ROW {
                let existingLat = sqlite3_column_double(statement, 1)
                let existingLon = sqlite3_column_double(statement, 2)

                let distance = distanceInMiles(
                    lat1: latitude,
                    lon1: longitude,
                    lat2: existingLat,
                    lon2: existingLon
                )

                guard distance <= eventTuningUnsafe().locationMatchMiles else { continue }

                let isHome = sqlite3_column_int(statement, 6) == 1
                let isBetter = isHome && !bestIsHome
                    || (isHome == bestIsHome && distance < bestDistance)

                guard isBetter else { continue }

                let city: String? =
                    sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 3))

                let state: String? =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 4))

                let placeName: String? =
                    sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 5))

                bestDistance = distance
                bestIsHome = isHome
                bestMatch = (city, state, placeName)
            }
        }

        sqlite3_finalize(statement)

        if let bestMatch {
            updateLocationGeocode(
                locationId: locationId,
                city: bestMatch.city,
                state: bestMatch.state,
                placeName: bestMatch.placeName
            )

            events.updateEventsFromLocation(locationId: locationId)

            print("Copied nearby geocode for location \(locationId): \(bestMatch.city ?? "nil"), \(bestMatch.state ?? "nil")")

            return true
        }

        return false
    }

    private func copyGeocode(fromLocationId: Int, toLocationId: Int) -> Bool {
        let sql = """
        SELECT city, state, placeName
        FROM locations
        WHERE locationId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(fromLocationId))

            if sqlite3_step(statement) == SQLITE_ROW {
                let city: String? =
                    sqlite3_column_type(statement, 0) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 0))

                let state: String? =
                    sqlite3_column_type(statement, 1) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 1))

                let placeName: String? =
                    sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 2))

                sqlite3_finalize(statement)

                updateLocationGeocode(
                    locationId: toLocationId,
                    city: city,
                    state: state,
                    placeName: placeName
                )
                events.updateEventsFromLocation(locationId: toLocationId)
                return true
            }
        }

        sqlite3_finalize(statement)
        return false
    }

    private func isLocationCurrentHome(locationId: Int) -> Bool {
        countRows("locations WHERE locationId = \(locationId) AND COALESCE(isCurrentHome, 0) = 1") > 0
    }
    
    func rebuildLocationsForExistingEventsOnce() {
        let resetSQL = """
        DELETE FROM locations;
        UPDATE events
        SET locationId = NULL,
            city = NULL,
            state = NULL,
            placeName = NULL;
        """

        sqlite3_exec(db, resetSQL, nil, nil, nil)

        let sql = """
        SELECT eventId, latitude, longitude
        FROM events
        WHERE isDeleted = 0
          AND latitude IS NOT NULL
          AND longitude IS NOT NULL;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let eventId = Int(sqlite3_column_int(statement, 0))
                let latitude = sqlite3_column_double(statement, 1)
                let longitude = sqlite3_column_double(statement, 2)

                let locationId = findOrCreateLocation(
                    latitude: latitude,
                    longitude: longitude
                )

                events.setEventLocationId(eventId: eventId, locationId: locationId)
            }
        }

        sqlite3_finalize(statement)

        print("Rebuilt locations for existing events")
        debugLocationCounts()
    }
    
    func getLocationTypeOptions() -> [String] {
        var options = Set(LocationRepository.defaultLocationTypes)

        if let custom = getAppMetadata(key: LocationRepository.customLocationTypesKey),
           !custom.isEmpty {
            for type in custom.split(separator: ",") {
                let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    options.insert(trimmed)
                }
            }
        }

        return options.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func addCustomLocationType(_ type: String) {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var options = Set(getLocationTypeOptions())
        options.insert(trimmed)

        let customOnly = options
            .subtracting(LocationRepository.defaultLocationTypes)
            .sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }

        setAppMetadata(
            key: LocationRepository.customLocationTypesKey,
            value: customOnly.joined(separator: ",")
        )
    }

    func geocodeLocationsUsedByEvents(limit: Int = 25) {
        startGeocodingEventLocations(limit: limit)
    }

    func getLocationsRankedByEventCount() -> [ManagedLocation] {
        let sql = """
        SELECT
            l.locationId,
            NULLIF(TRIM(l.nickname), '') as nickname,
            NULLIF(TRIM(l.placeName), '') as placeName,
            NULLIF(TRIM(l.city), '') as city,
            NULLIF(TRIM(l.state), '') as state,
            l.locationType,
            COALESCE(l.isFavorite, 0) as isFavorite,
            l.latitude,
            l.longitude,
            COALESCE(l.isCurrentHome, 0) as isCurrentHome,
            l.homeStartDate,
            l.homeEndDate,
            (
                SELECT COUNT(*)
                FROM events e
                WHERE e.locationId = l.locationId
                  AND e.isDeleted = 0
                  AND e.parentEventId IS NULL
            ) as eventCount
        FROM locations l
        WHERE EXISTS (
            SELECT 1
            FROM events e
            WHERE e.locationId = l.locationId
              AND e.isDeleted = 0
        )
        OR COALESCE(l.isCurrentHome, 0) = 1
        OR (
            l.homeStartDate IS NOT NULL
            AND l.homeEndDate IS NOT NULL
        )
        ORDER BY COALESCE(l.isCurrentHome, 0) DESC,
            eventCount DESC,
            placeName ASC,
            city ASC;
        """

        return fetchManagedLocations(sql: sql, bindLocationId: nil)
    }

    func getLocation(locationId: Int) -> ManagedLocation? {
        let sql = """
        SELECT
            l.locationId,
            NULLIF(TRIM(l.nickname), '') as nickname,
            NULLIF(TRIM(l.placeName), '') as placeName,
            NULLIF(TRIM(l.city), '') as city,
            NULLIF(TRIM(l.state), '') as state,
            l.locationType,
            COALESCE(l.isFavorite, 0) as isFavorite,
            l.latitude,
            l.longitude,
            COALESCE(l.isCurrentHome, 0) as isCurrentHome,
            l.homeStartDate,
            l.homeEndDate,
            (
                SELECT COUNT(*)
                FROM events e
                WHERE e.locationId = l.locationId
                  AND e.isDeleted = 0
                  AND e.parentEventId IS NULL
            ) as eventCount
        FROM locations l
        WHERE l.locationId = ?;
        """

        return fetchManagedLocations(sql: sql, bindLocationId: locationId).first
    }

    func locationsNeedingGeocodeCount() -> Int {
        countRows(
            """
            (
                SELECT DISTINCT l.locationId
                FROM locations l
                JOIN events e ON e.locationId = l.locationId
                WHERE e.isDeleted = 0
                  AND l.latitude IS NOT NULL
                  AND l.longitude IS NOT NULL
                  AND (
                        l.geocodeStatus IS NULL
                        OR l.geocodeStatus IN ('pending', 'failed')
                        OR l.placeName IS NULL OR TRIM(l.placeName) = ''
                        OR l.city IS NULL OR TRIM(l.city) = ''
                  )
            )
            """
        )
    }

    private func fetchManagedLocations(sql: String, bindLocationId: Int?) -> [ManagedLocation] {
        var statement: OpaquePointer?
        var locations: [ManagedLocation] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if let bindLocationId {
                sqlite3_bind_int(statement, 1, Int32(bindLocationId))
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                let locationId = Int(sqlite3_column_int(statement, 0))

                let nickname: String? =
                    sqlite3_column_type(statement, 1) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 1))

                let placeName: String? =
                    sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 2))

                let city: String? =
                    sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 3))

                let state: String? =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 4))

                let locationType: String? =
                    sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 5))

                let isFavorite = sqlite3_column_int(statement, 6) == 1

                let latitude: Double? =
                    sqlite3_column_type(statement, 7) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 7)

                let longitude: Double? =
                    sqlite3_column_type(statement, 8) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 8)

                let eventCount = Int(sqlite3_column_int(statement, 12))

                let isCurrentHome = sqlite3_column_int(statement, 9) == 1

                let homeStartDate: String? =
                    sqlite3_column_type(statement, 10) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 10))

                let homeEndDate: String? =
                    sqlite3_column_type(statement, 11) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 11))

                locations.append(
                    ManagedLocation(
                        locationId: locationId,
                        nickname: nickname,
                        placeName: placeName,
                        city: city,
                        state: state,
                        locationType: locationType,
                        isFavorite: isFavorite,
                        eventCount: eventCount,
                        latitude: latitude,
                        longitude: longitude,
                        isCurrentHome: isCurrentHome,
                        homeStartDate: homeStartDate,
                        homeEndDate: homeEndDate
                    )
                )
            }
        } else {
            print("Failed to get locations: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
        return locations
    }

    func updateLocationNickname(locationId: Int, nickname: String?) {
        let trimmed = nickname?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        UPDATE locations
        SET nickname = ?,
            updatedAt = ?
        WHERE locationId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindOptionalText(value, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(locationId))

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed updating location nickname: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
    }

    func updateLocationType(locationId: Int, locationType: String?) {
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        UPDATE locations
        SET locationType = ?,
            updatedAt = ?
        WHERE locationId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if let locationType = locationType, !locationType.isEmpty {
                sqlite3_bind_text(
                    statement,
                    1,
                    (locationType as NSString).utf8String,
                    -1,
                    nil
                )
            } else {
                sqlite3_bind_null(statement, 1)
            }

            sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(locationId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    func setLocationFavorite(locationId: Int, isFavorite: Bool) {
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        UPDATE locations
        SET isFavorite = ?,
            updatedAt = ?
        WHERE locationId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
            sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(locationId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    func getCurrentHomeLocation() -> ManagedLocation? {
        let sql = """
        SELECT
            l.locationId,
            NULLIF(TRIM(l.nickname), '') as nickname,
            NULLIF(TRIM(l.placeName), '') as placeName,
            NULLIF(TRIM(l.city), '') as city,
            NULLIF(TRIM(l.state), '') as state,
            l.locationType,
            COALESCE(l.isFavorite, 0) as isFavorite,
            l.latitude,
            l.longitude,
            COALESCE(l.isCurrentHome, 0) as isCurrentHome,
            l.homeStartDate,
            l.homeEndDate,
            0 as eventCount
        FROM locations l
        WHERE COALESCE(l.isCurrentHome, 0) = 1
        LIMIT 1;
        """

        return fetchManagedLocations(sql: sql, bindLocationId: nil).first
    }

    func hasCurrentHome() -> Bool {
        getCurrentHomeLocation() != nil
    }

    /// Creates or reuses a location row and marks it as Current Home before photo import.
    @discardableResult
    func createDesignatedCurrentHome(
        latitude: Double,
        longitude: Double,
        nickname: String?,
        homeStartDate: Date?
    ) -> Int {
        let locationId = sync { () -> Int in
            let locationId = findOrCreateLocation(latitude: latitude, longitude: longitude)

            if locationId > 0 {
                let trimmedNickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmedNickname, !trimmedNickname.isEmpty {
                    updateLocationNickname(locationId: locationId, nickname: trimmedNickname)
                }

                updateLocationHomeDesignation(
                    locationId: locationId,
                    role: .current,
                    homeStartDate: homeStartDate,
                    homeEndDate: nil
                )
            }

            return locationId
        }

        return locationId
    }

    func updateLocationHomeDesignation(
        locationId: Int,
        role: LocationHomeRole,
        homeStartDate: Date?,
        homeEndDate: Date?
    ) {
        let now = ISO8601DateFormatter().string(from: Date())
        let startISO = homeStartDate.map(isoDateString)
        let endISO = homeEndDate.map(isoDateString)

        if role == .current {
            clearCurrentHomeDesignation(excluding: locationId)
        }

        let isCurrentHome = role == .current
        let storedStart = role == .none ? nil : startISO
        let storedEnd = role == .former ? endISO : nil

        let sql = """
        UPDATE locations
        SET isCurrentHome = ?,
            homeStartDate = ?,
            homeEndDate = ?,
            updatedAt = ?
        WHERE locationId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, isCurrentHome ? 1 : 0)
            bindOptionalText(storedStart, to: statement, index: 2)
            bindOptionalText(storedEnd, to: statement, index: 3)
            sqlite3_bind_text(statement, 4, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 5, Int32(locationId))

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed updating home designation: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)

        if role == .current || role == .former {
            clearLegacyHomeType(from: locationId)
        }
    }

    private func clearCurrentHomeDesignation(excluding locationId: Int) {
        let sql = """
        UPDATE locations
        SET isCurrentHome = 0
        WHERE isCurrentHome = 1
          AND locationId != ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(locationId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    private func clearLegacyHomeType(from locationId: Int) {
        let sql = """
        UPDATE locations
        SET locationType = NULL
        WHERE locationId = ?
          AND TRIM(COALESCE(locationType, '')) = 'Home';
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(locationId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    func migrateLegacyHomeLocations() {
        let flagKey = "legacyHomeLocationsMigrated"
        guard getAppMetadata(key: flagKey) == nil else { return }

        let sql = """
        SELECT locationId, nickname, locationType
        FROM locations
        WHERE TRIM(COALESCE(locationType, '')) = 'Home'
           OR LOWER(TRIM(COALESCE(nickname, ''))) LIKE '%our home%'
           OR LOWER(TRIM(COALESCE(nickname, ''))) = 'home';
        """

        var statement: OpaquePointer?
        var candidates: [(id: Int, nickname: String?)] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let locationId = Int(sqlite3_column_int(statement, 0))
                let nickname: String? =
                    sqlite3_column_type(statement, 1) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 1))
                candidates.append((locationId, nickname))
            }
        }

        sqlite3_finalize(statement)

        if let preferred = candidates.first(where: {
            $0.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "our home"
        }) {
            updateLocationHomeDesignation(
                locationId: preferred.id,
                role: .current,
                homeStartDate: nil,
                homeEndDate: nil
            )
        } else if candidates.count == 1 {
            updateLocationHomeDesignation(
                locationId: candidates[0].id,
                role: .current,
                homeStartDate: nil,
                homeEndDate: nil
            )
        }

        setAppMetadata(key: flagKey, value: "1")
    }
    func distanceInMiles(
        lat1: Double,
        lon1: Double,
        lat2: Double,
        lon2: Double
    ) -> Double {
        let earthRadiusMiles = 3958.8

        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180

        let a =
            sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1 * .pi / 180) *
            cos(lat2 * .pi / 180) *
            sin(dLon / 2) *
            sin(dLon / 2)

        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return earthRadiusMiles * c
    }


    /// ~11 m precision at mid-latitudes (4 decimal places). Used for location dedup keys only.
    func coordinateBucket(_ value: Double) -> Double {
        return (value * 10_000).rounded() / 10_000
    }
    func deduplicateLocationsByAddress(
        maxDistanceMiles: Double? = nil
    ) -> Int {
        sync {
            let miles = maxDistanceMiles ?? eventTuningUnsafe().addressDeduplicationMaxMiles
            return deduplicateLocationsByAddressUnsafe(maxDistanceMiles: miles)
        }
    }

    private struct LocationMergeRow {
        let locationId: Int
        let latitude: Double
        let longitude: Double
        let placeName: String?
        let city: String?
        let state: String?
        let eventCount: Int
        let isFavorite: Bool
        let locationType: String?
        let isCurrentHome: Bool
        let nickname: String?
        let homeStartDate: String?
        let homeEndDate: String?
    }

    private func loadLocationMergeRows() -> [LocationMergeRow] {
        let sql = """
        SELECT
            l.locationId,
            l.latitude,
            l.longitude,
            COALESCE(
                NULLIF(TRIM(l.placeName), ''),
                (
                    SELECT MAX(NULLIF(TRIM(e.placeName), ''))
                    FROM events e
                    WHERE e.locationId = l.locationId
                      AND e.isDeleted = 0
                )
            ) as placeName,
            COALESCE(
                NULLIF(TRIM(l.city), ''),
                (
                    SELECT MAX(NULLIF(TRIM(e.city), ''))
                    FROM events e
                    WHERE e.locationId = l.locationId
                      AND e.isDeleted = 0
                )
            ) as city,
            COALESCE(
                NULLIF(TRIM(l.state), ''),
                (
                    SELECT MAX(NULLIF(TRIM(e.state), ''))
                    FROM events e
                    WHERE e.locationId = l.locationId
                      AND e.isDeleted = 0
                )
            ) as state,
            COALESCE(l.isFavorite, 0),
            l.locationType,
            COALESCE(l.isCurrentHome, 0),
            NULLIF(TRIM(l.nickname), ''),
            l.homeStartDate,
            l.homeEndDate,
            (
                SELECT COUNT(*)
                FROM events e
                WHERE e.locationId = l.locationId
                  AND e.isDeleted = 0
            ) as eventCount
        FROM locations l
        WHERE l.latitude IS NOT NULL
          AND l.longitude IS NOT NULL;
        """

        var statement: OpaquePointer?
        var rows: [LocationMergeRow] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let placeName: String? =
                    sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 3))

                let city: String? =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 4))

                let state: String? =
                    sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 5))

                let locationType: String? =
                    sqlite3_column_type(statement, 7) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 7))

                let isCurrentHome = sqlite3_column_int(statement, 8) == 1

                let nickname: String? =
                    sqlite3_column_type(statement, 9) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 9))

                let homeStartDate: String? =
                    sqlite3_column_type(statement, 10) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 10))

                let homeEndDate: String? =
                    sqlite3_column_type(statement, 11) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 11))

                rows.append(
                    LocationMergeRow(
                        locationId: Int(sqlite3_column_int(statement, 0)),
                        latitude: sqlite3_column_double(statement, 1),
                        longitude: sqlite3_column_double(statement, 2),
                        placeName: placeName,
                        city: city,
                        state: state,
                        eventCount: Int(sqlite3_column_int(statement, 12)),
                        isFavorite: sqlite3_column_int(statement, 6) == 1,
                        locationType: locationType,
                        isCurrentHome: isCurrentHome,
                        nickname: nickname,
                        homeStartDate: homeStartDate,
                        homeEndDate: homeEndDate
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return rows
    }

    @discardableResult
    private func applyLocationMergeClusters(
        rows: [LocationMergeRow],
        parent: [Int]
    ) -> Int {
        var parent = parent

        func find(_ index: Int) -> Int {
            if parent[index] != index {
                parent[index] = find(parent[index])
            }
            return parent[index]
        }

        var clusters: [Int: [Int]] = [:]

        for index in rows.indices {
            let root = find(index)
            clusters[root, default: []].append(index)
        }

        var mergedCount = 0

        func canonicalRank(for index: Int) -> Int {
            var score = rows[index].eventCount

            if rows[index].isCurrentHome {
                score += 1_000_000
            }

            if rows[index].isFavorite {
                score += 10_000
            }

            if let nickname = rows[index].nickname, !nickname.isEmpty {
                score += 1_000
            }

            return score
        }

        for clusterIndices in clusters.values where clusterIndices.count > 1 {
            let canonicalIndex = clusterIndices.max {
                if canonicalRank(for: $0) != canonicalRank(for: $1) {
                    return canonicalRank(for: $0) < canonicalRank(for: $1)
                }
                return rows[$0].locationId > rows[$1].locationId
            }!

            let canonical = rows[canonicalIndex]

            for index in clusterIndices where index != canonicalIndex {
                let duplicate = rows[index]
                events.reassignEvents(
                    fromLocationId: duplicate.locationId,
                    toLocationId: canonical.locationId
                )
                absorbLocationMetadata(
                    toLocationId: canonical.locationId,
                    duplicateIsFavorite: duplicate.isFavorite,
                    duplicateLocationType: duplicate.locationType,
                    duplicateIsCurrentHome: duplicate.isCurrentHome,
                    duplicateNickname: duplicate.nickname,
                    duplicateHomeStartDate: duplicate.homeStartDate,
                    duplicateHomeEndDate: duplicate.homeEndDate
                )
                deleteLocationIfUnused(locationId: duplicate.locationId)
                mergedCount += 1
            }

            events.updateEventsFromLocation(locationId: canonical.locationId)
        }

        return mergedCount
    }

    @discardableResult
    func deduplicateLocationsByAddressUnsafe(
        maxDistanceMiles: Double
    ) -> Int {
        let rows = loadLocationMergeRows()
        guard rows.count > 1 else { return 0 }

        var indicesByPlaceKey: [String: [Int]] = [:]

        for (index, row) in rows.enumerated() {
            guard let key = Self.normalizedPlaceKey(
                placeName: row.placeName,
                city: row.city,
                state: row.state
            ) else {
                continue
            }

            indicesByPlaceKey[key, default: []].append(index)
        }

        var parent = Array(0..<rows.count)

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

        for indices in indicesByPlaceKey.values where indices.count > 1 {
            for leftOffset in 0..<indices.count {
                for rightOffset in (leftOffset + 1)..<indices.count {
                    let left = indices[leftOffset]
                    let right = indices[rightOffset]
                    let distance = distanceInMiles(
                        lat1: rows[left].latitude,
                        lon1: rows[left].longitude,
                        lat2: rows[right].latitude,
                        lon2: rows[right].longitude
                    )

                    if distance <= maxDistanceMiles {
                        union(left, right)
                    }
                }
            }
        }

        return applyLocationMergeClusters(rows: rows, parent: parent)
    }

    private func mergeLocationAfterGeocodeUnsafe(locationId: Int) {
        let rows = loadLocationMergeRows()
        guard rows.count > 1,
              let sourceIndex = rows.firstIndex(where: { $0.locationId == locationId }) else {
            return
        }

        guard let placeKey = Self.normalizedPlaceKey(
            placeName: rows[sourceIndex].placeName,
            city: rows[sourceIndex].city,
            state: rows[sourceIndex].state
        ) else {
            return
        }

        var parent = Array(0..<rows.count)

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

        for (index, row) in rows.enumerated() where index != sourceIndex {
            guard Self.normalizedPlaceKey(
                placeName: row.placeName,
                city: row.city,
                state: row.state
            ) == placeKey else {
                continue
            }

            let distance = distanceInMiles(
                lat1: rows[sourceIndex].latitude,
                lon1: rows[sourceIndex].longitude,
                lat2: row.latitude,
                lon2: row.longitude
            )

            if distance <= eventTuningUnsafe().addressDeduplicationMaxMiles {
                union(sourceIndex, index)
            }
        }

        let mergedWithAnother = rows.indices.contains { index in
            index != sourceIndex && find(sourceIndex) == find(index)
        }

        guard mergedWithAnother else { return }

        _ = applyLocationMergeClusters(rows: rows, parent: parent)
    }

    /// Reuses an existing location within ~80 m when place names agree (or are unknown), or same normalized place name within ~0.5 mi.
    @discardableResult
    func mergeDuplicateLocations(
        proximityMiles: Double? = nil,
        samePlaceNameMiles: Double? = nil,
        frequentPlaceMiles: Double? = nil,
        frequentPlaceMinEvents: Int? = nil
    ) -> Int {
        let tuning = eventTuningUnsafe()
        let proximity = proximityMiles ?? tuning.locationMatchMiles
        let samePlace = samePlaceNameMiles ?? tuning.samePlaceNameMergeMiles
        let frequentMiles = frequentPlaceMiles ?? tuning.frequentPlaceMergeMiles
        let frequentMinEvents = frequentPlaceMinEvents ?? tuning.frequentPlaceMinEvents
        let rows = loadLocationMergeRows()
        guard rows.count > 1 else { return 0 }

        var parent = Array(0..<rows.count)

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

        func placeKey(for row: LocationMergeRow) -> String? {
            Self.normalizedPlaceKey(
                placeName: row.placeName,
                city: row.city,
                state: row.state
            )
        }

        func isTaggedHome(_ row: LocationMergeRow) -> Bool {
            row.isCurrentHome
        }

        func sameState(_ left: LocationMergeRow, _ right: LocationMergeRow) -> Bool {
            let leftState = left.state?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            let rightState = right.state?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""

            return !leftState.isEmpty && leftState == rightState
        }

        for left in 0..<rows.count {
            for right in (left + 1)..<rows.count {
                let distance = distanceInMiles(
                    lat1: rows[left].latitude,
                    lon1: rows[left].longitude,
                    lat2: rows[right].latitude,
                    lon2: rows[right].longitude
                )

                if distance <= proximity {
                    let leftKey = placeKey(for: rows[left])
                    let rightKey = placeKey(for: rows[right])

                    if leftKey == nil && rightKey == nil {
                        union(left, right)
                    } else if let leftKey,
                              let rightKey,
                              leftKey == rightKey {
                        union(left, right)
                    }

                    continue
                }

                if isTaggedHome(rows[left]),
                   isTaggedHome(rows[right]),
                   sameState(rows[left], rows[right]),
                   distance <= eventTuningUnsafe().homeLocationMergeMiles {
                    union(left, right)
                    continue
                }

                if isTaggedHome(rows[left]) || isTaggedHome(rows[right]),
                   distance <= eventTuningUnsafe().homeLocationMergeMiles {
                    union(left, right)
                    continue
                }

                guard let leftKey = placeKey(for: rows[left]),
                      leftKey == placeKey(for: rows[right]) else {
                    continue
                }

                if distance <= samePlace {
                    union(left, right)
                    continue
                }

                let leftEvents = rows[left].eventCount
                let rightEvents = rows[right].eventCount

                if distance <= frequentMiles,
                   leftEvents >= frequentMinEvents,
                   rightEvents >= frequentMinEvents {
                    union(left, right)
                }
            }
        }

        return applyLocationMergeClusters(rows: rows, parent: parent)
    }

    private static func normalizedPlaceKey(
        placeName: String?,
        city: String?,
        state: String?
    ) -> String? {
        guard let rawPlace = placeName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPlace.isEmpty,
              let rawCity = city?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawCity.isEmpty else {
            return nil
        }

        let normalizedPlace = normalizePlaceNameToken(rawPlace)
        let normalizedCity = normalizePlaceNameToken(rawCity)

        guard isSpecificPlaceName(normalizedPlace, city: normalizedCity) else {
            return nil
        }

        let normalizedState = state?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        return "\(normalizedPlace)|\(normalizedCity)|\(normalizedState)"
    }

    private static func normalizePlaceNameToken(_ value: String) -> String {
        var text = value.lowercased()
        text = text.replacingOccurrences(
            of: "[^a-z0-9\\s]",
            with: " ",
            options: .regularExpression
        )

        let replacements: [(String, String)] = [
            (" street ", " st "),
            (" st ", " st "),
            (" court ", " ct "),
            (" ct ", " ct "),
            (" drive ", " dr "),
            (" dr ", " dr "),
            (" road ", " rd "),
            (" rd ", " rd "),
            (" avenue ", " ave "),
            (" ave ", " ave "),
            (" boulevard ", " blvd "),
            (" blvd ", " blvd "),
            (" lane ", " ln "),
            (" ln ", " ln "),
            (" parkway ", " pkwy "),
            (" pkwy ", " pkwy "),
            (" circle ", " cir "),
            (" cir ", " cir "),
            (" place ", " pl "),
            (" pl ", " pl "),
            (" highway ", " hwy "),
            (" hwy ", " hwy "),
        ]

        text = " \(text) "
        for (from, to) in replacements {
            text = text.replacingOccurrences(of: from, with: to)
        }

        return text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSpecificPlaceName(_ placeName: String, city: String) -> Bool {
        if placeName.count < 5 {
            return false
        }

        if placeName == city {
            return false
        }

        let genericNames: Set<String> = [
            "home",
            "work",
            "unknown",
            "unknown location",
            city,
        ]

        if genericNames.contains(placeName) {
            return false
        }

        if placeName.rangeOfCharacter(from: .decimalDigits) != nil {
            return true
        }

        return placeName.count >= 10
    }

    private func absorbLocationMetadata(
        toLocationId: Int,
        duplicateIsFavorite: Bool,
        duplicateLocationType: String?,
        duplicateIsCurrentHome: Bool = false,
        duplicateNickname: String? = nil,
        duplicateHomeStartDate: String? = nil,
        duplicateHomeEndDate: String? = nil
    ) {
        if duplicateIsFavorite {
            setLocationFavorite(locationId: toLocationId, isFavorite: true)
        }

        if duplicateIsCurrentHome {
            clearCurrentHomeDesignation(excluding: toLocationId)

            let sql = """
            UPDATE locations
            SET isCurrentHome = 1,
                homeStartDate = COALESCE(homeStartDate, ?),
                homeEndDate = NULL,
                updatedAt = ?
            WHERE locationId = ?;
            """

            let now = ISO8601DateFormatter().string(from: Date())
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                bindOptionalText(duplicateHomeStartDate, to: statement, index: 1)
                sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 3, Int32(toLocationId))
                sqlite3_step(statement)
            }

            sqlite3_finalize(statement)
        } else if let duplicateHomeStartDate,
                  let duplicateHomeEndDate {
            let sql = """
            UPDATE locations
            SET homeStartDate = COALESCE(homeStartDate, ?),
                homeEndDate = COALESCE(homeEndDate, ?),
                updatedAt = ?
            WHERE locationId = ?
              AND COALESCE(isCurrentHome, 0) = 0;
            """

            let now = ISO8601DateFormatter().string(from: Date())
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                bindOptionalText(duplicateHomeStartDate, to: statement, index: 1)
                bindOptionalText(duplicateHomeEndDate, to: statement, index: 2)
                sqlite3_bind_text(statement, 3, (now as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 4, Int32(toLocationId))
                sqlite3_step(statement)
            }

            sqlite3_finalize(statement)
        }

        if let duplicateNickname,
           !duplicateNickname.isEmpty {
            let sql = """
            UPDATE locations
            SET nickname = ?
            WHERE locationId = ?
              AND (nickname IS NULL OR TRIM(nickname) = '');
            """

            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(
                    statement,
                    1,
                    (duplicateNickname as NSString).utf8String,
                    -1,
                    nil
                )
                sqlite3_bind_int(statement, 2, Int32(toLocationId))
                sqlite3_step(statement)
            }

            sqlite3_finalize(statement)
        }

        if let duplicateLocationType,
           !duplicateLocationType.isEmpty {
            let sql = """
            UPDATE locations
            SET locationType = ?
            WHERE locationId = ?
              AND (locationType IS NULL OR TRIM(locationType) = '');
            """

            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(
                    statement,
                    1,
                    (duplicateLocationType as NSString).utf8String,
                    -1,
                    nil
                )
                sqlite3_bind_int(statement, 2, Int32(toLocationId))
                sqlite3_step(statement)
            }

            sqlite3_finalize(statement)
        }
    }

    private func deleteLocationIfUnused(locationId: Int) {
        let sql = """
        DELETE FROM locations
        WHERE locationId = ?
          AND NOT EXISTS (
                SELECT 1
                FROM events e
                WHERE e.locationId = ?
                  AND e.isDeleted = 0
            );
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(locationId))
            sqlite3_bind_int(statement, 2, Int32(locationId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    // MARK: - Trip events (away-from-home containers + day/place sub-events)

    func findDesignatedHomeLocationId(
        latitude: Double,
        longitude: Double,
        at date: Date
    ) -> Int? {
        let sql = """
        SELECT locationId, latitude, longitude, isCurrentHome, homeStartDate, homeEndDate
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
        var bestLocationId: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        let day = Calendar.current.startOfDay(for: date)

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let locationId = Int(sqlite3_column_int(statement, 0))
                let homeLatitude = sqlite3_column_double(statement, 1)
                let homeLongitude = sqlite3_column_double(statement, 2)
                let isCurrentHome = sqlite3_column_int(statement, 3) == 1

                let homeStartDate: String? =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 4))

                let homeEndDate: String? =
                    sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 5))

                let appliesToDate: Bool

                if isCurrentHome {
                    appliesToDate = true
                } else if let startISO = homeStartDate,
                          let endISO = homeEndDate,
                          let start = EventDateParser.parseDate(startISO),
                          let end = EventDateParser.parseDate(endISO) {
                    let startDay = Calendar.current.startOfDay(for: start)
                    let endDay = Calendar.current.startOfDay(for: end)
                    appliesToDate = day >= startDay && day <= endDay
                } else {
                    appliesToDate = false
                }

                guard appliesToDate else { continue }

                let distance = distanceInMiles(
                    lat1: latitude,
                    lon1: longitude,
                    lat2: homeLatitude,
                    lon2: homeLongitude
                )

                guard distance <= eventTuningUnsafe().homeEventSnapMiles else { continue }

                if distance < bestDistance {
                    bestDistance = distance
                    bestLocationId = locationId
                }
            }
        }

        sqlite3_finalize(statement)
        return bestLocationId
    }
    func mergeNearbyLocationsIntoCurrentHome() {
        guard let home = getCurrentHomeLocation(),
              let homeLatitude = home.latitude,
              let homeLongitude = home.longitude else {
            return
        }

        let homeLocationId = home.locationId
        let sql = """
        SELECT locationId, latitude, longitude
        FROM locations
        WHERE locationId != ?
          AND latitude IS NOT NULL
          AND longitude IS NOT NULL;
        """

        var statement: OpaquePointer?
        var merged = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(homeLocationId))

            while sqlite3_step(statement) == SQLITE_ROW {
                let locationId = Int(sqlite3_column_int(statement, 0))
                let latitude = sqlite3_column_double(statement, 1)
                let longitude = sqlite3_column_double(statement, 2)

                let distance = distanceInMiles(
                    lat1: homeLatitude,
                    lon1: homeLongitude,
                    lat2: latitude,
                    lon2: longitude
                )

                guard distance <= eventTuningUnsafe().homeEventSnapMiles else { continue }

                absorbGeocodeMetadata(
                    fromLocationId: locationId,
                    toLocationId: homeLocationId
                )
                events.reassignEvents(fromLocationId: locationId, toLocationId: homeLocationId)
                deleteLocationIfUnused(locationId: locationId)
                merged += 1
            }
        }

        sqlite3_finalize(statement)

        if merged > 0 {
            events.updateEventsFromLocation(locationId: homeLocationId)
            print("Merged \(merged) nearby location row(s) into Current Home")
        }
    }

    func backfillCurrentHomeAddressIfNeeded() {
        guard let home = getCurrentHomeLocation(),
              let homeLatitude = home.latitude,
              let homeLongitude = home.longitude else {
            return
        }

        let homeLocationId = home.locationId
        let needsAddress = (home.placeName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || (home.city?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        guard needsAddress else { return }

        let nearbySQL = """
        SELECT locationId, latitude, longitude, city, state, placeName
        FROM locations
        WHERE locationId != ?
          AND geocodeStatus = 'complete'
          AND latitude IS NOT NULL
          AND longitude IS NOT NULL
          AND (
                NULLIF(TRIM(placeName), '') IS NOT NULL
                OR NULLIF(TRIM(city), '') IS NOT NULL
          );
        """

        var statement: OpaquePointer?
        var bestSourceId: Int?
        var bestDistance = Double.greatestFiniteMagnitude

        if sqlite3_prepare_v2(db, nearbySQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(homeLocationId))

            while sqlite3_step(statement) == SQLITE_ROW {
                let sourceId = Int(sqlite3_column_int(statement, 0))
                let latitude = sqlite3_column_double(statement, 1)
                let longitude = sqlite3_column_double(statement, 2)

                let distance = distanceInMiles(
                    lat1: homeLatitude,
                    lon1: homeLongitude,
                    lat2: latitude,
                    lon2: longitude
                )

                guard distance <= eventTuningUnsafe().homeEventSnapMiles else { continue }

                if distance < bestDistance {
                    bestDistance = distance
                    bestSourceId = sourceId
                }
            }
        }

        sqlite3_finalize(statement)

        if let bestSourceId,
           absorbGeocodeMetadata(fromLocationId: bestSourceId, toLocationId: homeLocationId) {
            events.updateEventsFromLocation(locationId: homeLocationId)
            print("Backfilled Current Home address from nearby location \(bestSourceId)")
            return
        }

        if !isLocationGeocodeComplete(locationId: homeLocationId) {
            resetLocationGeocodeToPending(locationId: homeLocationId)
            LocationGeocodeCoordinator.shared.enqueue([
                PendingLocation(
                    locationId: homeLocationId,
                    latitude: homeLatitude,
                    longitude: homeLongitude
                )
            ])
        }
    }

    @discardableResult
    private func absorbGeocodeMetadata(fromLocationId: Int, toLocationId: Int) -> Bool {
        guard fromLocationId != toLocationId else { return false }

        let sql = """
        SELECT
            NULLIF(TRIM(fromLoc.placeName), ''),
            NULLIF(TRIM(fromLoc.city), ''),
            NULLIF(TRIM(fromLoc.state), ''),
            NULLIF(TRIM(toLoc.placeName), ''),
            NULLIF(TRIM(toLoc.city), ''),
            NULLIF(TRIM(toLoc.state), '')
        FROM locations fromLoc
        JOIN locations toLoc ON toLoc.locationId = ?
        WHERE fromLoc.locationId = ?;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return false
        }

        sqlite3_bind_int(statement, 1, Int32(toLocationId))
        sqlite3_bind_int(statement, 2, Int32(fromLocationId))

        guard sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            return false
        }

        let fromPlaceName: String? =
            sqlite3_column_type(statement, 0) == SQLITE_NULL
            ? nil
            : String(cString: sqlite3_column_text(statement, 0))

        let fromCity: String? =
            sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil
            : String(cString: sqlite3_column_text(statement, 1))

        let fromState: String? =
            sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil
            : String(cString: sqlite3_column_text(statement, 2))

        let toPlaceName: String? =
            sqlite3_column_type(statement, 3) == SQLITE_NULL
            ? nil
            : String(cString: sqlite3_column_text(statement, 3))

        let toCity: String? =
            sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil
            : String(cString: sqlite3_column_text(statement, 4))

        let toState: String? =
            sqlite3_column_type(statement, 5) == SQLITE_NULL
            ? nil
            : String(cString: sqlite3_column_text(statement, 5))

        sqlite3_finalize(statement)

        let placeName = toPlaceName ?? fromPlaceName
        let city = toCity ?? fromCity
        let state = toState ?? fromState

        guard placeName != nil || city != nil || state != nil else { return false }

        updateLocationGeocode(
            locationId: toLocationId,
            city: city,
            state: state,
            placeName: placeName
        )

        return true
    }

    func getEventStartDate(eventId: Int) -> Date? {
        let sql = """
        SELECT startDate
        FROM events
        WHERE eventId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))

            if sqlite3_step(statement) == SQLITE_ROW {
                let startString = String(cString: sqlite3_column_text(statement, 0))
                sqlite3_finalize(statement)
                return iso8601Formatter.date(from: startString)
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    func findLocationWithinMiles(
        latitude: Double,
        longitude: Double,
        maxMiles: Double
    ) -> Int? {
        let latDelta = maxMiles / 69.0
        let lonDelta = maxMiles / max(0.2, 69.0 * cos(latitude * .pi / 180.0))

        let sql = """
        SELECT
            l.locationId,
            l.latitude,
            l.longitude,
            COALESCE(l.isFavorite, 0),
            NULLIF(TRIM(l.nickname), ''),
            (
                SELECT COUNT(*)
                FROM events e
                WHERE e.locationId = l.locationId
                  AND e.isDeleted = 0
            ) as eventCount
        FROM locations l
        WHERE l.latitude IS NOT NULL
          AND l.longitude IS NOT NULL
          AND l.latitude BETWEEN ? AND ?
          AND l.longitude BETWEEN ? AND ?;
        """

        var statement: OpaquePointer?
        var bestLocationId: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        var bestHomeLocationId: Int?
        var bestHomeDistance = Double.greatestFiniteMagnitude

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, latitude - latDelta)
            sqlite3_bind_double(statement, 2, latitude + latDelta)
            sqlite3_bind_double(statement, 3, longitude - lonDelta)
            sqlite3_bind_double(statement, 4, longitude + lonDelta)

            while sqlite3_step(statement) == SQLITE_ROW {
                let candidateId = Int(sqlite3_column_int(statement, 0))
                let candidateLat = sqlite3_column_double(statement, 1)
                let candidateLon = sqlite3_column_double(statement, 2)
                let isFavorite = sqlite3_column_int(statement, 3) == 1
                let nickname: String? =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 4))

                let distance = distanceInMiles(
                    lat1: latitude,
                    lon1: longitude,
                    lat2: candidateLat,
                    lon2: candidateLon
                )

                guard distance <= maxMiles else { continue }

                if isLocationCurrentHome(locationId: candidateId),
                   distance <= eventTuningUnsafe().homeEventSnapMiles,
                   distance < bestHomeDistance {
                    bestHomeDistance = distance
                    bestHomeLocationId = candidateId
                }

                let isCurated = isFavorite || !(nickname?.isEmpty ?? true)
                if isCurated, distance > eventTuningUnsafe().curatedLocationMatchMiles {
                    continue
                }

                if distance < bestDistance {
                    bestDistance = distance
                    bestLocationId = candidateId
                }
            }
        }

        sqlite3_finalize(statement)

        if let bestHomeLocationId {
            return bestHomeLocationId
        }

        return bestLocationId
    }

    func findOrCreateLocation(
        latitude: Double,
        longitude: Double,
        at date: Date = Date()
    ) -> Int {
        if let homeLocationId = findDesignatedHomeLocationId(
            latitude: latitude,
            longitude: longitude,
            at: date
        ) {
            return homeLocationId
        }

        if let nearbyId = findLocationWithinMiles(
            latitude: latitude,
            longitude: longitude,
            maxMiles: eventTuningUnsafe().locationMatchMiles
        ) {
            return nearbyId
        }

        let latBucket = coordinateBucket(latitude)
        let lonBucket = coordinateBucket(longitude)
        let now = ISO8601DateFormatter().string(from: Date())

        let insertSQL = """
        INSERT OR IGNORE INTO locations
        (
            latitudeBucket, longitudeBucket,
            latitude, longitude,
            geocodeStatus,
            createdAt, updatedAt
        )
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, latBucket)
            sqlite3_bind_double(statement, 2, lonBucket)
            sqlite3_bind_double(statement, 3, latitude)
            sqlite3_bind_double(statement, 4, longitude)
            sqlite3_bind_text(statement, 5, ("pending" as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 6, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 7, (now as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)

        let selectSQL = """
        SELECT locationId
        FROM locations
        WHERE latitudeBucket = ?
          AND longitudeBucket = ?;
        """

        if sqlite3_prepare_v2(db, selectSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, latBucket)
            sqlite3_bind_double(statement, 2, lonBucket)

            if sqlite3_step(statement) == SQLITE_ROW {
                let locationId = Int(sqlite3_column_int(statement, 0))
                sqlite3_finalize(statement)
                return locationId
            }
        }

        sqlite3_finalize(statement)
        return -1
    }
    
    func updateLocationGeocode(
        locationId: Int,
        city: String?,
        state: String?,
        placeName: String?,
        status: String = "complete"
    ) {
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        UPDATE locations
        SET city = ?,
            state = ?,
            placeName = ?,
            geocodeStatus = ?,
            lastGeocodedAt = ?,
            updatedAt = ?
        WHERE locationId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindOptionalText(city, to: statement, index: 1)
            bindOptionalText(state, to: statement, index: 2)
            bindOptionalText(placeName, to: statement, index: 3)

            sqlite3_bind_text(statement, 4, (status as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 5, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 6, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 7, Int32(locationId))

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed updating location: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
    }

}
