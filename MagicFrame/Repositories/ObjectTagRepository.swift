import Foundation
import SQLite3

final class ObjectTagRepository {

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    private var db: OpaquePointer? { database.connection }

    func upsertPhotoObjectTagsUnsafe(
        photoId: String,
        detections: [PhotoObjectDetection],
        source: String,
        createdAt: String
    ) {
        guard !detections.isEmpty else { return }

        let sql = """
        INSERT INTO photo_object_tags (photoId, objectKey, confidence, source, createdAt)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(photoId, objectKey) DO UPDATE SET
            confidence = MAX(photo_object_tags.confidence, excluded.confidence),
            source = excluded.source,
            createdAt = excluded.createdAt;
        """

        for detection in detections {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (detection.objectKey as NSString).utf8String, -1, nil)
                sqlite3_bind_double(statement, 3, detection.confidence)
                sqlite3_bind_text(statement, 4, (source as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 5, (createdAt as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }

    func rebuildEventObjectTagsUnsafe(eventId: Int, updatedAt: String) {
        let deleteSQL = "DELETE FROM event_object_tags WHERE eventId = ?;"
        var deleteStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(deleteStatement, 1, Int32(eventId))
            sqlite3_step(deleteStatement)
        }
        sqlite3_finalize(deleteStatement)

        let insertSQL = """
        INSERT INTO event_object_tags (eventId, objectKey, photoCount, maxConfidence, updatedAt)
        SELECT
            ?,
            pot.objectKey,
            COUNT(DISTINCT pot.photoId),
            MAX(pot.confidence),
            ?
        FROM photo_object_tags pot
        JOIN photo_events pe ON pe.photoId = pot.photoId
        WHERE pe.eventId = ?
           OR pe.eventId IN (
               SELECT child.eventId
               FROM events child
               WHERE child.parentEventId = ?
                 AND child.isDeleted = 0
           )
        GROUP BY pot.objectKey;
        """

        var insertStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(insertStatement, 1, Int32(eventId))
            sqlite3_bind_text(insertStatement, 2, (updatedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_int(insertStatement, 3, Int32(eventId))
            sqlite3_bind_int(insertStatement, 4, Int32(eventId))
            sqlite3_step(insertStatement)
        }
        sqlite3_finalize(insertStatement)
    }

    func isObjectRecognitionCompletedUnsafe(eventId: Int) -> Bool {
        let sql = """
        SELECT COALESCE(objectRecognitionCompleted, 0)
        FROM events
        WHERE eventId = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var completed = false

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if sqlite3_step(statement) == SQLITE_ROW {
                completed = sqlite3_column_int(statement, 0) != 0
            }
        }

        sqlite3_finalize(statement)
        return completed
    }

    func markPhotoVisionScannedUnsafe(
        photoId: String,
        algorithmVersion: Int,
        scannedAt: String
    ) {
        let sql = """
        INSERT INTO photo_vision_scans (photoId, algorithmVersion, scannedAt)
        VALUES (?, ?, ?)
        ON CONFLICT(photoId, algorithmVersion) DO UPDATE SET
            scannedAt = excluded.scannedAt;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(algorithmVersion))
            sqlite3_bind_text(statement, 3, (scannedAt as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func filterUnscannedPhotoIdsUnsafe(
        photoIds: [String],
        algorithmVersion: Int
    ) -> [String] {
        guard !photoIds.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: photoIds.count).joined(separator: ", ")
        let sql = """
        SELECT photoId
        FROM photo_vision_scans
        WHERE algorithmVersion = ?
          AND photoId IN (\(placeholders));
        """

        var statement: OpaquePointer?
        var scanned = Set<String>()

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(algorithmVersion))
            for (index, photoId) in photoIds.enumerated() {
                sqlite3_bind_text(
                    statement,
                    Int32(index + 2),
                    (photoId as NSString).utf8String,
                    -1,
                    nil
                )
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0) {
                    scanned.insert(String(cString: cString))
                }
            }
        }

        sqlite3_finalize(statement)
        return photoIds.filter { !scanned.contains($0) }
    }

    func clearPhotoVisionScansForEventsUnsafe(eventIds: [Int]) {
        guard !eventIds.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ", ")
        let sql = """
        DELETE FROM photo_vision_scans
        WHERE photoId IN (
            SELECT pe.photoId
            FROM photo_events pe
            WHERE pe.eventId IN (\(placeholders))
               OR pe.eventId IN (
                   SELECT child.eventId
                   FROM events child
                   WHERE child.parentEventId IN (\(placeholders))
                     AND child.isDeleted = 0
               )
        );
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_int(statement, Int32(index + 1), Int32(eventId))
            }
            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_int(statement, Int32(eventIds.count + index + 1), Int32(eventId))
            }
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func clearObjectDetectionsForEventsUnsafe(eventIds: [Int]) {
        guard !eventIds.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ", ")
        let photoScopeSQL = """
        SELECT pe.photoId
        FROM photo_events pe
        WHERE pe.eventId IN (\(placeholders))
           OR pe.eventId IN (
               SELECT child.eventId
               FROM events child
               WHERE child.parentEventId IN (\(placeholders))
                 AND child.isDeleted = 0
           )
        """

        let deletePhotoTagsSQL = """
        DELETE FROM photo_object_tags
        WHERE photoId IN (\(photoScopeSQL));
        """

        var photoTagsStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deletePhotoTagsSQL, -1, &photoTagsStatement, nil) == SQLITE_OK {
            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_int(photoTagsStatement, Int32(index + 1), Int32(eventId))
            }
            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_int(
                    photoTagsStatement,
                    Int32(eventIds.count + index + 1),
                    Int32(eventId)
                )
            }
            sqlite3_step(photoTagsStatement)
        }
        sqlite3_finalize(photoTagsStatement)

        let deleteEventTagsSQL = """
        DELETE FROM event_object_tags
        WHERE eventId IN (\(placeholders))
           OR eventId IN (
               SELECT child.eventId
               FROM events child
               WHERE child.parentEventId IN (\(placeholders))
                 AND child.isDeleted = 0
           );
        """

        var eventTagsStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteEventTagsSQL, -1, &eventTagsStatement, nil) == SQLITE_OK {
            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_int(eventTagsStatement, Int32(index + 1), Int32(eventId))
            }
            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_int(
                    eventTagsStatement,
                    Int32(eventIds.count + index + 1),
                    Int32(eventId)
                )
            }
            sqlite3_step(eventTagsStatement)
        }
        sqlite3_finalize(eventTagsStatement)
    }

    func objectRecognitionAlgorithmVersionUnsafe(eventId: Int) -> Int {
        let sql = """
        SELECT COALESCE(objectRecognitionAlgorithmVersion, 0)
        FROM events
        WHERE eventId = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var version = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if sqlite3_step(statement) == SQLITE_ROW {
                version = Int(sqlite3_column_int(statement, 0))
            }
        }

        sqlite3_finalize(statement)
        return version
    }
}
