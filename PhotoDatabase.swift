//
//  PhotoDatabase.swift
//  MagicFrame
//

import Foundation
import SQLite3
import CoreLocation
import MapKit
import Photos

extension Notification.Name {
    static let locationGeocodeProgressChanged = Notification.Name("locationGeocodeProgressChanged")
    static let eventSyncProgressChanged = Notification.Name("eventSyncProgressChanged")
}

struct EventSyncProgress {
    let processed: Int
    let total: Int
    let remainingUnassigned: Int
    var statusMessage: String?
    var isRebuild: Bool = false

    var displayStatus: String {
        if let statusMessage {
            return statusMessage
        }

        if isRebuild {
            return "Rebuilding events… \(remainingUnassigned.formatted()) photos left"
        }

        return "Building events… \(remainingUnassigned.formatted()) photos left"
    }
}

struct LocationGeocodeProgress {
    let queueCount: Int
    let isProcessing: Bool
    let pendingInDatabase: Int

    var displayRemaining: Int {
        max(queueCount + (isProcessing ? 1 : 0), pendingInDatabase)
    }

    var isActive: Bool {
        isProcessing || displayRemaining > 0
    }
}

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
        isSimilarGroupPick: Bool = false
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
    }
}

struct IndexedEvent {
    let eventId: Int
    let name: String
    let startDate: String
    let endDate: String
    let photoCount: Int
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let state: String?
    let placeName: String?
    let people: [String]
    let coverPhotoId: String?
    let showOnFrame: Bool
    let userEditedName: Bool
    let locationNickname: String?
    let locationId: Int?
    let parentEventId: Int?
    let isTripEvent: Bool
    let eventType: String?
    let activityType: String?
    let milestoneType: String?
    let holidayType: String?
    let eventMainPerson: String?
    let tripType: String?
    let childEventName: String?
    let userEditedChildEventName: Bool
    let isUserHidden: Bool

    var isTripSubEvent: Bool {
        parentEventId != nil
    }

    var isTripContainer: Bool {
        isTripEvent && parentEventId == nil
    }

    var usesSuggestedName: Bool {
        !userEditedName
    }

    var locationTitleLine: String? {
        if let locationNickname, !locationNickname.isEmpty {
            return locationNickname
        }
        if let placeName, !placeName.isEmpty {
            return placeName
        }
        return nil
    }

    var cityStateLine: String? {
        switch (city, state) {
        case let (city?, state?):
            return "\(city), \(state)"
        case let (city?, nil):
            return city
        case let (nil, state?):
            return state
        default:
            return nil
        }
    }

    var eventYear: Int? {
        EventDateParser.year(from: startDate)
    }

    var displayDateText: String? {
        EventDateParser.displayDateRange(startDate: startDate, endDate: endDate)
    }

    var listTitleText: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if EventDateParser.nameIsDateOnly(name, startDate: startDate, endDate: endDate) {
            return nil
        }

        return trimmed
    }

    /// Default label for a trip day segment (location nickname, place, or city/state).
    var defaultChildEventName: String {
        locationTitleLine ?? cityStateLine ?? "Photos"
    }

    func resolvedChildEventName() -> String {
        let trimmed = childEventName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return defaultChildEventName
    }

    var locationDisplayText: String? {
        if let locationNickname, !locationNickname.isEmpty {
            return locationNickname
        }
        if let placeName, !placeName.isEmpty {
            return placeName
        }
        if let city, let state {
            return "\(city), \(state)"
        }
        if let city {
            return city
        }
        if let state {
            return state
        }
        return nil
    }
}

struct EventCandidatePhoto {
    let id: String
    let date: Date
    let latitude: Double?
    let longitude: Double?
}

struct PendingLocation {
    let locationId: Int
    let latitude: Double
    let longitude: Double
}

struct ManagedLocation: Identifiable {
    let locationId: Int
    let nickname: String?
    let placeName: String?
    let city: String?
    let state: String?
    let locationType: String?
    let isFavorite: Bool
    let eventCount: Int
    let latitude: Double?
    let longitude: Double?
    let isCurrentHome: Bool
    let homeStartDate: String?
    let homeEndDate: String?

    var id: Int { locationId }

    var homeRole: LocationHomeRole {
        if isCurrentHome {
            return .current
        }
        if homeStartDate != nil, homeEndDate != nil {
            return .former
        }
        return .none
    }

    var isFormerHome: Bool {
        homeRole == .former
    }

    var homeOccupancySummary: String? {
        guard let start = EventDateParser.parseDate(homeStartDate ?? ""),
              let end = EventDateParser.parseDate(homeEndDate ?? "") else {
            if isCurrentHome,
               let start = EventDateParser.parseDate(homeStartDate ?? "") {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                return "Since \(formatter.string(from: start))"
            }
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    var displayTitle: String {
        if isCurrentHome {
            if let nickname, !nickname.isEmpty {
                return nickname
            }
            return "Current Home"
        }

        if isFormerHome {
            if let nickname, !nickname.isEmpty {
                return nickname
            }
            return "Former Home"
        }

        if let nickname, !nickname.isEmpty {
            return nickname
        }
        if let placeName, !placeName.isEmpty {
            return placeName
        }
        if let cityState = cityStateLine {
            return cityState
        }
        if let latitude, let longitude {
            return String(format: "%.4f, %.4f", latitude, longitude)
        }
        return "Location #\(locationId)"
    }

    var cityStateLine: String? {
        switch (city, state) {
        case let (city?, state?):
            return "\(city), \(state)"
        case let (city?, nil):
            return city
        case let (nil, state?):
            return state
        default:
            return nil
        }
    }

    /// Subtitle under the main title in list/detail when a user nickname or geocoded place is shown.
    var detailSubtitle: String? {
        if let nickname, !nickname.isEmpty {
            if let placeName, !placeName.isEmpty {
                return placeName
            }
            return cityStateLine
        }

        if let placeName, !placeName.isEmpty {
            return cityStateLine
        }

        return nil
    }

    var cityStateSubtitle: String? {
        detailSubtitle
    }

    var mapCoordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }
}

struct EventTuningSettings: Codable, Equatable {
    static let storageKey = "eventTuningSettings"

    var localEventMatchMiles: Double = 1.0
    var tripEventMatchMiles: Double = 40.0
    var awayFromHomeMiles: Double = 50.0
    var eventMatchMaxGapHours: Double = 8.0
    var eventMatchDistanceWeight: Double = 600.0

    var sameDayEventMergeMiles: Double = 0.75
    var tripMergeMaxGapHours: Double = 36.0
    var tripSubEventMatchMiles: Double = 2.0
    var tripSubEventMaxGapHours: Double = 4.0

    var locationMatchMiles: Double = 0.05
    var curatedLocationMatchMiles: Double = 0.03
    var samePlaceNameMergeMiles: Double = 0.5
    var addressDeduplicationMaxMiles: Double = 1.0
    var frequentPlaceMergeMiles: Double = 0.35
    var frequentPlaceMinEvents: Int = 5
    var homeLocationMergeMiles: Double = 0.12
    var homeEventSnapMiles: Double = 0.2

    static let defaults = EventTuningSettings()

    var eventMatchMaxGapSeconds: TimeInterval { eventMatchMaxGapHours * 3600 }
    var tripMergeMaxGapSeconds: TimeInterval { tripMergeMaxGapHours * 3600 }
    var tripSubEventMaxGapSeconds: TimeInterval { tripSubEventMaxGapHours * 3600 }
}

final class PhotoDatabase {

    static let defaultLocationTypes = ["Stadium", "Beach", "Lake"]
    private static let customLocationTypesKey = "customLocationTypes"
    static let faceMetricsAlgorithmVersionKey = "faceMetricsAlgorithmVersion"
    static let cropAlgorithmVersionKey = "cropAlgorithmVersion"

    private var eventTuningCache: EventTuningSettings?

    static let shared = PhotoDatabase()

    private let databaseManager: DatabaseManager
    private let photoRepository: PhotoRepository
    private let peopleRepository: PeopleRepository
    private let eventRepository: EventRepository
    private lazy var eventClustering: EventClusteringService = {
        EventClusteringService(host: self, database: databaseManager, events: eventRepository)
    }()
    private var pendingGeocodeEnqueues: [PendingLocation] = []

    private let iso8601Formatter = ISO8601DateFormatter()
    private let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    private var db: OpaquePointer? {
        databaseManager.connection
    }

    private var dbQueue: DispatchQueue {
        databaseManager.queue
    }

    private var dbQueueKey: DispatchSpecificKey<UInt8> {
        databaseManager.queueKey
    }

    private init() {
        databaseManager = DatabaseManager.shared
        photoRepository = PhotoRepository(database: databaseManager)
        peopleRepository = PeopleRepository(database: databaseManager)
        eventRepository = EventRepository(database: databaseManager, photos: photoRepository)
        createTablesIfNeeded()
        migrateTablesIfNeeded()
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
                setAppMetadata(key: EventTuningSettings.storageKey, value: json)
            }
            eventTuningCache = settings
        }
    }

    func resetEventTuningSettings() {
        dbQueue.sync {
            let sql = "DELETE FROM app_metadata WHERE key = ?;"
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(
                    statement,
                    1,
                    (EventTuningSettings.storageKey as NSString).utf8String,
                    -1,
                    nil
                )
                sqlite3_step(statement)
            }

            sqlite3_finalize(statement)
            eventTuningCache = nil
        }
    }

    func eventTuningUnsafe() -> EventTuningSettings {
        if let eventTuningCache {
            return eventTuningCache
        }

        if let json = getAppMetadata(key: EventTuningSettings.storageKey),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(EventTuningSettings.self, from: data) {
            eventTuningCache = decoded
            return decoded
        }

        return .defaults
    }

    private var isOnDatabaseQueue: Bool {
        databaseManager.isOnQueue
    }

    func flushPendingGeocodeEnqueues() {
        guard !pendingGeocodeEnqueues.isEmpty else { return }
        let batch = pendingGeocodeEnqueues
        pendingGeocodeEnqueues = []
        LocationGeocodeCoordinator.shared.enqueue(batch)
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

    func resumeGeocodingIfNeeded() {
        repairHomeLocations()
        restoreDeletedTripContainersOnQueue()
        resumeGeocodingCoordinatorIfNeeded()
    }

    func resumeGeocodingCoordinatorIfNeeded() {
        LocationGeocodeCoordinator.shared.resumeIfNeeded()
    }

    func stopGeocoding() {
        LocationGeocodeCoordinator.shared.stopAll()
    }

    func repairHomeLocations() {
        dbQueue.sync {
            mergeNearbyLocationsIntoCurrentHome()
            snapEventsNearDesignatedHomesUnsafe()
            backfillCurrentHomeAddressIfNeeded()
        }
        flushPendingGeocodeEnqueues()
    }

    func restoreDeletedTripContainersOnQueue() {
        dbQueue.sync {
            eventRepository.restoreDeletedTripContainers()
        }
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
        dbQueue.sync {
            updateLocationGeocode(
                locationId: locationId,
                city: city,
                state: state,
                placeName: placeName,
                status: "complete"
            )
            updateEventsFromLocation(locationId: locationId)
            mergeLocationAfterGeocodeUnsafe(locationId: locationId)
        }
    }

    func markLocationGeocodeFailed(locationId: Int) {
        dbQueue.sync {
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
    
    func createTablesIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS photos (
            id TEXT PRIMARY KEY,

            creationDate TEXT,
            modificationDate TEXT,

            mediaType INTEGER,
            mediaSubtype INTEGER,

            width INTEGER,
            height INTEGER,

            isFavorite INTEGER,
            isHidden INTEGER,

            latitude REAL,
            longitude REAL,

            isScreenshot INTEGER,

            aspectRatio REAL,
            orientation TEXT,

            qualityScore INTEGER,

            isDeleted INTEGER DEFAULT 0,
            deletedAt TEXT,
            lastSeenAt TEXT,

            indexedAt TEXT,

            eventNeedsReview INTEGER DEFAULT 0,
            eventAssignedAt TEXT
        );

        CREATE TABLE IF NOT EXISTS events (
            eventId INTEGER PRIMARY KEY AUTOINCREMENT,

            name TEXT,
            startDate TEXT,
            endDate TEXT,

            latitude REAL,
            longitude REAL,

            city TEXT,
            state TEXT,
            placeName TEXT,

            locationId INTEGER,

            coverPhotoId TEXT,
            userEditedName INTEGER DEFAULT 0,

            isDeleted INTEGER DEFAULT 0,
            deletedAt TEXT,
            updatedAt TEXT,

            showAsSlideshowEvent INTEGER DEFAULT 0,
            includeTitleSlide INTEGER DEFAULT 0,
            maxSlideshowPhotos INTEGER DEFAULT 3,

            photoCount INTEGER DEFAULT 0,

            eventType TEXT,
            activityType TEXT,
            milestoneType TEXT,
            holidayType TEXT,
            eventMainPerson TEXT,
            tripType TEXT
        );

        
        
        CREATE TABLE IF NOT EXISTS photo_events (
            photoId TEXT,
            eventId INTEGER,
            includeInSlideshow INTEGER,
            manuallyExcluded INTEGER,
            manualBoost INTEGER,
            PRIMARY KEY (photoId, eventId)
        );
        
        CREATE TABLE IF NOT EXISTS people (
            personId INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL
        );

        CREATE TABLE IF NOT EXISTS photo_people (
            photoId TEXT NOT NULL,
            personId INTEGER NOT NULL,
            source TEXT,
            PRIMARY KEY (photoId, personId)
        );

        CREATE TABLE IF NOT EXISTS event_people (
            eventId INTEGER,
            personId INTEGER,
            photoCount INTEGER,
            PRIMARY KEY (eventId, personId)
        );
        
        CREATE TABLE IF NOT EXISTS app_metadata (
            key TEXT PRIMARY KEY,
            value TEXT
        );
        
        CREATE TABLE IF NOT EXISTS locations (
            locationId INTEGER PRIMARY KEY AUTOINCREMENT,
            latitudeBucket REAL NOT NULL,
            longitudeBucket REAL NOT NULL,
            latitude REAL,
            longitude REAL,
            city TEXT,
            state TEXT,
            placeName TEXT,
            nickname TEXT,
            locationType TEXT,
            geocodeStatus TEXT,
            lastGeocodedAt TEXT,
            createdAt TEXT,
            updatedAt TEXT,
            UNIQUE(latitudeBucket, longitudeBucket)
        );
        
        CREATE INDEX IF NOT EXISTS idx_photos_creationDate
        ON photos(creationDate);

        CREATE INDEX IF NOT EXISTS idx_photos_deleted
        ON photos(isDeleted);

        CREATE INDEX IF NOT EXISTS idx_photo_events_eventId
        ON photo_events(eventId);

        CREATE INDEX IF NOT EXISTS idx_photo_events_photoId
        ON photo_events(photoId);

        CREATE INDEX IF NOT EXISTS idx_photo_people_photoId
        ON photo_people(photoId);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            print("Tables ready")
        } else {
            print("Unable to create tables: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func migrateTablesIfNeeded() {
        addColumnIfNeeded(table: "photos", column: "isDeleted", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "photos", column: "deletedAt", definition: "TEXT")
        addColumnIfNeeded(table: "photos", column: "lastSeenAt", definition: "TEXT")

        addColumnIfNeeded(table: "photos", column: "eventAssignedAt", definition: "TEXT")
        addColumnIfNeeded(table: "photos", column: "eventNeedsReview", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "photos", column: "captureDateOverride", definition: "TEXT")
        addColumnIfNeeded(table: "photos", column: "userLatitude", definition: "REAL")
        addColumnIfNeeded(table: "photos", column: "userLongitude", definition: "REAL")

        addColumnIfNeeded(table: "events", column: "locationId", definition: "INTEGER")
        addColumnIfNeeded(table: "events", column: "isDeleted", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "events", column: "deletedAt", definition: "TEXT")
        addColumnIfNeeded(table: "events", column: "updatedAt", definition: "TEXT")
        addColumnIfNeeded(table: "events", column: "photoCount", definition: "INTEGER DEFAULT 0")
        
        addColumnIfNeeded(table: "events", column: "coverPhotoId", definition: "TEXT")
        addColumnIfNeeded(table: "events", column: "isFavorite", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "events", column: "userEditedName", definition: "INTEGER DEFAULT 0")
        
        addColumnIfNeeded(table: "events", column: "showAsSlideshowEvent", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "events", column: "includeTitleSlide", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "events", column: "maxSlideshowPhotos", definition: "INTEGER DEFAULT 3")
        addColumnIfNeeded(table: "events", column: "isUserHidden", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "events", column: "parentEventId", definition: "INTEGER")
        addColumnIfNeeded(table: "events", column: "isTripEvent", definition: "INTEGER DEFAULT 0")

        dropColumnIfNeeded(table: "events", column: "eventSubType")
        dropColumnIfNeeded(table: "events", column: "eventType")

        sqlite3_exec(
            db,
            "DELETE FROM app_metadata WHERE key = 'customEventSubTypes';",
            nil,
            nil,
            nil
        )

        addColumnIfNeeded(table: "events", column: "eventType", definition: "TEXT")
        addColumnIfNeeded(table: "events", column: "activityType", definition: "TEXT")
        addColumnIfNeeded(table: "events", column: "milestoneType", definition: "TEXT")
        addColumnIfNeeded(table: "events", column: "holidayType", definition: "TEXT")
        addColumnIfNeeded(table: "events", column: "eventMainPerson", definition: "TEXT")
        addColumnIfNeeded(table: "events", column: "tripType", definition: "TEXT")
        eventRepository.migrateLegacyTripEventTypeAttribute()
        addColumnIfNeeded(table: "locations", column: "isFavorite", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "locations", column: "nickname", definition: "TEXT")
        addColumnIfNeeded(table: "locations", column: "isCurrentHome", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "locations", column: "homeStartDate", definition: "TEXT")
        addColumnIfNeeded(table: "locations", column: "homeEndDate", definition: "TEXT")

        migrateLegacyHomeLocations()
        
        addColumnIfNeeded(table: "photo_events", column: "includeInSlideshow", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "photo_events", column: "manuallyExcluded", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "photo_events", column: "manualBoost", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "photo_events", column: "isSimilarGroupPick", definition: "INTEGER DEFAULT 0")

        addColumnIfNeeded(table: "photos", column: "faceEyesOpenScore", definition: "REAL")
        addColumnIfNeeded(table: "photos", column: "faceSmileScore", definition: "REAL")
        addColumnIfNeeded(table: "photos", column: "listCropFocusX", definition: "REAL")
        addColumnIfNeeded(table: "photos", column: "listCropFocusY", definition: "REAL")
        addColumnIfNeeded(table: "photos", column: "frameCropFocusX", definition: "REAL")
        addColumnIfNeeded(table: "photos", column: "frameCropFocusY", definition: "REAL")
        addColumnIfNeeded(table: "events", column: "childEventName", definition: "TEXT")
        addColumnIfNeeded(table: "events", column: "userEditedChildEventName", definition: "INTEGER DEFAULT 0")

        eventRepository.migrateTripSubEventChildNamesIfNeeded()

        sqlite3_exec(
            db,
            """
            CREATE INDEX IF NOT EXISTS idx_events_locationId ON events(locationId);
            CREATE INDEX IF NOT EXISTS idx_events_parentEventId ON events(parentEventId);
            CREATE INDEX IF NOT EXISTS idx_events_assignment
            ON events(isDeleted, parentEventId, startDate, endDate);
            """,
            nil,
            nil,
            nil
        )

        repairStaleGeocodeStatuses()
    }

    private func repairStaleGeocodeStatuses() {
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
    
    private func addColumnIfNeeded(table: String, column: String, definition: String) {
        guard !columnExists(table: table, column: column) else { return }

        let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);"

        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            print("Added column \(column) to \(table)")
        } else {
            print("Failed to add column \(column): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func columnExists(table: String, column: String) -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let columnName = String(cString: sqlite3_column_text(statement, 1))
                if columnName == column {
                    sqlite3_finalize(statement)
                    return true
                }
            }
        }

        sqlite3_finalize(statement)
        return false
    }

    private func dropColumnIfNeeded(table: String, column: String) {
        guard columnExists(table: table, column: column) else { return }

        let sql = "ALTER TABLE \(table) DROP COLUMN \(column);"

        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            print("Dropped column \(column) from \(table)")
        } else {
            print("Failed to drop column \(column): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func resetDatabaseForDevelopmentOnly() {
        let sql = """
        DROP TABLE IF EXISTS event_people;
        DROP TABLE IF EXISTS photo_people;
        DROP TABLE IF EXISTS people;
        DROP TABLE IF EXISTS photo_events;
        DROP TABLE IF EXISTS events;
        DROP TABLE IF EXISTS photos;
        """

        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            print("DEV reset complete")
            createTablesIfNeeded()
            migrateTablesIfNeeded()
        } else {
            print("Unable to reset tables: \(String(cString: sqlite3_errmsg(db)))")
        }
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

    func debugLocationCounts() {
        print("---- LOCATION DEBUG ----")
        print("locations rows: \(countRows("locations"))")
        print("pending locations: \(countRows("locations WHERE geocodeStatus = 'pending'"))")
        print("complete locations: \(countRows("locations WHERE geocodeStatus = 'complete'"))")
        print("events with locationId: \(countRows("events WHERE locationId IS NOT NULL"))")
        print("events without locationId: \(countRows("events WHERE locationId IS NULL"))")
        print("------------------------")
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

    func importPeopleFromAlbums() {
        importPeopleFromCollectionType(.album)
        importPeopleFromCollectionType(.smartAlbum)
    }

    private func importPeopleFromCollectionType(_ type: PHAssetCollectionType) {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: type,
            subtype: .any,
            options: nil
        )

        collections.enumerateObjects { collection, _, _ in
            guard let albumName = collection.localizedTitle else { return }
            guard albumName.hasPrefix("P-") else { return }

            let personName = String(albumName.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !personName.isEmpty else { return }

            let personId = self.upsertPerson(name: personName)
            let assets = PHAsset.fetchAssets(in: collection, options: nil)

            assets.enumerateObjects { asset, _, _ in
                self.linkPhotoToPerson(
                    photoId: asset.localIdentifier,
                    personId: personId,
                    source: "album"
                )
            }

            print("Imported \(assets.count) photos for person: \(personName)")
        }
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

        print("events has locationId: \(columnExists(table: "events", column: "locationId"))")

        print("locations rows: \(countRows("locations"))")

    }
    
    func countPhotosMissingLocation() -> Int {
        countRows(
            """
            photos
            WHERE isDeleted = 0
              AND isScreenshot = 0
              AND COALESCE(userLatitude, latitude) IS NULL
            """
        )
    }

    func countActivePhotos() -> Int {
        dbQueue.sync {
            countRows("photos WHERE isDeleted = 0")
        }
    }

    func getLikelyUploadBatches(
        gapSeconds: TimeInterval = 6 * 60 * 60,
        minPhotos: Int = 1
    ) -> [PhotoUploadBatch] {
        let sql = """
        SELECT id, creationDate, captureDateOverride, userLatitude, userLongitude
        FROM photos
        WHERE isDeleted = 0
          AND isScreenshot = 0
          AND COALESCE(userLatitude, latitude) IS NULL
        ORDER BY creationDate ASC;
        """

        var statement: OpaquePointer?
        struct Row {
            let id: String
            let importDate: Date
            let captureOverride: Date?
            let userLatitude: Double?
            let userLongitude: Double?
        }

        var rows: [Row] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(statement, 0))
                let creationString = String(cString: sqlite3_column_text(statement, 1))

                guard let importDate = iso8601Formatter.date(from: creationString) else {
                    continue
                }

                let captureOverride: Date?
                if sqlite3_column_type(statement, 2) != SQLITE_NULL {
                    let overrideString = String(cString: sqlite3_column_text(statement, 2))
                    captureOverride = iso8601Formatter.date(from: overrideString)
                } else {
                    captureOverride = nil
                }

                let userLatitude: Double? =
                    sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 3)

                let userLongitude: Double? =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 4)

                rows.append(
                    Row(
                        id: id,
                        importDate: importDate,
                        captureOverride: captureOverride,
                        userLatitude: userLatitude,
                        userLongitude: userLongitude
                    )
                )
            }
        }

        sqlite3_finalize(statement)

        guard !rows.isEmpty else { return [] }

        var batches: [[Row]] = []
        var currentBatch: [Row] = [rows[0]]

        for row in rows.dropFirst() {
            let gap = row.importDate.timeIntervalSince(currentBatch.last!.importDate)
            if gap > gapSeconds {
                batches.append(currentBatch)
                currentBatch = [row]
            } else {
                currentBatch.append(row)
            }
        }

        batches.append(currentBatch)

        return batches
            .filter { $0.count >= minPhotos }
            .map { batchRows in
                let importStart = batchRows.first!.importDate
                let importEnd = batchRows.last!.importDate
                let photoIds = batchRows.map(\.id)
                let samplePhotoIds = Array(photoIds.prefix(24))

                let overrides = batchRows.compactMap(\.captureOverride)
                let assignedCaptureDate =
                    overrides.count == batchRows.count ? overrides.first : nil

                let hasAssignedLocation = batchRows.allSatisfy {
                    $0.userLatitude != nil && $0.userLongitude != nil
                }

                let assignedLocationId: Int?
                if hasAssignedLocation,
                   let latitude = batchRows.first?.userLatitude,
                   let longitude = batchRows.first?.userLongitude {
                    assignedLocationId = findLocationWithinMiles(
                        latitude: latitude,
                        longitude: longitude,
                        maxMiles: eventTuningUnsafe().locationMatchMiles
                    )
                } else {
                    assignedLocationId = nil
                }

                let id = iso8601Formatter.string(from: importStart)

                return PhotoUploadBatch(
                    id: id,
                    importStart: importStart,
                    importEnd: importEnd,
                    photoIds: photoIds,
                    samplePhotoIds: samplePhotoIds,
                    assignedCaptureDate: assignedCaptureDate,
                    assignedLocationId: assignedLocationId,
                    hasAssignedLocation: hasAssignedLocation
                )
            }
            .sorted { $0.importStart > $1.importStart }
    }

    func applyArchiveBatchMetadata(
        photoIds: [String],
        captureDate: Date,
        latitude: Double,
        longitude: Double
    ) {
        let captureISO = iso8601Formatter.string(from: captureDate)
        let now = iso8601Formatter.string(from: Date())

        let sql = """
        UPDATE photos
        SET captureDateOverride = ?,
            userLatitude = ?,
            userLongitude = ?,
            eventAssignedAt = NULL,
            eventNeedsReview = 0,
            indexedAt = ?
        WHERE id = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            print("Failed to prepare archive batch update: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        for photoId in photoIds {
            sqlite3_bind_text(statement, 1, (captureISO as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 2, latitude)
            sqlite3_bind_double(statement, 3, longitude)
            sqlite3_bind_text(statement, 4, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 5, (photoId as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed archive batch update for \(photoId): \(String(cString: sqlite3_errmsg(db)))")
            }

            sqlite3_reset(statement)
        }

        sqlite3_finalize(statement)
        print("Applied archive metadata to \(photoIds.count) photos")
    }


    /// Clears all event assignments and re-groups every photo. Preserves locations
    /// (nicknames, current/former home, favorites). Custom event names are not kept.
    private func updateEventLocationId(eventId: Int, locationId: Int) {

        let sql = """
        UPDATE events
        SET locationId = ?
        WHERE eventId = ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(locationId))
            sqlite3_bind_int(statement, 2, Int32(eventId))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    private func clearEventLocationFields(eventId: Int) {
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

            updateEventsFromLocation(locationId: locationId)

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
                updateEventsFromLocation(locationId: toLocationId)
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

                updateEventLocationId(eventId: eventId, locationId: locationId)
            }
        }

        sqlite3_finalize(statement)

        print("Rebuilt locations for existing events")
        debugLocationCounts()
    }
    
    func getLocationTypeOptions() -> [String] {
        var options = Set(PhotoDatabase.defaultLocationTypes)

        if let custom = getAppMetadata(key: PhotoDatabase.customLocationTypesKey),
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
            .subtracting(PhotoDatabase.defaultLocationTypes)
            .sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }

        setAppMetadata(
            key: PhotoDatabase.customLocationTypesKey,
            value: customOnly.joined(separator: ",")
        )
    }

    func getAllPersonNames() -> [String] {
        peopleRepository.getAllPersonNames()
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
        let locationId = dbQueue.sync { () -> Int in
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

        guard locationId > 0 else { return locationId }

        requestFreshGeocodeForLocation(
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

    private func migrateLegacyHomeLocations() {
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

    private func isoDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Calendar.current.startOfDay(for: date))
    }

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
        Int(getAppMetadata(key: PhotoDatabase.faceMetricsAlgorithmVersionKey) ?? "") ?? 0
    }

    func setFaceMetricsAlgorithmVersion(_ version: Int) {
        setAppMetadata(
            key: PhotoDatabase.faceMetricsAlgorithmVersionKey,
            value: String(version)
        )
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
        Int(getAppMetadata(key: PhotoDatabase.cropAlgorithmVersionKey) ?? "") ?? 0
    }

    func setCropAlgorithmVersion(_ version: Int) {
        setAppMetadata(
            key: PhotoDatabase.cropAlgorithmVersionKey,
            value: String(version)
        )
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
            let pending = getPendingLocations(limit: limit)
            LocationGeocodeCoordinator.shared.enqueue(pending)
        } else {
            startGeocodingAllPending()
        }
    }
    
    func debugCounts() {
        print("photos rows: \(countRows("photos"))")
        print("active photos rows: \(countRows("photos WHERE isDeleted = 0"))")
        print("deleted photos rows: \(countRows("photos WHERE isDeleted = 1"))")
        print("events rows: \(countRows("events"))")
        print("people rows: \(countRows("people"))")
        print("photo_people rows: \(countRows("photo_people"))")
        print("event_people rows: \(countRows("event_people"))")
        print("events with city rows: \(countRows("events WHERE city IS NOT NULL AND city != ''"))")
    }

    func debugPrintFirstEvents() {
        let sql = """
        SELECT eventId, name, city, state, placeName
        FROM events
        ORDER BY eventId ASC
        LIMIT 20;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let eventId = Int(sqlite3_column_int(statement, 0))
                let name = String(cString: sqlite3_column_text(statement, 1))

                let city =
                    sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? "nil"
                    : String(cString: sqlite3_column_text(statement, 2))

                let state =
                    sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? "nil"
                    : String(cString: sqlite3_column_text(statement, 3))

                let place =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? "nil"
                    : String(cString: sqlite3_column_text(statement, 4))

                print("DB EVENT \(eventId): \(name) | \(city), \(state) | \(place)")
            }
        } else {
            print("debugPrintFirstEvents failed: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
    }

    func debugPrintAlbumNames() {
        print("---- Regular Albums ----")
        debugPrintAlbums(type: .album)

        print("---- Smart Albums ----")
        debugPrintAlbums(type: .smartAlbum)
    }

    private func debugPrintAlbums(type: PHAssetCollectionType) {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: type,
            subtype: .any,
            options: nil
        )

        collections.enumerateObjects { collection, _, _ in
            print("Album: \(collection.localizedTitle ?? "nil")")
        }
    }

    private func debugEventPeopleCount() {
        let sql = "SELECT COUNT(*) FROM event_people;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                print("event_people rows: \(sqlite3_column_int(statement, 0))")
            }
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

    private func readIndexedPhoto(from statement: OpaquePointer?) -> IndexedPhoto {
        photoRepository.readIndexedPhotoRow(from: statement)
    }

    private func getHighestEventId() -> Int {
        let sql = "SELECT MAX(eventId) FROM events;"
        var statement: OpaquePointer?
        var highest = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                highest = Int(sqlite3_column_int(statement, 0))
            }
        }

        sqlite3_finalize(statement)
        return highest
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

    private static func optionalString(on object: NSObject, key: String) -> String? {
        guard let raw = object.value(forKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func mapItemAddressRepresentations(_ mapItem: MKMapItem) -> MKAddressRepresentations? {
        (mapItem as NSObject).value(forKey: "addressRepresentations") as? MKAddressRepresentations
    }

    private static func mapItemAddress(_ mapItem: MKMapItem) -> MKAddress? {
        (mapItem as NSObject).value(forKey: "address") as? MKAddress
    }

    static func geocodedCity(from mapItem: MKMapItem) -> String? {
        guard let reps = mapItemAddressRepresentations(mapItem) else { return nil }
        return optionalString(on: reps, key: "cityName")
    }

    static func geocodedCityWithContext(from mapItem: MKMapItem) -> String? {
        guard let reps = mapItemAddressRepresentations(mapItem) else { return nil }
        return optionalString(on: reps, key: "cityWithContext")
    }

    static func administrativeArea(from mapItem: MKMapItem) -> String? {
        guard let context = geocodedCityWithContext(from: mapItem) else { return nil }
        let parts = context
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        return parts[1]
    }

    /// Safe coordinate lookup — `MKMapItem.location` and `.placemark` can be nil at runtime on iOS 26.
    static func coordinate(from mapItem: MKMapItem) -> CLLocationCoordinate2D? {
        if let location = (mapItem as NSObject).value(forKey: "location") as? CLLocation {
            return location.coordinate
        }

        if let placemark = (mapItem as NSObject).value(forKey: "placemark") as? MKPlacemark,
           let coordinate = placemark.location?.coordinate {
            return coordinate
        }

        return nil
    }

    static func placeLabel(from mapItem: MKMapItem) -> String? {
        let city = geocodedCity(from: mapItem)
        let state = administrativeArea(from: mapItem)
        let cityWithContext = geocodedCityWithContext(from: mapItem)

        if let name = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           name != city,
           name != state,
           name != cityWithContext {
            return name
        }

        if let address = mapItemAddress(mapItem),
           let shortAddress = optionalString(on: address, key: "shortAddress"),
           shortAddress != city,
           shortAddress != cityWithContext {
            return shortAddress
        }

        return nil
    }

    static func geocodedFormattedAddress(from mapItem: MKMapItem) -> String {
        if let placeName = placeLabel(from: mapItem) {
            if let city = geocodedCity(from: mapItem),
               let state = administrativeArea(from: mapItem) {
                return "\(placeName), \(city), \(state)"
            }
            return placeName
        }

        if let reps = mapItemAddressRepresentations(mapItem),
           let fullAddress = reps.fullAddress(includingRegion: false, singleLine: true),
           !fullAddress.isEmpty {
            return fullAddress
        }

        if let address = mapItemAddress(mapItem),
           let fullAddress = optionalString(on: address, key: "fullAddress") {
            return fullAddress
        }

        return ""
    }

    /// ~11 m precision at mid-latitudes (4 decimal places). Used for location dedup keys only.
    private func coordinateBucket(_ value: Double) -> Double {
        return (value * 10_000).rounded() / 10_000
    }

    private func getCoverPhotoCoordinates(eventId: Int) -> (latitude: Double, longitude: Double)? {
        let sql = """
        SELECT p.latitude, p.longitude
        FROM events e
        JOIN photos p ON p.id = e.coverPhotoId
        WHERE e.eventId = ?
          AND p.isDeleted = 0
          AND p.latitude IS NOT NULL
          AND p.longitude IS NOT NULL;
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

    private struct PhotoCoordinate {
        let latitude: Double
        let longitude: Double
        let qualityScore: Int
    }

    private func getPhotoCoordinatesForEvent(eventId: Int) -> [PhotoCoordinate] {
        let sql = """
        SELECT p.latitude, p.longitude, p.qualityScore
        FROM photos p
        JOIN photo_events pe ON p.id = pe.photoId
        WHERE pe.eventId = ?
          AND p.isDeleted = 0
          AND p.latitude IS NOT NULL
          AND p.longitude IS NOT NULL;
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
            let latBucket = coordinateBucket(coordinate.latitude)
            let lonBucket = coordinateBucket(coordinate.longitude)
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

        let latitude =
            cluster.map(\.latitude).reduce(0, +) / Double(cluster.count)
        let longitude =
            cluster.map(\.longitude).reduce(0, +) / Double(cluster.count)

        return (latitude, longitude)
    }

    private func representativeCoordinatesForEvent(eventId: Int) -> (latitude: Double, longitude: Double)? {
        if let cluster = getDensestClusterCoordinates(eventId: eventId) {
            return cluster
        }

        return getCoverPhotoCoordinates(eventId: eventId)
    }

    func updateEventLocationFromRepresentativePoint(eventId: Int) {
        guard let coordinates = representativeCoordinatesForEvent(eventId: eventId) else {
            return
        }

        let previousLocationId = getEventLocationId(eventId: eventId)
        let eventDate = getEventStartDate(eventId: eventId) ?? Date()
        let locationId = findOrCreateLocation(
            latitude: coordinates.latitude,
            longitude: coordinates.longitude,
            at: eventDate
        )

        guard locationId > 0 else { return }

        updateEventLocationId(eventId: eventId, locationId: locationId)
        clearEventLocationFields(eventId: eventId)

        if previousLocationId == locationId,
           isLocationGeocodeComplete(locationId: locationId) {
            return
        }

        if previousLocationId == locationId,
           !isLocationGeocodeComplete(locationId: locationId) {
            requestFreshGeocodeForLocation(
                locationId: locationId,
                latitude: coordinates.latitude,
                longitude: coordinates.longitude
            )
            return
        }

        resetLocationForGeocoding(
            locationId: locationId,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude
        )
        requestFreshGeocodeForLocation(
            locationId: locationId,
            latitude: coordinates.latitude,
            longitude: coordinates.longitude
        )

        syncDefaultChildEventNameIfSubEvent(eventId: eventId)
    }

    private func syncDefaultChildEventNameIfSubEvent(eventId: Int) {
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
        syncDefaultChildEventName(forSubEventId: eventId)
    }

    private func getEventLocationId(eventId: Int) -> Int? {
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

    private func isLocationGeocodeComplete(locationId: Int) -> Bool {
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

    private func resetLocationForGeocoding(
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

    private func requestFreshGeocodeForLocation(
        locationId: Int,
        latitude: Double,
        longitude: Double
    ) {
        resetLocationGeocodeToPending(locationId: locationId)
        let pending = PendingLocation(
            locationId: locationId,
            latitude: latitude,
            longitude: longitude
        )

        if isOnDatabaseQueue {
            pendingGeocodeEnqueues.append(pending)
        } else {
            LocationGeocodeCoordinator.shared.enqueue([pending])
        }
    }

    func deduplicateLocationsByAddress(
        maxDistanceMiles: Double? = nil
    ) -> Int {
        dbQueue.sync {
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
                reassignEvents(
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

            updateEventsFromLocation(locationId: canonical.locationId)
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

    private func reassignEvents(fromLocationId: Int, toLocationId: Int) {
        guard fromLocationId != toLocationId else { return }

        let sql = """
        UPDATE events
        SET locationId = ?
        WHERE locationId = ?
          AND isDeleted = 0;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(toLocationId))
            sqlite3_bind_int(statement, 2, Int32(fromLocationId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
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

    private func findDesignatedHomeLocationId(
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

    func snapEventsNearDesignatedHomes() {
        dbQueue.sync {
            snapEventsNearDesignatedHomesUnsafe()
        }
    }

    func snapEventsNearDesignatedHomesUnsafe() {
        guard let home = getCurrentHomeLocation(),
              let homeLatitude = home.latitude,
              let homeLongitude = home.longitude else {
            return
        }

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

                let distanceFromHome = distanceInMiles(
                    lat1: storedLatitude,
                    lon1: storedLongitude,
                    lat2: homeLatitude,
                    lon2: homeLongitude
                )

                guard distanceFromHome <= eventTuningUnsafe().homeEventSnapMiles else { continue }

                guard let homeLocationId = homeLocationIdForEvent(
                    eventId: eventId,
                    storedLatitude: storedLatitude,
                    storedLongitude: storedLongitude,
                    at: eventDate
                ) else {
                    continue
                }

                guard currentLocationId != homeLocationId else { continue }

                updateEventLocationId(eventId: eventId, locationId: homeLocationId)
                clearEventLocationFields(eventId: eventId)
                updateEventsFromLocation(locationId: homeLocationId)
                relinked += 1
            }
        }

        sqlite3_finalize(statement)

        if relinked > 0 {
            print("Relinked \(relinked) home events to designated home location")
        }
    }

    private func homeLocationIdForEvent(
        eventId: Int,
        storedLatitude: Double,
        storedLongitude: Double,
        at date: Date
    ) -> Int? {
        if let rep = representativeCoordinatesForEvent(eventId: eventId),
           let homeId = findDesignatedHomeLocationId(
               latitude: rep.latitude,
               longitude: rep.longitude,
               at: date
           ) {
            return homeId
        }

        if let homeId = findDesignatedHomeLocationId(
            latitude: storedLatitude,
            longitude: storedLongitude,
            at: date
        ) {
            return homeId
        }

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

                if let homeId = findDesignatedHomeLocationId(
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
                reassignEvents(fromLocationId: locationId, toLocationId: homeLocationId)
                deleteLocationIfUnused(locationId: locationId)
                merged += 1
            }
        }

        sqlite3_finalize(statement)

        if merged > 0 {
            updateEventsFromLocation(locationId: homeLocationId)
            print("Merged \(merged) nearby location row(s) into Current Home")
        }
    }

    private func backfillCurrentHomeAddressIfNeeded() {
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
            updateEventsFromLocation(locationId: homeLocationId)
            print("Backfilled Current Home address from nearby location \(bestSourceId)")
            return
        }

        if !isLocationGeocodeComplete(locationId: homeLocationId) {
            requestFreshGeocodeForLocation(
                locationId: homeLocationId,
                latitude: homeLatitude,
                longitude: homeLongitude
            )
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

    private func getEventStartDate(eventId: Int) -> Date? {
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

    private func findLocationWithinMiles(
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
    
    private func sqliteOptionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: cString)
    }

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {

        if let value = value {

            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)

        } else {

            sqlite3_bind_null(statement, index)

        }

    }
    
    private func updateEventLocationDetails(
        eventId: Int,
        city: String?,
        state: String?,
        placeName: String?
    ) {
        let sql = """
        UPDATE events
        SET city = ?,
            state = ?,
            placeName = ?
        WHERE eventId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if let city = city {
                sqlite3_bind_text(statement, 1, (city as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 1)
            }

            if let state = state {
                sqlite3_bind_text(statement, 2, (state as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 2)
            }

            if let placeName = placeName {
                sqlite3_bind_text(statement, 3, (placeName as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 3)
            }

            sqlite3_bind_int(statement, 4, Int32(eventId))

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed updating event location: \(String(cString: sqlite3_errmsg(db)))")
            } else {
                print("Updated event \(eventId): \(city ?? "nil"), \(state ?? "nil")")
            }
        }

        sqlite3_finalize(statement)
    }
    func debugEventPipeline() {

        print("---- EVENT PIPELINE DEBUG ----")
        print("events rows: \(countRows("events"))")
        print("photo_events rows: \(countRows("photo_events"))")
        print("active photos rows: \(countRows("photos WHERE isDeleted = 0"))")
        print("photos with location rows: \(countRows("photos WHERE latitude IS NOT NULL AND longitude IS NOT NULL AND isDeleted = 0"))")
        print("clusterable photos rows: \(countRows("photos WHERE latitude IS NOT NULL AND longitude IS NOT NULL AND isScreenshot = 0 AND isDeleted = 0"))")
        print("events linked to active photos: \(countRows("photo_events pe JOIN photos p ON pe.photoId = p.id WHERE p.isDeleted = 0"))")
        print("------------------------------")

    }
    // MARK: - Event clustering
    final class EventClusteringService {

        static let eventSyncPhotoBatchSize = 500
        static let eventSyncRebuildBatchSize = 200

        private unowned let host: PhotoDatabase
        private let database: DatabaseManager
        private let events: EventRepository

        private var isRebuildContext = false
        private var lastProgressPost = Date.distantPast
        private var homeCandidatesCache: [CachedHomeCandidate]?

        private var db: OpaquePointer? { database.connection }

        private let iso8601Formatter = ISO8601DateFormatter()
        private let displayDateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            return f
        }()

        init(host: PhotoDatabase, database: DatabaseManager, events: EventRepository) {
            self.host = host
            self.database = database
            self.events = events
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
        DELETE FROM event_people;
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
            print("No unassigned photos to process")
        } else {
            print("Assigned photos in \(batches) batch(es)")
        }

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
            let photos = events.getUnassignedPhotosForEvents(limit: batchLimit)
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
        host.countRows(
            """
            photos
            WHERE isDeleted = 0
              AND eventAssignedAt IS NULL
              AND isScreenshot = 0
              AND COALESCE(userLatitude, latitude) IS NOT NULL
              AND COALESCE(userLongitude, longitude) IS NOT NULL
            """
        )
        }


        func rebuildAllEvents() {
        prepareEventRebuild()
        while syncEventsAssignmentBatch() { }
        finishEventRebuild()
        print("Event rebuild complete")
        }

        @discardableResult

        func prepareEventRebuild() -> Int {
        sync {
            isRebuildContext = true
            print("Rebuilding all events (preserving locations)")

            postEventSyncStatus("Clearing existing events…", isRebuild: true)
            clearAllEventDataPreservingLocations()

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
        DELETE FROM event_people;
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
        maxTouchedEvents: Int?
        ) {
        let total = photos.count
        print("Event assignment starting (\(total.formatted()) photos in this batch)")

        loadHomeCandidatesCache()
        defer { homeCandidatesCache = nil }

        var touchedEventIds = Set<Int>()

        for (index, photo) in photos.enumerated() {
            if let maxTouchedEvents, touchedEventIds.count >= maxTouchedEvents {
                break
            }

            if let eventId = findMatchingEvent(for: photo) {
                events.attachPhotoToEvent(photoId: photo.id, eventId: eventId)
                events.markPhotoEventAssigned(photoId: photo.id)
                events.expandEventDatesAfterAttach(eventId: eventId, photoDate: photo.date)
                touchedEventIds.insert(eventId)
            } else {
                let eventId = createEventFromPhoto(photo)
                if eventId > 0 {
                    events.attachPhotoToEvent(photoId: photo.id, eventId: eventId)
                    events.markPhotoEventAssigned(photoId: photo.id)
                    touchedEventIds.insert(eventId)
                }
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
                object: progress
            )
        }
        }


        func postEventSyncStatus(_ message: String, isRebuild: Bool = false) {
        let progress = EventSyncProgress(
            processed: 0,
            total: 0,
            remainingUnassigned: 0,
            statusMessage: message,
            isRebuild: isRebuild || isRebuildContext
        )

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .eventSyncProgressChanged,
                object: progress
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

        postEventSyncStatus("Merging nearby events…")

        mergeNearbyEventsSameDay(maxDistanceMiles: host.eventTuningUnsafe().sameDayEventMergeMiles)

        postEventSyncStatus("Merging trip events…")
        mergeAwayTripEvents()

        postEventSyncStatus("Building trip sub-events…")
        materializeTripSubEventsForAllCandidates()

        postEventSyncStatus("Deduplicating locations…")
        var mergedLocations = 0
        for _ in 0..<4 {
            let passMerged = host.mergeDuplicateLocations()
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
        host.rebuildEventPeople()

        postEventSyncStatus("Updating cover photos…")
        events.updateAllEventCoverPhotosUnsafe()
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

        updateTripParentSummary(parentEventId: parentEventId)
        host.rebuildEventPeople()
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


        func updateTripParentSummary(parentEventId: Int) {
        let sql = """
        UPDATE events
        SET
            startDate = (
                SELECT MIN(e.startDate)
                FROM events e
                WHERE e.parentEventId = ?
                  AND e.isDeleted = 0
            ),
            endDate = (
                SELECT MAX(e.endDate)
                FROM events e
                WHERE e.parentEventId = ?
                  AND e.isDeleted = 0
            ),
            photoCount = (
                SELECT COUNT(DISTINCT pe.photoId)
                FROM events e
                JOIN photo_events pe ON e.eventId = pe.eventId
                JOIN photos p ON pe.photoId = p.id
                WHERE e.parentEventId = ?
                  AND e.isDeleted = 0
                  AND p.isDeleted = 0
            ),
            latitude = (
                SELECT AVG(e.latitude)
                FROM events e
                WHERE e.parentEventId = ?
                  AND e.isDeleted = 0
                  AND e.latitude IS NOT NULL
            ),
            longitude = (
                SELECT AVG(e.longitude)
                FROM events e
                WHERE e.parentEventId = ?
                  AND e.isDeleted = 0
                  AND e.longitude IS NOT NULL
            ),
            city = (
                SELECT e.city
                FROM events e
                WHERE e.parentEventId = ?
                  AND e.isDeleted = 0
                  AND e.city IS NOT NULL
                GROUP BY e.city
                ORDER BY COUNT(*) DESC
                LIMIT 1
            ),
            state = (
                SELECT e.state
                FROM events e
                WHERE e.parentEventId = ?
                  AND e.isDeleted = 0
                  AND e.state IS NOT NULL
                GROUP BY e.state
                ORDER BY COUNT(*) DESC
                LIMIT 1
            ),
            isTripEvent = 1
        WHERE eventId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for index in 1...8 {
                sqlite3_bind_int(statement, Int32(index), Int32(parentEventId))
            }
            sqlite3_bind_int(statement, 9, Int32(parentEventId))

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed updating trip parent summary: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
        host.updateCoverPhotoForEvent(eventId: parentEventId)
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
}

// MARK: - Sequential geocoding queue

final class LocationGeocodeCoordinator {

    static let shared = LocationGeocodeCoordinator()

    private let interRequestDelay: TimeInterval = 1.25
    private let maxRetries = 5
    private let baseRetryDelay: TimeInterval = 3.0
    private let geocodeTimeout: TimeInterval = 45
    private let progressLogInterval = 25

    private var queue: [PendingLocation] = []
    private var queuedIds = Set<Int>()
    private var isProcessing = false
    private var retryCounts: [Int: Int] = [:]
    private var inFlightLocation: PendingLocation?
    private var processedSinceLog = 0
    private var geocodeTimeoutWorkItem: DispatchWorkItem?
    private var lastProgressPost = Date.distantPast
    private var inFlightRequest: MKReverseGeocodingRequest?

    private init() {}

    /// Halts the in-memory queue — use when geocoding is starving the UI.
    func stopAll() {
        geocodeTimeoutWorkItem?.cancel()
        geocodeTimeoutWorkItem = nil
        inFlightRequest?.cancel()
        inFlightRequest = nil
        queue.removeAll()
        queuedIds.removeAll()
        retryCounts.removeAll()
        inFlightLocation = nil
        processedSinceLog = 0
        isProcessing = false
        lastProgressPost = .distantPast
        print("Geocode queue: stopped")
        postProgress(isProcessing: false)
    }

    func enqueueAllPendingFromDatabase() {
        enqueue(PhotoDatabase.shared.fetchPendingGeocodeLocations(limit: nil))
    }

    func enqueueEventLocationsMissingDetails(limit: Int?) {
        enqueue(PhotoDatabase.shared.fetchEventLocationsNeedingGeocode(limit: limit))
    }

    /// Restarts processing when the queue stalled (e.g. after backgrounding or XPC drop).
    func resumeIfNeeded() {
        if isProcessing, let location = inFlightLocation {
            print("Geocode queue: resuming interrupted request for location \(location.locationId)")
            inFlightRequest?.cancel()
            clearInFlight()
            queue.insert(location, at: 0)
            isProcessing = false
        } else if isProcessing, inFlightLocation == nil, queue.isEmpty {
            isProcessing = false
        }

        guard !queue.isEmpty || inFlightLocation != nil else {
            if isProcessing {
                finishProcessing()
            }
            return
        }

        startProcessingIfNeeded()
    }

    func enqueue(_ locations: [PendingLocation]) {
        guard !locations.isEmpty else { return }

        var added = 0
        for location in locations {
            guard !queuedIds.contains(location.locationId) else { continue }
            queuedIds.insert(location.locationId)
            queue.append(location)
            added += 1
        }

        guard added > 0 else {
            startProcessingIfNeeded()
            return
        }

        print("Geocode queue: added \(added), total queued \(queue.count)")
        startProcessingIfNeeded()
    }

    private func startProcessingIfNeeded() {
        guard !isProcessing else {
            postProgress(isProcessing: true)
            return
        }

        isProcessing = true
        processNext()
    }

    private func processNext() {
        if queue.isEmpty {
            refillQueueFromDatabase()
        }

        guard !queue.isEmpty else {
            finishProcessing()
            return
        }

        postProgress(isProcessing: true)

        let location = queue.removeFirst()

        if PhotoDatabase.shared.tryCopyNearbyGeocode(
            locationId: location.locationId,
            latitude: location.latitude,
            longitude: location.longitude
        ) {
            queuedIds.remove(location.locationId)
            retryCounts.removeValue(forKey: location.locationId)
            print("Copied nearby geocode for location \(location.locationId)")
            noteProcessedLocation()
            scheduleNext(after: 0.05)
            return
        }

        inFlightLocation = location
        scheduleGeocodeTimeout()

        let clLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
        guard let request = MKReverseGeocodingRequest(location: clLocation) else {
            handleGeocodeResponse(location: location, mapItems: nil, error: nil)
            return
        }

        inFlightRequest = request
        Task { [weak self] in
            do {
                let mapItems = try await request.mapItems
                self?.handleGeocodeResponse(location: location, mapItems: mapItems, error: nil)
            } catch {
                self?.handleGeocodeResponse(location: location, mapItems: nil, error: error)
            }
        }
    }

    private func scheduleGeocodeTimeout() {
        geocodeTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleGeocodeTimeout()
        }
        geocodeTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + geocodeTimeout, execute: workItem)
    }

    private func clearInFlight() {
        geocodeTimeoutWorkItem?.cancel()
        geocodeTimeoutWorkItem = nil
        inFlightRequest?.cancel()
        inFlightRequest = nil
        inFlightLocation = nil
    }

    private func handleGeocodeTimeout() {
        guard let location = inFlightLocation else { return }

        print("Geocode timeout for location \(location.locationId)")
        inFlightRequest?.cancel()
        clearInFlight()

        let attempt = retryCounts[location.locationId, default: 0]
        if attempt < maxRetries {
            retryCounts[location.locationId] = attempt + 1
            queue.insert(location, at: 0)
            scheduleNext(after: baseRetryDelay)
            return
        }

        PhotoDatabase.shared.markLocationGeocodeFailed(locationId: location.locationId)
        queuedIds.remove(location.locationId)
        retryCounts.removeValue(forKey: location.locationId)
        noteProcessedLocation()
        scheduleNext(after: interRequestDelay)
    }

    private func refillQueueFromDatabase() {
        let pending = PhotoDatabase.shared.fetchPendingGeocodeLocations(limit: 100)
        for location in pending where !queuedIds.contains(location.locationId) {
            queuedIds.insert(location.locationId)
            queue.append(location)
        }
    }

    private func handleGeocodeResponse(
        location: PendingLocation,
        mapItems: [MKMapItem]?,
        error: Error?
    ) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            let nextDelay: TimeInterval = await self.processGeocodeResult(
                location: location,
                mapItems: mapItems,
                error: error
            )

            await MainActor.run {
                self.scheduleNext(after: nextDelay)
            }
        }
    }

    private func processGeocodeResult(
        location: PendingLocation,
        mapItems: [MKMapItem]?,
        error: Error?
    ) async -> TimeInterval {
        let stillCurrent = await MainActor.run {
            guard inFlightLocation?.locationId == location.locationId else { return false }
            clearInFlight()
            return true
        }

        guard stillCurrent else { return interRequestDelay }

        if let mapItem = mapItems?.first {
            let city = PhotoDatabase.geocodedCity(from: mapItem)
            let state = PhotoDatabase.administrativeArea(from: mapItem)
            PhotoDatabase.shared.completeLocationGeocode(
                locationId: location.locationId,
                city: city,
                state: state,
                placeName: PhotoDatabase.placeLabel(from: mapItem)
            )
            await MainActor.run {
                queuedIds.remove(location.locationId)
                retryCounts.removeValue(forKey: location.locationId)
            }
            print(
                "Geocoded location \(location.locationId): \(city ?? "nil"), \(state ?? "nil")"
            )
            await MainActor.run {
                noteProcessedLocation()
            }
            return interRequestDelay
        }

        if let error, isRetryableGeocodeError(error) {
            let attempt = await MainActor.run {
                retryCounts[location.locationId, default: 0]
            }
            if attempt < maxRetries {
                await MainActor.run {
                    retryCounts[location.locationId] = attempt + 1
                    queue.insert(location, at: 0)
                }
                let delay = baseRetryDelay * pow(2.0, Double(attempt))
                print(
                    "Geocode retry \(attempt + 1)/\(maxRetries) for location \(location.locationId) in \(Int(delay))s: \(error.localizedDescription)"
                )
                return delay
            }
        }

        let message = error?.localizedDescription ?? "no map item returned"
        print("Geocode failed for location \(location.locationId): \(message)")
        PhotoDatabase.shared.markLocationGeocodeFailed(locationId: location.locationId)
        await MainActor.run {
            queuedIds.remove(location.locationId)
            retryCounts.removeValue(forKey: location.locationId)
            noteProcessedLocation()
        }
        return interRequestDelay
    }

    private func noteProcessedLocation() {
        processedSinceLog += 1
        guard processedSinceLog % progressLogInterval == 0 else { return }

        let pending = PhotoDatabase.shared.countPendingGeocodeLocations()
        print(
            "Geocode progress: \(pending.formatted()) pending in database,"
            + " \(queue.count.formatted()) in queue"
        )
    }

    private func scheduleNext(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.processNext()
        }
    }

    private func finishProcessing() {
        clearInFlight()
        isProcessing = false
        processedSinceLog = 0
        postProgress(isProcessing: false)
        print("Geocode queue finished")
    }

    private func postProgress(isProcessing: Bool) {
        let now = Date()
        guard isProcessing == false
            || now.timeIntervalSince(lastProgressPost) >= 2.0 else {
            return
        }
        lastProgressPost = now

        let pending = PhotoDatabase.shared.countPendingGeocodeLocations()
        let progress = LocationGeocodeProgress(
            queueCount: queue.count,
            isProcessing: isProcessing,
            pendingInDatabase: pending
        )

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .locationGeocodeProgressChanged,
                object: progress
            )
        }
    }

    private func isRetryableGeocodeError(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == kCLErrorDomain {
            switch CLError.Code(rawValue: nsError.code) {
            case .network, .locationUnknown:
                return true
            case .geocodeFoundNoResult, .geocodeFoundPartialResult:
                return false
            default:
                return true
            }
        }

        if nsError.domain == "GEOErrorDomain" {
            return true
        }

        return true
    }
}

