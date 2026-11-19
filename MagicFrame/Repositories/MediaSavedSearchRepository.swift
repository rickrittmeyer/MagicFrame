import Foundation
import SQLite3

final class MediaSavedSearchRepository {

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    private var db: OpaquePointer? { database.connection }

    private func sync<T>(_ work: () -> T) -> T {
        if database.isOnQueue {
            return work()
        }
        return database.sync(work)
    }

    private var nowISO: String {
        ISO8601DateFormatter().string(from: Date())
    }

    func fetchAll(enabledOnly: Bool = false) -> [MediaSavedSearch] {
        sync { fetchAllUnsafe(enabledOnly: enabledOnly) }
    }

    func fetch(id: Int) -> MediaSavedSearch? {
        sync { fetchUnsafe(id: id) }
    }

    func fetch(named name: String) -> MediaSavedSearch? {
        sync { fetchUnsafe(named: name) }
    }

    func fetch(tagCategory: String, tagValue: String) -> MediaSavedSearch? {
        sync { fetchUnsafe(tagCategory: tagCategory, tagValue: tagValue) }
    }

    @discardableResult
    func save(_ search: MediaSavedSearch) -> Int {
        sync { saveUnsafe(search) }
    }

    func delete(id: Int) {
        sync { deleteUnsafe(id: id) }
    }

    // MARK: - Unsafe

    func fetchAllUnsafe(enabledOnly: Bool) -> [MediaSavedSearch] {
        var sql = """
        SELECT mediaSavedSearchId, name, targetTagCategory, targetTagValue, queryJSON,
               isEnabled, performFaceDetect, legacyPictureSearchId, createdAt, updatedAt
        FROM media_saved_searches
        """
        if enabledOnly {
            sql += " WHERE isEnabled = 1"
        }
        sql += " ORDER BY name COLLATE NOCASE ASC;"

        var statement: OpaquePointer?
        var rows: [MediaSavedSearch] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let row = rowFromStatement(statement) {
                rows.append(row)
            }
        }
        return rows
    }

    func fetchUnsafe(id: Int) -> MediaSavedSearch? {
        let sql = """
        SELECT mediaSavedSearchId, name, targetTagCategory, targetTagValue, queryJSON,
               isEnabled, performFaceDetect, legacyPictureSearchId, createdAt, updatedAt
        FROM media_saved_searches
        WHERE mediaSavedSearchId = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(id))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return rowFromStatement(statement)
    }

    func fetchUnsafe(named name: String) -> MediaSavedSearch? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sql = """
        SELECT mediaSavedSearchId, name, targetTagCategory, targetTagValue, queryJSON,
               isEnabled, performFaceDetect, legacyPictureSearchId, createdAt, updatedAt
        FROM media_saved_searches
        WHERE LOWER(TRIM(name)) = LOWER(TRIM(?))
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (trimmed as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return rowFromStatement(statement)
    }

    func fetchUnsafe(tagCategory: String, tagValue: String) -> MediaSavedSearch? {
        let category = tagCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let sql = """
        SELECT mediaSavedSearchId, name, targetTagCategory, targetTagValue, queryJSON,
               isEnabled, performFaceDetect, legacyPictureSearchId, createdAt, updatedAt
        FROM media_saved_searches
        WHERE LOWER(TRIM(targetTagValue)) = LOWER(TRIM(?))
          AND (
            TRIM(?) = ''
            OR LOWER(TRIM(COALESCE(targetTagCategory, ''))) = LOWER(TRIM(?))
          )
        ORDER BY mediaSavedSearchId ASC
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (value as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (category as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (category as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return rowFromStatement(statement)
    }

    @discardableResult
    func saveUnsafe(_ search: MediaSavedSearch) -> Int {
        let now = nowISO
        guard let queryJSON = try? search.encodingQueryJSON() else { return -1 }

        if let id = search.mediaSavedSearchId, id > 0 {
            let sql = """
            UPDATE media_saved_searches
            SET name = ?, targetTagCategory = ?, targetTagValue = ?, queryJSON = ?,
                isEnabled = ?, performFaceDetect = ?, legacyPictureSearchId = ?, updatedAt = ?
            WHERE mediaSavedSearchId = ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                bindSearch(statement, search, queryJSON: queryJSON, createdAt: nil, updatedAt: now)
                sqlite3_bind_int(statement, 9, Int32(id))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            return id
        }

        if let existing = fetchUnsafe(named: search.name), let id = existing.mediaSavedSearchId {
            var updated = search
            updated.mediaSavedSearchId = id
            if updated.legacyPictureSearchId == nil {
                updated.legacyPictureSearchId = existing.legacyPictureSearchId
            }
            return saveUnsafe(updated)
        }

        let sql = """
        INSERT INTO media_saved_searches (
            name, targetTagCategory, targetTagValue, queryJSON,
            isEnabled, performFaceDetect, legacyPictureSearchId, createdAt, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindSearch(statement, search, queryJSON: queryJSON, createdAt: now, updatedAt: now)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        return Int(sqlite3_last_insert_rowid(db))
    }

    func deleteUnsafe(id: Int) {
        let sql = "DELETE FROM media_saved_searches WHERE mediaSavedSearchId = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(id))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    private func bindSearch(
        _ statement: OpaquePointer?,
        _ search: MediaSavedSearch,
        queryJSON: String,
        createdAt: String?,
        updatedAt: String
    ) {
        sqlite3_bind_text(statement, 1, (search.name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (search.targetTagCategory as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (search.targetTagValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (queryJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 5, search.isEnabled ? 1 : 0)
        sqlite3_bind_int(statement, 6, search.performFaceDetect ? 1 : 0)
        if let legacyId = search.legacyPictureSearchId {
            sqlite3_bind_int(statement, 7, Int32(legacyId))
        } else {
            sqlite3_bind_null(statement, 7)
        }
        if let createdAt {
            sqlite3_bind_text(statement, 8, (createdAt as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 9, (updatedAt as NSString).utf8String, -1, nil)
        } else {
            // UPDATE path: params 1…8 then id at 9; updatedAt is index 8
            sqlite3_bind_text(statement, 8, (updatedAt as NSString).utf8String, -1, nil)
        }
    }

    private func rowFromStatement(_ statement: OpaquePointer?) -> MediaSavedSearch? {
        guard let statement,
              let namePtr = sqlite3_column_text(statement, 1),
              let jsonPtr = sqlite3_column_text(statement, 4) else {
            return nil
        }
        let json = String(cString: jsonPtr)
        guard let query = try? MediaSavedSearch.decodingQueryJSON(json) else {
            return nil
        }
        let category = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
        let tagValue = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
        let legacyId: Int? = sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int(statement, 7))
        return MediaSavedSearch(
            mediaSavedSearchId: Int(sqlite3_column_int(statement, 0)),
            name: String(cString: namePtr),
            targetTagCategory: category,
            targetTagValue: tagValue,
            query: query,
            isEnabled: sqlite3_column_int(statement, 5) != 0,
            performFaceDetect: sqlite3_column_int(statement, 6) != 0,
            legacyPictureSearchId: legacyId,
            createdAt: sqlite3_column_text(statement, 8).map { String(cString: $0) },
            updatedAt: sqlite3_column_text(statement, 9).map { String(cString: $0) }
        )
    }
}
