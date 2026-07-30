import Foundation
import SQLite3

/// Repository-specific data fixes invoked during `migrateTablesIfNeeded`.
struct LegacyDataMigrationHooks {
    var migrateLegacyTripEventType: () -> Void = {}
    var migrateLegacyHomeLocations: () -> Void = {}
    var migrateTripSubEventChildNames: () -> Void = {}
    var repairStaleGeocodeStatuses: () -> Void = {}
    var seedOccasionsIfNeeded: () -> Void = {}
    var backfillPhotoOccasionFromLegacyOnFrame: () -> Void = {}
    var backfillEventAttributeTagsFromColumns: () -> Void = {}
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
            name TEXT UNIQUE NOT NULL,
            birthDate TEXT
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

        // One-time legacy cleanup only. Do NOT drop `eventType` here — doing so on every
        // launch rebuilds the entire events table and wipes the column's data.
        dropColumnIfNeeded(table: "events", column: "eventSubType", on: db)

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
        addColumnIfNeeded(table: "events", column: "eventMainPerson2", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "events", column: "weddingDate", definition: "TEXT", on: db)
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
        addColumnIfNeeded(table: "photo_events", column: "assignmentConfidence", definition: "REAL", on: db)
        addColumnIfNeeded(table: "photo_events", column: "assignmentMethod", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "photo_events", column: "assignedAt", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "photo_events", column: "needsReview", definition: "INTEGER DEFAULT 0", on: db)

        addColumnIfNeeded(table: "photos", column: "faceEyesOpenScore", definition: "REAL", on: db)
        addColumnIfNeeded(table: "photos", column: "faceSmileScore", definition: "REAL", on: db)
        addColumnIfNeeded(table: "photos", column: "listCropFocusX", definition: "REAL", on: db)
        addColumnIfNeeded(table: "photos", column: "listCropFocusY", definition: "REAL", on: db)
        addColumnIfNeeded(table: "photos", column: "frameCropFocusX", definition: "REAL", on: db)
        addColumnIfNeeded(table: "photos", column: "frameCropFocusY", definition: "REAL", on: db)
        addColumnIfNeeded(table: "events", column: "childEventName", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "events", column: "userEditedChildEventName", definition: "INTEGER DEFAULT 0", on: db)
        addColumnIfNeeded(
            table: "events",
            column: "clusteredByTimeOnly",
            definition: "INTEGER DEFAULT 0",
            on: db
        )
        addColumnIfNeeded(table: "events", column: "userManualCity", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "events", column: "userManualState", definition: "TEXT", on: db)
        addColumnIfNeeded(
            table: "events",
            column: "userEditedManualLocation",
            definition: "INTEGER DEFAULT 0",
            on: db
        )

        legacyHooks.migrateTripSubEventChildNames()

        sqlite3_exec(
            db,
            """
            CREATE INDEX IF NOT EXISTS idx_events_locationId ON events(locationId);
            CREATE INDEX IF NOT EXISTS idx_events_parentEventId ON events(parentEventId);
            CREATE INDEX IF NOT EXISTS idx_events_assignment
            ON events(isDeleted, parentEventId, startDate, endDate);
            CREATE INDEX IF NOT EXISTS idx_photo_people_personId
            ON photo_people(personId);
            """,
            nil,
            nil,
            nil
        )

        migrateMetadataTablesIfNeeded(on: db)
        migrateOccasionTablesIfNeeded(on: db)
        migrateOccasionScoringTablesIfNeeded(on: db)
        migrateEventTagsIfNeeded(on: db)
        migrateObjectTagTablesIfNeeded(on: db)
        migrateVisionJobTablesIfNeeded(on: db)
        legacyHooks.backfillEventAttributeTagsFromColumns()
        migrateOccasionLandingMetricsCacheIfNeeded(on: db)
        migratePhotoOccasionTablesIfNeeded(on: db)

        legacyHooks.repairStaleGeocodeStatuses()
        legacyHooks.seedOccasionsIfNeeded()
        legacyHooks.backfillPhotoOccasionFromLegacyOnFrame()
    }

    private static func migrateVisionJobTablesIfNeeded(on db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS vision_jobs (
            visionJobId INTEGER PRIMARY KEY AUTOINCREMENT,
            jobType TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            priority INTEGER NOT NULL DEFAULT 0,
            photoId TEXT,
            eventId INTEGER,
            occasionKey TEXT,
            algorithmVersion INTEGER NOT NULL,
            payloadJSON TEXT NOT NULL DEFAULT '{}',
            dedupeKey TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            maxAttempts INTEGER NOT NULL DEFAULT 3,
            lastError TEXT,
            createdAt TEXT NOT NULL,
            startedAt TEXT,
            finishedAt TEXT,
            UNIQUE (dedupeKey),
            FOREIGN KEY (photoId) REFERENCES photos(id),
            FOREIGN KEY (eventId) REFERENCES events(eventId)
        );

        CREATE INDEX IF NOT EXISTS idx_vision_jobs_claim
        ON vision_jobs(status, priority DESC, createdAt);

        CREATE INDEX IF NOT EXISTS idx_vision_jobs_event
        ON vision_jobs(eventId, status);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print(
                "Vision job table migration failed:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }
    }

    private static func migrateOccasionTablesIfNeeded(on db: OpaquePointer) {
        addColumnIfNeeded(table: "people", column: "birthDate", definition: "TEXT", on: db)

        let sql = """
        CREATE TABLE IF NOT EXISTS occasions (
            occasionId INTEGER PRIMARY KEY AUTOINCREMENT,
            occasionKey TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            occasionType TEXT NOT NULL,
            personId INTEGER,
            defaultWindowDaysBefore INTEGER DEFAULT 3,
            defaultWindowDaysAfter INTEGER DEFAULT 3,
            weekendBoost REAL NOT NULL DEFAULT 0,
            isEnabled INTEGER DEFAULT 1,
            FOREIGN KEY (personId) REFERENCES people(personId)
        );

        CREATE TABLE IF NOT EXISTS occasion_dates (
            occasionDateId INTEGER PRIMARY KEY AUTOINCREMENT,
            occasionId INTEGER NOT NULL,
            year INTEGER NOT NULL,
            date TEXT NOT NULL,
            observedDate TEXT,
            startDate TEXT,
            endDate TEXT,
            UNIQUE(occasionId, year),
            FOREIGN KEY (occasionId) REFERENCES occasions(occasionId)
        );

        CREATE INDEX IF NOT EXISTS idx_occasion_dates_occasion_year
        ON occasion_dates(occasionId, year);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("Occasion table migration failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private static func migrateOccasionScoringTablesIfNeeded(on db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS occasion_scoring_rules (
            ruleId INTEGER PRIMARY KEY AUTOINCREMENT,
            occasionId INTEGER NOT NULL,
            signalType TEXT NOT NULL,
            signalValue TEXT NOT NULL,
            score REAL NOT NULL,
            UNIQUE(occasionId, signalType, signalValue),
            FOREIGN KEY (occasionId) REFERENCES occasions(occasionId)
        );

        CREATE TABLE IF NOT EXISTS event_occasion_scores (
            eventOccasionScoreId INTEGER PRIMARY KEY AUTOINCREMENT,
            eventId INTEGER NOT NULL,
            occasionId INTEGER NOT NULL,
            year INTEGER NOT NULL,
            dateScore REAL NOT NULL DEFAULT 0,
            objectScore REAL NOT NULL DEFAULT 0,
            albumScore REAL NOT NULL DEFAULT 0,
            peopleScore REAL NOT NULL DEFAULT 0,
            locationScore REAL NOT NULL DEFAULT 0,
            userScore REAL NOT NULL DEFAULT 0,
            weekendScore REAL NOT NULL DEFAULT 0,
            totalScore REAL NOT NULL DEFAULT 0,
            confidence TEXT,
            isConfirmed INTEGER NOT NULL DEFAULT 0,
            isRejected INTEGER NOT NULL DEFAULT 0,
            scoredAt TEXT NOT NULL,
            UNIQUE(eventId, occasionId, year),
            FOREIGN KEY (eventId) REFERENCES events(eventId),
            FOREIGN KEY (occasionId) REFERENCES occasions(occasionId)
        );

        CREATE INDEX IF NOT EXISTS idx_event_occasion_scores_event
        ON event_occasion_scores(eventId);
        CREATE INDEX IF NOT EXISTS idx_event_occasion_scores_occasion_year
        ON event_occasion_scores(occasionId, year);
        CREATE INDEX IF NOT EXISTS idx_event_occasion_scores_total
        ON event_occasion_scores(totalScore DESC);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print(
                "Occasion scoring table migration failed:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }

        addColumnIfNeeded(
            table: "occasions",
            column: "weekendBoost",
            definition: "REAL NOT NULL DEFAULT 0",
            on: db
        )
        addColumnIfNeeded(
            table: "event_occasion_scores",
            column: "weekendScore",
            definition: "REAL NOT NULL DEFAULT 0",
            on: db
        )

        addColumnIfNeeded(table: "occasions", column: "anchorMonth", definition: "INTEGER", on: db)
        addColumnIfNeeded(table: "occasions", column: "anchorDay", definition: "INTEGER", on: db)

        backfillOccasionAnchorColumnsIfNeeded(on: db)
        migrateChristmasThanksgivingWindowColumnsIfNeeded(on: db)
    }

    private static func migrateChristmasThanksgivingWindowColumnsIfNeeded(on db: OpaquePointer) {
        addColumnIfNeeded(
            table: "occasions",
            column: "christmasWindowUsesThanksgivingStart",
            definition: "INTEGER NOT NULL DEFAULT 0",
            on: db
        )
        addColumnIfNeeded(
            table: "occasions",
            column: "windowDaysAfterThanksgiving",
            definition: "INTEGER NOT NULL DEFAULT 0",
            on: db
        )
    }

    private static func backfillOccasionAnchorColumnsIfNeeded(on db: OpaquePointer) {
        let sql = """
        UPDATE occasions
        SET anchorMonth = 12, anchorDay = 25
        WHERE occasionKey = 'christmas' AND anchorMonth IS NULL;

        UPDATE occasions
        SET anchorMonth = 10, anchorDay = 31
        WHERE occasionKey = 'halloween' AND anchorMonth IS NULL;

        UPDATE occasions
        SET defaultWindowDaysBefore = 35
        WHERE occasionKey = 'christmas' AND defaultWindowDaysBefore <= 10;
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print(
                "Occasion anchor backfill failed:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }
    }

    private static func migrateObjectTagTablesIfNeeded(on db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS photo_object_tags (
            photoObjectTagId INTEGER PRIMARY KEY AUTOINCREMENT,
            photoId TEXT NOT NULL,
            objectKey TEXT NOT NULL,
            confidence REAL NOT NULL,
            source TEXT NOT NULL,
            createdAt TEXT NOT NULL,
            UNIQUE (photoId, objectKey),
            FOREIGN KEY (photoId) REFERENCES photos(id)
        );

        CREATE INDEX IF NOT EXISTS idx_photo_object_tags_photo
        ON photo_object_tags(photoId);

        CREATE INDEX IF NOT EXISTS idx_photo_object_tags_object
        ON photo_object_tags(objectKey);

        CREATE TABLE IF NOT EXISTS event_object_tags (
            eventObjectTagId INTEGER PRIMARY KEY AUTOINCREMENT,
            eventId INTEGER NOT NULL,
            objectKey TEXT NOT NULL,
            photoCount INTEGER NOT NULL DEFAULT 0,
            maxConfidence REAL NOT NULL DEFAULT 0,
            updatedAt TEXT NOT NULL,
            UNIQUE (eventId, objectKey),
            FOREIGN KEY (eventId) REFERENCES events(eventId)
        );

        CREATE INDEX IF NOT EXISTS idx_event_object_tags_event
        ON event_object_tags(eventId);

        CREATE INDEX IF NOT EXISTS idx_event_object_tags_object
        ON event_object_tags(objectKey);

        CREATE TABLE IF NOT EXISTS photo_vision_scans (
            photoVisionScanId INTEGER PRIMARY KEY AUTOINCREMENT,
            photoId TEXT NOT NULL,
            algorithmVersion INTEGER NOT NULL,
            scannedAt TEXT NOT NULL,
            UNIQUE (photoId, algorithmVersion),
            FOREIGN KEY (photoId) REFERENCES photos(id)
        );

        CREATE INDEX IF NOT EXISTS idx_photo_vision_scans_photo
        ON photo_vision_scans(photoId);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print(
                "Object tag table migration failed:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }
    }

    private static func migrateEventTagsIfNeeded(on db: OpaquePointer) {
        addColumnIfNeeded(
            table: "events",
            column: "objectRecognitionCompleted",
            definition: "INTEGER NOT NULL DEFAULT 0",
            on: db
        )
        addColumnIfNeeded(
            table: "events",
            column: "objectRecognitionCompletedAt",
            definition: "TEXT",
            on: db
        )
        addColumnIfNeeded(
            table: "events",
            column: "objectRecognitionAlgorithmVersion",
            definition: "INTEGER NOT NULL DEFAULT 0",
            on: db
        )

        let sql = """
        CREATE TABLE IF NOT EXISTS event_tags (
            eventTagId INTEGER PRIMARY KEY AUTOINCREMENT,
            eventId INTEGER NOT NULL,
            tagCategory TEXT NOT NULL,
            tagValue TEXT NOT NULL,
            source TEXT NOT NULL,
            appliedPhase TEXT,
            occasionId INTEGER,
            scoringYear INTEGER,
            confidence TEXT,
            totalScore REAL,
            isRejected INTEGER NOT NULL DEFAULT 0,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            UNIQUE (eventId, tagCategory),
            FOREIGN KEY (eventId) REFERENCES events(eventId),
            FOREIGN KEY (occasionId) REFERENCES occasions(occasionId)
        );

        CREATE INDEX IF NOT EXISTS idx_event_tags_event ON event_tags(eventId);
        CREATE INDEX IF NOT EXISTS idx_event_tags_source ON event_tags(eventId, source);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("Event tags migration failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private static func migratePhotoOccasionTablesIfNeeded(on db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS photo_occasion (
            photoOccasionId INTEGER PRIMARY KEY AUTOINCREMENT,
            photoId TEXT NOT NULL,
            occasionId INTEGER NOT NULL,
            source TEXT NOT NULL,
            personId INTEGER,
            isOnFrame INTEGER NOT NULL DEFAULT 0,
            isRejected INTEGER NOT NULL DEFAULT 0,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            UNIQUE (photoId, occasionId),
            FOREIGN KEY (photoId) REFERENCES photos(id),
            FOREIGN KEY (occasionId) REFERENCES occasions(occasionId),
            FOREIGN KEY (personId) REFERENCES people(personId)
        );

        CREATE INDEX IF NOT EXISTS idx_photo_occasion_occasion_frame
        ON photo_occasion(occasionId, isOnFrame, isRejected);

        CREATE INDEX IF NOT EXISTS idx_photo_occasion_photo
        ON photo_occasion(photoId);

        CREATE TABLE IF NOT EXISTS occasion_subjects (
            occasionSubjectId INTEGER PRIMARY KEY AUTOINCREMENT,
            occasionId INTEGER NOT NULL,
            personId INTEGER NOT NULL,
            role TEXT NOT NULL,
            UNIQUE (occasionId, personId, role),
            FOREIGN KEY (occasionId) REFERENCES occasions(occasionId),
            FOREIGN KEY (personId) REFERENCES people(personId)
        );

        CREATE INDEX IF NOT EXISTS idx_occasion_subjects_occasion
        ON occasion_subjects(occasionId);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print(
                "Photo occasion migration failed:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }
    }

    private static func migrateOccasionLandingMetricsCacheIfNeeded(on db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS occasion_landing_metrics (
            tagValue TEXT PRIMARY KEY,
            collectionCount INTEGER NOT NULL,
            onFramePhotoCount INTEGER NOT NULL,
            metricsGeneration INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_occasion_landing_metrics_generation
        ON occasion_landing_metrics(metricsGeneration);

        CREATE TABLE IF NOT EXISTS occasion_collection_events (
            occasionId INTEGER NOT NULL,
            eventId INTEGER NOT NULL,
            PRIMARY KEY (occasionId, eventId),
            FOREIGN KEY (occasionId) REFERENCES occasions(occasionId),
            FOREIGN KEY (eventId) REFERENCES events(eventId)
        );

        CREATE INDEX IF NOT EXISTS idx_occasion_collection_events_event
        ON occasion_collection_events(eventId);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print(
                "Occasion landing metrics cache migration failed:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }
    }

    private static func migrateMetadataTablesIfNeeded(on db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS albums (
            albumId TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            collectionType TEXT NOT NULL,
            collectionSubtype TEXT,
            isPersonAlbum INTEGER DEFAULT 0,
            personId INTEGER,
            isHighCardinality INTEGER DEFAULT 0,
            assetCount INTEGER DEFAULT 0,
            indexedAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            FOREIGN KEY (personId) REFERENCES people(personId)
        );

        CREATE TABLE IF NOT EXISTS photo_albums (
            photoId TEXT NOT NULL,
            albumId TEXT NOT NULL,
            source TEXT NOT NULL,
            PRIMARY KEY (photoId, albumId),
            FOREIGN KEY (photoId) REFERENCES photos(id),
            FOREIGN KEY (albumId) REFERENCES albums(albumId)
        );

        CREATE TABLE IF NOT EXISTS photo_text_metadata (
            photoId TEXT PRIMARY KEY,
            originalFilename TEXT,
            assetTitle TEXT,
            assetDescription TEXT,
            keywordsJson TEXT,
            metadataSource TEXT NOT NULL,
            metadataVersion INTEGER NOT NULL DEFAULT 1,
            indexedAt TEXT NOT NULL,
            FOREIGN KEY (photoId) REFERENCES photos(id)
        );

        CREATE INDEX IF NOT EXISTS idx_albums_person ON albums(isPersonAlbum, personId);
        CREATE INDEX IF NOT EXISTS idx_photo_albums_album ON photo_albums(albumId);
        CREATE INDEX IF NOT EXISTS idx_photo_albums_photo ON photo_albums(photoId);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("Metadata table migration failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    static func dropDevelopmentTables(on db: OpaquePointer) -> Bool {
        let sql = """
        DROP TABLE IF EXISTS photo_albums;
        DROP TABLE IF EXISTS photo_text_metadata;
        DROP TABLE IF EXISTS albums;
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
