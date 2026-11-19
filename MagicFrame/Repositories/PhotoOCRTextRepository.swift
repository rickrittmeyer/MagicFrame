import Foundation
import SQLite3

/// SQLite access for `photo_ocr_text` (Vision OCR strings found in photo pixels).
final class PhotoOCRTextRepository {

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
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

    func upsert(
        photoId: String,
        fullText: String,
        observationCount: Int,
        algorithmVersion: Int,
        indexedAt: String
    ) {
        sync {
            upsertUnsafe(
                photoId: photoId,
                fullText: fullText,
                observationCount: observationCount,
                algorithmVersion: algorithmVersion,
                indexedAt: indexedAt
            )
        }
    }

    func upsertUnsafe(
        photoId: String,
        fullText: String,
        observationCount: Int,
        algorithmVersion: Int,
        indexedAt: String
    ) {
        let sql = """
        INSERT INTO photo_ocr_text (
            photoId, fullText, observationCount, algorithmVersion, indexedAt
        )
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(photoId) DO UPDATE SET
            fullText = excluded.fullText,
            observationCount = excluded.observationCount,
            algorithmVersion = excluded.algorithmVersion,
            indexedAt = excluded.indexedAt;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let photoIdNS = photoId as NSString
            let fullTextNS = fullText as NSString
            let indexedAtNS = indexedAt as NSString
            sqlite3_bind_text(statement, 1, photoIdNS.utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, fullTextNS.utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(observationCount))
            sqlite3_bind_int(statement, 4, Int32(algorithmVersion))
            sqlite3_bind_text(statement, 5, indexedAtNS.utf8String, -1, nil)
            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to upsert photo OCR text: \(String(cString: sqlite3_errmsg(db)))")
            }
        } else if let db {
            print("photo_ocr_text upsert prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(statement)
    }

    func fetchFullTextUnsafe(photoId: String) -> String? {
        let sql = """
        SELECT fullText
        FROM photo_ocr_text
        WHERE photoId = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var text: String?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let photoIdNS = photoId as NSString
            sqlite3_bind_text(statement, 1, photoIdNS.utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW,
               let cString = sqlite3_column_text(statement, 0) {
                text = String(cString: cString)
            }
        }
        sqlite3_finalize(statement)
        return text
    }
}
