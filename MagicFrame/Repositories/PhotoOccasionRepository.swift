import Foundation
import SQLite3

/// Per-occasion photo links and on-frame flags (`photo_occasion`, `occasion_subjects`).
final class PhotoOccasionRepository {

    static let legacyBackfillMetadataKey = "photoOccasionLegacyBackfillVersion"
    static let legacyBackfillMetadataValue = "1"

    private let database: DatabaseManager
    private let metadata: AppMetadataStore

    init(database: DatabaseManager, metadata: AppMetadataStore) {
        self.database = database
        self.metadata = metadata
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

    private static let iso8601Now: () -> String = {
        ISO8601DateFormatter().string(from: Date())
    }

    /// One-time: copies on-frame slideshow picks + holiday event tags into `photo_occasion`.
    func backfillFromLegacyOnFrameIfNeeded() -> PhotoOccasionBackfillResult {
        sync {
            backfillFromLegacyOnFrameIfNeededUnsafe()
        }
    }

    func backfillFromLegacyOnFrameIfNeededUnsafe() -> PhotoOccasionBackfillResult {
        if metadata.get(key: Self.legacyBackfillMetadataKey) == Self.legacyBackfillMetadataValue {
            return .skipped
        }

        let now = Self.iso8601Now()
        let sql = """
        INSERT INTO photo_occasion (
            photoId, occasionId, source, personId, isOnFrame,
            isRejected, createdAt, updatedAt
        )
        SELECT DISTINCT
            source_rows.photoId,
            source_rows.occasionId,
            'event_inherit',
            NULL,
            1,
            0,
            ?,
            ?
        FROM (
            SELECT
                pe.photoId,
                resolved.occasionId
            FROM photo_events pe
            JOIN photos p
                ON p.id = pe.photoId
               AND p.isDeleted = 0
            JOIN events e
                ON e.eventId = pe.eventId
               AND e.isDeleted = 0
            JOIN event_tags ht
                ON ht.tagCategory = 'holiday'
               AND ht.isRejected = 0
            JOIN (
                SELECT
                    ht2.eventTagId,
                    COALESCE(
                        NULLIF(ht2.occasionId, 0),
                        (
                            SELECT o.occasionId
                            FROM occasions o
                            WHERE lower(o.occasionKey) = lower(trim(ht2.tagValue))
                            LIMIT 1
                        ),
                        (
                            SELECT o.occasionId
                            FROM occasions o
                            WHERE o.name = trim(ht2.tagValue) COLLATE NOCASE
                            LIMIT 1
                        )
                    ) AS occasionId
                FROM event_tags ht2
                WHERE ht2.tagCategory = 'holiday'
                  AND ht2.isRejected = 0
            ) resolved
                ON resolved.eventTagId = ht.eventTagId
               AND resolved.occasionId IS NOT NULL
            WHERE COALESCE(pe.includeInSlideshow, 0) = 1
              AND (
                  ht.eventId = pe.eventId
                  OR (
                      e.parentEventId IS NOT NULL
                      AND ht.eventId = e.parentEventId
                  )
                  OR EXISTS (
                      SELECT 1
                      FROM events child
                      WHERE child.parentEventId = pe.eventId
                        AND child.isDeleted = 0
                        AND child.eventId = ht.eventId
                  )
              )

            UNION

            SELECT
                pe.photoId,
                resolved.occasionId
            FROM photo_events pe
            JOIN photos p
                ON p.id = pe.photoId
               AND p.isDeleted = 0
            JOIN events e
                ON e.eventId = pe.eventId
               AND e.isDeleted = 0
            JOIN (
                SELECT
                    e2.eventId,
                    COALESCE(
                        (
                            SELECT o.occasionId
                            FROM occasions o
                            WHERE lower(o.occasionKey) = lower(trim(e2.holidayType))
                            LIMIT 1
                        ),
                        (
                            SELECT o.occasionId
                            FROM occasions o
                            WHERE o.name = trim(e2.holidayType) COLLATE NOCASE
                            LIMIT 1
                        )
                    ) AS occasionId
                FROM events e2
                WHERE e2.isDeleted = 0
                  AND e2.holidayType IS NOT NULL
                  AND trim(e2.holidayType) != ''
            ) resolved
                ON resolved.eventId = e.eventId
               AND resolved.occasionId IS NOT NULL
            WHERE COALESCE(pe.includeInSlideshow, 0) = 1
              AND (
                  e.eventId = resolved.eventId
                  OR (
                      e.parentEventId IS NOT NULL
                      AND e.parentEventId = resolved.eventId
                  )
                  OR EXISTS (
                      SELECT 1
                      FROM events child
                      WHERE child.parentEventId = e.eventId
                        AND child.isDeleted = 0
                        AND child.eventId = resolved.eventId
                  )
              )
        ) source_rows
        ON CONFLICT(photoId, occasionId) DO UPDATE SET
            isOnFrame = CASE
                WHEN excluded.isOnFrame = 1 THEN 1
                ELSE photo_occasion.isOnFrame
            END,
            source = CASE
                WHEN photo_occasion.source = 'user' THEN photo_occasion.source
                ELSE excluded.source
            END,
            isRejected = 0,
            updatedAt = excluded.updatedAt;
        """

        var statement: OpaquePointer?
        var rowsUpserted = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_DONE {
                rowsUpserted = Int(sqlite3_changes(db))
            } else if let db {
                print(
                    "Photo occasion legacy backfill failed:"
                        + " \(String(cString: sqlite3_errmsg(db)))"
                )
            }
        }

        sqlite3_finalize(statement)

        metadata.set(
            key: Self.legacyBackfillMetadataKey,
            value: Self.legacyBackfillMetadataValue
        )

        print(
            "Photo occasion legacy backfill complete:"
                + " \(rowsUpserted.formatted()) row(s) upserted"
        )

        return PhotoOccasionBackfillResult(didRun: true, rowsUpserted: rowsUpserted)
    }

    // MARK: - Photo ↔ occasion

    func linkPhotoToOccasion(
        photoId: String,
        occasionId: Int,
        source: PhotoOccasionSource,
        personId: Int? = nil,
        isOnFrame: Bool = false
    ) {
        sync {
            linkPhotoToOccasionUnsafe(
                photoId: photoId,
                occasionId: occasionId,
                source: source,
                personId: personId,
                isOnFrame: isOnFrame
            )
        }
    }

    func linkPhotoToOccasionUnsafe(
        photoId: String,
        occasionId: Int,
        source: PhotoOccasionSource,
        personId: Int? = nil,
        isOnFrame: Bool = false
    ) {
        let now = Self.iso8601Now()
        let sql = """
        INSERT INTO photo_occasion (
            photoId, occasionId, source, personId, isOnFrame,
            isRejected, createdAt, updatedAt
        )
        VALUES (?, ?, ?, ?, ?, 0, ?, ?)
        ON CONFLICT(photoId, occasionId) DO UPDATE SET
            source = CASE
                WHEN photo_occasion.source = 'user' THEN photo_occasion.source
                ELSE excluded.source
            END,
            personId = COALESCE(excluded.personId, photo_occasion.personId),
            isOnFrame = CASE
                WHEN excluded.isOnFrame = 1 THEN 1
                ELSE photo_occasion.isOnFrame
            END,
            isRejected = 0,
            updatedAt = excluded.updatedAt;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(occasionId))
        sqlite3_bind_text(statement, 3, (source.rawValue as NSString).utf8String, -1, nil)

        if let personId, personId > 0 {
            sqlite3_bind_int(statement, 4, Int32(personId))
        } else {
            sqlite3_bind_null(statement, 4)
        }

        sqlite3_bind_int(statement, 5, isOnFrame ? 1 : 0)
        sqlite3_bind_text(statement, 6, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (now as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    func setPhotoOccasionOnFrame(photoId: String, occasionId: Int, isOnFrame: Bool) {
        sync {
            setPhotoOccasionOnFrameUnsafe(
                photoId: photoId,
                occasionId: occasionId,
                isOnFrame: isOnFrame
            )
        }
    }

    func photoOccasionSourceUnsafe(photoId: String, occasionId: Int) -> PhotoOccasionSource? {
        let sql = """
        SELECT source
        FROM photo_occasion
        WHERE photoId = ?
          AND occasionId = ?
          AND isRejected = 0
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var source: PhotoOccasionSource?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(occasionId))
            if sqlite3_step(statement) == SQLITE_ROW,
               let raw = sqlite3_column_text(statement, 0) {
                source = PhotoOccasionSource(rawValue: String(cString: raw))
            }
        }

        sqlite3_finalize(statement)
        return source
    }

    func isPhotoOnFrameForOccasionUnsafe(photoId: String, occasionId: Int) -> Bool {
        let sql = """
        SELECT isOnFrame
        FROM photo_occasion
        WHERE photoId = ?
          AND occasionId = ?
          AND isRejected = 0
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var isOnFrame = false

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(occasionId))
            if sqlite3_step(statement) == SQLITE_ROW {
                isOnFrame = sqlite3_column_int(statement, 0) != 0
            }
        }

        sqlite3_finalize(statement)
        return isOnFrame
    }

    func setPhotoOccasionOnFrameUnsafe(
        photoId: String,
        occasionId: Int,
        isOnFrame: Bool
    ) {
        let now = Self.iso8601Now()
        let sql = """
        UPDATE photo_occasion
        SET isOnFrame = ?, updatedAt = ?
        WHERE photoId = ?
          AND occasionId = ?
          AND isRejected = 0;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_int(statement, 1, isOnFrame ? 1 : 0)
        sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (photoId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 4, Int32(occasionId))
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    func setPhotosOccasionOnFrame(
        photoIds: [String],
        occasionId: Int,
        isOnFrame: Bool
    ) {
        sync {
            for photoId in photoIds {
                setPhotoOccasionOnFrameUnsafe(
                    photoId: photoId,
                    occasionId: occasionId,
                    isOnFrame: isOnFrame
                )
            }
        }
    }

    func rejectPhotoOccasion(photoId: String, occasionId: Int) {
        sync {
            rejectPhotoOccasionUnsafe(photoId: photoId, occasionId: occasionId)
        }
    }

    func rejectPhotoOccasionUnsafe(photoId: String, occasionId: Int) {
        let now = Self.iso8601Now()
        let sql = """
        UPDATE photo_occasion
        SET isRejected = 1, isOnFrame = 0, updatedAt = ?
        WHERE photoId = ?
          AND occasionId = ?;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_text(statement, 1, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (photoId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 3, Int32(occasionId))
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    func fetchOnFramePhotoIds(occasionId: Int) -> [String] {
        sync { fetchOnFramePhotoIdsUnsafe(occasionId: occasionId) }
    }

    func fetchOnFramePhotoIdsUnsafe(occasionId: Int) -> [String] {
        let sql = """
        SELECT photoId
        FROM photo_occasion
        WHERE occasionId = ?
          AND isOnFrame = 1
          AND isRejected = 0
        ORDER BY updatedAt DESC, photoId ASC;
        """

        var statement: OpaquePointer?
        var photoIds: [String] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(occasionId))

            while sqlite3_step(statement) == SQLITE_ROW {
                photoIds.append(String(cString: sqlite3_column_text(statement, 0)))
            }
        }

        sqlite3_finalize(statement)
        return photoIds
    }

    func countOnFramePhotos(occasionId: Int) -> Int {
        sync { countOnFramePhotosUnsafe(occasionId: occasionId) }
    }

    func countOnFramePhotosUnsafe(occasionId: Int) -> Int {
        let sql = """
        SELECT COUNT(*)
        FROM photo_occasion
        WHERE occasionId = ?
          AND isOnFrame = 1
          AND isRejected = 0;
        """

        var statement: OpaquePointer?
        var count = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(occasionId))
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        }

        sqlite3_finalize(statement)
        return count
    }

    func fetchPhotoOccasions(photoId: String) -> [PhotoOccasionLink] {
        sync { fetchPhotoOccasionsUnsafe(photoId: photoId) }
    }

    func fetchPhotoOccasionsUnsafe(photoId: String) -> [PhotoOccasionLink] {
        let sql = """
        SELECT
            po.photoOccasionId,
            po.photoId,
            po.occasionId,
            o.occasionKey,
            po.source,
            po.personId,
            po.isOnFrame,
            po.isRejected
        FROM photo_occasion po
        JOIN occasions o ON o.occasionId = po.occasionId
        WHERE po.photoId = ?
          AND po.isRejected = 0
        ORDER BY o.name ASC;
        """

        var statement: OpaquePointer?
        var links: [PhotoOccasionLink] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)

            while sqlite3_step(statement) == SQLITE_ROW {
                if let link = readPhotoOccasionLink(from: statement) {
                    links.append(link)
                }
            }
        }

        sqlite3_finalize(statement)
        return links
    }

    func occasionId(forKey occasionKey: String) -> Int? {
        sync { occasionIdUnsafe(occasionKey: occasionKey) }
    }

    func occasionIdUnsafe(occasionKey: String) -> Int? {
        let sql = """
        SELECT occasionId
        FROM occasions
        WHERE occasionKey = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var occasionId: Int?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (occasionKey as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                occasionId = Int(sqlite3_column_int(statement, 0))
            }
        }

        sqlite3_finalize(statement)
        return occasionId
    }

    // MARK: - People discovery (Mother's Day wizard)

    func searchPhotosWithPeople(
        requiredPersonId: Int,
        includingAnyOfPersonIds childPersonIds: [Int],
        exactPeopleOnly: Bool
    ) -> [String] {
        sync {
            searchPhotosWithPeopleUnsafe(
                requiredPersonId: requiredPersonId,
                includingAnyOfPersonIds: childPersonIds,
                exactPeopleOnly: exactPeopleOnly
            )
        }
    }

    func searchPhotosWithPeopleUnsafe(
        requiredPersonId: Int,
        includingAnyOfPersonIds childPersonIds: [Int],
        exactPeopleOnly: Bool
    ) -> [String] {
        guard requiredPersonId > 0, !childPersonIds.isEmpty else { return [] }

        let allowedPeople = [requiredPersonId] + childPersonIds
        let allowedPlaceholders = Array(repeating: "?", count: allowedPeople.count).joined(separator: ", ")
        let childPlaceholders = Array(repeating: "?", count: childPersonIds.count).joined(separator: ", ")

        var sql = """
        SELECT DISTINCT p.id
        FROM photos p
        WHERE p.isDeleted = 0
          AND EXISTS (
              SELECT 1
              FROM photo_people pp
              WHERE pp.photoId = p.id
                AND pp.personId = ?
          )
          AND EXISTS (
              SELECT 1
              FROM photo_people pp
              WHERE pp.photoId = p.id
                AND pp.personId IN (\(childPlaceholders))
          )
        """

        if exactPeopleOnly {
            sql += """


              AND NOT EXISTS (
                  SELECT 1
                  FROM photo_people pp
                  WHERE pp.photoId = p.id
                    AND pp.personId NOT IN (\(allowedPlaceholders))
              )
            """
        }

        sql += "\nORDER BY p.creationDate DESC, p.id ASC;"

        var statement: OpaquePointer?
        var photoIds: [String] = []

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        var bindIndex: Int32 = 1
        sqlite3_bind_int(statement, bindIndex, Int32(requiredPersonId))
        bindIndex += 1

        for childId in childPersonIds {
            sqlite3_bind_int(statement, bindIndex, Int32(childId))
            bindIndex += 1
        }

        if exactPeopleOnly {
            for personId in allowedPeople {
                sqlite3_bind_int(statement, bindIndex, Int32(personId))
                bindIndex += 1
            }
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            photoIds.append(String(cString: sqlite3_column_text(statement, 0)))
        }

        sqlite3_finalize(statement)
        return photoIds
    }

    func searchPhotosWithPerson(personId: Int, exactPeopleOnly: Bool) -> [String] {
        sync {
            searchPhotosWithPersonUnsafe(personId: personId, exactPeopleOnly: exactPeopleOnly)
        }
    }

    func searchPhotosWithPersonUnsafe(personId: Int, exactPeopleOnly: Bool) -> [String] {
        guard personId > 0 else { return [] }

        var sql = """
        SELECT DISTINCT p.id
        FROM photos p
        WHERE p.isDeleted = 0
          AND EXISTS (
              SELECT 1
              FROM photo_people pp
              WHERE pp.photoId = p.id
                AND pp.personId = ?
          )
        """

        if exactPeopleOnly {
            sql += """


              AND NOT EXISTS (
                  SELECT 1
                  FROM photo_people pp
                  WHERE pp.photoId = p.id
                    AND pp.personId != ?
              )
            """
        }

        sql += "\nORDER BY p.creationDate DESC, p.id ASC;"

        var statement: OpaquePointer?
        var photoIds: [String] = []

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        sqlite3_bind_int(statement, 1, Int32(personId))
        if exactPeopleOnly {
            sqlite3_bind_int(statement, 2, Int32(personId))
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            photoIds.append(String(cString: sqlite3_column_text(statement, 0)))
        }

        sqlite3_finalize(statement)
        return photoIds
    }

    // MARK: - Occasion subjects (Mom + children config)

    func saveOccasionSubjects(
        occasionId: Int,
        subjects: [(personId: Int, role: OccasionSubjectRole)]
    ) {
        sync {
            saveOccasionSubjectsUnsafe(occasionId: occasionId, subjects: subjects)
        }
    }

    func saveOccasionSubjectsUnsafe(
        occasionId: Int,
        subjects: [(personId: Int, role: OccasionSubjectRole)]
    ) {
        let deleteSQL = "DELETE FROM occasion_subjects WHERE occasionId = ?;"
        var deleteStatement: OpaquePointer?

        if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(deleteStatement, 1, Int32(occasionId))
            sqlite3_step(deleteStatement)
        }

        sqlite3_finalize(deleteStatement)

        let insertSQL = """
        INSERT INTO occasion_subjects (occasionId, personId, role)
        VALUES (?, ?, ?);
        """

        for subject in subjects where subject.personId > 0 {
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(occasionId))
                sqlite3_bind_int(statement, 2, Int32(subject.personId))
                sqlite3_bind_text(
                    statement,
                    3,
                    (subject.role.rawValue as NSString).utf8String,
                    -1,
                    nil
                )
                sqlite3_step(statement)
            }

            sqlite3_finalize(statement)
        }
    }

    func fetchOccasionSubjects(occasionId: Int) -> [OccasionSubject] {
        sync { fetchOccasionSubjectsUnsafe(occasionId: occasionId) }
    }

    func fetchOccasionSubjectsUnsafe(occasionId: Int) -> [OccasionSubject] {
        let sql = """
        SELECT
            os.occasionSubjectId,
            os.occasionId,
            os.personId,
            p.name,
            os.role
        FROM occasion_subjects os
        JOIN people p ON p.personId = os.personId
        WHERE os.occasionId = ?
        ORDER BY
            CASE os.role
                WHEN 'mother' THEN 0
                WHEN 'father' THEN 0
                WHEN 'child' THEN 1
                ELSE 2
            END,
            p.name ASC;
        """

        var statement: OpaquePointer?
        var subjects: [OccasionSubject] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(occasionId))

            while sqlite3_step(statement) == SQLITE_ROW {
                let subjectId = Int(sqlite3_column_int(statement, 0))
                let occasion = Int(sqlite3_column_int(statement, 1))
                let personId = Int(sqlite3_column_int(statement, 2))
                let personName = sqlite3_column_type(statement, 3) != SQLITE_NULL
                    ? String(cString: sqlite3_column_text(statement, 3))
                    : nil
                let roleRaw = String(cString: sqlite3_column_text(statement, 4))
                let role = OccasionSubjectRole(rawValue: roleRaw) ?? .person

                subjects.append(
                    OccasionSubject(
                        occasionSubjectId: subjectId,
                        occasionId: occasion,
                        personId: personId,
                        personName: personName,
                        role: role
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return subjects
    }

    // MARK: - Readers

    private func readPhotoOccasionLink(from statement: OpaquePointer?) -> PhotoOccasionLink? {
        let photoOccasionId = Int(sqlite3_column_int(statement, 0))
        let photoId = String(cString: sqlite3_column_text(statement, 1))
        let occasionId = Int(sqlite3_column_int(statement, 2))
        let occasionKey = sqlite3_column_type(statement, 3) != SQLITE_NULL
            ? String(cString: sqlite3_column_text(statement, 3))
            : nil
        let sourceRaw = String(cString: sqlite3_column_text(statement, 4))
        let source = PhotoOccasionSource(rawValue: sourceRaw) ?? .user

        let personId: Int? =
            sqlite3_column_type(statement, 5) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int(statement, 5))

        let isOnFrame = sqlite3_column_int(statement, 6) == 1
        let isRejected = sqlite3_column_int(statement, 7) == 1

        return PhotoOccasionLink(
            photoOccasionId: photoOccasionId,
            photoId: photoId,
            occasionId: occasionId,
            occasionKey: occasionKey,
            source: source,
            personId: personId,
            isOnFrame: isOnFrame,
            isRejected: isRejected
        )
    }
}
