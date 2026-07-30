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

    func setBirthDate(personId: Int, birthDateISO: String) {
        sync {
            setBirthDateUnsafe(personId: personId, birthDateISO: birthDateISO)
        }
    }

    /// First-name style match against `people.name` (exact, or word boundary).
    func findPersonId(matchingName name: String) -> Int? {
        sync {
            let id = findPersonIdUnsafe(matchingName: name)
            return id.flatMap { $0 > 0 ? $0 : nil }
        }
    }

    // MARK: - Unsafe (caller must be on database queue)

    func setBirthDateUnsafe(personId: Int, birthDateISO: String) {
        guard personId > 0 else { return }

        let sql = """
        UPDATE people
        SET birthDate = ?
        WHERE personId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (birthDateISO as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(personId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    func findPersonIdUnsafe(matchingName target: String) -> Int? {
        let sql = """
        SELECT personId
        FROM people
        WHERE LOWER(TRIM(name)) = LOWER(TRIM(?))
           OR LOWER(TRIM(name)) LIKE LOWER(TRIM(?) || ' %')
           OR LOWER(TRIM(name)) LIKE LOWER('% ' || TRIM(?))
        ORDER BY LENGTH(name) ASC
        LIMIT 1;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }

        sqlite3_bind_text(statement, 1, (target as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (target as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (target as NSString).utf8String, -1, nil)

        var personId: Int?
        if sqlite3_step(statement) == SQLITE_ROW {
            personId = Int(sqlite3_column_int(statement, 0))
        }

        sqlite3_finalize(statement)
        return personId
    }

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

    struct PersonRecord: Sendable, Identifiable {
        let personId: Int
        let name: String

        var id: Int { personId }
    }

    struct PersonBirthdayRecord: Sendable {
        let personId: Int
        let name: String
        let birthDateISO: String
    }

    func fetchAllPeople() -> [PersonRecord] {
        sync { fetchAllPeopleUnsafe() }
    }

    func fetchPeopleWithBirthDates() -> [PersonBirthdayRecord] {
        sync { fetchPeopleWithBirthDatesUnsafe() }
    }

    func fetchAllPeopleUnsafe() -> [PersonRecord] {
        let sql = """
        SELECT personId, name
        FROM people
        WHERE TRIM(name) != ''
        ORDER BY name COLLATE NOCASE ASC;
        """

        var statement: OpaquePointer?
        var records: [PersonRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = sqliteOptionalText(statement, column: 1) else { continue }
                records.append(
                    PersonRecord(
                        personId: Int(sqlite3_column_int(statement, 0)),
                        name: name
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return records
    }

    func fetchPeopleWithBirthDatesUnsafe() -> [PersonBirthdayRecord] {
        let sql = """
        SELECT personId, name, birthDate
        FROM people
        WHERE birthDate IS NOT NULL
          AND TRIM(birthDate) != ''
        ORDER BY name COLLATE NOCASE ASC;
        """

        var statement: OpaquePointer?
        var records: [PersonBirthdayRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = sqliteOptionalText(statement, column: 1),
                      let birthDateISO = sqliteOptionalText(statement, column: 2) else {
                    continue
                }

                records.append(
                    PersonBirthdayRecord(
                        personId: Int(sqlite3_column_int(statement, 0)),
                        name: name,
                        birthDateISO: birthDateISO
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return records
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
