import Foundation
import SQLite3

/// SQLite access for `people` and `photo_people`.
final class PeopleRepository {

    static let shared = PeopleRepository()

    private let database: DatabaseManager

    init(database: DatabaseManager = .shared) {
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

    func upsertPerson(name: String) -> Int {
        sync {
            upsertPersonUnsafe(name: name)
        }
    }

    func linkPhotoToPerson(photoId: String, personId: Int, source: String) {
        sync {
            linkPhotoToPersonUnsafe(photoId: photoId, personId: personId, source: source)
        }
    }

    func getAllPersonNames() -> [String] {
        sync {
            getAllPersonNamesUnsafe()
        }
    }

    // MARK: - Unsafe (caller must be on database queue)

    func upsertPersonUnsafe(name: String) -> Int {
        let insertSQL = """
        INSERT OR IGNORE INTO people (name)
        VALUES (?);
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)

        let selectSQL = """
        SELECT personId FROM people
        WHERE name = ?;
        """

        if sqlite3_prepare_v2(db, selectSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) == SQLITE_ROW {
                let personId = Int(sqlite3_column_int(statement, 0))
                sqlite3_finalize(statement)
                return personId
            }
        }

        sqlite3_finalize(statement)
        return -1
    }

    func linkPhotoToPersonUnsafe(photoId: String, personId: Int, source: String) {
        guard personId > 0 else { return }

        let sql = """
        INSERT OR REPLACE INTO photo_people
        (photoId, personId, source)
        VALUES (?, ?, ?);
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(personId))
            sqlite3_bind_text(statement, 3, (source as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to link person to photo: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
    }

    func getAllPersonNamesUnsafe() -> [String] {
        let sql = """
        SELECT name
        FROM people
        WHERE TRIM(name) != ''
        ORDER BY name COLLATE NOCASE ASC;
        """

        var statement: OpaquePointer?
        var names: [String] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqliteOptionalText(statement, column: 0) {
                    names.append(name)
                }
            }
        }

        sqlite3_finalize(statement)
        return names
    }

    private func sqliteOptionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: cString)
    }
}
