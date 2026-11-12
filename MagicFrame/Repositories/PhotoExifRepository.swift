import Foundation
import SQLite3

struct PhotoExifRecord: Sendable {
    var dateTimeOriginal: String? = nil
    var dateTimeDigitized: String? = nil
    var gpsTimestamp: String? = nil
    var imageUniqueId: String? = nil
    var cameraMake: String? = nil
    var cameraModel: String? = nil
    var lensModel: String? = nil
    /// `read`, `notLocal`, or `noHeader`.
    var status: String
}

final class PhotoExifRepository {

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    private var db: OpaquePointer? { database.connection }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if database.isOnQueue { return try work() }
        return try database.sync(work)
    }

    func fetchPhotoIdsNeedingExif() -> [String] {
        sync { fetchPhotoIdsNeedingExifUnsafe() }
    }

    func upsert(photoId: String, record: PhotoExifRecord, indexedAt: String) {
        sync {
            upsertUnsafe(photoId: photoId, record: record, indexedAt: indexedAt)
        }
    }

    private func fetchPhotoIdsNeedingExifUnsafe() -> [String] {
        let sql = """
        SELECT p.id
        FROM photos p
        LEFT JOIN photo_exif e ON e.photoId = p.id
        WHERE p.isDeleted = 0
          AND (e.photoId IS NULL OR e.status = 'notLocal')
        ORDER BY p.creationDate ASC;
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

    private func upsertUnsafe(photoId: String, record: PhotoExifRecord, indexedAt: String) {
        let sql = """
        INSERT INTO photo_exif (
            photoId, dateTimeOriginal, dateTimeDigitized, gpsTimestamp, imageUniqueId,
            cameraMake, cameraModel, lensModel, status, indexedAt
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(photoId) DO UPDATE SET
            dateTimeOriginal = excluded.dateTimeOriginal,
            dateTimeDigitized = excluded.dateTimeDigitized,
            gpsTimestamp = excluded.gpsTimestamp,
            imageUniqueId = excluded.imageUniqueId,
            cameraMake = excluded.cameraMake,
            cameraModel = excluded.cameraModel,
            lensModel = excluded.lensModel,
            status = excluded.status,
            indexedAt = excluded.indexedAt;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        bindOptionalText(statement, index: 2, value: record.dateTimeOriginal)
        bindOptionalText(statement, index: 3, value: record.dateTimeDigitized)
        bindOptionalText(statement, index: 4, value: record.gpsTimestamp)
        bindOptionalText(statement, index: 5, value: record.imageUniqueId)
        bindOptionalText(statement, index: 6, value: record.cameraMake)
        bindOptionalText(statement, index: 7, value: record.cameraModel)
        bindOptionalText(statement, index: 8, value: record.lensModel)
        sqlite3_bind_text(statement, 9, (record.status as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 10, (indexedAt as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func bindOptionalText(_ statement: OpaquePointer?, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}
