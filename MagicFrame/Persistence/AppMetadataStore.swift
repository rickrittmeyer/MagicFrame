import Foundation
import SQLite3

/// Read/write `app_metadata` key-value rows.
final class AppMetadataStore {

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    func get(key: String) -> String? {
        database.queue.sync {
            getUnsafe(key: key)
        }
    }

    func set(key: String, value: String) {
        database.queue.sync {
            setUnsafe(key: key, value: value)
        }
    }

    func delete(key: String) {
        database.queue.sync {
            let sql = "DELETE FROM app_metadata WHERE key = ?;"
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(database.connection, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }

            sqlite3_finalize(statement)
        }
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

            if sqlite3_step(statement) == SQLITE_ROW {
                let value = String(cString: sqlite3_column_text(statement, 0))
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
