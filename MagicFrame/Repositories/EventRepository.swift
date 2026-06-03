import Foundation
import SQLite3

/// SQLite access for `events`, `photo_events`, and `event_people`.
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
        locationId: Int?
    ) -> Int {
        let sql = """
        INSERT INTO events
        (
            name, startDate, endDate, latitude, longitude,
            city, state, placeName, locationId,
            isDeleted, deletedAt, updatedAt, photoCount
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, 0);
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

            sqlite3_bind_text(statement, 10, (now as NSString).utf8String, -1, nil)

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

            coverPhotoId =
                String(
                    cString:
                        sqlite3_column_text(statement, 0)
                )
        }
    }

    sqlite3_finalize(statement)

    guard let coverPhotoId = coverPhotoId else {
        clearCoverPhotoForEvent(eventId: eventId)
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
        // debugEventPeopleCount omitted
    } else {
        print("Failed to rebuild event people: \(String(cString: sqlite3_errmsg(db)))")
    }
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

    let column = field.sqlColumn
    let sql = """
    SELECT DISTINCT \(column)
    FROM events
    WHERE isDeleted = 0
      AND \(column) IS NOT NULL
      AND TRIM(\(column)) != '';
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqliteOptionalText(statement, column: 0) {
                options.insert(value)
            }
        }
    }

    sqlite3_finalize(statement)

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
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    let storedValue = (trimmed?.isEmpty ?? true) ? nil : trimmed
    let now = ISO8601DateFormatter().string(from: Date())
    let column = field.sqlColumn

    let sql = """
    UPDATE events
    SET \(column) = ?,
        updatedAt = ?
    WHERE eventId = ?;
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        bindOptionalText(storedValue, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 3, Int32(eventId))

        if sqlite3_step(statement) != SQLITE_DONE {
            print("Failed to update \(column): \(String(cString: sqlite3_errmsg(db)))")
        }
    } else {
        print("Failed to prepare update \(column): \(String(cString: sqlite3_errmsg(db)))")
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
        COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 THEN pe.photoId END) as photoCount,
        GROUP_CONCAT(DISTINCT p.name) as peopleNames,
        e.showAsSlideshowEvent,
        e.userEditedName,
        l.nickname as locationNickname,
        e.locationId,
        e.parentEventId,
        e.isTripEvent,
        e.eventType,
        e.activityType,
        e.milestoneType,
        e.holidayType,
        e.eventMainPerson,
        e.tripType,
        e.childEventName,
        COALESCE(e.userEditedChildEventName, 0) as userEditedChildEventName,
        COALESCE(e.isUserHidden, 0) as isUserHidden
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
        e.eventType,
        e.activityType,
        e.milestoneType,
        e.holidayType,
        e.eventMainPerson,
        e.tripType,
        e.childEventName,
        e.userEditedChildEventName,
        e.isUserHidden
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
        getEventsUnsafe(includeHidden: includeHidden)
    }
    }


    func getEventsUnsafe(includeHidden: Bool) -> [IndexedEvent] {
        let hiddenFilter = includeHidden
            ? "AND COALESCE(e.isUserHidden, 0) = 1"
            : "AND COALESCE(e.isUserHidden, 0) = 0"
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
        GROUP_CONCAT(DISTINCT p.name) as peopleNames,
        e.showAsSlideshowEvent,
        e.userEditedName,
        l.nickname as locationNickname,
        e.locationId,
        e.parentEventId,
        e.isTripEvent,
        e.eventType,
        e.activityType,
        e.milestoneType,
        e.holidayType,
        e.eventMainPerson,
        e.tripType,
        e.childEventName,
        COALESCE(e.userEditedChildEventName, 0) as userEditedChildEventName,
        COALESCE(e.isUserHidden, 0) as isUserHidden
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
    LEFT JOIN event_people ep
        ON e.eventId = ep.eventId
    LEFT JOIN people p
        ON ep.personId = p.personId
    WHERE e.isDeleted = 0
      \(hiddenFilter)
      AND e.parentEventId IS NULL
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
        e.eventType,
        e.activityType,
        e.milestoneType,
        e.holidayType,
        e.eventMainPerson,
        e.tripType,
        e.childEventName,
        e.userEditedChildEventName,
        e.isUserHidden
    HAVING COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 THEN pe.photoId END) > 0
    ORDER BY e.startDate DESC;
    """

    var statement: OpaquePointer?
    var events: [IndexedEvent] = []

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
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
        COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 THEN pe.photoId END) as photoCount,
        GROUP_CONCAT(DISTINCT p.name) as peopleNames,
        e.showAsSlideshowEvent,
        e.userEditedName,
        l.nickname as locationNickname,
        e.locationId,
        e.parentEventId,
        e.isTripEvent,
        e.eventType,
        e.activityType,
        e.milestoneType,
        e.holidayType,
        e.eventMainPerson,
        e.tripType,
        e.childEventName,
        COALESCE(e.userEditedChildEventName, 0) as userEditedChildEventName,
        COALESCE(e.isUserHidden, 0) as isUserHidden
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
    LEFT JOIN event_people ep
        ON e.eventId = ep.eventId
    LEFT JOIN people p
        ON ep.personId = p.personId
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
        e.eventType,
        e.activityType,
        e.milestoneType,
        e.holidayType,
        e.eventMainPerson,
        e.tripType,
        e.childEventName,
        e.userEditedChildEventName,
        e.isUserHidden;
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

    let eventType = sqliteOptionalText(statement, column: 18)
    let activityType = sqliteOptionalText(statement, column: 19)
    let milestoneType = sqliteOptionalText(statement, column: 20)
    let holidayType = sqliteOptionalText(statement, column: 21)
    let eventMainPerson = sqliteOptionalText(statement, column: 22)
    let tripType = sqliteOptionalText(statement, column: 23)
    let childEventName = sqliteOptionalText(statement, column: 24)
    let userEditedChildEventName = sqlite3_column_int(statement, 25) == 1
    let isUserHidden = sqlite3_column_int(statement, 26) == 1

    return IndexedEvent(
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
        showOnFrame: showOnFrame,
        userEditedName: userEditedName,
        locationNickname: locationNickname,
        locationId: locationId,
        parentEventId: parentEventId,
        isTripEvent: isTripEvent,
        eventType: eventType,
        activityType: activityType,
        milestoneType: milestoneType,
        holidayType: holidayType,
        eventMainPerson: eventMainPerson,
        tripType: tripType,
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

    func getSlideshowPhotoIdsByEvent(eventIds: [Int]) -> [Int: [String]] {
    guard !eventIds.isEmpty else { return [:] }

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
      AND COALESCE(pe.includeInSlideshow, 0) = 1
      AND COALESCE(pe.manuallyExcluded, 0) = 0
      AND e.isDeleted = 0
      AND COALESCE(e.parentEventId, e.eventId) IN (\(placeholders))
    GROUP BY displayEventId, p.id, p.isFavorite, p.qualityScore
    """

    var statement: OpaquePointer?
    var grouped: [Int: [SlideshowPhotoCandidate]] = [:]

    if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
        for (index, eventId) in eventIds.enumerated() {
            sqlite3_bind_int(statement, Int32(index + 1), Int32(eventId))
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            let displayEventId = Int(sqlite3_column_int(statement, 0))
            let photoId = String(cString: sqlite3_column_text(statement, 1))
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
    } else {
        print("Failed to get slideshow photos: \(String(cString: sqlite3_errmsg(db)))")
    }

    sqlite3_finalize(statement)

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
    rebuildEventPeople()
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
           COALESCE(pe.isSimilarGroupPick, 0) as isSimilarGroupPick
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
            updateEventSummary(eventId: parentId)
            updateCoverPhotoForEvent(eventId: parentId)
            refreshed.insert(parentId)
        }
    }

    rebuildEventPeople()
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
            isSimilarGroupPick: isSimilarGroupPick
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
        COUNT(DISTINCT CASE WHEN ph.isDeleted = 0 THEN pe.photoId END) as photoCount,
        GROUP_CONCAT(DISTINCT p.name) as peopleNames,
        e.showAsSlideshowEvent,
        e.userEditedName,
        l.nickname as locationNickname,
        e.locationId,
        e.parentEventId,
        e.isTripEvent,
        e.eventType,
        e.activityType,
        e.milestoneType,
        e.holidayType,
        e.eventMainPerson,
        e.tripType,
        e.childEventName,
        COALESCE(e.userEditedChildEventName, 0) as userEditedChildEventName,
        COALESCE(e.isUserHidden, 0) as isUserHidden
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
        e.eventType,
        e.activityType,
        e.milestoneType,
        e.holidayType,
        e.eventMainPerson,
        e.tripType,
        e.childEventName,
        e.userEditedChildEventName,
        e.isUserHidden
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


    func attachPhotoToEvent(photoId: String, eventId: Int) {
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
            let id = String(cString: sqlite3_column_text(statement, 0))
            let dateString = String(cString: sqlite3_column_text(statement, 1))

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


    func markPhotoEventAssigned(photoId: String) {
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


    func updateEventSummary(eventId: Int) {
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


    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()
}
