import Foundation
import SQLite3

/// SQLite access for `events` and `photo_events` (people via live `photo_people` joins).
final class EventRepository {

    static let shared = EventRepository()

    private let database: DatabaseManager
    private let photos: PhotoRepository

    init(database: DatabaseManager = .shared, photos: PhotoRepository = .shared) {
        self.database = database
        self.photos = photos
    }

    private var db: OpaquePointer? {
        database.connection
    }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if database.isOnQueue {
            return try work()
        }
        return try database.sync(work)
    }

    // MARK: - App metadata (event attribute options)

    private func getAppMetadata(key: String) -> String? {
        let sql = """
        SELECT value
        FROM app_metadata
        WHERE key = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) == SQLITE_ROW,
               let value = sqliteOptionalText(statement, column: 0) {
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

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    /// Inserts a new top-level event row; returns `eventId`.
    func insertEventRow(
        name: String,
        startDate: String,
        endDate: String,
        latitude: Double?,
        longitude: Double?,
        locationId: Int?,
        clusteredByTimeOnly: Bool = false
    ) -> Int {
        let sql = """
        INSERT INTO events
        (
            name, startDate, endDate, latitude, longitude,
            city, state, placeName, locationId,
            clusteredByTimeOnly,
            isDeleted, deletedAt, updatedAt, photoCount
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, 0);
        """

        let now = ISO8601DateFormatter().string(from: Date())
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (startDate as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (endDate as NSString).utf8String, -1, nil)

            if let latitude {
                sqlite3_bind_double(statement, 4, latitude)
            } else {
                sqlite3_bind_null(statement, 4)
            }

            if let longitude {
                sqlite3_bind_double(statement, 5, longitude)
            } else {
                sqlite3_bind_null(statement, 5)
            }

            sqlite3_bind_null(statement, 6)
            sqlite3_bind_null(statement, 7)
            sqlite3_bind_null(statement, 8)

            if let locationId, locationId > 0 {
                sqlite3_bind_int(statement, 9, Int32(locationId))
            } else {
                sqlite3_bind_null(statement, 9)
            }

            sqlite3_bind_int(statement, 10, clusteredByTimeOnly ? 1 : 0)
            sqlite3_bind_text(statement, 11, (now as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to insert event row: \(String(cString: sqlite3_errmsg(db)))")
            }
        } else {
            print("Failed to prepare insert event: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
        return Int(sqlite3_last_insert_rowid(db))
    }


    // MARK: - Extracted methods

    private struct SlideshowPhotoCandidate {
    let id: String
    let isFavorite: Bool
    let peopleCount: Int
    let qualityScore: Int
    }

    func updateCoverPhotoForEvent(eventId: Int) {
        applyCoverPhotoSelection(
            eventId: eventId,
            photoId: fetchGenericCoverPhotoIdUnsafe(eventId: eventId)
        )
    }

    /// Prefers Vision Bride+Groom photos, then Bride or Groom alone, then generic cover ranking.
    func updateWeddingCoverPhotoForEvent(eventId: Int) {
        sync {
            updateWeddingCoverPhotoForEventUnsafe(eventId: eventId)
        }
    }

    func updateWeddingCoverPhotoForEventUnsafe(eventId: Int) {
        applyCoverPhotoSelection(
            eventId: eventId,
            photoId: fetchWeddingCoverPhotoIdUnsafe(eventId: eventId)
                ?? fetchGenericCoverPhotoIdUnsafe(eventId: eventId)
        )
    }

    private func fetchGenericCoverPhotoIdUnsafe(eventId: Int) -> String? {
        let sql = """
        SELECT p.id
        FROM photos p
        JOIN photo_events pe
            ON p.id = pe.photoId
        WHERE (
            pe.eventId = ?
            OR pe.eventId IN (
                SELECT child.eventId
                FROM events child
                WHERE child.parentEventId = ?
                  AND child.isDeleted = 0
            )
        )
          AND p.isDeleted = 0
          AND COALESCE(p.mediaType, 1) != 2
          AND COALESCE(pe.manuallyExcluded, 0) = 0
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
            sqlite3_bind_int(statement, 2, Int32(eventId))
            if sqlite3_step(statement) == SQLITE_ROW {
                coverPhotoId = String(cString: sqlite3_column_text(statement, 0))
            }
        }

        sqlite3_finalize(statement)
        return coverPhotoId
    }

    private func fetchWeddingCoverPhotoIdUnsafe(eventId: Int) -> String? {
        let sql = """
        SELECT
            p.id,
            CASE
                WHEN bride.photoId IS NOT NULL AND groom.photoId IS NOT NULL THEN 2
                WHEN bride.photoId IS NOT NULL OR groom.photoId IS NOT NULL THEN 1
                ELSE 0
            END AS weddingTier,
            COALESCE(bride.confidence, 0) + COALESCE(groom.confidence, 0) AS tagScore
        FROM photos p
        JOIN photo_events pe
            ON p.id = pe.photoId
        LEFT JOIN photo_object_tags bride
            ON bride.photoId = p.id
           AND LOWER(bride.objectKey) = 'bride'
        LEFT JOIN photo_object_tags groom
            ON groom.photoId = p.id
           AND LOWER(groom.objectKey) = 'groom'
        WHERE (
            pe.eventId = ?
            OR pe.eventId IN (
                SELECT child.eventId
                FROM events child
                WHERE child.parentEventId = ?
                  AND child.isDeleted = 0
            )
        )
          AND p.isDeleted = 0
          AND COALESCE(p.mediaType, 1) != 2
          AND COALESCE(pe.manuallyExcluded, 0) = 0
        ORDER BY
            weddingTier DESC,
            tagScore DESC,
            p.isFavorite DESC,
            p.qualityScore DESC,
            p.creationDate DESC
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var coverPhotoId: String?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_int(statement, 2, Int32(eventId))
            if sqlite3_step(statement) == SQLITE_ROW {
                coverPhotoId = String(cString: sqlite3_column_text(statement, 0))
            }
        }

        sqlite3_finalize(statement)
        return coverPhotoId
    }

    private func applyCoverPhotoSelection(eventId: Int, photoId: String?) {
        guard let coverPhotoId = photoId else {
            clearCoverPhotoForEvent(eventId: eventId)
            return
        }

        let updateSQL = """
        UPDATE events
        SET coverPhotoId = ?
        WHERE eventId = ?;
        """

        var statement: OpaquePointer?
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


    func clearCoverPhotoForEvent(eventId: Int) {
    let updateSQL = """
    UPDATE events
    SET coverPhotoId = NULL
    WHERE eventId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, updateSQL, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(eventId))
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)
    }


    func updateAllEventCoverPhotos() {
    sync {
        updateAllEventCoverPhotosUnsafe()
    }
    }


    func updateAllEventCoverPhotosUnsafe() {

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

            updateCoverPhotoForEvent(eventId: eventId)
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


    struct EventPersonRecord: Sendable, Equatable {
        let personId: Int
        let name: String
        let photoCount: Int
    }

    func fetchEventPeople(eventId: Int, includeChildEvents: Bool) -> [EventPersonRecord] {
        sync {
            fetchEventPeopleUnsafe(eventId: eventId, includeChildEvents: includeChildEvents)
        }
    }

    func fetchEventPeopleUnsafe(eventId: Int, includeChildEvents: Bool) -> [EventPersonRecord] {
        // On-demand from photo_people (no denormalized event_people table).
        let eventScopeSQL: String
        if includeChildEvents {
            eventScopeSQL = """
            (
                pev.eventId = ?
                OR pev.eventId IN (
                    SELECT child.eventId
                    FROM events child
                    WHERE child.parentEventId = ?
                      AND child.isDeleted = 0
                )
            )
            """
        } else {
            eventScopeSQL = "pev.eventId = ?"
        }

        let sql = """
        SELECT pp.personId, p.displayName, COUNT(DISTINCT pp.photoId) AS photoCount
        FROM photo_events pev
        JOIN photos ph
            ON ph.id = pev.photoId
           AND ph.isDeleted = 0
        JOIN photo_people pp
            ON pp.photoId = pev.photoId
        JOIN people p
            ON p.personId = pp.personId
        WHERE \(eventScopeSQL)
          AND TRIM(COALESCE(p.displayName, '')) != ''
        GROUP BY pp.personId, p.displayName
        ORDER BY photoCount DESC, p.displayName COLLATE NOCASE ASC;
        """

        var statement: OpaquePointer?
        var records: [EventPersonRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if includeChildEvents {
                sqlite3_bind_int(statement, 2, Int32(eventId))
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = sqliteOptionalText(statement, column: 1) else { continue }
                records.append(
                    EventPersonRecord(
                        personId: Int(sqlite3_column_int(statement, 0)),
                        name: name,
                        photoCount: Int(sqlite3_column_int(statement, 2))
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return records
    }


    func setEventShowOnFrame(eventId: Int, show: Bool) {
    let now = ISO8601DateFormatter().string(from: Date())

    let sql = """
    UPDATE events
    SET showAsSlideshowEvent = ?,
        updatedAt = ?
    WHERE eventId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, show ? 1 : 0)
        sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 3, Int32(eventId))
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)
    }


    func setEventFavorite(eventId: Int, isFavorite: Bool) {
    let now = ISO8601DateFormatter().string(from: Date())

    let sql = """
    UPDATE events
    SET isFavorite = ?,
        updatedAt = ?
    WHERE eventId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
        sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 3, Int32(eventId))
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)
    }


    /// Parent list-event ids that have at least one photo marked on frame (includeInSlideshow),
    /// including photos attached to trip child days.
    func listEventIdsWithOnFramePhotos(among eventIds: [Int]) -> Set<Int> {
        let unique = Array(Set(eventIds.filter { $0 > 0 }))
        guard !unique.isEmpty else { return [] }

        var result = Set<Int>()
        let chunkSize = 400
        for chunkStart in stride(from: 0, to: unique.count, by: chunkSize) {
            let chunk = Array(unique[chunkStart..<min(chunkStart + chunkSize, unique.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let sql = """
            SELECT DISTINCT listEventId FROM (
                SELECT e.eventId AS listEventId
                FROM events e
                JOIN photo_events pe ON pe.eventId = e.eventId
                JOIN photos p ON p.id = pe.photoId
                WHERE e.eventId IN (\(placeholders))
                  AND e.isDeleted = 0
                  AND p.isDeleted = 0
                  AND COALESCE(pe.includeInSlideshow, 0) = 1
                UNION
                SELECT e.parentEventId AS listEventId
                FROM events e
                JOIN photo_events pe ON pe.eventId = e.eventId
                JOIN photos p ON p.id = pe.photoId
                WHERE e.parentEventId IN (\(placeholders))
                  AND e.isDeleted = 0
                  AND p.isDeleted = 0
                  AND COALESCE(pe.includeInSlideshow, 0) = 1
            );
            """

            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                for (index, eventId) in chunk.enumerated() {
                    sqlite3_bind_int(statement, Int32(index + 1), Int32(eventId))
                    sqlite3_bind_int(statement, Int32(chunk.count + index + 1), Int32(eventId))
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    result.insert(Int(sqlite3_column_int(statement, 0)))
                }
            }
            sqlite3_finalize(statement)
        }
        return result
    }


    func setEventUserHidden(eventId: Int, hidden: Bool) {
    let now = ISO8601DateFormatter().string(from: Date())

    let sql = """
    UPDATE events
    SET isUserHidden = ?,
        updatedAt = ?
    WHERE eventId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, hidden ? 1 : 0)
        sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 3, Int32(eventId))
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)
    }


    func getEventAttributeOptions(for field: EventAttributeField) -> [String] {
    var options = Set(field.builtInOptions)

    if let metadataKey = field.customOptionsMetadataKey,
       let custom = getAppMetadata(key: metadataKey),
       !custom.isEmpty {
        for type in custom.split(separator: ",") {
            let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                options.insert(trimmed)
            }
        }
    }

    let sql = """
    SELECT DISTINCT tagValue
    FROM event_tags
    WHERE isRejected = 0
      AND tagCategory = ?
      AND TRIM(tagValue) != '';
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, (field.tagCategory as NSString).utf8String, -1, nil)
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqliteOptionalText(statement, column: 0) {
                options.insert(value)
            }
        }
    }

    sqlite3_finalize(statement)

    // Main-person options also include the secondary category / multi-value rows.
    if field == .mainPerson {
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(
                statement,
                1,
                (EventAttributeField.secondaryMainPerson.tagCategory as NSString).utf8String,
                -1,
                nil
            )
            while sqlite3_step(statement) == SQLITE_ROW {
                if let value = sqliteOptionalText(statement, column: 0) {
                    options.insert(value)
                }
            }
        }
        sqlite3_finalize(statement)
    }

    if field == .eventType {
        options = Set(
            options.filter { $0.localizedCaseInsensitiveCompare("Trip") != .orderedSame }
        )
    }

    if field == .tripType {
        return []
    }

    return options.sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
    }


    func migrateLegacyTripEventTypeAttribute() {
    let now = ISO8601DateFormatter().string(from: Date())

    // Clear pre-archive column if it still exists.
    if let db,
       SQLiteMigrations.columnExists(table: "events", column: "eventType", on: db) {
        let clearSQL = """
        UPDATE events
        SET eventType = NULL,
            updatedAt = ?
        WHERE isDeleted = 0
          AND LOWER(TRIM(COALESCE(eventType, ''))) = 'trip';
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, clearSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    guard let custom = getAppMetadata(key: "customEventTypes"),
          !custom.isEmpty else {
        return
    }

    let filtered = custom
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && $0.localizedCaseInsensitiveCompare("Trip") != .orderedSame }

    setAppMetadata(key: "customEventTypes", value: filtered.joined(separator: ","))
    }


    func addCustomEventAttributeOption(_ value: String, for field: EventAttributeField) {
    guard field.allowsCustomOptions else { return }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if field == .eventType,
       trimmed.localizedCaseInsensitiveCompare("Trip") == .orderedSame {
        return
    }

    var options = Set(getEventAttributeOptions(for: field))
    options.insert(trimmed)

    let customOnly = options
        .subtracting(field.builtInOptions)
        .sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

    guard let metadataKey = field.customOptionsMetadataKey else { return }

    setAppMetadata(
        key: metadataKey,
        value: customOnly.joined(separator: ",")
    )
    }


    func updateEventAttribute(
    eventId: Int,
    field: EventAttributeField,
    value: String?
    ) {
    // Classification is stored only in `event_tags` (see EventTagRepository).
    // Touch updatedAt so list caches refresh.
    _ = field
    _ = value
    let now = ISO8601DateFormatter().string(from: Date())
    let sql = """
    UPDATE events
    SET updatedAt = ?
    WHERE eventId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(eventId))

        if sqlite3_step(statement) != SQLITE_DONE {
            print("Failed to touch event updatedAt: \(String(cString: sqlite3_errmsg(db)))")
        }
    } else {
        print("Failed to prepare touch event updatedAt: \(String(cString: sqlite3_errmsg(db)))")
    }

    sqlite3_finalize(statement)
    }

    struct AnniversaryCandidateEvent: Sendable {
        let eventId: Int
        let startDate: String
    }

    func fetchAnniversaryCandidateEventsUnsafe(
        weddingDateISO: String,
        excludingEventId: Int
    ) -> [AnniversaryCandidateEvent] {
        let sql = """
        SELECT eventId, startDate
        FROM events
        WHERE isDeleted = 0
          AND eventId != ?
          AND startDate >= ?
        ORDER BY startDate ASC;
        """

        var statement: OpaquePointer?
        var candidates: [AnniversaryCandidateEvent] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(excludingEventId))
            sqlite3_bind_text(statement, 2, (weddingDateISO as NSString).utf8String, -1, nil)

            while sqlite3_step(statement) == SQLITE_ROW {
                let eventId = Int(sqlite3_column_int(statement, 0))
                let startDate = sqliteOptionalText(statement, column: 1) ?? ""
                candidates.append(
                    AnniversaryCandidateEvent(eventId: eventId, startDate: startDate)
                )
            }
        }

        sqlite3_finalize(statement)
        return candidates
    }

    func updateWeddingDate(eventId: Int, weddingDate: String?) {
        let trimmed = weddingDate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedValue = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        UPDATE events
        SET weddingDate = ?,
            updatedAt = ?
        WHERE eventId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindOptionalText(storedValue, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(eventId))

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to update weddingDate: \(String(cString: sqlite3_errmsg(db)))")
            }
        } else {
            print("Failed to prepare update weddingDate: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
    }


    func getEventsForLocation(locationId: Int) -> [IndexedEvent] {
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
        COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 AND COALESCE(ph.mediaType, 1) != 2 THEN pe.photoId END) as photoCount,
        GROUP_CONCAT(DISTINCT p.displayName) as peopleNames,
        e.showAsSlideshowEvent,
        e.userEditedName,
        l.nickname as locationNickname,
        e.locationId,
        e.parentEventId,
        e.isTripEvent,
        e.weddingDate,
        e.childEventName,
        COALESCE(e.userEditedChildEventName, 0) as userEditedChildEventName,
        COALESCE(e.isUserHidden, 0) as isUserHidden,
        COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 AND COALESCE(ph.mediaType, 1) = 2 THEN pe.photoId END) as videoCount,
        COALESCE(e.isFavorite, 0) as isFavorite
    FROM events e
    LEFT JOIN locations l
        ON e.locationId = l.locationId
    LEFT JOIN photo_events pe
        ON e.eventId = pe.eventId
    LEFT JOIN photos ph
        ON pe.photoId = ph.id
    LEFT JOIN photo_people pp
        ON pp.photoId = pe.photoId
       AND COALESCE(ph.isDeleted, 0) = 0
    LEFT JOIN people p
        ON p.personId = pp.personId
    WHERE e.isDeleted = 0
      AND COALESCE(e.isUserHidden, 0) = 0
      AND e.parentEventId IS NULL
      AND e.locationId = ?
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
        e.coverPhotoId,
        e.showAsSlideshowEvent,
        e.userEditedName,
        l.nickname,
        e.locationId,
        e.parentEventId,
        e.isTripEvent,
        e.weddingDate,
        e.childEventName,
        e.userEditedChildEventName,
        e.isUserHidden,
        e.isFavorite
    ORDER BY e.startDate DESC;
    """

    var statement: OpaquePointer?
    var events: [IndexedEvent] = []

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(locationId))

        while sqlite3_step(statement) == SQLITE_ROW {
            events.append(parseIndexedEvent(from: statement))
        }
    } else {
        print("Failed to get events for location: \(String(cString: sqlite3_errmsg(db)))")
    }

    sqlite3_finalize(statement)
    return events
    }

    @discardableResult

    func updateEventName(eventId: Int, name: String, userEdited: Bool) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    let now = ISO8601DateFormatter().string(from: Date())
    let nameNSString = trimmed as NSString
    let nowNSString = now as NSString

    let sql = """
    UPDATE events
    SET name = ?,
        userEditedName = ?,
        updatedAt = ?
    WHERE eventId = ?;
    """

    var statement: OpaquePointer?
    var success = false

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, nameNSString.utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, userEdited ? 1 : 0)
        sqlite3_bind_text(statement, 3, nowNSString.utf8String, -1, nil)
        sqlite3_bind_int(statement, 4, Int32(eventId))

        if sqlite3_step(statement) == SQLITE_DONE {
            success = true
        } else {
            print("Failed to update event name: \(String(cString: sqlite3_errmsg(db)))")
        }
    } else {
        print("Failed to prepare update event name: \(String(cString: sqlite3_errmsg(db)))")
    }

    sqlite3_finalize(statement)
    return success
    }

    @discardableResult

    func updateChildEventName(eventId: Int, name: String, userEdited: Bool) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    let now = ISO8601DateFormatter().string(from: Date())
    let sql = """
    UPDATE events
    SET childEventName = ?,
        userEditedChildEventName = ?,
        updatedAt = ?
    WHERE eventId = ?
      AND parentEventId IS NOT NULL;
    """

    var statement: OpaquePointer?
    var success = false

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, (trimmed as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, userEdited ? 1 : 0)
        sqlite3_bind_text(statement, 3, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 4, Int32(eventId))

        if sqlite3_step(statement) == SQLITE_DONE {
            success = true
        } else {
            print("Failed to update child event name: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    sqlite3_finalize(statement)
    return success
    }


    func syncDefaultChildEventName(forSubEventId eventId: Int) {
    guard let event = getEvent(eventId: eventId), event.isTripSubEvent else { return }
    guard !event.userEditedChildEventName else { return }

    updateChildEventName(
        eventId: eventId,
        name: event.defaultChildEventName,
        userEdited: false
    )
    }


    func migrateTripSubEventChildNamesIfNeeded() {
    let sql = """
    SELECT eventId
    FROM events
    WHERE isDeleted = 0
      AND parentEventId IS NOT NULL
      AND (childEventName IS NULL OR TRIM(childEventName) = '');
    """

    var statement: OpaquePointer?
    var eventIds: [Int] = []

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
            eventIds.append(Int(sqlite3_column_int(statement, 0)))
        }
    }

    sqlite3_finalize(statement)

    for eventId in eventIds {
        syncDefaultChildEventName(forSubEventId: eventId)
    }
    }


    func getEvents(includeHidden: Bool = false) -> [IndexedEvent] {
    sync {
        getEventsUnsafe(includeHidden: includeHidden, forList: false, limit: nil)
    }
    }

    /// Lighter list query (no people join). Use for the scrolling events library.
    func getEventsForList(
        includeHidden: Bool = false,
        limit: Int? = nil,
        filter: EventListFilter = .allEvents
    ) -> [IndexedEvent] {
        sync {
            getEventsUnsafe(
                includeHidden: includeHidden,
                forList: true,
                limit: limit,
                filter: filter
            )
        }
    }

    func countListEvents(
        includeHidden: Bool = false,
        filter: EventListFilter = .allEvents
    ) -> Int {
        sync {
            countListEventsUnsafe(includeHidden: includeHidden, filter: filter)
        }
    }

    func countOnFramePhotosForHolidayTag(
        tagValue: String,
        includeHidden: Bool = false
    ) -> Int {
        sync {
            countOnFramePhotosForHolidayTagUnsafe(
                tagValue: tagValue,
                includeHidden: includeHidden
            )
        }
    }

    func fetchOnFramePhotoIdsForListEventUnsafe(listEventId: Int) -> [String] {
        guard listEventId > 0 else { return [] }

        let sql = """
        SELECT DISTINCT p.id
        FROM events e
        LEFT JOIN photo_events pe
            ON e.eventId = pe.eventId
            OR pe.eventId IN (
                SELECT child.eventId
                FROM events child
                WHERE child.parentEventId = e.eventId
                  AND child.isDeleted = 0
            )
        JOIN photos p
            ON pe.photoId = p.id
        WHERE e.eventId = ?
          AND e.isDeleted = 0
          AND COALESCE(e.isUserHidden, 0) = 0
          AND p.isDeleted = 0
          AND COALESCE(pe.includeInSlideshow, 0) = 1
        ORDER BY p.creationDate DESC, p.id ASC;
        """

        var statement: OpaquePointer?
        var photoIds: [String] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(listEventId))
            while sqlite3_step(statement) == SQLITE_ROW {
                photoIds.append(String(cString: sqlite3_column_text(statement, 0)))
            }
        }

        sqlite3_finalize(statement)
        return photoIds
    }

    func fetchOnFramePhotoIdsForHolidayTagUnsafe(
        tagValue: String,
        includeHidden: Bool = false
    ) -> [String] {
        let filter = EventListFilter.holidayTag(value: tagValue)
        let hiddenFilter = includeHidden
            ? "AND COALESCE(e.isUserHidden, 0) = 1"
            : "AND COALESCE(e.isUserHidden, 0) = 0"
        let listFilter = listFilterWhereSQL(filter: filter)
        let scopeFilter = listScopeFilterSQL(filter: filter)
        let sql = """
        SELECT DISTINCT p.id
        FROM events e
        LEFT JOIN photo_events pe
            ON e.eventId = pe.eventId
            OR pe.eventId IN (
                SELECT child.eventId
                FROM events child
                WHERE child.parentEventId = e.eventId
                  AND child.isDeleted = 0
            )
        JOIN photos p
            ON pe.photoId = p.id
        WHERE e.isDeleted = 0
          \(hiddenFilter)
          \(scopeFilter)
          \(listFilter)
          AND p.isDeleted = 0
          AND COALESCE(pe.includeInSlideshow, 0) = 1
        ORDER BY p.creationDate DESC, p.id ASC;
        """

        var statement: OpaquePointer?
        var photoIds: [String] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                photoIds.append(String(cString: sqlite3_column_text(statement, 0)))
            }
        } else if let db {
            print(
                "Failed to fetch on-frame photos for holiday tag:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }

        sqlite3_finalize(statement)
        return photoIds
    }

    func countOnFramePhotosForHolidayTagUnsafe(
        tagValue: String,
        includeHidden: Bool = false
    ) -> Int {
        let filter = EventListFilter.holidayTag(value: tagValue)
        let hiddenFilter = includeHidden
            ? "AND COALESCE(e.isUserHidden, 0) = 1"
            : "AND COALESCE(e.isUserHidden, 0) = 0"
        let listFilter = listFilterWhereSQL(filter: filter)
        let scopeFilter = listScopeFilterSQL(filter: filter)
        let sql = """
        SELECT COUNT(DISTINCT p.id)
        FROM events e
        LEFT JOIN photo_events pe
            ON e.eventId = pe.eventId
            OR pe.eventId IN (
                SELECT child.eventId
                FROM events child
                WHERE child.parentEventId = e.eventId
                  AND child.isDeleted = 0
            )
        JOIN photos p
            ON pe.photoId = p.id
        WHERE e.isDeleted = 0
          \(hiddenFilter)
          \(scopeFilter)
          \(listFilter)
          AND p.isDeleted = 0
          AND COALESCE(pe.includeInSlideshow, 0) = 1;
        """

        var statement: OpaquePointer?
        var count = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = Int(sqlite3_column_int(statement, 0))
        } else if let db {
            print(
                "Failed to count on-frame photos for holiday tag:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }

        sqlite3_finalize(statement)
        return count
    }

    func holidayTagCollectionCounts(includeHidden: Bool = false) -> [String: Int] {
        sync { holidayTagCollectionCountsUnsafe(includeHidden: includeHidden) }
    }

    func holidayTagOnFramePhotoCounts(includeHidden: Bool = false) -> [String: Int] {
        sync { holidayTagOnFramePhotoCountsUnsafe(includeHidden: includeHidden) }
    }

    func holidayTagCollectionCountsUnsafe(includeHidden: Bool = false) -> [String: Int] {
        let hiddenFilter = includeHidden
            ? "AND COALESCE(parent.isUserHidden, 0) = 1"
            : "AND COALESCE(parent.isUserHidden, 0) = 0"
        let sql = """
        SELECT ht.tagValue, COUNT(DISTINCT parent.eventId)
        FROM event_tags ht
        JOIN events tagged
            ON tagged.eventId = ht.eventId
           AND tagged.isDeleted = 0
        JOIN events parent
            ON parent.eventId = COALESCE(tagged.parentEventId, tagged.eventId)
           AND parent.parentEventId IS NULL
           AND parent.isDeleted = 0
        WHERE ht.tagCategory = 'holiday'
          AND ht.isRejected = 0
          \(hiddenFilter)
          AND EXISTS (
              SELECT 1
              FROM photo_events pe
              JOIN photos p ON pe.photoId = p.id AND p.isDeleted = 0
              WHERE pe.eventId = parent.eventId
                 OR pe.eventId IN (
                     SELECT child.eventId
                     FROM events child
                     WHERE child.parentEventId = parent.eventId
                       AND child.isDeleted = 0
                 )
          )
        GROUP BY ht.tagValue;
        """

        return readHolidayTagCountMap(sql: sql)
    }

    func holidayTagOnFramePhotoCountsUnsafe(includeHidden: Bool = false) -> [String: Int] {
        let hiddenFilter = includeHidden
            ? "AND COALESCE(parent.isUserHidden, 0) = 1"
            : "AND COALESCE(parent.isUserHidden, 0) = 0"
        let sql = """
        SELECT ht.tagValue, COUNT(DISTINCT p.id)
        FROM event_tags ht
        JOIN events tagged
            ON tagged.eventId = ht.eventId
           AND tagged.isDeleted = 0
        JOIN events parent
            ON parent.eventId = COALESCE(tagged.parentEventId, tagged.eventId)
           AND parent.parentEventId IS NULL
           AND parent.isDeleted = 0
        JOIN photo_events pe
            ON pe.eventId = parent.eventId
            OR pe.eventId IN (
                SELECT child.eventId
                FROM events child
                WHERE child.parentEventId = parent.eventId
                  AND child.isDeleted = 0
            )
        JOIN photos p
            ON pe.photoId = p.id
        WHERE ht.tagCategory = 'holiday'
          AND ht.isRejected = 0
          \(hiddenFilter)
          AND p.isDeleted = 0
          AND COALESCE(pe.includeInSlideshow, 0) = 1
        GROUP BY ht.tagValue;
        """

        return readHolidayTagCountMap(sql: sql)
    }

    private func readHolidayTagCountMap(sql: String) -> [String: Int] {
        var statement: OpaquePointer?
        var counts: [String: Int] = [:]

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let tagValue = sqliteOptionalText(statement, column: 0) else { continue }
                counts[tagValue] = Int(sqlite3_column_int(statement, 1))
            }
        } else if let db {
            print(
                "Failed to read holiday tag counts:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }

        sqlite3_finalize(statement)
        return counts
    }

    func resolveListEventIdUnsafe(eventId: Int) -> Int {
        let sql = """
        SELECT COALESCE(parentEventId, eventId)
        FROM events
        WHERE eventId = ?
          AND isDeleted = 0
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var listEventId = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if sqlite3_step(statement) == SQLITE_ROW {
                listEventId = Int(sqlite3_column_int(statement, 0))
            }
        }

        sqlite3_finalize(statement)
        return listEventId
    }

    func listEventQualifiesForFilterUnsafe(
        listEventId: Int,
        filter: EventListFilter,
        includeHidden: Bool = false
    ) -> Bool {
        guard listEventId > 0 else { return false }

        let hiddenFilter = includeHidden
            ? "AND COALESCE(e.isUserHidden, 0) = 1"
            : "AND COALESCE(e.isUserHidden, 0) = 0"
        let listFilter = listFilterWhereSQL(filter: filter)
        let sql = """
        SELECT 1
        FROM events e
        WHERE e.eventId = ?
          AND e.isDeleted = 0
          AND e.parentEventId IS NULL
          \(hiddenFilter)
          \(listFilter)
          AND EXISTS (
              SELECT 1
              FROM photo_events pe
              JOIN photos ph ON ph.id = pe.photoId AND ph.isDeleted = 0
              WHERE pe.eventId = e.eventId
                 OR pe.eventId IN (
                     SELECT child.eventId
                     FROM events child
                     WHERE child.parentEventId = e.eventId
                       AND child.isDeleted = 0
                 )
          )
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var qualifies = false

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(listEventId))
            qualifies = sqlite3_step(statement) == SQLITE_ROW
        }

        sqlite3_finalize(statement)
        return qualifies
    }

    func fetchListEventIdsForFilterUnsafe(
        filter: EventListFilter,
        includeHidden: Bool = false
    ) -> [Int] {
        let hiddenFilter = includeHidden
            ? "AND COALESCE(e.isUserHidden, 0) = 1"
            : "AND COALESCE(e.isUserHidden, 0) = 0"
        let listFilter = listFilterWhereSQL(filter: filter)
        let sql = """
        SELECT e.eventId
        FROM events e
        WHERE e.isDeleted = 0
          AND e.parentEventId IS NULL
          \(hiddenFilter)
          \(listFilter)
          AND EXISTS (
              SELECT 1
              FROM photo_events pe
              JOIN photos ph ON ph.id = pe.photoId AND ph.isDeleted = 0
              WHERE pe.eventId = e.eventId
                 OR pe.eventId IN (
                     SELECT child.eventId
                     FROM events child
                     WHERE child.parentEventId = e.eventId
                       AND child.isDeleted = 0
                 )
          )
        ORDER BY e.startDate DESC, e.eventId ASC;
        """

        var statement: OpaquePointer?
        var eventIds: [Int] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                eventIds.append(Int(sqlite3_column_int(statement, 0)))
            }
        }

        sqlite3_finalize(statement)
        return eventIds
    }

    func countBirthdayPersonEventsUnsafe(
        personId: Int,
        includeHidden: Bool = false
    ) -> Int {
        countListEventsUnsafe(
            includeHidden: includeHidden,
            filter: .birthdayPerson(personId: personId, displayName: "")
        )
    }

    func countListEventsUnsafe(
        includeHidden: Bool,
        filter: EventListFilter = .allEvents
    ) -> Int {
        let hiddenFilter = includeHidden
            ? "AND COALESCE(e.isUserHidden, 0) = 1"
            : "AND COALESCE(e.isUserHidden, 0) = 0"
        let listFilter = listFilterWhereSQL(filter: filter)
        let scopeFilter = listScopeFilterSQL(filter: filter)
        let sql = """
        SELECT COUNT(*) FROM (
            SELECT e.eventId
            FROM events e
            LEFT JOIN photo_events pe
                ON e.eventId = pe.eventId
                OR pe.eventId IN (
                    SELECT child.eventId
                    FROM events child
                    WHERE child.parentEventId = e.eventId
                      AND child.isDeleted = 0
                )
            LEFT JOIN photos ph
                ON pe.photoId = ph.id
            WHERE e.isDeleted = 0
              \(hiddenFilter)
              \(scopeFilter)
              \(listFilter)
            GROUP BY e.eventId
            HAVING COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 THEN pe.photoId END) > 0
        );
        """

        var statement: OpaquePointer?
        var count = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = Int(sqlite3_column_int(statement, 0))
        } else if let db {
            print("Failed to count events: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
        return count
    }


    func getEventsUnsafe(
        includeHidden: Bool,
        forList: Bool,
        limit: Int? = nil,
        filter: EventListFilter = .allEvents
    ) -> [IndexedEvent] {
        let hiddenFilter = includeHidden
            ? "AND COALESCE(e.isUserHidden, 0) = 1"
            : "AND COALESCE(e.isUserHidden, 0) = 0"
        let listFilter = listFilterWhereSQL(filter: filter)
        let scopeFilter = listScopeFilterSQL(filter: filter)
        let peopleSelect = forList
            ? "NULL as peopleNames"
            : "GROUP_CONCAT(DISTINCT p.displayName) as peopleNames"
        let peopleJoins = forList
            ? ""
            : """
            LEFT JOIN photo_people pp
                ON pp.photoId = pe.photoId
               AND COALESCE(ph.isDeleted, 0) = 0
            LEFT JOIN people p
                ON p.personId = pp.personId
            """
        var sql = """
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
        COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 AND COALESCE(ph.mediaType, 1) != 2 THEN pe.photoId END) as photoCount,
        \(peopleSelect),
        e.showAsSlideshowEvent,
        e.userEditedName,
        l.nickname as locationNickname,
        e.locationId,
        e.parentEventId,
        e.isTripEvent,
        e.weddingDate,
        e.childEventName,
        COALESCE(e.userEditedChildEventName, 0) as userEditedChildEventName,
        COALESCE(e.isUserHidden, 0) as isUserHidden,
        COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 AND COALESCE(ph.mediaType, 1) = 2 THEN pe.photoId END) as videoCount,
        COALESCE(e.isFavorite, 0) as isFavorite
    FROM events e
    LEFT JOIN locations l
        ON e.locationId = l.locationId
    LEFT JOIN photo_events pe
        ON e.eventId = pe.eventId
        OR pe.eventId IN (
            SELECT child.eventId
            FROM events child
            WHERE child.parentEventId = e.eventId
              AND child.isDeleted = 0
        )
    LEFT JOIN photos ph
        ON pe.photoId = ph.id
    \(peopleJoins)
    WHERE e.isDeleted = 0
      \(hiddenFilter)
      \(scopeFilter)
      \(listFilter)
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
        e.coverPhotoId,
        e.showAsSlideshowEvent,
        e.userEditedName,
        l.nickname,
        e.locationId,
        e.parentEventId,
        e.isTripEvent,
        e.weddingDate,
        e.childEventName,
        e.userEditedChildEventName,
        e.isUserHidden,
        e.isFavorite
    HAVING COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 THEN pe.photoId END) > 0
    ORDER BY e.startDate DESC
    """

        if limit != nil {
            sql += "\nLIMIT ?;"
        } else {
            sql += ";"
        }

    var statement: OpaquePointer?
    var events: [IndexedEvent] = []

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        if let limit {
            sqlite3_bind_int(statement, 1, Int32(limit))
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            events.append(parseIndexedEvent(from: statement))
        }
    } else {
        print("Failed to get events: \(String(cString: sqlite3_errmsg(db)))")
    }

    sqlite3_finalize(statement)
    return events
    }


    func getEvent(eventId: Int) -> IndexedEvent? {
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
        COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 AND COALESCE(ph.mediaType, 1) != 2 THEN pe.photoId END) as photoCount,
        GROUP_CONCAT(DISTINCT p.displayName) as peopleNames,
        e.showAsSlideshowEvent,
        e.userEditedName,
        l.nickname as locationNickname,
        e.locationId,
        e.parentEventId,
        e.isTripEvent,
        e.weddingDate,
        e.childEventName,
        COALESCE(e.userEditedChildEventName, 0) as userEditedChildEventName,
        COALESCE(e.isUserHidden, 0) as isUserHidden,
        COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 AND COALESCE(ph.mediaType, 1) = 2 THEN pe.photoId END) as videoCount,
        COALESCE(e.isFavorite, 0) as isFavorite
    FROM events e
    LEFT JOIN locations l
        ON e.locationId = l.locationId
    LEFT JOIN photo_events pe
        ON e.eventId = pe.eventId
        OR pe.eventId IN (
            SELECT child.eventId
            FROM events child
            WHERE child.parentEventId = e.eventId
              AND child.isDeleted = 0
        )
    LEFT JOIN photos ph
        ON pe.photoId = ph.id
    LEFT JOIN photo_people pp
        ON pp.photoId = pe.photoId
       AND COALESCE(ph.isDeleted, 0) = 0
    LEFT JOIN people p
        ON p.personId = pp.personId
    WHERE e.isDeleted = 0
      AND e.eventId = ?
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
        e.coverPhotoId,
        e.showAsSlideshowEvent,
        e.userEditedName,
        l.nickname,
        e.locationId,
        e.parentEventId,
        e.isTripEvent,
        e.weddingDate,
        e.childEventName,
        e.userEditedChildEventName,
        e.isUserHidden,
        e.isFavorite;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(eventId))

        if sqlite3_step(statement) == SQLITE_ROW {
            let event = parseIndexedEvent(from: statement)
            sqlite3_finalize(statement)
            return event
        }
    } else {
        print("Failed to get event: \(String(cString: sqlite3_errmsg(db)))")
    }

    sqlite3_finalize(statement)
    return nil
    }


    func sqliteOptionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
          let cString = sqlite3_column_text(statement, column) else {
        return nil
    }
    return String(cString: cString)
    }


    func parseIndexedEvent(from statement: OpaquePointer?) -> IndexedEvent {
    let eventId = Int(sqlite3_column_int(statement, 0))
    let name = sqliteOptionalText(statement, column: 1) ?? ""
    let startDate = sqliteOptionalText(statement, column: 2) ?? ""
    let endDate = sqliteOptionalText(statement, column: 3) ?? startDate

    let latitude: Double? =
        sqlite3_column_type(statement, 4) == SQLITE_NULL
        ? nil
        : sqlite3_column_double(statement, 4)

    let longitude: Double? =
        sqlite3_column_type(statement, 5) == SQLITE_NULL
        ? nil
        : sqlite3_column_double(statement, 5)

    let city = sqliteOptionalText(statement, column: 6)
    let state = sqliteOptionalText(statement, column: 7)
    let placeName = sqliteOptionalText(statement, column: 8)
    let coverPhotoId = sqliteOptionalText(statement, column: 9)

    let photoCount = Int(sqlite3_column_int(statement, 10))

    let people: [String]
    if let peopleString = sqliteOptionalText(statement, column: 11) {
        people = peopleString
            .split(separator: ",")
            .map { String($0) }
    } else {
        people = []
    }

    let showOnFrame = sqlite3_column_int(statement, 12) == 1
    let userEditedName = sqlite3_column_int(statement, 13) == 1

    let locationNickname = sqliteOptionalText(statement, column: 14)

    let locationId: Int? =
        sqlite3_column_type(statement, 15) == SQLITE_NULL
        ? nil
        : Int(sqlite3_column_int(statement, 15))

    let parentEventId: Int? =
        sqlite3_column_type(statement, 16) == SQLITE_NULL
        ? nil
        : Int(sqlite3_column_int(statement, 16))

    let isTripEvent = sqlite3_column_int(statement, 17) == 1

    let weddingDate = sqliteOptionalText(statement, column: 18)
    let childEventName = sqliteOptionalText(statement, column: 19)
    let userEditedChildEventName = sqlite3_column_int(statement, 20) == 1
    let isUserHidden = sqlite3_column_int(statement, 21) == 1
    let videoCount = Int(sqlite3_column_int(statement, 22))
    let isFavorite = sqlite3_column_int(statement, 23) == 1

    return IndexedEvent(
        eventId: eventId,
        name: name,
        startDate: startDate,
        endDate: endDate,
        photoCount: photoCount,
        videoCount: videoCount,
        latitude: latitude,
        longitude: longitude,
        city: city,
        state: state,
        placeName: placeName,
        people: people,
        coverPhotoId: coverPhotoId,
        showOnFrame: showOnFrame,
        isFavorite: isFavorite,
        userEditedName: userEditedName,
        locationNickname: locationNickname,
        locationId: locationId,
        parentEventId: parentEventId,
        isTripEvent: isTripEvent,
        attributeTags: [],
        weddingDate: weddingDate,
        childEventName: childEventName,
        userEditedChildEventName: userEditedChildEventName,
        isUserHidden: isUserHidden
    )
    }


    func getSlideshowPhotoIds(for events: [IndexedEvent]) -> [Int: [String]] {
    sync {
        var slideshowPhotos = getSlideshowPhotoIdsByEvent(
            eventIds: events.map(\.eventId)
        )

        for event in events {
            guard slideshowPhotos[event.eventId]?.isEmpty ?? true else { continue }

            if let coverPhotoId = event.coverPhotoId {
                slideshowPhotos[event.eventId] = [coverPhotoId]
            }
        }

        return slideshowPhotos
    }
    }

    /// SQLite bind limit on iOS is typically 999; chunk `IN` lists to stay safe.
    private static let slideshowEventIdChunkSize = 400

    func getSlideshowPhotoIdsByEvent(eventIds: [Int]) -> [Int: [String]] {
    guard !eventIds.isEmpty else { return [:] }

    var grouped: [Int: [SlideshowPhotoCandidate]] = [:]

    for chunkStart in stride(from: 0, to: eventIds.count, by: Self.slideshowEventIdChunkSize) {
        let chunkEnd = min(chunkStart + Self.slideshowEventIdChunkSize, eventIds.count)
        let chunk = Array(eventIds[chunkStart..<chunkEnd])
        mergeSlideshowCandidates(into: &grouped, eventIds: chunk)
    }

    var slideshowPhotos: [Int: [String]] = [:]
    for eventId in eventIds {
        let candidates = grouped[eventId] ?? []
        let picked = sortedSlideshowPhotoIds(from: candidates)
        if !picked.isEmpty {
            slideshowPhotos[eventId] = picked
        }
    }

    return slideshowPhotos
    }

    private func mergeSlideshowCandidates(
        into grouped: inout [Int: [SlideshowPhotoCandidate]],
        eventIds: [Int]
    ) {
        guard !eventIds.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ", ")
        let sql = """
        SELECT
            COALESCE(e.parentEventId, e.eventId) AS displayEventId,
            p.id,
            p.isFavorite,
            p.qualityScore,
            COUNT(DISTINCT pp.personId) AS peopleCount
        FROM photos p
        JOIN photo_events pe ON p.id = pe.photoId
        JOIN events e ON pe.eventId = e.eventId
        LEFT JOIN photo_people pp ON p.id = pp.photoId
        WHERE p.isDeleted = 0
          AND COALESCE(p.mediaType, 1) != 2
          AND COALESCE(pe.includeInSlideshow, 0) = 1
          AND COALESCE(pe.manuallyExcluded, 0) = 0
          AND e.isDeleted = 0
          AND COALESCE(e.parentEventId, e.eventId) IN (\(placeholders))
        GROUP BY displayEventId, p.id, p.isFavorite, p.qualityScore
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_int(statement, Int32(index + 1), Int32(eventId))
            }

            while sqlite3_step(statement) == SQLITE_ROW {
                let displayEventId = Int(sqlite3_column_int(statement, 0))
                guard let photoId = sqliteOptionalText(statement, column: 1) else { continue }

                let isFavorite = sqlite3_column_int(statement, 2) == 1
                let qualityScore = Int(sqlite3_column_int(statement, 3))
                let peopleCount = Int(sqlite3_column_int(statement, 4))

                grouped[displayEventId, default: []].append(
                    SlideshowPhotoCandidate(
                        id: photoId,
                        isFavorite: isFavorite,
                        peopleCount: peopleCount,
                        qualityScore: qualityScore
                    )
                )
            }
        } else if let db {
            print("Failed to get slideshow photos: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
    }


    private func sortedSlideshowPhotoIds(from candidates: [SlideshowPhotoCandidate]) -> [String] {
    candidates
        .sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite && !rhs.isFavorite
            }
            if lhs.qualityScore != rhs.qualityScore {
                return lhs.qualityScore > rhs.qualityScore
            }
            if lhs.peopleCount != rhs.peopleCount {
                return lhs.peopleCount > rhs.peopleCount
            }
            return lhs.id < rhs.id
        }
        .map(\.id)
    }


    func setPhotoShowOnFrame(photoId: String, eventId: Int, show: Bool) {
        sync {
            setPhotoShowOnFrameUnsafe(photoId: photoId, eventId: eventId, show: show)
        }
    }

    func setPhotoShowOnFrameUnsafe(photoId: String, eventId: Int, show: Bool) {
        let sql = """
        UPDATE photo_events
        SET includeInSlideshow = ?
        WHERE photoId = ?
          AND eventId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, show ? 1 : 0)
            sqlite3_bind_text(statement, 2, (photoId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(eventId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }


    func removePhotoFromEvent(photoId: String, eventId: Int) {
    let deleteSQL = """
    DELETE FROM photo_events
    WHERE photoId = ?
      AND eventId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(eventId))
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)

    let resetSQL = """
    UPDATE photos
    SET eventAssignedAt = NULL,
        eventNeedsReview = 0
    WHERE id = ?;
    """

    if sqlite3_prepare_v2(db, resetSQL, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)

    updateEventSummary(eventId: eventId)
    updateCoverPhotoForEvent(eventId: eventId)
    cleanupEmptyEvents()
    }


    func getPhotosForEvent(eventId: Int, includeHidden: Bool = false) -> [IndexedPhoto] {
    let hiddenFilter = includeHidden
        ? ""
        : "AND COALESCE(pe.manuallyExcluded, 0) = 0"
    let sql = """
    SELECT p.id, p.creationDate, p.isFavorite, p.width, p.height,
           p.mediaSubtype, p.latitude, p.longitude, p.isScreenshot,
           p.aspectRatio, p.orientation, p.qualityScore,
           p.faceEyesOpenScore, p.faceSmileScore,
           COALESCE(pe.includeInSlideshow, 0) as showOnFrame,
           COALESCE(pe.manuallyExcluded, 0) as manuallyExcluded,
           COALESCE(pe.isSimilarGroupPick, 0) as isSimilarGroupPick,
           COALESCE(p.mediaType, 1) as mediaType
    FROM photos p
    JOIN photo_events pe ON p.id = pe.photoId
    WHERE (
        pe.eventId = ?
        OR pe.eventId IN (
            SELECT child.eventId
            FROM events child
            WHERE child.parentEventId = ?
              AND child.isDeleted = 0
        )
    )
      AND p.isDeleted = 0
      \(hiddenFilter)
    ORDER BY p.creationDate ASC, p.qualityScore DESC;
    """

    var statement: OpaquePointer?
    var photos: [IndexedPhoto] = []

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(eventId))
        sqlite3_bind_int(statement, 2, Int32(eventId))

        while sqlite3_step(statement) == SQLITE_ROW {
            photos.append(readEventPhoto(from: statement))
        }
    } else {
        print("Failed to get photos for event: \(String(cString: sqlite3_errmsg(db)))")
    }

    sqlite3_finalize(statement)
    return photos
    }


    func setSimilarGroupPicks(groupPhotoIds: [String], pickedPhotoIds: Set<String>) {
    guard !groupPhotoIds.isEmpty else { return }

    sync {
        let sql = """
        UPDATE photo_events
        SET isSimilarGroupPick = ?
        WHERE photoId = ?
          AND eventId = ?;
        """

        for photoId in groupPhotoIds {
            guard let eventId = getEventIdForPhotoUnsafe(photoId: photoId) else { continue }

            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, pickedPhotoIds.contains(photoId) ? 1 : 0)
                sqlite3_bind_text(statement, 2, (photoId as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 3, Int32(eventId))
                sqlite3_step(statement)
            }

            sqlite3_finalize(statement)
        }
    }
    }


    func setPhotosShowOnFrame(photoIds: [String], show: Bool) {
    guard !photoIds.isEmpty else { return }

    sync {
        var touchedEventIds = Set<Int>()

        for photoId in photoIds {
            guard let eventId = getEventIdForPhotoUnsafe(photoId: photoId) else { continue }

            let sql = """
            UPDATE photo_events
            SET includeInSlideshow = ?
            WHERE photoId = ?
              AND eventId = ?;
            """

            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, show ? 1 : 0)
                sqlite3_bind_text(statement, 2, (photoId as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 3, Int32(eventId))
                sqlite3_step(statement)
            }

            sqlite3_finalize(statement)
            touchedEventIds.insert(eventId)
        }

        refreshSummariesAndCovers(for: touchedEventIds)
    }
    }


    func setPhotosHiddenInEvent(photoIds: [String], hidden: Bool) {
    guard !photoIds.isEmpty else { return }

    sync {
        var touchedEventIds = Set<Int>()

        for photoId in photoIds {
            guard let eventId = getEventIdForPhotoUnsafe(photoId: photoId) else { continue }

            let sql = """
            UPDATE photo_events
            SET manuallyExcluded = ?,
                includeInSlideshow = CASE WHEN ? = 1 THEN 0 ELSE includeInSlideshow END
            WHERE photoId = ?
              AND eventId = ?;
            """

            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, hidden ? 1 : 0)
                sqlite3_bind_int(statement, 2, hidden ? 1 : 0)
                sqlite3_bind_text(statement, 3, (photoId as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 4, Int32(eventId))
                sqlite3_step(statement)
            }

            sqlite3_finalize(statement)
            touchedEventIds.insert(eventId)
        }

        refreshSummariesAndCovers(for: touchedEventIds)
    }
    }


    func getEventIdForPhotoUnsafe(photoId: String) -> Int? {
    let sql = """
    SELECT eventId
    FROM photo_events
    WHERE photoId = ?
    LIMIT 1;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)

        if sqlite3_step(statement) == SQLITE_ROW {
            let eventId = Int(sqlite3_column_int(statement, 0))
            sqlite3_finalize(statement)
            return eventId
        }
    }

    sqlite3_finalize(statement)
    return nil
    }


    func refreshSummariesAndCovers(for eventIds: Set<Int>) {
    var refreshed = Set<Int>()

    for eventId in eventIds {
        updateEventSummary(eventId: eventId)
        updateCoverPhotoForEvent(eventId: eventId)
        refreshed.insert(eventId)

        if let parentId = parentEventIdUnsafe(for: eventId), !refreshed.contains(parentId) {
            if hasActiveSubEventsUnsafe(eventId: parentId) {
                updateTripParentSummary(parentEventId: parentId)
            } else {
                updateEventSummary(eventId: parentId)
            }
            updateCoverPhotoForEvent(eventId: parentId)
            refreshed.insert(parentId)
        }
    }
    }


    func parentEventIdUnsafe(for eventId: Int) -> Int? {
    let sql = """
    SELECT parentEventId
    FROM events
    WHERE eventId = ?
      AND parentEventId IS NOT NULL
    LIMIT 1;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(eventId))

        if sqlite3_step(statement) == SQLITE_ROW {
            let parentId = Int(sqlite3_column_int(statement, 0))
            sqlite3_finalize(statement)
            return parentId
        }
    }

    sqlite3_finalize(statement)
    return nil
    }


    func readEventPhoto(from statement: OpaquePointer?) -> IndexedPhoto {
        let photo = photos.readIndexedPhotoRow(from: statement)
        let showOnFrame = sqlite3_column_int(statement, 14) == 1
        let isHiddenInEvent = sqlite3_column_int(statement, 15) == 1
        let isSimilarGroupPick = sqlite3_column_int(statement, 16) == 1
        let isVideo = sqlite3_column_int(statement, 17) == 2

        return IndexedPhoto(
            id: photo.id,
            creationDate: photo.creationDate,
            isFavorite: photo.isFavorite,
            width: photo.width,
            height: photo.height,
            mediaSubtype: photo.mediaSubtype,
            latitude: photo.latitude,
            longitude: photo.longitude,
            isScreenshot: photo.isScreenshot,
            aspectRatio: photo.aspectRatio,
            orientation: photo.orientation,
            qualityScore: photo.qualityScore,
            faceEyesOpenScore: photo.faceEyesOpenScore,
            faceSmileScore: photo.faceSmileScore,
            showOnFrame: showOnFrame,
            isHiddenInEvent: isHiddenInEvent,
            isSimilarGroupPick: isSimilarGroupPick,
            isVideo: isVideo
        )
    }


    func getEventIdForPhoto(photoId: String) -> Int? {
    let sql = """
    SELECT eventId
    FROM photo_events
    WHERE photoId = ?
    LIMIT 1;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)

        if sqlite3_step(statement) == SQLITE_ROW {
            let eventId = Int(sqlite3_column_int(statement, 0))
            sqlite3_finalize(statement)
            return eventId
        }
    }

    sqlite3_finalize(statement)
    return nil
    }


    func getSubEvents(parentEventId: Int) -> [IndexedEvent] {
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
        COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 AND COALESCE(ph.mediaType, 1) != 2 THEN pe.photoId END) as photoCount,
        GROUP_CONCAT(DISTINCT p.displayName) as peopleNames,
        e.showAsSlideshowEvent,
        e.userEditedName,
        l.nickname as locationNickname,
        e.locationId,
        e.parentEventId,
        e.isTripEvent,
        e.weddingDate,
        e.childEventName,
        COALESCE(e.userEditedChildEventName, 0) as userEditedChildEventName,
        COALESCE(e.isUserHidden, 0) as isUserHidden,
        COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 AND COALESCE(ph.mediaType, 1) = 2 THEN pe.photoId END) as videoCount,
        COALESCE(e.isFavorite, 0) as isFavorite
    FROM events e
    LEFT JOIN locations l
        ON e.locationId = l.locationId
    LEFT JOIN photo_events pe
        ON e.eventId = pe.eventId
    LEFT JOIN photos ph
        ON pe.photoId = ph.id
    LEFT JOIN photo_people pp
        ON pp.photoId = pe.photoId
       AND COALESCE(ph.isDeleted, 0) = 0
    LEFT JOIN people p
        ON p.personId = pp.personId
    WHERE e.isDeleted = 0
      AND e.parentEventId = ?
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
        e.coverPhotoId,
        e.showAsSlideshowEvent,
        e.userEditedName,
        l.nickname,
        e.locationId,
        e.parentEventId,
        e.isTripEvent,
        e.weddingDate,
        e.childEventName,
        e.userEditedChildEventName,
        e.isUserHidden,
        e.isFavorite
    ORDER BY e.startDate ASC;
    """

    var statement: OpaquePointer?
    var events: [IndexedEvent] = []

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(parentEventId))

        while sqlite3_step(statement) == SQLITE_ROW {
            events.append(parseIndexedEvent(from: statement))
        }
    }

    sqlite3_finalize(statement)
    return events
    }


    func getTripSections(for parentEventId: Int, includeHidden: Bool = false) -> [TripEventSection] {
    guard let parent = getEvent(eventId: parentEventId) else { return [] }

    return getSubEvents(parentEventId: parentEventId).map { subEvent in
        let dayNumber = tripDayNumber(
            tripStartISO: parent.startDate,
            segmentStartISO: subEvent.startDate
        )
        return TripEventSection(
            dayNumber: dayNumber,
            childEventName: subEvent.resolvedChildEventName(),
            subEventId: subEvent.eventId,
            photos: getPhotosForEvent(eventId: subEvent.eventId, includeHidden: includeHidden)
        )
    }
    }


    func tripDayNumber(tripStartISO: String, segmentStartISO: String) -> Int {
    guard let tripStart = EventDateParser.parseDate(tripStartISO),
          let segmentStart = EventDateParser.parseDate(segmentStartISO) else {
        return 1
    }

    let calendar = Calendar.current
    let startDay = calendar.startOfDay(for: tripStart)
    let segmentDay = calendar.startOfDay(for: segmentStart)
    let dayOffset = calendar.dateComponents([.day], from: startDay, to: segmentDay).day ?? 0
    return max(1, dayOffset + 1)
    }


    func attachPhotoToEvent(
        photoId: String,
        eventId: Int,
        assignmentConfidence: Double? = nil,
        assignmentMethod: PhotoEventAssignmentMethod? = nil,
        needsReview: Bool = false
    ) {
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
        INSERT INTO photo_events (
            photoId, eventId, assignmentConfidence, assignmentMethod, assignedAt, needsReview
        )
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(photoId, eventId) DO UPDATE SET
            assignmentConfidence = excluded.assignmentConfidence,
            assignmentMethod = excluded.assignmentMethod,
            assignedAt = excluded.assignedAt,
            needsReview = excluded.needsReview;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(eventId))

            if let assignmentConfidence {
                sqlite3_bind_double(statement, 3, assignmentConfidence)
            } else {
                sqlite3_bind_null(statement, 3)
            }

            if let assignmentMethod {
                sqlite3_bind_text(
                    statement,
                    4,
                    (assignmentMethod.rawValue as NSString).utf8String,
                    -1,
                    nil
                )
            } else {
                sqlite3_bind_null(statement, 4)
            }

            sqlite3_bind_text(statement, 5, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 6, needsReview ? 1 : 0)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed attaching photo to event: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
    }

    func countUnassignedGPSPhotosForEvents() -> Int {
        countPhotosMatching(
            """
            isDeleted = 0
              AND eventAssignedAt IS NULL
              AND isScreenshot = 0
              AND COALESCE(userLatitude, latitude) IS NOT NULL
              AND COALESCE(userLongitude, longitude) IS NOT NULL
            """
        )
    }

    func countUnassignedMetadataPhotosForEvents() -> Int {
        countPhotosMatching(
            """
            isDeleted = 0
              AND eventAssignedAt IS NULL
              AND isScreenshot = 0
              AND COALESCE(userLatitude, latitude) IS NULL
              AND COALESCE(userLongitude, longitude) IS NULL
            """
        )
    }

    func getUnassignedGPSPhotosForEvents(limit: Int) -> [EventCandidatePhoto] {
        getUnassignedPhotosForEvents(limit: limit)
    }

    func getUnassignedMetadataPhotosForEvents(
        limit: Int,
        ascending: Bool = false
    ) -> [PhotoMetadataAssignmentCandidate] {
        let order = ascending ? "ASC" : "DESC"
        let sql = """
        SELECT id,
               COALESCE(captureDateOverride, creationDate) AS effectiveDate
        FROM photos
        WHERE isDeleted = 0
          AND eventAssignedAt IS NULL
          AND isScreenshot = 0
          AND COALESCE(userLatitude, latitude) IS NULL
          AND COALESCE(userLongitude, longitude) IS NULL
        ORDER BY effectiveDate \(order)
        LIMIT ?;
        """

        var statement: OpaquePointer?
        var photos: [PhotoMetadataAssignmentCandidate] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = sqliteOptionalText(statement, column: 0),
                      let dateString = sqliteOptionalText(statement, column: 1),
                      let date = Self.iso8601Formatter.date(from: dateString) else {
                    continue
                }

                photos.append(PhotoMetadataAssignmentCandidate(id: id, date: date))
            }
        } else {
            print(
                "Failed to get unassigned metadata photos: \(String(cString: sqlite3_errmsg(db!)))"
            )
        }

        sqlite3_finalize(statement)
        return photos
    }

    func fetchMetadataMatchableEvents(
        near photoDate: Date,
        maxGapSeconds: TimeInterval
    ) -> [(eventId: Int, startDate: Date, endDate: Date)] {
        let windowStart = Self.iso8601Formatter.string(
            from: photoDate.addingTimeInterval(-maxGapSeconds)
        )
        let windowEnd = Self.iso8601Formatter.string(
            from: photoDate.addingTimeInterval(maxGapSeconds)
        )

        let sql = """
        SELECT DISTINCT e.eventId, e.startDate, e.endDate
        FROM events e
        WHERE e.isDeleted = 0
          AND TRIM(COALESCE(e.startDate, '')) != ''
          AND TRIM(COALESCE(e.endDate, '')) != ''
          AND e.startDate <= ?
          AND e.endDate >= ?
          AND EXISTS (
            SELECT 1
            FROM photo_events pe
            JOIN photos p ON p.id = pe.photoId
            WHERE pe.eventId = e.eventId
              AND p.isDeleted = 0
              AND COALESCE(p.userLatitude, p.latitude) IS NOT NULL
              AND COALESCE(p.userLongitude, p.longitude) IS NOT NULL
          )
        ORDER BY e.startDate DESC;
        """

        var statement: OpaquePointer?
        var rows: [(eventId: Int, startDate: Date, endDate: Date)] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (windowEnd as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (windowStart as NSString).utf8String, -1, nil)

            while sqlite3_step(statement) == SQLITE_ROW {
                let eventId = Int(sqlite3_column_int(statement, 0))
                guard let startString = sqliteOptionalText(statement, column: 1),
                      let endString = sqliteOptionalText(statement, column: 2),
                      let startDate = Self.iso8601Formatter.date(from: startString),
                      let endDate = Self.iso8601Formatter.date(from: endString) else {
                    continue
                }

                rows.append((eventId: eventId, startDate: startDate, endDate: endDate))
            }
        }

        sqlite3_finalize(statement)
        return rows
    }

    struct SameDayLocatedEvent {
        let eventId: Int
        let startDate: Date
        let endDate: Date
        let startDay: Date
        let endDay: Date
        let isSingleDay: Bool
        let isLeaf: Bool
    }

    /// One read of every GPS-backed event, so same-day matching does not query per photo.
    func fetchSameDayLocatedEvents() -> [SameDayLocatedEvent] {
        let calendar = Calendar.current
        let sql = """
        SELECT eventId, startDate, endDate,
               (
                   SELECT COUNT(*)
                   FROM events child
                   WHERE child.parentEventId = events.eventId
                     AND child.isDeleted = 0
               ) AS childCount
        FROM events
        WHERE isDeleted = 0
          AND COALESCE(isUserHidden, 0) = 0
          AND COALESCE(clusteredByTimeOnly, 0) = 0
          AND latitude IS NOT NULL
          AND longitude IS NOT NULL
          AND TRIM(COALESCE(startDate, '')) != ''
          AND TRIM(COALESCE(endDate, '')) != '';
        """

        var statement: OpaquePointer?
        var located: [SameDayLocatedEvent] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let eventId = Int(sqlite3_column_int(statement, 0))
                guard let startString = sqliteOptionalText(statement, column: 1),
                      let endString = sqliteOptionalText(statement, column: 2),
                      let startDate = Self.iso8601Formatter.date(from: startString),
                      let endDate = Self.iso8601Formatter.date(from: endString) else {
                    continue
                }
                let startDay = calendar.startOfDay(for: startDate)
                let endDay = calendar.startOfDay(for: endDate)
                located.append(
                    SameDayLocatedEvent(
                        eventId: eventId,
                        startDate: startDate,
                        endDate: endDate,
                        startDay: startDay,
                        endDay: endDay,
                        isSingleDay: startDay == endDay,
                        isLeaf: sqlite3_column_int(statement, 3) == 0
                    )
                )
            }
        } else {
            print(
                "Failed to load same-day located events: \(String(cString: sqlite3_errmsg(db!)))"
            )
        }

        sqlite3_finalize(statement)
        return located
    }

    func bestSameDayLocatedEvent(
        photoDate: Date,
        in locatedEvents: [SameDayLocatedEvent]
    ) -> Int? {
        let calendar = Calendar.current
        let photoDay = calendar.startOfDay(for: photoDate)

        struct Candidate {
            let eventId: Int
            let gap: TimeInterval
            let isSingleDay: Bool
            let isLeaf: Bool
        }

        let candidates: [Candidate] = locatedEvents.compactMap { event in
            guard event.startDay <= photoDay, photoDay <= event.endDay else { return nil }
            return Candidate(
                eventId: event.eventId,
                gap: timeGapSeconds(
                    photoDate: photoDate,
                    startDate: event.startDate,
                    endDate: event.endDate
                ),
                isSingleDay: event.isSingleDay,
                isLeaf: event.isLeaf
            )
        }

        return candidates.min { lhs, rhs in
            if lhs.isSingleDay != rhs.isSingleDay { return lhs.isSingleDay }
            if lhs.isLeaf != rhs.isLeaf { return lhs.isLeaf }
            return lhs.gap < rhs.gap
        }?.eventId
    }

    /// GPS-backed event on the photo's local calendar day.
    /// A single-day event (the game) wins over a multi-day trip that merely covers that day.
    /// When several single-day events exist, the closest in time wins.
    func findSameDayLocatedEvent(photoDate: Date) -> Int? {
        bestSameDayLocatedEvent(photoDate: photoDate, in: fetchSameDayLocatedEvents())
    }

    /// Best time-only event for a photo (date/time clustering; no GPS required on the event).
    func findTimeOnlyMatchingEvent(
        photoDate: Date,
        maxGapSeconds: TimeInterval
    ) -> Int? {
        let windowStart = Self.iso8601Formatter.string(
            from: photoDate.addingTimeInterval(-maxGapSeconds)
        )
        let windowEnd = Self.iso8601Formatter.string(
            from: photoDate.addingTimeInterval(maxGapSeconds)
        )

        let sql = """
        SELECT eventId, startDate, endDate
        FROM events
        WHERE isDeleted = 0
          AND parentEventId IS NULL
          AND COALESCE(clusteredByTimeOnly, 0) = 1
          AND TRIM(COALESCE(startDate, '')) != ''
          AND TRIM(COALESCE(endDate, '')) != ''
          AND startDate <= ?
          AND endDate >= ?
        ORDER BY startDate DESC;
        """

        var statement: OpaquePointer?
        var bestEventId: Int?
        var bestGap = TimeInterval.greatestFiniteMagnitude

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (windowEnd as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (windowStart as NSString).utf8String, -1, nil)

            while sqlite3_step(statement) == SQLITE_ROW {
                let eventId = Int(sqlite3_column_int(statement, 0))
                guard let startString = sqliteOptionalText(statement, column: 1),
                      let endString = sqliteOptionalText(statement, column: 2),
                      let startDate = Self.iso8601Formatter.date(from: startString),
                      let endDate = Self.iso8601Formatter.date(from: endString) else {
                    continue
                }

                let gap: TimeInterval
                if photoDate >= startDate && photoDate <= endDate {
                    gap = 0
                } else {
                    gap = min(
                        abs(photoDate.timeIntervalSince(startDate)),
                        abs(photoDate.timeIntervalSince(endDate))
                    )
                }

                guard gap <= maxGapSeconds, gap < bestGap else { continue }
                bestGap = gap
                bestEventId = eventId
            }
        } else {
            print(
                "Failed to find time-only event: \(String(cString: sqlite3_errmsg(db!)))"
            )
        }

        sqlite3_finalize(statement)
        return bestEventId
    }

    func sharedNonHighCardinalityAlbumCount(photoId: String, eventId: Int) -> Int {
        let sql = """
        SELECT COUNT(DISTINCT pa1.albumId)
        FROM photo_albums pa1
        JOIN photo_albums pa2 ON pa1.albumId = pa2.albumId
        JOIN albums a ON a.albumId = pa1.albumId
        JOIN photo_events pe ON pe.photoId = pa2.photoId
        JOIN photos p ON p.id = pa2.photoId
        WHERE pa1.photoId = ?
          AND pe.eventId = ?
          AND COALESCE(a.isHighCardinality, 0) = 0
          AND p.isDeleted = 0;
        """

        return countFromQuery(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(eventId))
        }
    }

    func sharedPeopleCount(photoId: String, eventId: Int) -> Int {
        let sql = """
        SELECT COUNT(DISTINCT pp1.personId)
        FROM photo_people pp1
        JOIN photo_people pp2 ON pp1.personId = pp2.personId
        JOIN photo_events pe ON pe.photoId = pp2.photoId
        JOIN photos p ON p.id = pp2.photoId
        WHERE pp1.photoId = ?
          AND pe.eventId = ?
          AND p.isDeleted = 0;
        """

        return countFromQuery(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(eventId))
        }
    }

    func countMetadataAttachedPhotos() -> Int {
        countPhotosMatching(
            """
            eventAssignedAt IS NOT NULL
              AND isDeleted = 0
              AND COALESCE(userLatitude, latitude) IS NULL
              AND COALESCE(userLongitude, longitude) IS NULL
            """
        )
    }

    func countMetadataAttachedPhotosNeedingReview() -> Int {
        countRowsMatching(
            """
            photo_events pe
            JOIN photos p ON p.id = pe.photoId
            WHERE p.isDeleted = 0
              AND COALESCE(pe.needsReview, 0) = 1
              AND pe.assignmentMethod IN ('album_time', 'people_time', 'album_people_time')
            """
        )
    }

    private func countPhotosMatching(_ whereSQL: String) -> Int {
        countRowsMatching("photos WHERE \(whereSQL)")
    }

    private func countRowsMatching(_ tableAndWhere: String) -> Int {
        let sql = "SELECT COUNT(*) FROM \(tableAndWhere);"
        return countFromQuery(sql: sql) { _ in }
    }

    private func countFromQuery(
        sql: String,
        bind: ((OpaquePointer?) -> Void)?
    ) -> Int {
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bind?(statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                let count = Int(sqlite3_column_int(statement, 0))
                sqlite3_finalize(statement)
                return count
            }
        }

        sqlite3_finalize(statement)
        return 0
    }

    func findBestMetadataAssignment(
        for photo: PhotoMetadataAssignmentCandidate,
        tuning: EventTuningSettings
    ) -> PhotoMetadataAssignmentMatch? {
        let candidates = fetchMetadataMatchableEvents(
            near: photo.date,
            maxGapSeconds: tuning.metadataAttachMaxGapSeconds
        )

        var best: PhotoMetadataAssignmentMatch?

        for candidate in candidates {
            let timeGap = timeGapSeconds(
                photoDate: photo.date,
                startDate: candidate.startDate,
                endDate: candidate.endDate
            )
            guard timeGap <= tuning.metadataAttachMaxGapSeconds else { continue }

            let sharedAlbums = sharedNonHighCardinalityAlbumCount(
                photoId: photo.id,
                eventId: candidate.eventId
            )
            let sharedPeople = sharedPeopleCount(photoId: photo.id, eventId: candidate.eventId)

            guard let scored = PhotoEventAssignmentScorer.score(
                input: PhotoEventAssignmentScorer.Input(
                    sharedAlbums: sharedAlbums,
                    sharedPeople: sharedPeople,
                    timeGapSeconds: timeGap,
                    maxGapSeconds: tuning.metadataAttachMaxGapSeconds
                ),
                tuning: tuning
            ) else {
                continue
            }

            let match = PhotoMetadataAssignmentMatch(
                eventId: candidate.eventId,
                confidence: scored.confidence,
                method: scored.method,
                sharedAlbums: sharedAlbums,
                sharedPeople: sharedPeople,
                needsReview: scored.needsReview
            )

            if let best, match.confidence <= best.confidence {
                continue
            }
            best = match
        }

        return best
    }

    private func timeGapSeconds(
        photoDate: Date,
        startDate: Date,
        endDate: Date
    ) -> TimeInterval {
        if photoDate >= startDate && photoDate <= endDate {
            return 0
        }
        return min(
            abs(photoDate.timeIntervalSince(startDate)),
            abs(photoDate.timeIntervalSince(endDate))
        )
    }

    func getUnassignedPhotosForEvents(limit: Int) -> [EventCandidatePhoto] {
    let sql = """
    SELECT id,
           COALESCE(captureDateOverride, creationDate) AS effectiveDate,
           COALESCE(userLatitude, latitude) AS effectiveLatitude,
           COALESCE(userLongitude, longitude) AS effectiveLongitude
    FROM photos
    WHERE isDeleted = 0
      AND eventAssignedAt IS NULL
      AND isScreenshot = 0
      AND COALESCE(userLatitude, latitude) IS NOT NULL
      AND COALESCE(userLongitude, longitude) IS NOT NULL
    ORDER BY effectiveDate ASC
    LIMIT ?;
    """

    var statement: OpaquePointer?
    var photos: [EventCandidatePhoto] = []

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_int(statement, 1, Int32(limit))
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqliteOptionalText(statement, column: 0),
                  let dateString = sqliteOptionalText(statement, column: 1) else {
                continue
            }

            let latitude = sqlite3_column_double(statement, 2)
            let longitude = sqlite3_column_double(statement, 3)

            if let date = Self.iso8601Formatter.date(from: dateString) {
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


    func markPhotoEventAssigned(photoId: String, needsReview: Bool = false) {
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        UPDATE photos
        SET eventAssignedAt = ?,
            eventNeedsReview = ?
        WHERE id = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, needsReview ? 1 : 0)
            sqlite3_bind_text(statement, 3, (photoId as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }


    func eventDateDiagnosticCounts() -> EventDateDiagnosticCounts {
        EventDateDiagnosticCounts(
            activeEvents: countEventsUnsafe(
                whereSQL: "isDeleted = 0 AND COALESCE(isUserHidden, 0) = 0"
            ),
            missingStartDate: countEventsUnsafe(
                whereSQL: """
                isDeleted = 0
                  AND COALESCE(isUserHidden, 0) = 0
                  AND (
                    startDate IS NULL
                    OR TRIM(COALESCE(startDate, '')) = ''
                  )
                """
            ),
            tripParentsMissingStartDate: countEventsUnsafe(
                whereSQL: """
                isDeleted = 0
                  AND COALESCE(isUserHidden, 0) = 0
                  AND (
                    startDate IS NULL
                    OR TRIM(COALESCE(startDate, '')) = ''
                  )
                  AND EXISTS (
                    SELECT 1
                    FROM events child
                    WHERE child.parentEventId = events.eventId
                      AND child.isDeleted = 0
                  )
                """
            )
        )
    }

    @discardableResult
    func repairEventDateSummaries() -> EventDateRepairResult {
        var tripParentsUpdated = 0
        for parentId in activeTripParentEventIdsNeedingDateRepairUnsafe() {
            updateTripParentSummary(parentEventId: parentId, refreshCover: false)
            tripParentsUpdated += 1
        }

        var leafEventsUpdated = 0
        for eventId in activeLeafEventIdsNeedingDateRepairUnsafe() {
            updateEventSummary(eventId: eventId)
            leafEventsUpdated += 1
        }

        return EventDateRepairResult(
            tripParentsUpdated: tripParentsUpdated,
            leafEventsUpdated: leafEventsUpdated
        )
    }

    func updateEventSummary(eventId: Int) {
        if hasActiveSubEventsUnsafe(eventId: eventId) {
            updateTripParentSummary(parentEventId: eventId)
            return
        }

    let sql = """
    UPDATE events
    SET
        startDate = COALESCE(
            (
                SELECT MIN(\(Self.effectivePhotoDateSQL))
                FROM photo_events pe
                JOIN photos p ON pe.photoId = p.id
                WHERE pe.eventId = ?
                  AND p.isDeleted = 0
                  AND \(Self.effectivePhotoDateSQL) IS NOT NULL
            ),
            startDate
        ),
        endDate = COALESCE(
            (
                SELECT MAX(\(Self.effectivePhotoDateSQL))
                FROM photo_events pe
                JOIN photos p ON pe.photoId = p.id
                WHERE pe.eventId = ?
                  AND p.isDeleted = 0
                  AND \(Self.effectivePhotoDateSQL) IS NOT NULL
            ),
            endDate
        ),
        latitude = CASE
            WHEN COALESCE(clusteredByTimeOnly, 0) = 1 THEN latitude
            ELSE (
                SELECT AVG(p.latitude)
                FROM photo_events pe
                JOIN photos p ON pe.photoId = p.id
                WHERE pe.eventId = ?
                  AND p.isDeleted = 0
                  AND p.latitude IS NOT NULL
            )
        END,
        longitude = CASE
            WHEN COALESCE(clusteredByTimeOnly, 0) = 1 THEN longitude
            ELSE (
                SELECT AVG(p.longitude)
                FROM photo_events pe
                JOIN photos p ON pe.photoId = p.id
                WHERE pe.eventId = ?
                  AND p.isDeleted = 0
                  AND p.longitude IS NOT NULL
            )
        END,
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

    /// Trip containers hold photos on child day events; derive dates from descendant photos.
    func updateTripParentSummary(parentEventId: Int, refreshCover: Bool = true) {
        let sql = """
        UPDATE events
        SET
            startDate = COALESCE(
                (
                    SELECT MIN(\(Self.effectivePhotoDateSQL))
                    FROM events e
                    JOIN photo_events pe ON e.eventId = pe.eventId
                    JOIN photos p ON pe.photoId = p.id
                    WHERE e.parentEventId = ?
                      AND e.isDeleted = 0
                      AND p.isDeleted = 0
                      AND \(Self.effectivePhotoDateSQL) IS NOT NULL
                ),
                startDate
            ),
            endDate = COALESCE(
                (
                    SELECT MAX(\(Self.effectivePhotoDateSQL))
                    FROM events e
                    JOIN photo_events pe ON e.eventId = pe.eventId
                    JOIN photos p ON pe.photoId = p.id
                    WHERE e.parentEventId = ?
                      AND e.isDeleted = 0
                      AND p.isDeleted = 0
                      AND \(Self.effectivePhotoDateSQL) IS NOT NULL
                ),
                endDate
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
            isTripEvent = 1,
            updatedAt = ?
        WHERE eventId = ?;
        """

        let now = ISO8601DateFormatter().string(from: Date())
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for index in 1...7 {
                sqlite3_bind_int(statement, Int32(index), Int32(parentEventId))
            }
            sqlite3_bind_text(statement, 8, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 9, Int32(parentEventId))

            if sqlite3_step(statement) != SQLITE_DONE {
                print(
                    "Failed updating trip parent summary: \(String(cString: sqlite3_errmsg(db!)))"
                )
            }
        }

        sqlite3_finalize(statement)
        if refreshCover {
            updateCoverPhotoForEvent(eventId: parentEventId)
        }
    }

    private func hasActiveSubEventsUnsafe(eventId: Int) -> Bool {
        let sql = """
        SELECT 1
        FROM events
        WHERE parentEventId = ?
          AND isDeleted = 0
        LIMIT 1;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            let found = sqlite3_step(statement) == SQLITE_ROW
            sqlite3_finalize(statement)
            return found
        }

        sqlite3_finalize(statement)
        return false
    }

    private func activeTripParentEventIdsNeedingDateRepairUnsafe() -> [Int] {
        let sql = """
        SELECT DISTINCT e.eventId
        FROM events e
        WHERE e.isDeleted = 0
          AND (
            e.startDate IS NULL
            OR TRIM(COALESCE(e.startDate, '')) = ''
            OR e.endDate IS NULL
            OR TRIM(COALESCE(e.endDate, '')) = ''
          )
          AND EXISTS (
            SELECT 1
            FROM events child
            WHERE child.parentEventId = e.eventId
              AND child.isDeleted = 0
          )
        ORDER BY e.eventId ASC;
        """
        return fetchEventIdsUnsafe(sql: sql, bind: nil)
    }

    private func activeLeafEventIdsNeedingDateRepairUnsafe() -> [Int] {
        let sql = """
        SELECT e.eventId
        FROM events e
        WHERE e.isDeleted = 0
          AND NOT EXISTS (
            SELECT 1
            FROM events child
            WHERE child.parentEventId = e.eventId
              AND child.isDeleted = 0
          )
          AND (
            e.startDate IS NULL
            OR TRIM(COALESCE(e.startDate, '')) = ''
            OR e.endDate IS NULL
            OR TRIM(COALESCE(e.endDate, '')) = ''
          )
          AND EXISTS (
            SELECT 1
            FROM photo_events pe
            JOIN photos p ON pe.photoId = p.id
            WHERE pe.eventId = e.eventId
              AND p.isDeleted = 0
          )
        ORDER BY e.eventId ASC;
        """
        return fetchEventIdsUnsafe(sql: sql, bind: nil)
    }

    private func fetchEventIdsUnsafe(
        sql: String,
        bind: ((OpaquePointer?) -> Void)?
    ) -> [Int] {
        var statement: OpaquePointer?
        var ids: [Int] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bind?(statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.append(Int(sqlite3_column_int(statement, 0)))
            }
        }

        sqlite3_finalize(statement)
        return ids
    }

    private func countEventsUnsafe(whereSQL: String) -> Int {
        let sql = "SELECT COUNT(*) FROM events WHERE \(whereSQL);"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_int(statement, 0))
            sqlite3_finalize(statement)
            return count
        }

        sqlite3_finalize(statement)
        return 0
    }

    private static let effectivePhotoDateSQL = """
    COALESCE(
        NULLIF(TRIM(p.captureDateOverride), ''),
        NULLIF(TRIM(p.creationDate), '')
    )
    """

    func cleanupEmptyEvents() {
    let now = ISO8601DateFormatter().string(from: Date())

    let sql = """
    UPDATE events
    SET isDeleted = 1,
        deletedAt = ?,
        updatedAt = ?
    WHERE isDeleted = 0
      AND COALESCE(isTripEvent, 0) = 0
      AND NOT EXISTS (
            SELECT 1
            FROM photo_events pe
            JOIN photos p ON p.id = pe.photoId
            WHERE p.isDeleted = 0
              AND (
                    pe.eventId = events.eventId
                    OR pe.eventId IN (
                        SELECT child.eventId
                        FROM events child
                        WHERE child.parentEventId = events.eventId
                          AND child.isDeleted = 0
                    )
              )
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

    /// Trip containers hold photos on sub-events after day/place split; undo mistaken soft-deletes.

    func restoreDeletedTripContainers() {
    let now = ISO8601DateFormatter().string(from: Date())

    let bulkSQL = """
    UPDATE events
    SET isDeleted = 0,
        deletedAt = NULL,
        updatedAt = ?,
        isTripEvent = 1
    WHERE isDeleted = 1
      AND parentEventId IS NULL
      AND EXISTS (
            SELECT 1
            FROM events child
            JOIN photo_events pe ON pe.eventId = child.eventId
            JOIN photos p ON p.id = pe.photoId AND p.isDeleted = 0
            WHERE child.parentEventId = events.eventId
              AND child.isDeleted = 0
      );
    """

    var statement: OpaquePointer?

    guard sqlite3_prepare_v2(db, bulkSQL, -1, &statement, nil) == SQLITE_OK else {
        sqlite3_finalize(statement)
        return
    }

    sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)

    guard sqlite3_step(statement) == SQLITE_DONE else {
        sqlite3_finalize(statement)
        return
    }

    sqlite3_finalize(statement)

    let restored = Int(sqlite3_changes(db))
    guard restored > 0 else { return }

    print("Restored \(restored) deleted trip container(s)")
    }


    func expandEventDatesAfterAttach(eventId: Int, photoDate: Date) {
        let dateISO = Self.iso8601Formatter.string(from: photoDate)

    let sql = """
    UPDATE events
    SET startDate = CASE WHEN ? < startDate THEN ? ELSE startDate END,
        endDate = CASE WHEN ? > endDate THEN ? ELSE endDate END
    WHERE eventId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        sqlite3_bind_text(statement, 1, (dateISO as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (dateISO as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (dateISO as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (dateISO as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 5, Int32(eventId))
        sqlite3_step(statement)
    }

    sqlite3_finalize(statement)
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

    func setEventLocationId(eventId: Int, locationId: Int) {
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

    func setEventCentroid(
        eventId: Int,
        latitude: Double,
        longitude: Double,
        clearTimeOnlyFlag: Bool
    ) {
        let sql = """
        UPDATE events
        SET latitude = ?,
            longitude = ?,
            clusteredByTimeOnly = CASE WHEN ? = 1 THEN 0 ELSE clusteredByTimeOnly END
        WHERE eventId = ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_double(statement, 1, latitude)
            sqlite3_bind_double(statement, 2, longitude)
            sqlite3_bind_int(statement, 3, clearTimeOnlyFlag ? 1 : 0)
            sqlite3_bind_int(statement, 4, Int32(eventId))
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

    func reassignEvents(fromLocationId: Int, toLocationId: Int) {
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


    func isObjectRecognitionCompletedUnsafe(eventId: Int) -> Bool {
        let sql = """
        SELECT COALESCE(objectRecognitionCompleted, 0)
        FROM events
        WHERE eventId = ?
          AND isDeleted = 0
        LIMIT 1;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if sqlite3_step(statement) == SQLITE_ROW {
                let completed = sqlite3_column_int(statement, 0) != 0
                sqlite3_finalize(statement)
                return completed
            }
        }

        sqlite3_finalize(statement)
        return false
    }

    func photoDateRangeISOForEventUnsafe(
        eventId: Int,
        includesDescendantPhotos: Bool = false
    ) -> (start: String, end: String)? {
        let eventScopeSQL: String
        if includesDescendantPhotos {
            eventScopeSQL = """
            FROM events e
            JOIN photo_events pe ON pe.eventId = e.eventId
            JOIN photos p ON pe.photoId = p.id
            WHERE p.isDeleted = 0
              AND \(Self.effectivePhotoDateSQL) IS NOT NULL
              AND e.isDeleted = 0
              AND (e.eventId = ? OR e.parentEventId = ?)
            """
        } else {
            eventScopeSQL = """
            FROM photo_events pe
            JOIN photos p ON pe.photoId = p.id
            WHERE pe.eventId = ?
              AND p.isDeleted = 0
              AND \(Self.effectivePhotoDateSQL) IS NOT NULL
            """
        }

        let sql = """
        SELECT
            MIN(\(Self.effectivePhotoDateSQL)),
            MAX(\(Self.effectivePhotoDateSQL))
        \(eventScopeSQL);
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if includesDescendantPhotos {
                sqlite3_bind_int(statement, 2, Int32(eventId))
            }
            if sqlite3_step(statement) == SQLITE_ROW,
               let start = sqliteOptionalText(statement, column: 0),
               let end = sqliteOptionalText(statement, column: 1),
               !start.isEmpty,
               !end.isEmpty {
                sqlite3_finalize(statement)
                return (start, end)
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    private func listFilterWhereSQL(filter: EventListFilter) -> String {
        switch filter {
        case .allEvents:
            return ""
        case .anyHoliday:
            return holidayTagExistsSQL(tagValueClause: "")
        case .holidayTag(let value):
            return holidayTagExistsSQL(
                tagValueClause: "AND ht.tagValue = '\(escapeSQLLiteral(value))'"
            )
        case .anyMilestone:
            return attributeTagExistsSQL(
                category: EventAttributeField.milestoneType.tagCategory,
                tagValueClause: ""
            )
        case .milestoneTag(let value):
            return attributeTagExistsSQL(
                category: EventAttributeField.milestoneType.tagCategory,
                tagValueClause: "AND ht.tagValue = '\(escapeSQLLiteral(value))'"
            )
        case .milestoneTags(let values):
            let cleaned = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !cleaned.isEmpty else {
                return attributeTagExistsSQL(
                    category: EventAttributeField.milestoneType.tagCategory,
                    tagValueClause: ""
                )
            }
            let inList = cleaned
                .map { "'\(escapeSQLLiteral($0))'" }
                .joined(separator: ", ")
            return attributeTagExistsSQL(
                category: EventAttributeField.milestoneType.tagCategory,
                tagValueClause: "AND ht.tagValue IN (\(inList))"
            )
        case .trips:
            return "AND COALESCE(e.isTripEvent, 0) = 1"
        case .anyActivity:
            return attributeTagExistsSQL(
                category: EventAttributeField.activityType.tagCategory,
                tagValueClause: ""
            )
        case .activityTag(let value):
            return attributeTagExistsSQL(
                category: EventAttributeField.activityType.tagCategory,
                tagValueClause: "AND ht.tagValue = '\(escapeSQLLiteral(value))'"
            )
        case .eventTypeTag(let value):
            return attributeTagExistsSQL(
                category: EventAttributeField.eventType.tagCategory,
                tagValueClause: "AND ht.tagValue = '\(escapeSQLLiteral(value))'"
            )
        case .eventTypeTags(let values):
            let cleaned = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !cleaned.isEmpty else {
                return attributeTagExistsSQL(
                    category: EventAttributeField.eventType.tagCategory,
                    tagValueClause: ""
                )
            }
            let inList = cleaned
                .map { "'\(escapeSQLLiteral($0))'" }
                .joined(separator: ", ")
            return attributeTagExistsSQL(
                category: EventAttributeField.eventType.tagCategory,
                tagValueClause: "AND ht.tagValue IN (\(inList))"
            )
        case .birthdayPerson(let personId, _):
            return birthdayPersonExistsSQL(personId: personId)
        case .location(let locationId, _):
            return "AND e.locationId = \(locationId)"
        }
    }

    private func holidayTagExistsSQL(tagValueClause: String) -> String {
        attributeTagExistsSQL(category: "holiday", tagValueClause: tagValueClause)
    }

    private func attributeTagExistsSQL(category: String, tagValueClause: String) -> String {
        """
        AND EXISTS (
            SELECT 1
            FROM event_tags ht
            WHERE ht.tagCategory = '\(escapeSQLLiteral(category))'
              AND ht.isRejected = 0
              \(tagValueClause)
              AND (
                  ht.eventId = e.eventId
                  OR ht.eventId IN (
                      SELECT child.eventId
                      FROM events child
                      WHERE child.parentEventId = e.eventId
                        AND child.isDeleted = 0
                  )
              )
        )
        """
    }

    /// Event date window overlaps birthday month/day (±3 days) for years near the event.
    private func birthdayPersonDateOverlapSQL(
        eventAlias: String,
        personAlias: String
    ) -> String {
        let windowDays = 3
        func yearOverlap(_ yearSQL: String) -> String {
            """
            (
                date(substr(\(eventAlias).startDate, 1, 10)) <= date(
                    printf('%04d-', \(yearSQL)) || substr(\(personAlias).birthDate, 6, 5),
                    '+\(windowDays) days'
                )
                AND date(substr(\(eventAlias).endDate, 1, 10)) >= date(
                    printf('%04d-', \(yearSQL)) || substr(\(personAlias).birthDate, 6, 5),
                    '-\(windowDays) days'
                )
            )
            """
        }
        return """
        (
            \(yearOverlap("CAST(substr(\(eventAlias).startDate, 1, 4) AS INTEGER)"))
            OR \(yearOverlap("CAST(substr(\(eventAlias).endDate, 1, 4) AS INTEGER)"))
            OR \(yearOverlap("CAST(substr(\(eventAlias).startDate, 1, 4) AS INTEGER) - 1"))
            OR \(yearOverlap("CAST(substr(\(eventAlias).startDate, 1, 4) AS INTEGER) + 1"))
        )
        """
    }

    private func birthdayPersonExistsSQL(personId: Int) -> String {
        let dateOverlapSQL = birthdayPersonDateOverlapSQL(eventAlias: "e", personAlias: "p")
        return """
        AND EXISTS (
            SELECT 1
            FROM people p
            WHERE p.personId = \(personId)
              AND p.birthDate IS NOT NULL
              AND TRIM(p.birthDate) != ''
              AND length(p.birthDate) >= 10
              AND \(dateOverlapSQL)
              AND (
                  EXISTS (
                      SELECT 1
                      FROM photo_events pe_b
                      JOIN photo_people pp ON pp.photoId = pe_b.photoId
                      JOIN photos ph_b ON ph_b.id = pp.photoId AND ph_b.isDeleted = 0
                      WHERE pp.personId = p.personId
                        AND (
                            pe_b.eventId = e.eventId
                            OR pe_b.eventId IN (
                                SELECT child.eventId
                                FROM events child
                                WHERE child.parentEventId = e.eventId
                                  AND child.isDeleted = 0
                            )
                        )
                  )
                  OR EXISTS (
                      SELECT 1
                      FROM event_tags et_main
                      WHERE et_main.eventId = e.eventId
                        AND et_main.isRejected = 0
                        AND et_main.tagCategory IN ('eventMainPerson', 'eventMainPerson2')
                        AND TRIM(et_main.tagValue) = p.displayName
                  )
              )
        )
        """
    }

    func eventMatchesListFilterUnsafe(eventId: Int, filter: EventListFilter) -> Bool {
        let listFilter = listFilterWhereSQL(filter: filter)
        let scopeFilter = listScopeFilterSQL(filter: filter)

        let sql = """
        SELECT 1
        FROM events e
        LEFT JOIN photo_events pe
            ON e.eventId = pe.eventId
            OR pe.eventId IN (
                SELECT child.eventId
                FROM events child
                WHERE child.parentEventId = e.eventId
                  AND child.isDeleted = 0
            )
        LEFT JOIN photos ph ON pe.photoId = ph.id
        WHERE e.eventId = ?
          AND e.isDeleted = 0
          \(scopeFilter)
          \(listFilter)
        GROUP BY e.eventId
        HAVING COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 THEN pe.photoId END) > 0
        LIMIT 1;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            let matches = sqlite3_step(statement) == SQLITE_ROW
            sqlite3_finalize(statement)
            return matches
        }

        sqlite3_finalize(statement)
        return false
    }

    private func listScopeFilterSQL(filter: EventListFilter) -> String {
        switch filter {
        case .allEvents, .anyHoliday, .holidayTag, .anyMilestone, .milestoneTag, .milestoneTags,
             .trips, .anyActivity, .activityTag, .eventTypeTag, .eventTypeTags,
             .birthdayPerson, .location:
            return "AND e.parentEventId IS NULL"
        }
    }

    private func escapeSQLLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()
}
