import Foundation
import SQLite3

/// Repository-specific data fixes invoked during `migrateTablesIfNeeded`.
struct LegacyDataMigrationHooks {
    var migrateLegacyTripEventType: () -> Void = {}
    var migrateLegacyHomeLocations: () -> Void = {}
    var migrateTripSubEventChildNames: () -> Void = {}
    var repairStaleGeocodeStatuses: () -> Void = {}
}

enum SQLiteMigrations {

    static func createTablesIfNeeded(on db: OpaquePointer) {
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

    static func migrateTablesIfNeeded(on db: OpaquePointer, legacyHooks: LegacyDataMigrationHooks) {
        addColumnIfNeeded(table: "photos", column: "isDeleted", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(table: "photos", column: "deletedAt", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "photos", column: "lastSeenAt", definition: "TEXT", on: db)

        addColumnIfNeeded(table: "photos", column: "eventAssignedAt", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "photos", column: "eventNeedsReview", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(table: "photos", column: "captureDateOverride", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "photos", column: "userLatitude", definition: "REAL", on: db)
        addColumnIfNeeded(table: "photos", column: "userLongitude", definition: "REAL", on: db)

        addColumnIfNeeded(table: "events", column: "locationId", definition: "INTEGER", on: db)
        addColumnIfNeeded(table: "events", column: "isDeleted", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(table: "events", column: "deletedAt", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "events", column: "updatedAt", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "events", column: "photoCount", definition: "INTEGER DEFAULT 0", on: db)

        addColumnIfNeeded(table: "events", column: "coverPhotoId", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "events", column: "isFavorite", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(table: "events", column: "userEditedName", definition: "INTEGER DEFAULT 0", on: db)

        addColumnIfNeeded(table: "events", column: "showAsSlideshowEvent", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(table: "events", column: "includeTitleSlide", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(table: "events", column: "maxSlideshowPhotos", definition: "INTEGER DEFAULT 3", on: db)
        addColumnIfNeeded(table: "events", column: "isUserHidden", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(table: "events", column: "parentEventId", definition: "INTEGER", on: db)
        addColumnIfNeeded(table: "events", column: "isTripEvent", definition: "INTEGER DEFAULT 0", on: db)

        dropColumnIfNeeded(table: "events", column: "eventSubType", on: db)
        dropColumnIfNeeded(table: "events", column: "eventType", on: db)

        sqlite3_exec(
            db,
            "DELETE FROM app_metadata WHERE key = 'customEventSubTypes';",
            nil,
            nil,
            nil
        )

        addColumnIfNeeded(table: "events", column: "eventType", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "events", column: "activityType", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "events", column: "milestoneType", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "events", column: "holidayType", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "events", column: "eventMainPerson", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "events", column: "tripType", definition: "TEXT", on: db)
        legacyHooks.migrateLegacyTripEventType()

        addColumnIfNeeded(table: "locations", column: "isFavorite", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(table: "locations", column: "nickname", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "locations", column: "isCurrentHome", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(table: "locations", column: "homeStartDate", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "locations", column: "homeEndDate", definition: "TEXT", on: db)

        legacyHooks.migrateLegacyHomeLocations()

        addColumnIfNeeded(table: "photo_events", column: "includeInSlideshow", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(table: "photo_events", column: "manuallyExcluded", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(table: "photo_events", column: "manualBoost", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(table: "photo_events", column: "isSimilarGroupPick", definition: "INTEGER DEFAULT 0", on: db)

        addColumnIfNeeded(table: "photos", column: "faceEyesOpenScore", definition: "REAL", on: db)
        addColumnIfNeeded(table: "photos", column: "faceSmileScore", definition: "REAL", on: db)
        addColumnIfNeeded(table: "photos", column: "listCropFocusX", definition: "REAL", on: db)
        addColumnIfNeeded(table: "photos", column: "listCropFocusY", definition: "REAL", on: db)
        addColumnIfNeeded(table: "photos", column: "frameCropFocusX", definition: "REAL", on: db)
        addColumnIfNeeded(table: "photos", column: "frameCropFocusY", definition: "REAL", on: db)
        addColumnIfNeeded(table: "events", column: "childEventName", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "events", column: "userEditedChildEventName", definition: "INTEGER DEFAULT 0", on: db)

        legacyHooks.migrateTripSubEventChildNames()

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

        legacyHooks.repairStaleGeocodeStatuses()
    }

    static func dropDevelopmentTables(on db: OpaquePointer) -> Bool {
        let sql = """
        DROP TABLE IF EXISTS event_people;
        DROP TABLE IF EXISTS photo_people;
        DROP TABLE IF EXISTS people;
        DROP TABLE IF EXISTS photo_events;
        DROP TABLE IF EXISTS events;
        DROP TABLE IF EXISTS photos;
        """
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    static func columnExists(table: String, column: String, on db: OpaquePointer) -> Bool {
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

    private static func addColumnIfNeeded(
        table: String,
        column: String,
        definition: String,
        on db: OpaquePointer
    ) {
        guard !columnExists(table: table, column: column, on: db) else { return }

        let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);"

        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            print("Added column \(column) to \(table)")
        } else {
            print("Failed to add column \(column): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private static func dropColumnIfNeeded(table: String, column: String, on db: OpaquePointer) {
        guard columnExists(table: table, column: column, on: db) else { return }

        let sql = "ALTER TABLE \(table) DROP COLUMN \(column);"

        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            print("Dropped column \(column) from \(table)")
        } else {
            print("Failed to drop column \(column): \(String(cString: sqlite3_errmsg(db)))")
        }
    }
}
