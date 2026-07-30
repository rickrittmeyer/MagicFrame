import Foundation
import SQLite3

/// SQLite access for `albums` and `photo_albums`.
final class AlbumRepository {

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

    func clearPhotoAlbumMemberships() {
        _ = sync {
            sqlite3_exec(db, "DELETE FROM photo_albums;", nil, nil, nil)
        }
    }

    func upsertAlbum(
        albumId: String,
        title: String,
        collectionType: String,
        collectionSubtype: String?,
        isPersonAlbum: Bool,
        personId: Int?,
        isHighCardinality: Bool,
        assetCount: Int,
        indexedAt: String
    ) {
        sync {
            upsertAlbumUnsafe(
                albumId: albumId,
                title: title,
                collectionType: collectionType,
                collectionSubtype: collectionSubtype,
                isPersonAlbum: isPersonAlbum,
                personId: personId,
                isHighCardinality: isHighCardinality,
                assetCount: assetCount,
                indexedAt: indexedAt
            )
        }
    }

    func insertPhotoAlbumLinks(_ links: [(photoId: String, albumId: String, source: String)]) {
        guard !links.isEmpty else { return }
        sync {
            insertPhotoAlbumLinksUnsafe(links)
        }
    }

    func countAlbums() -> Int {
        sync { countRowsUnsafe("albums") }
    }

    func countPhotoAlbumLinks() -> Int {
        sync { countRowsUnsafe("photo_albums") }
    }

    // MARK: - Unsafe

    func upsertAlbumUnsafe(
        albumId: String,
        title: String,
        collectionType: String,
        collectionSubtype: String?,
        isPersonAlbum: Bool,
        personId: Int?,
        isHighCardinality: Bool,
        assetCount: Int,
        indexedAt: String
    ) {
        let sql = """
        INSERT INTO albums (
            albumId, title, collectionType, collectionSubtype,
            isPersonAlbum, personId, isHighCardinality, assetCount,
            indexedAt, updatedAt
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(albumId) DO UPDATE SET
            title = excluded.title,
            collectionType = excluded.collectionType,
            collectionSubtype = excluded.collectionSubtype,
            isPersonAlbum = excluded.isPersonAlbum,
            personId = excluded.personId,
            isHighCardinality = excluded.isHighCardinality,
            assetCount = excluded.assetCount,
            updatedAt = excluded.updatedAt;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (albumId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (title as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (collectionType as NSString).utf8String, -1, nil)
            bindOptionalText(statement, index: 4, value: collectionSubtype)
            sqlite3_bind_int(statement, 5, isPersonAlbum ? 1 : 0)
            if let personId {
                sqlite3_bind_int(statement, 6, Int32(personId))
            } else {
                sqlite3_bind_null(statement, 6)
            }
            sqlite3_bind_int(statement, 7, isHighCardinality ? 1 : 0)
            sqlite3_bind_int(statement, 8, Int32(assetCount))
            sqlite3_bind_text(statement, 9, (indexedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 10, (indexedAt as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func insertPhotoAlbumLinksUnsafe(_ links: [(photoId: String, albumId: String, source: String)]) {
        let sql = """
        INSERT OR IGNORE INTO photo_albums (photoId, albumId, source)
        VALUES (?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }

        for link in links {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, (link.photoId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (link.albumId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (link.source as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
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
