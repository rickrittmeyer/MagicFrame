//
//  PhotoDatabase.swift
//  MagicFrame
//

import Foundation
import SQLite3
import CoreLocation
import Photos

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
final class PhotoDatabase {

    static let shared = PhotoDatabase()
    private var db: OpaquePointer?

    private init() {
        openDatabase()
        createTablesIfNeeded()
        migrateTablesIfNeeded()
    }

    private func openDatabase() {
        let fileURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagicFrame.sqlite")

        if sqlite3_open(fileURL.path, &db) == SQLITE_OK {
            print("Database opened")
            print("Database path: \(fileURL.path)")
        } else {
            print("Unable to open database")
        }
    }

    private func getPendingLocations(limit: Int) -> [PendingLocation] {
        let sql = """
        SELECT locationId, latitude, longitude
        FROM locations
        WHERE geocodeStatus = 'pending'
          AND latitude IS NOT NULL
          AND longitude IS NOT NULL
        ORDER BY locationId ASC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        var locations: [PendingLocation] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))

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
    
    func updateEventsFromLocation(locationId: Int) {
        let sql = """
        UPDATE events
        SET city = (
                SELECT city
                FROM locations
                WHERE locationId = ?
            ),
            state = (
                SELECT state
                FROM locations
                WHERE locationId = ?
            ),
            placeName = (
                SELECT placeName
                FROM locations
                WHERE locationId = ?
            )
        WHERE locationId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(locationId))
            sqlite3_bind_int(statement, 2, Int32(locationId))
            sqlite3_bind_int(statement, 3, Int32(locationId))
            sqlite3_bind_int(statement, 4, Int32(locationId))

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed updating events from location: \(String(cString: sqlite3_errmsg(db)))")
            }
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
        );
                
            }
        
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

            eventType TEXT,
            locationId INTEGER,

            coverPhotoId TEXT,
            userEditedName INTEGER DEFAULT 0,

            isDeleted INTEGER DEFAULT 0,
            deletedAt TEXT,
            updatedAt TEXT,

            showAsSlideshowEvent INTEGER DEFAULT 0,
            includeTitleSlide INTEGER DEFAULT 0,
            maxSlideshowPhotos INTEGER DEFAULT 3,

            photoCount INTEGER DEFAULT 0
        );

        
        
        CREATE TABLE IF NOT EXISTS photo_events (
            photoId TEXT,
            eventId INTEGER,
            includeInSlideshow INTEGER
            manuallyExcluded INTEGER
            manualBoost INTEGER
            PRIMARY KEY (photoId, eventId)
        );

            }
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
        
        addColumnIfNeeded(table: "photo_events", column: "includeInSlideshow", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "photo_events", column: "manuallyExcluded", definition: "INTEGER DEFAULT 0")
        addColumnIfNeeded(table: "photo_events", column: "manualBoost", definition: "INTEGER DEFAULT 0")
    }
    
    func updateCoverPhotoForEvent(eventId: Int) {

        let sql = """
        SELECT p.id
        FROM photos p
        JOIN photo_events pe
            ON p.id = pe.photoId
        WHERE pe.eventId = ?
          AND p.isDeleted = 0
        ORDER BY
            p.isFavorite DESC,
            p.qualityScore DESC,
            p.creationDate DESC
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var coverPhotoId: String?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {

            sqlite3_bind_int(statement, 1, Int32(eventId))

            if sqlite3_step(statement) == SQLITE_ROW {

                coverPhotoId =
                    String(
                        cString:
                            sqlite3_column_text(statement, 0)
                    )
            }
        }

        sqlite3_finalize(statement)

        guard let coverPhotoId = coverPhotoId else {
            return
        }

        let updateSQL = """
        UPDATE events
        SET coverPhotoId = ?
        WHERE eventId = ?;
        """

        if sqlite3_prepare_v2(db, updateSQL, -1, &statement, nil) == SQLITE_OK {

            sqlite3_bind_text(
                statement,
                1,
                (coverPhotoId as NSString).utf8String,
                -1,
                nil
            )

            sqlite3_bind_int(statement, 2, Int32(eventId))

            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)

        print("Updated cover photo for event \(eventId)")
    }
    
    func updateAllEventCoverPhotos() {

        let sql = """

        SELECT eventId

        FROM events

        WHERE isDeleted = 0;

        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {

            while sqlite3_step(statement) == SQLITE_ROW {

                let eventId =

                    Int(sqlite3_column_int(statement, 0))

                updateCoverPhotoForEvent(

                    eventId: eventId

                )

            }

        }

        sqlite3_finalize(statement)

        print("Finished updating cover photos")

    }
    
    
    func backfillEventAssignedAt() {

        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """

        UPDATE photos

        SET eventAssignedAt = ?,
            eventNeedsReview = 0
        WHERE id IN (
            SELECT DISTINCT photoId
            FROM photo_events
        )
          AND eventAssignedAt IS NULL;

        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {

            sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {

                print("Failed to backfill eventAssignedAt: \(String(cString: sqlite3_errmsg(db)))")

            } else {

                print("Backfilled eventAssignedAt")

            }

        }

        sqlite3_finalize(statement)

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
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        INSERT INTO photos
        (
            id, creationDate, modificationDate, mediaType, mediaSubtype,
            width, height, isFavorite, isHidden, latitude, longitude,
            isScreenshot, aspectRatio, orientation, qualityScore,
            isDeleted, deletedAt, lastSeenAt, indexedAt
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            creationDate = excluded.creationDate,
            modificationDate = excluded.modificationDate,
            mediaType = excluded.mediaType,
            mediaSubtype = excluded.mediaSubtype,
            width = excluded.width,
            height = excluded.height,
            isFavorite = excluded.isFavorite,
            isHidden = excluded.isHidden,
            latitude = excluded.latitude,
            longitude = excluded.longitude,
            isScreenshot = excluded.isScreenshot,
            aspectRatio = excluded.aspectRatio,
            orientation = excluded.orientation,
            qualityScore = excluded.qualityScore,
            isDeleted = 0,
            deletedAt = NULL,
            lastSeenAt = excluded.lastSeenAt,
            indexedAt = excluded.indexedAt;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (creationDate as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (modificationDate as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 4, Int32(mediaType))
            sqlite3_bind_int(statement, 5, Int32(mediaSubtype))
            sqlite3_bind_int(statement, 6, Int32(width))
            sqlite3_bind_int(statement, 7, Int32(height))
            sqlite3_bind_int(statement, 8, isFavorite ? 1 : 0)
            sqlite3_bind_int(statement, 9, isHidden ? 1 : 0)

            if let latitude = latitude {
                sqlite3_bind_double(statement, 10, latitude)
            } else {
                sqlite3_bind_null(statement, 10)
            }

            if let longitude = longitude {
                sqlite3_bind_double(statement, 11, longitude)
            } else {
                sqlite3_bind_null(statement, 11)
            }

            sqlite3_bind_int(statement, 12, isScreenshot ? 1 : 0)
            sqlite3_bind_double(statement, 13, aspectRatio)
            sqlite3_bind_text(statement, 14, (orientation as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 15, Int32(qualityScore))
            sqlite3_bind_text(statement, 16, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 17, (now as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to upsert photo: \(String(cString: sqlite3_errmsg(db)))")
            }
        } else {
            print("Failed to prepare upsert photo: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
    }

    func markPhotosDeletedIfMissing(currentIds: Set<String>) {
        let existingIds = fetchAllActivePhotoIds()
        let now = ISO8601DateFormatter().string(from: Date())

        for id in existingIds where !currentIds.contains(id) {
            markPhotoDeleted(photoId: id, deletedAt: now)
        }

        print("Soft delete check complete")
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
    
    private func fetchAllActivePhotoIds() -> [String] {
        let sql = """
        SELECT id
        FROM photos
        WHERE isDeleted = 0;
        """

        var statement: OpaquePointer?
        var ids: [String] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(statement, 0)))
            }
        }

        sqlite3_finalize(statement)
        return ids
    }

    private func markPhotoDeleted(photoId: String, deletedAt: String) {
        let sql = """
        UPDATE photos
        SET isDeleted = 1,
            deletedAt = ?,
            indexedAt = ?
        WHERE id = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (deletedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (deletedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (photoId as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to soft delete photo: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
    }

    func getRecentPhotos(limit: Int = 100) -> [IndexedPhoto] {
        let sql = """
        SELECT id, creationDate, isFavorite, width, height, mediaSubtype,
               latitude, longitude, isScreenshot, aspectRatio, orientation, qualityScore
        FROM photos
        WHERE isDeleted = 0
        ORDER BY creationDate DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        var photos: [IndexedPhoto] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))

            while sqlite3_step(statement) == SQLITE_ROW {
                photos.append(readIndexedPhoto(from: statement))
            }
        }

        sqlite3_finalize(statement)
        return photos
    }

    func upsertPerson(name: String) -> Int {
        let insertSQL = """
        INSERT OR IGNORE INTO people (name)
        VALUES (?);
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)

        let selectSQL = """
        SELECT personId FROM people
        WHERE name = ?;
        """

        if sqlite3_prepare_v2(db, selectSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) == SQLITE_ROW {
                let personId = Int(sqlite3_column_int(statement, 0))
                sqlite3_finalize(statement)
                return personId
            }
        }

        sqlite3_finalize(statement)
        return -1
    }

    func linkPhotoToPerson(photoId: String, personId: Int, source: String) {
        guard personId > 0 else { return }

        let sql = """
        INSERT OR REPLACE INTO photo_people
        (photoId, personId, source)
        VALUES (?, ?, ?);
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(personId))
            sqlite3_bind_text(statement, 3, (source as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to link person to photo: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
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
        let maxDistanceMiles = 10.0

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

                    let distance = distanceInMiles(
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
    
    func debugSchema() {

        print("events has locationId: \(columnExists(table: "events", column: "locationId"))")

        print("locations rows: \(countRows("locations"))")

    }
    
    func syncEventsIncrementally() {
        
        let deleteSQL = """
        
        """
        
        let photos = getUnassignedPhotosForEvents()

        guard !photos.isEmpty else {
            print("No unassigned photos to process")
            cleanupEmptyEvents()
            rebuildEventPeople()
            return
        }

        print("Processing \(photos.count) unassigned photos")

        for photo in photos {
            if let eventId = findMatchingEvent(for: photo) {
                attachPhotoToEvent(photoId: photo.id, eventId: eventId)
                updateEventSummary(eventId: eventId)
                markPhotoEventAssigned(photoId: photo.id)
            } else {
                let eventId = createEventFromPhoto(photo)
                if eventId > 0 {
                    attachPhotoToEvent(photoId: photo.id, eventId: eventId)
                    updateEventSummary(eventId: eventId)
                    markPhotoEventAssigned(photoId: photo.id)
                }
            }
        }

        cleanupEmptyEvents()
        rebuildEventPeople()

        print("Incremental event sync complete")
    }
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
    
    private func copyNearbyCompletedLocationIfPossible(locationId: Int, latitude: Double, longitude: Double) -> Bool {
        let sql = """
        SELECT locationId, latitude, longitude, city, state, placeName
        FROM locations
        WHERE geocodeStatus = 'complete'
          AND city IS NOT NULL
          AND state IS NOT NULL
          AND latitude IS NOT NULL
          AND longitude IS NOT NULL;
        """

        var statement: OpaquePointer?
        var bestMatch: (city: String?, state: String?, placeName: String?)?
        var bestDistance = Double.greatestFiniteMagnitude

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let existingLat = sqlite3_column_double(statement, 1)
                let existingLon = sqlite3_column_double(statement, 2)

                let distance = distanceInMiles(
                    lat1: latitude,
                    lon1: longitude,
                    lat2: existingLat,
                    lon2: existingLon
                )

                if distance < bestDistance {
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
                    bestMatch = (city, state, placeName)
                }
            }
        }

        sqlite3_finalize(statement)

        if bestDistance <= 1.0, let bestMatch = bestMatch {
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
    
    private func findMatchingEvent(for photo: EventCandidatePhoto) -> Int? {
        guard let photoLatitude = photo.latitude,
              let photoLongitude = photo.longitude else {
            return nil
        }

        let formatter = ISO8601DateFormatter()

        let sql = """
        SELECT eventId, startDate, endDate, latitude, longitude
        FROM events
        WHERE isDeleted = 0
          AND latitude IS NOT NULL
          AND longitude IS NOT NULL;
        """

        var statement: OpaquePointer?
        var bestEventId: Int?
        var bestScore = Double.greatestFiniteMagnitude

        let maxGapSeconds: TimeInterval = 4 * 60 * 60
        let maxDistanceMiles = 10.0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let eventId = Int(sqlite3_column_int(statement, 0))
                let startString = String(cString: sqlite3_column_text(statement, 1))
                let endString = String(cString: sqlite3_column_text(statement, 2))
                let eventLatitude = sqlite3_column_double(statement, 3)
                let eventLongitude = sqlite3_column_double(statement, 4)

                guard let startDate = formatter.date(from: startString),
                      let endDate = formatter.date(from: endString) else {
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

                guard timeGap <= maxGapSeconds else { continue }

                let distance = distanceInMiles(
                    lat1: photoLatitude,
                    lon1: photoLongitude,
                    lat2: eventLatitude,
                    lon2: eventLongitude
                )

                guard distance <= maxDistanceMiles else { continue }

                let score = timeGap + (distance * 600)

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
    
    private func attachPhotoToEvent(photoId: String, eventId: Int) {
        let sql = """
        INSERT OR IGNORE INTO photo_events (photoId, eventId)
        VALUES (?, ?);
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(eventId))

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed attaching photo to event: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
    }
    
    
    private func createEventFromPhoto(_ photo: EventCandidatePhoto) -> Int {
        let formatter = ISO8601DateFormatter()
        let dateString = formatter.string(from: photo.date)

        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        let name = displayFormatter.string(from: photo.date)

        let locationId: Int?

        if let latitude = photo.latitude,
           let longitude = photo.longitude {
            locationId = findOrCreateLocation(
                latitude: latitude,
                longitude: longitude
            )
        } else {
            locationId = nil
        }

        let sql = """
        INSERT INTO events
        (
            name, startDate, endDate, latitude, longitude,
            city, state, placeName, eventType, locationId,
            isDeleted, deletedAt, updatedAt, photoCount
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, 0);
        """

        let now = ISO8601DateFormatter().string(from: Date())
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (dateString as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (dateString as NSString).utf8String, -1, nil)

            if let latitude = photo.latitude {
                sqlite3_bind_double(statement, 4, latitude)
            } else {
                sqlite3_bind_null(statement, 4)
            }

            if let longitude = photo.longitude {
                sqlite3_bind_double(statement, 5, longitude)
            } else {
                sqlite3_bind_null(statement, 5)
            }

            sqlite3_bind_null(statement, 6)
            sqlite3_bind_null(statement, 7)
            sqlite3_bind_null(statement, 8)

            sqlite3_bind_text(statement, 9, ("incremental_cluster" as NSString).utf8String, -1, nil)

            if let locationId = locationId, locationId > 0 {
                sqlite3_bind_int(statement, 10, Int32(locationId))
            } else {
                sqlite3_bind_null(statement, 10)
            }

            sqlite3_bind_text(statement, 11, (now as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to create event from photo: \(String(cString: sqlite3_errmsg(db)))")
            }
        } else {
            print("Failed to prepare create event: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)

        return Int(sqlite3_last_insert_rowid(db))
    }
    
    private func getUnassignedPhotosForEvents() -> [EventCandidatePhoto] {
        let sql = """
        SELECT id, creationDate, latitude, longitude
        FROM photos
        WHERE isDeleted = 0
          AND eventAssignedAt IS NULL
          AND isScreenshot = 0
          AND latitude IS NOT NULL
          AND longitude IS NOT NULL
        ORDER BY creationDate ASC;
        """

        var statement: OpaquePointer?
        var photos: [EventCandidatePhoto] = []
        let formatter = ISO8601DateFormatter()

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
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
            print("Failed to get unassigned photos: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
        return photos
    }
    
    private func markPhotoEventAssigned(photoId: String) {
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        UPDATE photos
        SET eventAssignedAt = ?,
            eventNeedsReview = 0
        WHERE id = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (photoId as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }
    
    private func updateEventSummary(eventId: Int) {
        let sql = """
        UPDATE events
        SET
            startDate = (
                SELECT MIN(p.creationDate)
                FROM photo_events pe
                JOIN photos p ON pe.photoId = p.id
                WHERE pe.eventId = ?
                  AND p.isDeleted = 0
            ),
            endDate = (
                SELECT MAX(p.creationDate)
                FROM photo_events pe
                JOIN photos p ON pe.photoId = p.id
                WHERE pe.eventId = ?
                  AND p.isDeleted = 0
            ),
            latitude = (
                SELECT AVG(p.latitude)
                FROM photo_events pe
                JOIN photos p ON pe.photoId = p.id
                WHERE pe.eventId = ?
                  AND p.isDeleted = 0
                  AND p.latitude IS NOT NULL
            ),
            longitude = (
                SELECT AVG(p.longitude)
                FROM photo_events pe
                JOIN photos p ON pe.photoId = p.id
                WHERE pe.eventId = ?
                  AND p.isDeleted = 0
                  AND p.longitude IS NOT NULL
            ),
            photoCount = (
                SELECT COUNT(*)
                FROM photo_events pe
                JOIN photos p ON pe.photoId = p.id
                WHERE pe.eventId = ?
                  AND p.isDeleted = 0
            ),
            updatedAt = ?
        WHERE eventId = ?;
        """

        let now = ISO8601DateFormatter().string(from: Date())
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_int(statement, 2, Int32(eventId))
            sqlite3_bind_int(statement, 3, Int32(eventId))
            sqlite3_bind_int(statement, 4, Int32(eventId))
            sqlite3_bind_int(statement, 5, Int32(eventId))
            sqlite3_bind_text(statement, 6, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 7, Int32(eventId))

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed updating event summary: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
    }
    
    private func cleanupEmptyEvents() {
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        UPDATE events
        SET isDeleted = 1,
            deletedAt = ?,
            updatedAt = ?
        WHERE isDeleted = 0
          AND eventId NOT IN (
              SELECT DISTINCT pe.eventId
              FROM photo_events pe
              JOIN photos p ON pe.photoId = p.id
              WHERE p.isDeleted = 0
          );
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed cleaning up empty events: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
    }
    
    private func saveEvent(
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
            locationId = findOrCreateLocation(
                latitude: eventLatitude,
                longitude: eventLongitude
            )
            print("Creating location for event lat/lon: \(eventLatitude), \(eventLongitude)")

        } else {
            locationId = nil
        }
        
        let insertEventSQL = """
        INSERT INTO events
        (
            name, startDate, endDate, latitude, longitude,
            city, state, placeName, eventType, locationId
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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

            sqlite3_bind_text(
                eventStatement,
                9,
                ("time_location_cluster" as NSString).utf8String,
                -1,
                nil
            )
            
            if let locationId = locationId, locationId > 0 {
                sqlite3_bind_int(eventStatement, 10, Int32(locationId))
            } else {
                sqlite3_bind_null(eventStatement, 10)
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

    func rebuildEventPeople() {
        let deleteSQL = "DELETE FROM event_people;"
        sqlite3_exec(db, deleteSQL, nil, nil, nil)

        let sql = """
        INSERT INTO event_people (eventId, personId, photoCount)
        SELECT
            pe.eventId,
            pp.personId,
            COUNT(*) as photoCount
        FROM photo_events pe
        JOIN photo_people pp ON pe.photoId = pp.photoId
        JOIN photos p ON p.id = pe.photoId
        WHERE p.isDeleted = 0
        GROUP BY pe.eventId, pp.personId;
        """

        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            print("Event people rebuilt")
            debugEventPeopleCount()
        } else {
            print("Failed to rebuild event people: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func getEvents() -> [IndexedEvent] {
        let sql = """
        SELECT
            e.eventId,
            e.name,
            e.startDate,
            e.endDate,
            e.latitude,
            e.longitude,
            COALESCE(e.city, l.city) as city,
            COALESCE(e.state, l.state) as state,
            COALESCE(e.placeName, l.placeName) as placeName,
            e.coverPhotoId,
            COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 THEN pe.photoId END) as photoCount,
            GROUP_CONCAT(DISTINCT p.name) as peopleNames
        FROM events e
        LEFT JOIN locations l
            ON e.locationId = l.locationId
        LEFT JOIN photo_events pe
            ON e.eventId = pe.eventId
        LEFT JOIN photos ph
            ON pe.photoId = ph.id
        LEFT JOIN event_people ep
            ON e.eventId = ep.eventId
        LEFT JOIN people p
            ON ep.personId = p.personId
        WHERE e.isDeleted = 0
        GROUP BY
            e.eventId,
            e.name,
            e.startDate,
            e.endDate,
            e.latitude,
            e.longitude,
            COALESCE(e.city, l.city),
            COALESCE(e.state, l.state),
            COALESCE(e.placeName, l.placeName),
            e.coverPhotoId
        ORDER BY e.startDate DESC;
        """

        var statement: OpaquePointer?
        var events: [IndexedEvent] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {

                let eventId = Int(sqlite3_column_int(statement, 0))
                let name = String(cString: sqlite3_column_text(statement, 1))
                let startDate = String(cString: sqlite3_column_text(statement, 2))
                let endDate = String(cString: sqlite3_column_text(statement, 3))

                let latitude: Double? =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 4)

                let longitude: Double? =
                    sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 5)

                let city: String? =
                    sqlite3_column_type(statement, 6) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 6))

                let state: String? =
                    sqlite3_column_type(statement, 7) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 7))

                let placeName: String? =
                    sqlite3_column_type(statement, 8) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 8))

                let coverPhotoId: String? =
                    sqlite3_column_type(statement, 9) == SQLITE_NULL
                    ? nil
                    : String(cString: sqlite3_column_text(statement, 9))

                let photoCount = Int(sqlite3_column_int(statement, 10))

                let people: [String]
                if sqlite3_column_type(statement, 11) == SQLITE_NULL {
                    people = []
                } else {
                    let peopleString = String(cString: sqlite3_column_text(statement, 11))
                    people = peopleString
                        .split(separator: ",")
                        .map { String($0) }
                }

                events.append(
                    IndexedEvent(
                        eventId: eventId,
                        name: name,
                        startDate: startDate,
                        endDate: endDate,
                        photoCount: photoCount,
                        latitude: latitude,
                        longitude: longitude,
                        city: city,
                        state: state,
                        placeName: placeName,
                        people: people,
                        coverPhotoId: coverPhotoId,
            
                    )
                )
            }
        } else {
            print("Failed to get events: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
        return events
    }
    func getPhotosForEvent(eventId: Int) -> [IndexedPhoto] {
        let sql = """
        SELECT p.id, p.creationDate, p.isFavorite, p.width, p.height,
               p.mediaSubtype, p.latitude, p.longitude, p.isScreenshot,
               p.aspectRatio, p.orientation, p.qualityScore
        FROM photos p
        JOIN photo_events pe ON p.id = pe.photoId
        WHERE pe.eventId = ?
          AND p.isDeleted = 0
        ORDER BY p.qualityScore DESC, p.creationDate DESC;
        """

        var statement: OpaquePointer?
        var photos: [IndexedPhoto] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))

            while sqlite3_step(statement) == SQLITE_ROW {
                photos.append(readIndexedPhoto(from: statement))
            }
        } else {
            print("Failed to get photos for event: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
        return photos
    }

    func geocodePendingLocations(limit: Int = 10) {

        let pendingLocations = getPendingLocations(limit: limit)

        guard !pendingLocations.isEmpty else {

            print("No pending locations to geocode")

            return

        }

        print("Geocoding \(pendingLocations.count) pending locations")

        for (index, location) in pendingLocations.enumerated() {

            if copyNearbyCompletedLocationIfPossible(

                locationId: location.locationId,

                latitude: location.latitude,

                longitude: location.longitude

            ) {

                continue

            }

            let delay = Double(index) * 1.5

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {

                self.reverseGeocode(

                    latitude: location.latitude,

                    longitude: location.longitude

                ) { city, state, placeName in

                    self.updateLocationGeocode(

                        locationId: location.locationId,

                        city: city,

                        state: state,

                        placeName: placeName

                    )

                    self.updateEventsFromLocation(

                        locationId: location.locationId

                    )

                    print(

                        "Geocoded location \(location.locationId): \(city ?? "nil"), \(state ?? "nil")"

                    )

                }

            }

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

    private func countRows(_ tableOrQuery: String) -> Int {
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
        let id = String(cString: sqlite3_column_text(statement, 0))
        let creationDate = String(cString: sqlite3_column_text(statement, 1))
        let isFavorite = sqlite3_column_int(statement, 2) == 1
        let width = Int(sqlite3_column_int(statement, 3))
        let height = Int(sqlite3_column_int(statement, 4))
        let mediaSubtype = Int(sqlite3_column_int(statement, 5))

        let latitude: Double? =
            sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, 6)

        let longitude: Double? =
            sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, 7)

        let isScreenshot = sqlite3_column_int(statement, 8) == 1
        let aspectRatio = sqlite3_column_double(statement, 9)
        let orientation = String(cString: sqlite3_column_text(statement, 10))
        let qualityScore = Int(sqlite3_column_int(statement, 11))

        return IndexedPhoto(
            id: id,
            creationDate: creationDate,
            isFavorite: isFavorite,
            width: width,
            height: height,
            mediaSubtype: mediaSubtype,
            latitude: latitude,
            longitude: longitude,
            isScreenshot: isScreenshot,
            aspectRatio: aspectRatio,
            orientation: orientation,
            qualityScore: qualityScore
            
        )
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

    private func distanceInMiles(
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

    private func reverseGeocode(
        latitude: Double,
        longitude: Double,
        completion: @escaping (String?, String?, String?) -> Void
    ) {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)

        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            guard let placemark = placemarks?.first else {
                completion(nil, nil, nil)
                return
            }

            completion(
                placemark.locality,
                placemark.administrativeArea,
                placemark.name
            )
        }
    }

    private func coordinateBucket(_ value: Double) -> Double {
        return (value * 100).rounded() / 100
    }
    
    func findOrCreateLocation(latitude: Double, longitude: Double) -> Int {
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
        placeName: String?
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

            sqlite3_bind_text(statement, 4, ("complete" as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 5, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 6, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 7, Int32(locationId))

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed updating location: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
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
}

