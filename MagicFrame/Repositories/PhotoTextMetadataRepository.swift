import Foundation
import SQLite3

/// SQLite access for `photo_text_metadata`.
final class PhotoTextMetadataRepository {

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
        originalFilename: String?,
        assetTitle: String?,
        assetDescription: String?,
        metadataSource: String,
        indexedAt: String
    ) {
        sync {
            upsertUnsafe(
                photoId: photoId,
                originalFilename: originalFilename,
                assetTitle: assetTitle,
                assetDescription: assetDescription,
                metadataSource: metadataSource,
                indexedAt: indexedAt
            )
        }
    }

    func countRows() -> Int {
        sync { countRowsUnsafe("photo_text_metadata") }
    }

    func fetchActivePhotoIdsMissingTextMetadata() -> [String] {
        sync { fetchActivePhotoIdsMissingTextMetadataUnsafe() }
    }

    // MARK: - Unsafe

    func upsertUnsafe(
        photoId: String,
        originalFilename: String?,
        assetTitle: String?,
        assetDescription: String?,
        metadataSource: String,
        indexedAt: String
    ) {
        let sql = """
        INSERT INTO photo_text_metadata (
            photoId, originalFilename, assetTitle, assetDescription,
            keywordsJson, metadataSource, metadataVersion, indexedAt
        )
        VALUES (?, ?, ?, ?, NULL, ?, 1, ?)
        ON CONFLICT(photoId) DO UPDATE SET
            originalFilename = excluded.originalFilename,
            assetTitle = excluded.assetTitle,
            assetDescription = excluded.assetDescription,
            metadataSource = excluded.metadataSource,
            indexedAt = excluded.indexedAt;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
            bindOptionalText(statement, index: 2, value: originalFilename)
            bindOptionalText(statement, index: 3, value: assetTitle)
            bindOptionalText(statement, index: 4, value: assetDescription)
            sqlite3_bind_text(statement, 5, (metadataSource as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 6, (indexedAt as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    private func fetchActivePhotoIdsMissingTextMetadataUnsafe() -> [String] {
        let sql = """
        SELECT p.id
        FROM photos p
        LEFT JOIN photo_text_metadata m ON m.photoId = p.id
        WHERE p.isDeleted = 0
          AND m.photoId IS NULL
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

    private func countRowsUnsafe(_ tableOrQuery: String) -> Int {
        let sql = "SELECT COUNT(*) FROM \(tableOrQuery);"
        var statement: OpaquePointer?
        var count = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = Int(sqlite3_column_int(statement, 0))
        }

        sqlite3_finalize(statement)
        return count
    }

    private func bindOptionalText(_ statement: OpaquePointer?, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}
