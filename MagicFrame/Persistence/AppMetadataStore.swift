import Foundation
import SQLite3

/// Read/write `app_metadata` key-value rows.
final class AppMetadataStore {

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if database.isOnQueue { return try work() }
        return try database.sync(work)
    }

    func get(key: String) -> String? {
        sync {
            getUnsafe(key: key)
        }
    }

    func set(key: String, value: String) {
        sync {
            setUnsafe(key: key, value: value)
        }
    }

    func delete(key: String) {
        sync {
            deleteUnsafe(key: key)
        }
    }

    private func deleteUnsafe(key: String) {
        let sql = "DELETE FROM app_metadata WHERE key = ?;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(database.connection, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    private func getUnsafe(key: String) -> String? {
        guard let db = database.connection else { return nil }

        let sql = """
        SELECT value
        FROM app_metadata
        WHERE key = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) == SQLITE_ROW,
               sqlite3_column_type(statement, 0) != SQLITE_NULL,
               let cString = sqlite3_column_text(statement, 0) {
                let value = String(cString: cString)
                sqlite3_finalize(statement)
                return value
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    private func setUnsafe(key: String, value: String) {
        guard let db = database.connection else { return }

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
}
