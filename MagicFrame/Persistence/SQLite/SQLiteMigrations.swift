import Foundation
import SQLite3

/// Repository-specific data fixes invoked during `migrateTablesIfNeeded`.
struct LegacyDataMigrationHooks {
    var migrateLegacyTripEventType: () -> Void = {}
    var migrateLegacyHomeLocations: () -> Void = {}
    var migrateTripSubEventChildNames: () -> Void = {}
    var repairStaleGeocodeStatuses: () -> Void = {}
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
            eventAssignedAt TEXT,
            visionAnalyzed INTEGER DEFAULT 0
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

            photoCount INTEGER DEFAULT 0
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
            displayName TEXT UNIQUE NOT NULL,
            firstName TEXT,
            lastName TEXT,
            maidenName TEXT,
            birthDate TEXT
        );

        CREATE TABLE IF NOT EXISTS photo_people (
            photoId TEXT NOT NULL,
            personId INTEGER NOT NULL,
            source TEXT,
            PRIMARY KEY (photoId, personId)
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
        addColumnIfNeeded(table: "photos", column: "duration", definition: "REAL", on: db)

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

        // Classification lives in `event_tags`. Keep pre-archive columns only until
        // backfill + rename to X* below; never re-add live names after archive.
        ensurePreArchiveEventAttributeColumnsIfNeeded(on: db)
        addColumnIfNeeded(table: "events", column: "weddingDate", definition: "TEXT", on: db)
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
        addColumnIfNeeded(
            table: "photos",
            column: "visionAnalyzed",
            definition: "INTEGER DEFAULT 0",
            on: db
        )
        addColumnIfNeeded(
            table: "photos",
            column: "faceRecognitionVersion",
            definition: "INTEGER DEFAULT 0",
            on: db
        )
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
        addColumnIfNeeded(table: "people", column: "birthDate", definition: "TEXT", on: db)
        migratePeopleDisplayNameFieldsIfNeeded(on: db)
        migrateFaceRecognitionTablesIfNeeded(on: db)
        migrateEventTagsIfNeeded(on: db)
        migrateEventTagsDropLegacyScoringColumnsIfNeeded(on: db)
        migrateSimilarEventTagsIfNeeded(on: db)
        migrateEventNameTemplatesIfNeeded(on: db)
        migrateObjectTagTablesIfNeeded(on: db)
        migrateVisionJobTablesIfNeeded(on: db)
        legacyHooks.backfillEventAttributeTagsFromColumns()
        archiveEventAttributeColumnsIfNeeded(on: db)
        dropArchivedEventAttributeColumnsIfNeeded(on: db)
        // After any holidayType column → event_tags backfill, wipe holiday tags once.
        clearAllHolidayEventTagsOnceIfNeeded(on: db)
        migratePictureSearchTablesIfNeeded(on: db)
        migrateStadiumsTablesIfNeeded(on: db)
        migrateHolidaysTablesIfNeeded(on: db)
        backfillVisionAnalyzedFromObjectTagsIfNeeded(on: db)
        clearPeopleImportedFromAlbumsIfNeeded(on: db)
        dropOccasionTablesIfNeeded(on: db)
        dropEventPeopleTableIfNeeded(on: db)

        legacyHooks.repairStaleGeocodeStatuses()
    }

    /// Rename legacy `people.name` → `displayName` and add structured name columns.
    private static func migratePeopleDisplayNameFieldsIfNeeded(on db: OpaquePointer) {
        guard tableExists("people", on: db) else { return }

        if columnExists(table: "people", column: "name", on: db),
           !columnExists(table: "people", column: "displayName", on: db) {
            if sqlite3_exec(
                db,
                "ALTER TABLE people RENAME COLUMN name TO displayName;",
                nil,
                nil,
                nil
            ) != SQLITE_OK {
                print("Failed to rename people.name → displayName: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        addColumnIfNeeded(table: "people", column: "displayName", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "people", column: "firstName", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "people", column: "lastName", definition: "TEXT", on: db)
        addColumnIfNeeded(table: "people", column: "maidenName", definition: "TEXT", on: db)

        // Legacy DBs that somehow have both: prefer non-empty displayName, else copy name.
        if columnExists(table: "people", column: "name", on: db),
           columnExists(table: "people", column: "displayName", on: db) {
            _ = sqlite3_exec(
                db,
                """
                UPDATE people
                SET displayName = name
                WHERE (displayName IS NULL OR TRIM(displayName) = '')
                  AND name IS NOT NULL
                  AND TRIM(name) != '';
                """,
                nil,
                nil,
                nil
            )
        }
    }

    private static func migrateFaceRecognitionTablesIfNeeded(on db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS person_clusters (
            clusterId INTEGER PRIMARY KEY AUTOINCREMENT,
            representativeFaceInstanceId INTEGER,
            faceCount INTEGER NOT NULL DEFAULT 0,
            personId INTEGER,
            ignored INTEGER NOT NULL DEFAULT 0,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS face_instances (
            faceInstanceId INTEGER PRIMARY KEY AUTOINCREMENT,
            photoId TEXT NOT NULL,
            bboxX REAL NOT NULL,
            bboxY REAL NOT NULL,
            bboxWidth REAL NOT NULL,
            bboxHeight REAL NOT NULL,
            quality REAL,
            embeddingBlob BLOB NOT NULL,
            embeddingVersion INTEGER NOT NULL,
            clusterId INTEGER,
            personId INTEGER,
            createdAt TEXT NOT NULL,
            FOREIGN KEY (photoId) REFERENCES photos(id),
            FOREIGN KEY (clusterId) REFERENCES person_clusters(clusterId),
            FOREIGN KEY (personId) REFERENCES people(personId)
        );

        CREATE INDEX IF NOT EXISTS idx_face_instances_photoId
            ON face_instances(photoId);
        CREATE INDEX IF NOT EXISTS idx_face_instances_clusterId
            ON face_instances(clusterId);
        CREATE INDEX IF NOT EXISTS idx_face_instances_personId
            ON face_instances(personId);
        CREATE INDEX IF NOT EXISTS idx_person_clusters_personId
            ON person_clusters(personId);
        CREATE INDEX IF NOT EXISTS idx_photos_faceRecognitionVersion
            ON photos(faceRecognitionVersion);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("Face recognition table migration failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// People on events are derived live from `photo_people`; the denormalized table is gone.
    private static func dropEventPeopleTableIfNeeded(on db: OpaquePointer) {
        guard tableExists("event_people", on: db) else { return }
        if sqlite3_exec(db, "DROP TABLE IF EXISTS event_people;", nil, nil, nil) != SQLITE_OK {
            print("Failed to drop event_people: \(String(cString: sqlite3_errmsg(db)))")
        } else {
            print("Dropped obsolete event_people table")
        }
    }

    /// `P-` album people were a placeholder. Wipe those rows once; face recognition will refill `people`.
    private static func clearPeopleImportedFromAlbumsIfNeeded(on db: OpaquePointer) {
        let metadataKey = "peopleFromAlbumsClearedV1"
        guard appMetadataValue(key: metadataKey, on: db) != "1" else { return }

        func deleteAll(from table: String) {
            guard tableExists(table, on: db) else { return }
            let sql = "DELETE FROM \(table);"
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                print("Failed to clear \(table): \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        deleteAll(from: "photo_people")
        deleteAll(from: "people_search_people")
        deleteAll(from: "event_score_card_people")

        if tableExists("albums", on: db),
           columnExists(table: "albums", column: "personId", on: db) {
            let sql = """
            UPDATE albums
            SET isPersonAlbum = 0,
                personId = NULL;
            """
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                print("Failed to clear album person links: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        deleteAll(from: "people")
        if tableExists("sqlite_sequence", on: db) {
            let sql = "DELETE FROM sqlite_sequence WHERE name = 'people';"
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                print("Failed to reset people id sequence: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        print("Cleared people imported from P- albums")
        setAppMetadataValue(key: metadataKey, value: "1", on: db)
    }

    /// Photos tagged by Vision (classify or event object scans) but never flagged analyzed
    /// were being re-scanned on every holiday open. Mark them done once.
    private static func backfillVisionAnalyzedFromObjectTagsIfNeeded(on db: OpaquePointer) {
        let metadataKey = "visionAnalyzedBackfillFromObjectTagsV1"
        guard appMetadataValue(key: metadataKey, on: db) != "1" else { return }
        guard tableExists("photos", on: db),
              tableExists("photo_object_tags", on: db),
              columnExists(table: "photos", column: "visionAnalyzed", on: db) else {
            setAppMetadataValue(key: metadataKey, value: "1", on: db)
            return
        }

        let sql = """
        UPDATE photos
        SET visionAnalyzed = 1
        WHERE COALESCE(visionAnalyzed, 0) = 0
          AND id IN (
            SELECT DISTINCT photoId
            FROM photo_object_tags
            WHERE source LIKE 'vision%'
          );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            print("Backfilled photos.visionAnalyzed from existing vision object tags")
        } else {
            print(
                "visionAnalyzed backfill failed: \(String(cString: sqlite3_errmsg(db)))"
            )
        }
        setAppMetadataValue(key: metadataKey, value: "1", on: db)
    }

    /// One-time: delete every `event_tags` holiday row (user + AI + rejected).
    private static func clearAllHolidayEventTagsOnceIfNeeded(on db: OpaquePointer) {
        let metadataKey = "holidayEventTagsClearedV1"
        guard appMetadataValue(key: metadataKey, on: db) != "1" else { return }
        guard tableExists("event_tags", on: db) else {
            setAppMetadataValue(key: metadataKey, value: "1", on: db)
            return
        }

        let holidayCategory = EventAttributeField.holidayType.tagCategory
        let sql = """
        DELETE FROM event_tags
        WHERE tagCategory = ? COLLATE NOCASE;
        """

        var statement: OpaquePointer?
        var deleted = 0
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (holidayCategory as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_DONE {
                deleted = Int(sqlite3_changes(db))
            }
        } else {
            print(
                "clearAllHolidayEventTagsOnceIfNeeded prepare failed:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
            sqlite3_finalize(statement)
            return
        }
        sqlite3_finalize(statement)

        setAppMetadataValue(key: metadataKey, value: "1", on: db)
        print("Cleared \(deleted) holiday event_tags row(s) (one-time)")
    }

    /// Removes the retired occasions system tables (order respects FKs).
    private static func dropOccasionTablesIfNeeded(on db: OpaquePointer) {
        let drops = [
            "DROP TABLE IF EXISTS occasion_landing_metrics;",
            "DROP TABLE IF EXISTS occasion_collection_events;",
            "DROP TABLE IF EXISTS photo_occasion;",
            "DROP TABLE IF EXISTS occasion_subjects;",
            "DROP TABLE IF EXISTS event_occasion_scores;",
            "DROP TABLE IF EXISTS occasion_scoring_rules;",
            "DROP TABLE IF EXISTS occasion_dates;",
            "DROP TABLE IF EXISTS occasions;",
        ]
        for sql in drops {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                print(
                    "Occasion table drop failed (\(sql)):"
                        + " \(String(cString: sqlite3_errmsg(db)))"
                )
            }
        }
    }

    private static func migratePictureSearchTablesIfNeeded(on db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS floating_holidays (
            floatingHolidayId INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL,
            ruleKind TEXT NOT NULL,
            month INTEGER NOT NULL,
            weekday INTEGER NOT NULL,
            weekOrdinal INTEGER NOT NULL,
            isEnabled INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE IF NOT EXISTS date_searches (
            dateSearchId INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            dateSearchType TEXT NOT NULL,
            sameDateSearchDate TEXT,
            movingHolidayKey TEXT,
            floatingHolidayId INTEGER,
            holidayId INTEGER,
            rangeStartMonthDay TEXT,
            rangeEndMonthDay TEXT,
            absoluteStartDate TEXT,
            absoluteEndDate TEXT,
            includeWeekendsBefore INTEGER NOT NULL DEFAULT 0,
            includeWeekendsAfter INTEGER NOT NULL DEFAULT 0,
            includeDaysBefore INTEGER NOT NULL DEFAULT 0,
            includeDaysAfter INTEGER NOT NULL DEFAULT 0,
            includeXDaysBefore INTEGER,
            includeYDaysAfter INTEGER,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            FOREIGN KEY (floatingHolidayId) REFERENCES floating_holidays(floatingHolidayId)
        );

        CREATE TABLE IF NOT EXISTS vision_tag_searches (
            visionTagSearchId INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            matchMode TEXT NOT NULL DEFAULT 'any',
            createdAt TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS vision_tag_search_tags (
            visionTagSearchId INTEGER NOT NULL,
            objectKey TEXT NOT NULL,
            minConfidence REAL NOT NULL DEFAULT 0.12,
            PRIMARY KEY (visionTagSearchId, objectKey),
            FOREIGN KEY (visionTagSearchId) REFERENCES vision_tag_searches(visionTagSearchId)
        );

        CREATE TABLE IF NOT EXISTS location_searches (
            locationSearchId INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            matchMode TEXT NOT NULL DEFAULT 'any',
            createdAt TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS location_search_terms (
            locationSearchTermId INTEGER PRIMARY KEY AUTOINCREMENT,
            locationSearchId INTEGER NOT NULL,
            searchTerm TEXT NOT NULL,
            locationId INTEGER,
            sortOrder INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (locationSearchId) REFERENCES location_searches(locationSearchId)
        );

        CREATE TABLE IF NOT EXISTS people_searches (
            peopleSearchId INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT,
            matchMode TEXT NOT NULL DEFAULT 'any',
            createdAt TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS people_search_people (
            peopleSearchId INTEGER NOT NULL,
            personId INTEGER NOT NULL,
            PRIMARY KEY (peopleSearchId, personId),
            FOREIGN KEY (peopleSearchId) REFERENCES people_searches(peopleSearchId),
            FOREIGN KEY (personId) REFERENCES people(personId)
        );

        CREATE TABLE IF NOT EXISTS picture_searches (
            pictureSearchId INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            targetTagCategory TEXT,
            targetEventType TEXT NOT NULL,
            dateSearchId INTEGER,
            visionTagSearchId INTEGER,
            locationSearchId INTEGER,
            peopleSearchId INTEGER,
            isEnabled INTEGER NOT NULL DEFAULT 1,
            performFaceDetect INTEGER NOT NULL DEFAULT 0,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            FOREIGN KEY (dateSearchId) REFERENCES date_searches(dateSearchId),
            FOREIGN KEY (visionTagSearchId) REFERENCES vision_tag_searches(visionTagSearchId),
            FOREIGN KEY (locationSearchId) REFERENCES location_searches(locationSearchId),
            FOREIGN KEY (peopleSearchId) REFERENCES people_searches(peopleSearchId)
        );

        CREATE TABLE IF NOT EXISTS picture_search_runs (
            pictureSearchRunId INTEGER PRIMARY KEY AUTOINCREMENT,
            pictureSearchId INTEGER NOT NULL,
            startedAt TEXT NOT NULL,
            finishedAt TEXT,
            status TEXT NOT NULL,
            photoHitCount INTEGER NOT NULL DEFAULT 0,
            eventCandidateCount INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY (pictureSearchId) REFERENCES picture_searches(pictureSearchId)
        );

        CREATE TABLE IF NOT EXISTS picture_search_photo_matches (
            pictureSearchPhotoMatchId INTEGER PRIMARY KEY AUTOINCREMENT,
            pictureSearchRunId INTEGER NOT NULL,
            photoId TEXT NOT NULL,
            eventId INTEGER,
            confidence REAL,
            UNIQUE (pictureSearchRunId, photoId),
            FOREIGN KEY (pictureSearchRunId) REFERENCES picture_search_runs(pictureSearchRunId),
            FOREIGN KEY (photoId) REFERENCES photos(id)
        );

        CREATE INDEX IF NOT EXISTS idx_picture_searches_event_type
        ON picture_searches(targetEventType);

        CREATE INDEX IF NOT EXISTS idx_picture_search_runs_search
        ON picture_search_runs(pictureSearchId, startedAt DESC);

        CREATE INDEX IF NOT EXISTS idx_picture_search_photo_matches_run
        ON picture_search_photo_matches(pictureSearchRunId);

        CREATE TABLE IF NOT EXISTS picture_search_event_scores (
            pictureSearchEventScoreId INTEGER PRIMARY KEY AUTOINCREMENT,
            pictureSearchRunId INTEGER NOT NULL,
            eventId INTEGER NOT NULL,
            targetEventType TEXT NOT NULL,
            visionScore REAL NOT NULL DEFAULT 0,
            dateScore REAL NOT NULL DEFAULT 0,
            locationScore REAL NOT NULL DEFAULT 0,
            peopleScore REAL NOT NULL DEFAULT 0,
            totalScore REAL NOT NULL DEFAULT 0,
            likelyGroom TEXT,
            likelyBride TEXT,
            scoredAt TEXT NOT NULL,
            UNIQUE (pictureSearchRunId, eventId),
            FOREIGN KEY (pictureSearchRunId) REFERENCES picture_search_runs(pictureSearchRunId),
            FOREIGN KEY (eventId) REFERENCES events(eventId)
        );

        CREATE INDEX IF NOT EXISTS idx_picture_search_event_scores_run
        ON picture_search_event_scores(pictureSearchRunId, totalScore DESC);

        CREATE TABLE IF NOT EXISTS event_score_cards (
            eventScoreCardId INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            targetTagCategory TEXT,
            targetEventType TEXT NOT NULL,
            dateSearchId INTEGER,
            onDatePoints REAL NOT NULL DEFAULT 10,
            pointsPerDayFromAnchor REAL NOT NULL DEFAULT -1,
            minimumScoreForAI REAL NOT NULL DEFAULT 0,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            FOREIGN KEY (dateSearchId) REFERENCES date_searches(dateSearchId)
        );

        CREATE TABLE IF NOT EXISTS event_score_card_vision_tags (
            eventScoreCardId INTEGER NOT NULL,
            objectKey TEXT NOT NULL,
            minConfidence REAL NOT NULL DEFAULT 0.12,
            points REAL NOT NULL DEFAULT 1,
            PRIMARY KEY (eventScoreCardId, objectKey),
            FOREIGN KEY (eventScoreCardId) REFERENCES event_score_cards(eventScoreCardId)
        );

        CREATE TABLE IF NOT EXISTS event_score_card_people (
            eventScoreCardId INTEGER NOT NULL,
            personId INTEGER NOT NULL,
            points REAL NOT NULL DEFAULT 5,
            PRIMARY KEY (eventScoreCardId, personId),
            FOREIGN KEY (eventScoreCardId) REFERENCES event_score_cards(eventScoreCardId),
            FOREIGN KEY (personId) REFERENCES people(personId)
        );

        CREATE TABLE IF NOT EXISTS event_score_card_locations (
            eventScoreCardId INTEGER NOT NULL,
            searchTerm TEXT NOT NULL,
            points REAL NOT NULL DEFAULT 5,
            PRIMARY KEY (eventScoreCardId, searchTerm),
            FOREIGN KEY (eventScoreCardId) REFERENCES event_score_cards(eventScoreCardId)
        );
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print(
                "Picture search table migration failed:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }

        addColumnIfNeeded(
            table: "vision_tag_search_tags",
            column: "minConfidence",
            definition: "REAL NOT NULL DEFAULT 0.12",
            on: db
        )
        addColumnIfNeeded(
            table: "picture_searches",
            column: "targetTagCategory",
            definition: "TEXT",
            on: db
        )
        addColumnIfNeeded(
            table: "picture_searches",
            column: "performFaceDetect",
            definition: "INTEGER NOT NULL DEFAULT 0",
            on: db
        )
        addColumnIfNeeded(
            table: "date_searches",
            column: "holidayId",
            definition: "INTEGER",
            on: db
        )
        backfillPictureSearchTargetTagCategoryIfNeeded(on: db)
    }

    private static func migrateStadiumsTablesIfNeeded(on db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS stadiums (
            stadiumId INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            city TEXT,
            state TEXT,
            latitude REAL,
            longitude REAL,
            createdAt TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS stadium_aliases (
            stadiumId INTEGER NOT NULL,
            alias TEXT NOT NULL,
            PRIMARY KEY (stadiumId, alias),
            FOREIGN KEY (stadiumId) REFERENCES stadiums(stadiumId)
        );

        CREATE UNIQUE INDEX IF NOT EXISTS idx_stadium_aliases_alias
        ON stadium_aliases(alias COLLATE NOCASE);

        CREATE TABLE IF NOT EXISTS stadium_teams (
            stadiumTeamId INTEGER PRIMARY KEY AUTOINCREMENT,
            stadiumId INTEGER NOT NULL,
            league TEXT NOT NULL,
            teamName TEXT NOT NULL,
            displayName TEXT,
            teamAbbreviation TEXT,
            isPrimaryHome INTEGER NOT NULL DEFAULT 1,
            UNIQUE (stadiumId, league, teamName),
            FOREIGN KEY (stadiumId) REFERENCES stadiums(stadiumId)
        );

        CREATE TABLE IF NOT EXISTS event_game_results (
            eventId INTEGER PRIMARY KEY,
            stadiumId INTEGER,
            league TEXT NOT NULL,
            espnEventId TEXT,
            homeTeam TEXT NOT NULL,
            awayTeam TEXT NOT NULL,
            homeScore INTEGER,
            awayScore INTEGER,
            gameDateISO TEXT,
            venueName TEXT,
            summaryLine TEXT NOT NULL,
            source TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            FOREIGN KEY (eventId) REFERENCES events(eventId),
            FOREIGN KEY (stadiumId) REFERENCES stadiums(stadiumId)
        );
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print(
                "Stadiums table migration failed:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }

        seedBuiltInStadiumsIfNeeded(on: db)
    }

    private static func seedBuiltInStadiumsIfNeeded(on db: OpaquePointer) {
        let metadataKey = "stadiumsSeededV2"
        guard appMetadataValue(key: metadataKey, on: db) != "1" else { return }

        struct TeamSeed {
            let league: String
            let teamName: String
            let displayName: String
            let abbreviation: String?
            let isPrimaryHome: Bool
        }

        struct StadiumSeed {
            let name: String
            let city: String
            let state: String
            let latitude: Double
            let longitude: Double
            let aliases: [String]
            let teams: [TeamSeed]
        }

        let seeds: [StadiumSeed] = [
            StadiumSeed(
                name: "Truist Park",
                city: "Atlanta",
                state: "GA",
                latitude: 33.8907,
                longitude: -84.4677,
                aliases: ["SunTrust Park", "Truist"],
                teams: [
                    TeamSeed(
                        league: "mlb",
                        teamName: "Atlanta Braves",
                        displayName: "Atlanta Braves",
                        abbreviation: "ATL",
                        isPrimaryHome: true
                    ),
                ]
            ),
            StadiumSeed(
                name: "Bobby Dodd Stadium",
                city: "Atlanta",
                state: "GA",
                latitude: 33.7725,
                longitude: -84.3928,
                aliases: [
                    "Booby Dodd Stadium",
                    "Bobby Dodd",
                    "Bobby Dodd Stadium at Historic Grant Field",
                    "Grant Field",
                ],
                teams: [
                    TeamSeed(
                        league: "college-football",
                        teamName: "Georgia Tech",
                        displayName: "Georgia Tech Yellow Jackets",
                        abbreviation: "GT",
                        isPrimaryHome: true
                    ),
                ]
            ),
            StadiumSeed(
                name: "Citi Field",
                city: "Queens",
                state: "NY",
                latitude: 40.7571,
                longitude: -73.8458,
                aliases: ["Citifield", "CitiField"],
                teams: [
                    TeamSeed(
                        league: "mlb",
                        teamName: "New York Mets",
                        displayName: "New York Mets",
                        abbreviation: "NYM",
                        isPrimaryHome: true
                    ),
                ]
            ),
            StadiumSeed(
                name: "Georgia Dome",
                city: "Atlanta",
                state: "GA",
                latitude: 33.7573,
                longitude: -84.4003,
                aliases: ["The Georgia Dome"],
                teams: [
                    TeamSeed(
                        league: "nfl",
                        teamName: "Atlanta Falcons",
                        displayName: "Atlanta Falcons",
                        abbreviation: "ATL",
                        isPrimaryHome: true
                    ),
                    TeamSeed(
                        league: "college-football",
                        teamName: "Georgia Tech",
                        displayName: "Georgia Tech Yellow Jackets",
                        abbreviation: "GT",
                        isPrimaryHome: false
                    ),
                    TeamSeed(
                        league: "college-football",
                        teamName: "Georgia",
                        displayName: "Georgia Bulldogs",
                        abbreviation: "UGA",
                        isPrimaryHome: false
                    ),
                ]
            ),
            StadiumSeed(
                name: "Mercedes-Benz Stadium",
                city: "Atlanta",
                state: "GA",
                latitude: 33.7554,
                longitude: -84.4008,
                aliases: [
                    "Mercedes Benz Stadium",
                    "Mercedes Benz",
                    "Mercedes-Benz",
                    "MB Stadium",
                ],
                teams: [
                    TeamSeed(
                        league: "nfl",
                        teamName: "Atlanta Falcons",
                        displayName: "Atlanta Falcons",
                        abbreviation: "ATL",
                        isPrimaryHome: true
                    ),
                    TeamSeed(
                        league: "college-football",
                        teamName: "Georgia Tech",
                        displayName: "Georgia Tech Yellow Jackets",
                        abbreviation: "GT",
                        isPrimaryHome: false
                    ),
                    TeamSeed(
                        league: "college-football",
                        teamName: "Georgia",
                        displayName: "Georgia Bulldogs",
                        abbreviation: "UGA",
                        isPrimaryHome: false
                    ),
                ]
            ),
            StadiumSeed(
                name: "Jordan-Hare Stadium",
                city: "Auburn",
                state: "AL",
                latitude: 32.602245,
                longitude: -85.489250,
                aliases: [
                    "Jordan Hare Stadium",
                    "Jordan Hare",
                    "Pat Dye Field",
                    "Pat Dye Field at Jordan-Hare Stadium",
                ],
                teams: [
                    TeamSeed(
                        league: "college-football",
                        teamName: "Auburn",
                        displayName: "Auburn Tigers",
                        abbreviation: "AUB",
                        isPrimaryHome: true
                    ),
                ]
            ),
        ]

        let now = ISO8601DateFormatter().string(from: Date())

        for seed in seeds {
            let stadiumId: Int
            let insertStadium = """
            INSERT OR IGNORE INTO stadiums (name, city, state, latitude, longitude, createdAt)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            var insertStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, insertStadium, -1, &insertStatement, nil) == SQLITE_OK {
                sqlite3_bind_text(insertStatement, 1, (seed.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStatement, 2, (seed.city as NSString).utf8String, -1, nil)
                sqlite3_bind_text(insertStatement, 3, (seed.state as NSString).utf8String, -1, nil)
                sqlite3_bind_double(insertStatement, 4, seed.latitude)
                sqlite3_bind_double(insertStatement, 5, seed.longitude)
                sqlite3_bind_text(insertStatement, 6, (now as NSString).utf8String, -1, nil)
                sqlite3_step(insertStatement)
            }
            sqlite3_finalize(insertStatement)

            let selectSQL = "SELECT stadiumId FROM stadiums WHERE name = ? LIMIT 1;"
            var selectStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStatement, nil) == SQLITE_OK else {
                continue
            }
            sqlite3_bind_text(selectStatement, 1, (seed.name as NSString).utf8String, -1, nil)
            guard sqlite3_step(selectStatement) == SQLITE_ROW else {
                sqlite3_finalize(selectStatement)
                continue
            }
            stadiumId = Int(sqlite3_column_int(selectStatement, 0))
            sqlite3_finalize(selectStatement)

            for alias in seed.aliases + [seed.name] {
                let aliasSQL = """
                INSERT OR IGNORE INTO stadium_aliases (stadiumId, alias) VALUES (?, ?);
                """
                var aliasStatement: OpaquePointer?
                if sqlite3_prepare_v2(db, aliasSQL, -1, &aliasStatement, nil) == SQLITE_OK {
                    sqlite3_bind_int(aliasStatement, 1, Int32(stadiumId))
                    sqlite3_bind_text(aliasStatement, 2, (alias as NSString).utf8String, -1, nil)
                    sqlite3_step(aliasStatement)
                }
                sqlite3_finalize(aliasStatement)
            }

            for team in seed.teams {
                let teamSQL = """
                INSERT OR IGNORE INTO stadium_teams (
                    stadiumId, league, teamName, displayName, teamAbbreviation, isPrimaryHome
                ) VALUES (?, ?, ?, ?, ?, ?);
                """
                var teamStatement: OpaquePointer?
                if sqlite3_prepare_v2(db, teamSQL, -1, &teamStatement, nil) == SQLITE_OK {
                    sqlite3_bind_int(teamStatement, 1, Int32(stadiumId))
                    sqlite3_bind_text(
                        teamStatement,
                        2,
                        (team.league as NSString).utf8String,
                        -1,
                        nil
                    )
                    sqlite3_bind_text(
                        teamStatement,
                        3,
                        (team.teamName as NSString).utf8String,
                        -1,
                        nil
                    )
                    sqlite3_bind_text(
                        teamStatement,
                        4,
                        (team.displayName as NSString).utf8String,
                        -1,
                        nil
                    )
                    if let abbreviation = team.abbreviation {
                        sqlite3_bind_text(
                            teamStatement,
                            5,
                            (abbreviation as NSString).utf8String,
                            -1,
                            nil
                        )
                    } else {
                        sqlite3_bind_null(teamStatement, 5)
                    }
                    sqlite3_bind_int(teamStatement, 6, team.isPrimaryHome ? 1 : 0)
                    sqlite3_step(teamStatement)
                }
                sqlite3_finalize(teamStatement)
            }
        }

        setAppMetadataValue(key: metadataKey, value: "1", on: db)
        print(
            "Seeded built-in stadiums (Truist, Bobby Dodd, Citi Field, Georgia Dome,"
                + " Mercedes-Benz, Jordan-Hare)"
        )
    }

    /// Unified holiday catalog (fixed / floating / computed) + per-year resolved anchors.
    private static func migrateHolidaysTablesIfNeeded(on db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS holidays (
            holidayId INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL,
            kind TEXT NOT NULL,
            fixedMonth INTEGER,
            fixedDay INTEGER,
            ruleKind TEXT,
            month INTEGER,
            weekday INTEGER,
            weekOrdinal INTEGER,
            includeWeekendsBefore INTEGER NOT NULL DEFAULT 1,
            isBuiltIn INTEGER NOT NULL DEFAULT 0,
            isEnabled INTEGER NOT NULL DEFAULT 1,
            sortIndex INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS holiday_dates (
            holidayDateId INTEGER PRIMARY KEY AUTOINCREMENT,
            holidayId INTEGER NOT NULL,
            year INTEGER NOT NULL,
            anchorDate TEXT NOT NULL,
            UNIQUE (holidayId, year),
            FOREIGN KEY (holidayId) REFERENCES holidays(holidayId)
        );

        CREATE INDEX IF NOT EXISTS idx_holiday_dates_holiday_year
        ON holiday_dates(holidayId, year);
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("Holidays table migration failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        seedBuiltInHolidaysIfNeeded(on: db)
        migrateFloatingHolidaysIntoHolidaysIfNeeded(on: db)
        seedHolidayDatesIfNeeded(on: db)
    }

    private static func seedBuiltInHolidaysIfNeeded(on db: OpaquePointer) {
        struct Seed {
            let name: String
            let kind: String
            let fixedMonth: Int?
            let fixedDay: Int?
            let ruleKind: String?
            let month: Int?
            let weekday: Int?
            let weekOrdinal: Int?
            let sortIndex: Int
        }

        // weekday: 1=Sunday … 7=Saturday (Calendar).
        let seeds: [Seed] = [
            Seed(name: "Christmas", kind: "fixed", fixedMonth: 12, fixedDay: 25,
                 ruleKind: nil, month: nil, weekday: nil, weekOrdinal: nil, sortIndex: 0),
            Seed(name: "Halloween", kind: "fixed", fixedMonth: 10, fixedDay: 31,
                 ruleKind: nil, month: nil, weekday: nil, weekOrdinal: nil, sortIndex: 1),
            Seed(name: "July 4th", kind: "fixed", fixedMonth: 7, fixedDay: 4,
                 ruleKind: nil, month: nil, weekday: nil, weekOrdinal: nil, sortIndex: 2),
            Seed(name: "New Years", kind: "fixed", fixedMonth: 1, fixedDay: 1,
                 ruleKind: nil, month: nil, weekday: nil, weekOrdinal: nil, sortIndex: 3),
            Seed(name: "Valentine's Day", kind: "fixed", fixedMonth: 2, fixedDay: 14,
                 ruleKind: nil, month: nil, weekday: nil, weekOrdinal: nil, sortIndex: 4),
            Seed(name: "St. Patty's Day", kind: "fixed", fixedMonth: 3, fixedDay: 17,
                 ruleKind: nil, month: nil, weekday: nil, weekOrdinal: nil, sortIndex: 5),
            Seed(name: "Thanksgiving", kind: "floating", fixedMonth: nil, fixedDay: nil,
                 ruleKind: "nthWeekdayOfMonth", month: 11, weekday: 5, weekOrdinal: 4, sortIndex: 6),
            Seed(name: "Easter", kind: "computed", fixedMonth: nil, fixedDay: nil,
                 ruleKind: "easter", month: nil, weekday: nil, weekOrdinal: nil, sortIndex: 7),
            Seed(name: "Mother's Day", kind: "floating", fixedMonth: nil, fixedDay: nil,
                 ruleKind: "nthWeekdayOfMonth", month: 5, weekday: 1, weekOrdinal: 2, sortIndex: 8),
            Seed(name: "Father's Day", kind: "floating", fixedMonth: nil, fixedDay: nil,
                 ruleKind: "nthWeekdayOfMonth", month: 6, weekday: 1, weekOrdinal: 3, sortIndex: 9),
        ]

        let insertSQL = """
        INSERT OR IGNORE INTO holidays (
            name, kind, fixedMonth, fixedDay, ruleKind, month, weekday, weekOrdinal,
            includeWeekendsBefore, isBuiltIn, isEnabled, sortIndex
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 1, 1, ?);
        """

        for seed in seeds {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (seed.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (seed.kind as NSString).utf8String, -1, nil)
                if let fixedMonth = seed.fixedMonth {
                    sqlite3_bind_int(statement, 3, Int32(fixedMonth))
                } else {
                    sqlite3_bind_null(statement, 3)
                }
                if let fixedDay = seed.fixedDay {
                    sqlite3_bind_int(statement, 4, Int32(fixedDay))
                } else {
                    sqlite3_bind_null(statement, 4)
                }
                if let ruleKind = seed.ruleKind {
                    sqlite3_bind_text(statement, 5, (ruleKind as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(statement, 5)
                }
                if let month = seed.month {
                    sqlite3_bind_int(statement, 6, Int32(month))
                } else {
                    sqlite3_bind_null(statement, 6)
                }
                if let weekday = seed.weekday {
                    sqlite3_bind_int(statement, 7, Int32(weekday))
                } else {
                    sqlite3_bind_null(statement, 7)
                }
                if let weekOrdinal = seed.weekOrdinal {
                    sqlite3_bind_int(statement, 8, Int32(weekOrdinal))
                } else {
                    sqlite3_bind_null(statement, 8)
                }
                sqlite3_bind_int(statement, 9, Int32(seed.sortIndex))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }

    private static func migrateFloatingHolidaysIntoHolidaysIfNeeded(on db: OpaquePointer) {
        guard tableExists("floating_holidays", on: db) else { return }

        let sql = """
        INSERT OR IGNORE INTO holidays (
            name, kind, fixedMonth, fixedDay, ruleKind, month, weekday, weekOrdinal,
            includeWeekendsBefore, isBuiltIn, isEnabled, sortIndex
        )
        SELECT
            name,
            'floating',
            NULL,
            NULL,
            ruleKind,
            month,
            weekday,
            weekOrdinal,
            1,
            0,
            isEnabled,
            1000
        FROM floating_holidays;
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print(
                "Floating holidays → holidays migration failed:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }
    }

    private static func seedHolidayDatesIfNeeded(on db: OpaquePointer) {
        // V2 expands anchors to 1900–2050 (V1 was roughly currentYear±35/5).
        let metadataKey = "holidayDatesSeededV2"
        guard appMetadataValue(key: metadataKey, on: db) != "1" else { return }

        let fetchSQL = """
        SELECT holidayId, name, kind, fixedMonth, fixedDay, ruleKind, month, weekday, weekOrdinal,
               includeWeekendsBefore, isBuiltIn, isEnabled, sortIndex
        FROM holidays
        WHERE isEnabled = 1;
        """
        var holidays: [HolidayDefinition] = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, fetchSQL, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let kindRaw = sqlite3_column_text(statement, 2),
                      let kind = HolidayKind(rawValue: String(cString: kindRaw)) else {
                    continue
                }
                holidays.append(
                    HolidayDefinition(
                        holidayId: Int(sqlite3_column_int(statement, 0)),
                        name: String(cString: sqlite3_column_text(statement, 1)),
                        kind: kind,
                        fixedMonth: sqlite3_column_type(statement, 3) == SQLITE_NULL
                            ? nil : Int(sqlite3_column_int(statement, 3)),
                        fixedDay: sqlite3_column_type(statement, 4) == SQLITE_NULL
                            ? nil : Int(sqlite3_column_int(statement, 4)),
                        ruleKind: sqlite3_column_type(statement, 5) == SQLITE_NULL
                            ? nil : String(cString: sqlite3_column_text(statement, 5)),
                        month: sqlite3_column_type(statement, 6) == SQLITE_NULL
                            ? nil : Int(sqlite3_column_int(statement, 6)),
                        weekday: sqlite3_column_type(statement, 7) == SQLITE_NULL
                            ? nil : Int(sqlite3_column_int(statement, 7)),
                        weekOrdinal: sqlite3_column_type(statement, 8) == SQLITE_NULL
                            ? nil : Int(sqlite3_column_int(statement, 8)),
                        includeWeekendsBefore: sqlite3_column_int(statement, 9) != 0,
                        isBuiltIn: sqlite3_column_int(statement, 10) != 0,
                        isEnabled: sqlite3_column_int(statement, 11) != 0,
                        sortIndex: Int(sqlite3_column_int(statement, 12))
                    )
                )
            }
        }
        sqlite3_finalize(statement)

        let calendar = Calendar(identifier: .gregorian)
        let yearRange = HolidayDateResolver.seededYearRange

        let upsertSQL = """
        INSERT INTO holiday_dates (holidayId, year, anchorDate)
        VALUES (?, ?, ?)
        ON CONFLICT(holidayId, year) DO UPDATE SET anchorDate = excluded.anchorDate;
        """

        for holiday in holidays {
            guard let holidayId = holiday.holidayId else { continue }
            for year in yearRange {
                guard let iso = HolidayDateResolver.dateISO(
                    for: holiday,
                    year: year,
                    calendar: calendar
                ) else {
                    continue
                }
                var upsert: OpaquePointer?
                if sqlite3_prepare_v2(db, upsertSQL, -1, &upsert, nil) == SQLITE_OK {
                    sqlite3_bind_int(upsert, 1, Int32(holidayId))
                    sqlite3_bind_int(upsert, 2, Int32(year))
                    sqlite3_bind_text(upsert, 3, (iso as NSString).utf8String, -1, nil)
                    sqlite3_step(upsert)
                }
                sqlite3_finalize(upsert)
            }
        }

        setAppMetadataValue(key: metadataKey, value: "1", on: db)
        print("Seeded holiday_dates for \(holidays.count) holiday(s), years \(yearRange.lowerBound)–\(yearRange.upperBound)")
    }

    /// Fills `targetTagCategory` from known tag values for legacy picture searches.
    private static func backfillPictureSearchTargetTagCategoryIfNeeded(on db: OpaquePointer) {
        guard tableExists("picture_searches", on: db),
              columnExists(table: "picture_searches", column: "targetTagCategory", on: db) else {
            return
        }

        let sql = """
        SELECT pictureSearchId, targetEventType
        FROM picture_searches
        WHERE targetTagCategory IS NULL
           OR TRIM(targetTagCategory) = '';
        """
        var statement: OpaquePointer?
        var updates: [(id: Int, category: String)] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(statement, 0))
                let value = String(cString: sqlite3_column_text(statement, 1))
                let category = EventAttributeField.pictureSearchCategory(forTargetValue: value).tagCategory
                updates.append((id, category))
            }
        }
        sqlite3_finalize(statement)

        guard !updates.isEmpty else { return }

        let updateSQL = """
        UPDATE picture_searches
        SET targetTagCategory = ?
        WHERE pictureSearchId = ?;
        """
        for update in updates {
            var updateStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK {
                sqlite3_bind_text(
                    updateStatement,
                    1,
                    (update.category as NSString).utf8String,
                    -1,
                    nil
                )
                sqlite3_bind_int(updateStatement, 2, Int32(update.id))
                sqlite3_step(updateStatement)
            }
            sqlite3_finalize(updateStatement)
        }
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
            totalScore REAL,
            isRejected INTEGER NOT NULL DEFAULT 0,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            UNIQUE (eventId, tagCategory, tagValue),
            FOREIGN KEY (eventId) REFERENCES events(eventId)
        );

        CREATE INDEX IF NOT EXISTS idx_event_tags_event ON event_tags(eventId);
        CREATE INDEX IF NOT EXISTS idx_event_tags_source ON event_tags(eventId, source);
        CREATE INDEX IF NOT EXISTS idx_event_tags_category
        ON event_tags(eventId, tagCategory);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("Event tags migration failed: \(String(cString: sqlite3_errmsg(db)))")
        }

        migrateEventTagsUniqueToIncludeTagValueIfNeeded(on: db)
    }

    /// Suggested event-name patterns by tag (Wedding, Senior Prom, …).
    private static func migrateEventNameTemplatesIfNeeded(on db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS event_name_templates (
            eventNameTemplateId INTEGER PRIMARY KEY AUTOINCREMENT,
            tagCategory TEXT NOT NULL,
            tagValue TEXT NOT NULL,
            nameTemplate TEXT NOT NULL,
            personCount INTEGER NOT NULL DEFAULT 1,
            UNIQUE (tagCategory, tagValue)
        );

        CREATE INDEX IF NOT EXISTS idx_event_name_templates_tag
        ON event_name_templates(tagCategory, tagValue);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("event_name_templates migration failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        seedEventNameTemplatesIfNeeded(on: db)
    }

    private static func seedEventNameTemplatesIfNeeded(on db: OpaquePointer) {
        let milestone = EventAttributeField.milestoneType.tagCategory
        // person1 = first main person (bride for Wedding); person2 = second (groom).
        let seeds: [(String, String, Int)] = [
            ("Wedding", "{person2} and {person1}'s Wedding", 2),
            ("Senior Prom", "{person1}'s Senior Prom", 1),
            ("Junior Prom", "{person1}'s Junior Prom", 1),
            ("Engagement Party", "{person1} and {person2}'s Engagement Party", 2),
            ("Christening", "{person1}'s Christening", 1),
            ("Confirmation", "{person1}'s Confirmation", 1),
        ]

        let sql = """
        INSERT OR IGNORE INTO event_name_templates (
            tagCategory, tagValue, nameTemplate, personCount
        )
        VALUES (?, ?, ?, ?);
        """

        for (tagValue, nameTemplate, personCount) in seeds {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (milestone as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (tagValue as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (nameTemplate as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 4, Int32(personCount))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }

    /// Alternatives offered after rejecting an AI tag (Wedding → Prom, Engagement, etc.).
    private static func migrateSimilarEventTagsIfNeeded(on db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS similar_event_tags (
            similarEventTagId INTEGER PRIMARY KEY AUTOINCREMENT,
            tagCategory TEXT NOT NULL,
            tagValue TEXT NOT NULL,
            possibleTagCategory TEXT NOT NULL,
            possibleTagValue TEXT NOT NULL,
            possibleNumberOfEventMainPeople INTEGER NOT NULL DEFAULT 1,
            UNIQUE (tagCategory, tagValue, possibleTagCategory, possibleTagValue)
        );

        CREATE INDEX IF NOT EXISTS idx_similar_event_tags_source
        ON similar_event_tags(tagCategory, tagValue);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("similar_event_tags migration failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        seedWeddingSimilarEventTagsIfNeeded(on: db)
    }

    private static func seedWeddingSimilarEventTagsIfNeeded(on db: OpaquePointer) {
        let milestone = EventAttributeField.milestoneType.tagCategory
        let seeds: [(String, Int)] = [
            ("Senior Prom", 1),
            ("Junior Prom", 1),
            ("Engagement Party", 2),
            ("Christening", 1),
            ("Confirmation", 1),
        ]

        let sql = """
        INSERT OR IGNORE INTO similar_event_tags (
            tagCategory, tagValue, possibleTagCategory, possibleTagValue,
            possibleNumberOfEventMainPeople
        )
        VALUES (?, ?, ?, ?, ?);
        """

        for (possibleValue, peopleCount) in seeds {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (milestone as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, ("Wedding" as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (milestone as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 4, (possibleValue as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 5, Int32(peopleCount))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }

    /// Allows multiple `eventMainPerson` rows per event (e.g. groom + bride).
    private static func migrateEventTagsUniqueToIncludeTagValueIfNeeded(on db: OpaquePointer) {
        guard tableExists("event_tags", on: db) else { return }
        if eventTagsUniqueIncludesTagValue(on: db) { return }

        let sql = """
        CREATE TABLE IF NOT EXISTS event_tags_v2 (
            eventTagId INTEGER PRIMARY KEY AUTOINCREMENT,
            eventId INTEGER NOT NULL,
            tagCategory TEXT NOT NULL,
            tagValue TEXT NOT NULL,
            source TEXT NOT NULL,
            totalScore REAL,
            isRejected INTEGER NOT NULL DEFAULT 0,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            UNIQUE (eventId, tagCategory, tagValue),
            FOREIGN KEY (eventId) REFERENCES events(eventId)
        );

        INSERT OR IGNORE INTO event_tags_v2 (
            eventTagId, eventId, tagCategory, tagValue, source,
            totalScore, isRejected, createdAt, updatedAt
        )
        SELECT
            eventTagId, eventId, tagCategory, tagValue, source,
            totalScore, isRejected, createdAt, updatedAt
        FROM event_tags;

        DROP TABLE event_tags;
        ALTER TABLE event_tags_v2 RENAME TO event_tags;

        CREATE INDEX IF NOT EXISTS idx_event_tags_event ON event_tags(eventId);
        CREATE INDEX IF NOT EXISTS idx_event_tags_source ON event_tags(eventId, source);
        CREATE INDEX IF NOT EXISTS idx_event_tags_category
        ON event_tags(eventId, tagCategory);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            print("Migrated event_tags unique key to (eventId, tagCategory, tagValue)")
        } else {
            print(
                "event_tags unique migration failed:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }
    }

    private static func tableExists(_ table: String, on db: OpaquePointer) -> Bool {
        let sql = """
        SELECT 1 FROM sqlite_master
        WHERE type = 'table' AND name = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        var exists = false
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (table as NSString).utf8String, -1, nil)
            exists = sqlite3_step(statement) == SQLITE_ROW
        }
        sqlite3_finalize(statement)
        return exists
    }

    private static func eventTagsUniqueIncludesTagValue(on db: OpaquePointer) -> Bool {
        let sql = """
        SELECT sql FROM sqlite_master
        WHERE type = 'table' AND name = 'event_tags'
        LIMIT 1;
        """
        var statement: OpaquePointer?
        var includes = false
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW,
           let cString = sqlite3_column_text(statement, 0) {
            let createSQL = String(cString: cString)
            includes = createSQL.contains("UNIQUE (eventId, tagCategory, tagValue)")
                || createSQL.contains("UNIQUE(eventId, tagCategory, tagValue)")
        }
        sqlite3_finalize(statement)
        return includes
    }

    /// Drops retired occasion/scoring columns from `event_tags` on upgraded databases.
    private static func migrateEventTagsDropLegacyScoringColumnsIfNeeded(on db: OpaquePointer) {
        guard tableExists("event_tags", on: db) else { return }
        guard eventTagsHasLegacyScoringColumns(on: db) else { return }

        let sql = """
        CREATE TABLE IF NOT EXISTS event_tags_v3 (
            eventTagId INTEGER PRIMARY KEY AUTOINCREMENT,
            eventId INTEGER NOT NULL,
            tagCategory TEXT NOT NULL,
            tagValue TEXT NOT NULL,
            source TEXT NOT NULL,
            totalScore REAL,
            isRejected INTEGER NOT NULL DEFAULT 0,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            UNIQUE (eventId, tagCategory, tagValue),
            FOREIGN KEY (eventId) REFERENCES events(eventId)
        );

        INSERT OR IGNORE INTO event_tags_v3 (
            eventTagId, eventId, tagCategory, tagValue, source,
            totalScore, isRejected, createdAt, updatedAt
        )
        SELECT
            eventTagId, eventId, tagCategory, tagValue, source,
            totalScore, isRejected, createdAt, updatedAt
        FROM event_tags;

        DROP TABLE event_tags;
        ALTER TABLE event_tags_v3 RENAME TO event_tags;

        CREATE INDEX IF NOT EXISTS idx_event_tags_event ON event_tags(eventId);
        CREATE INDEX IF NOT EXISTS idx_event_tags_source ON event_tags(eventId, source);
        CREATE INDEX IF NOT EXISTS idx_event_tags_category
        ON event_tags(eventId, tagCategory);
        """

        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            print("Migrated event_tags to drop legacy scoring columns")
        } else {
            print(
                "event_tags legacy column drop failed:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }
    }

    private static func eventTagsHasLegacyScoringColumns(on db: OpaquePointer) -> Bool {
        let legacyColumns: Set<String> = [
            "appliedPhase",
            "occasionId",
            "scoringYear",
            "confidence",
        ]
        let sql = "PRAGMA table_info(event_tags);"
        var statement: OpaquePointer?
        var found = Set<String>()
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(statement, 1))
                if legacyColumns.contains(name) {
                    found.insert(name)
                }
            }
        }
        sqlite3_finalize(statement)
        return !found.isEmpty
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

        CREATE TABLE IF NOT EXISTS photo_exif (
            photoId TEXT PRIMARY KEY,
            dateTimeOriginal TEXT,
            dateTimeDigitized TEXT,
            gpsTimestamp TEXT,
            imageUniqueId TEXT,
            cameraMake TEXT,
            cameraModel TEXT,
            lensModel TEXT,
            status TEXT NOT NULL,
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
        DROP TABLE IF EXISTS photo_exif;
        DROP TABLE IF EXISTS photo_albums;
        DROP TABLE IF EXISTS photo_text_metadata;
        DROP TABLE IF EXISTS albums;
        DROP TABLE IF EXISTS face_instances;
        DROP TABLE IF EXISTS person_clusters;
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

    private static let eventAttributeLegacyColumns = [
        "eventType",
        "activityType",
        "milestoneType",
        "holidayType",
        "eventMainPerson",
        "eventMainPerson2",
        "tripType",
    ]

    private static let eventAttributeColumnsDroppedMetadataKey =
        "eventAttributeArchiveColumnsDroppedV1"

    /// Live attribute columns only for DBs that have not finished the tags cutover.
    private static func ensurePreArchiveEventAttributeColumnsIfNeeded(on db: OpaquePointer) {
        // After backfill/archive/drop, never recreate live classification columns.
        if appMetadataValue(key: "eventAttributeTagsBackfilledV1", on: db) == "1"
            || appMetadataValue(key: eventAttributeColumnsDroppedMetadataKey, on: db) == "1" {
            return
        }
        if eventAttributeLegacyColumns.contains(where: {
            columnExists(table: "events", column: "X\($0)", on: db)
        }) {
            return
        }

        for column in eventAttributeLegacyColumns {
            addColumnIfNeeded(table: "events", column: column, definition: "TEXT", on: db)
        }
    }

    /// After tags are backfilled, rename classification columns to `X*` archive names.
    private static func archiveEventAttributeColumnsIfNeeded(on db: OpaquePointer) {
        for column in eventAttributeLegacyColumns {
            renameColumnIfNeeded(
                table: "events",
                from: column,
                to: "X\(column)",
                on: db
            )
        }
    }

    /// Drop archived `X*` classification columns once tags are the source of truth.
    private static func dropArchivedEventAttributeColumnsIfNeeded(on db: OpaquePointer) {
        if appMetadataValue(key: eventAttributeColumnsDroppedMetadataKey, on: db) == "1" {
            return
        }

        // Only drop after backfill has run (or there was nothing to backfill).
        let backfilled = appMetadataValue(key: "eventAttributeTagsBackfilledV1", on: db) == "1"
        let hasArchivedColumns = eventAttributeLegacyColumns.contains {
            columnExists(table: "events", column: "X\($0)", on: db)
        }
        let hasLiveColumns = eventAttributeLegacyColumns.contains {
            columnExists(table: "events", column: $0, on: db)
        }

        guard backfilled || hasArchivedColumns || !hasLiveColumns else { return }

        for column in eventAttributeLegacyColumns {
            dropColumnIfNeeded(table: "events", column: "X\(column)", on: db)
            // Belt-and-suspenders if archive rename never ran.
            dropColumnIfNeeded(table: "events", column: column, on: db)
        }

        setAppMetadataValue(key: eventAttributeColumnsDroppedMetadataKey, value: "1", on: db)
        print("Dropped archived event attribute columns (XeventType, …)")
    }

    private static func appMetadataValue(key: String, on db: OpaquePointer) -> String? {
        let sql = "SELECT value FROM app_metadata WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        var value: String?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW,
               let cString = sqlite3_column_text(statement, 0) {
                value = String(cString: cString)
            }
        }
        sqlite3_finalize(statement)
        return value
    }

    private static func setAppMetadataValue(key: String, value: String, on db: OpaquePointer) {
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

    private static func renameColumnIfNeeded(
        table: String,
        from: String,
        to: String,
        on db: OpaquePointer
    ) {
        guard columnExists(table: table, column: from, on: db) else { return }
        guard !columnExists(table: table, column: to, on: db) else { return }

        let sql = "ALTER TABLE \(table) RENAME COLUMN \(from) TO \(to);"
        if sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK {
            print("Renamed \(table).\(from) → \(to)")
        } else {
            print(
                "Failed to rename \(table).\(from) → \(to):"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }
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
