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

    func upsertPerson(
        displayName: String,
        firstName: String? = nil,
        lastName: String? = nil,
        maidenName: String? = nil
    ) -> Int {
        sync {
            upsertPersonUnsafe(
                displayName: displayName,
                firstName: firstName,
                lastName: lastName,
                maidenName: maidenName
            )
        }
    }

    /// Compatibility wrapper for callers that only have a single display string.
    func upsertPerson(name: String) -> Int {
        upsertPerson(displayName: name)
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

    func updatePersonNames(
        personId: Int,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    ) {
        sync {
            updatePersonNamesUnsafe(
                personId: personId,
                displayName: displayName,
                firstName: firstName,
                lastName: lastName,
                maidenName: maidenName
            )
        }
    }

    /// Match against display / first / last / maiden (exact or word-boundary).
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

    func updatePersonNamesUnsafe(
        personId: Int,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    ) {
        guard personId > 0 else { return }
        let trimmedDisplay = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplay.isEmpty else { return }

        let sql = """
        UPDATE people
        SET displayName = ?,
            firstName = ?,
            lastName = ?,
            maidenName = ?
        WHERE personId = ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (trimmedDisplay as NSString).utf8String, -1, nil)
        bindOptionalText(statement, 2, trimmedOptional(firstName))
        bindOptionalText(statement, 3, trimmedOptional(lastName))
        bindOptionalText(statement, 4, trimmedOptional(maidenName))
        sqlite3_bind_int(statement, 5, Int32(personId))
        sqlite3_step(statement)
    }

    func findPersonIdUnsafe(matchingName target: String) -> Int? {
        let sql = """
        SELECT personId
        FROM people
        WHERE LOWER(TRIM(displayName)) = LOWER(TRIM(?))
           OR LOWER(TRIM(COALESCE(firstName, ''))) = LOWER(TRIM(?))
           OR LOWER(TRIM(COALESCE(lastName, ''))) = LOWER(TRIM(?))
           OR LOWER(TRIM(COALESCE(maidenName, ''))) = LOWER(TRIM(?))
           OR LOWER(TRIM(displayName)) LIKE LOWER(TRIM(?) || ' %')
           OR LOWER(TRIM(displayName)) LIKE LOWER('% ' || TRIM(?))
        ORDER BY LENGTH(displayName) ASC
        LIMIT 1;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        for index in 1...6 {
            sqlite3_bind_text(statement, Int32(index), (target as NSString).utf8String, -1, nil)
        }

        var personId: Int?
        if sqlite3_step(statement) == SQLITE_ROW {
            personId = Int(sqlite3_column_int(statement, 0))
        }
        return personId
    }

    func upsertPersonUnsafe(
        displayName: String,
        firstName: String? = nil,
        lastName: String? = nil,
        maidenName: String? = nil
    ) -> Int {
        let trimmedDisplay = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplay.isEmpty else { return -1 }

        if let existing = findPersonIdByDisplayNameUnsafe(trimmedDisplay) {
            updatePersonNamesUnsafe(
                personId: existing,
                displayName: trimmedDisplay,
                firstName: firstName ?? fetchPersonUnsafe(personId: existing)?.firstName,
                lastName: lastName ?? fetchPersonUnsafe(personId: existing)?.lastName,
                maidenName: maidenName ?? fetchPersonUnsafe(personId: existing)?.maidenName
            )
            return existing
        }

        let insertSQL = """
        INSERT INTO people (displayName, firstName, lastName, maidenName)
        VALUES (?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (trimmedDisplay as NSString).utf8String, -1, nil)
        bindOptionalText(statement, 2, trimmedOptional(firstName))
        bindOptionalText(statement, 3, trimmedOptional(lastName))
        bindOptionalText(statement, 4, trimmedOptional(maidenName))

        guard sqlite3_step(statement) == SQLITE_DONE else { return -1 }
        return Int(sqlite3_last_insert_rowid(db))
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
        let displayName: String
        let firstName: String?
        let lastName: String?
        let maidenName: String?

        var id: Int { personId }
        /// UI / legacy alias for `displayName`.
        var name: String { displayName }
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

    func fetchPersonUnsafe(personId: Int) -> PersonRecord? {
        let sql = """
        SELECT personId, displayName, firstName, lastName, maidenName
        FROM people
        WHERE personId = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(personId))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return mapPerson(from: statement)
    }

    func fetchAllPeopleUnsafe() -> [PersonRecord] {
        let sql = """
        SELECT personId, displayName, firstName, lastName, maidenName
        FROM people
        WHERE TRIM(COALESCE(displayName, '')) != ''
        ORDER BY displayName COLLATE NOCASE ASC;
        """

        var statement: OpaquePointer?
        var records: [PersonRecord] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let record = mapPerson(from: statement) {
                    records.append(record)
                }
            }
        }

        sqlite3_finalize(statement)
        return records
    }

    func fetchPeopleWithBirthDatesUnsafe() -> [PersonBirthdayRecord] {
        let sql = """
        SELECT personId, displayName, birthDate
        FROM people
        WHERE birthDate IS NOT NULL
          AND TRIM(birthDate) != ''
        ORDER BY displayName COLLATE NOCASE ASC;
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
        fetchAllPeopleUnsafe().map(\.displayName)
    }

    /// Removes face-sourced links, then deletes people who no longer appear on any photo.
    func wipeFaceRecognitionPeopleUnsafe(faceSource: String = "face") {
        let deleteLinks = "DELETE FROM photo_people WHERE source = ?;"
        var linksStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteLinks, -1, &linksStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(linksStatement, 1, (faceSource as NSString).utf8String, -1, nil)
            sqlite3_step(linksStatement)
        }
        sqlite3_finalize(linksStatement)

        _ = sqlite3_exec(
            db,
            """
            DELETE FROM people
            WHERE personId NOT IN (SELECT DISTINCT personId FROM photo_people);
            """,
            nil,
            nil,
            nil
        )
    }

    func fetchPhotoIdsForPersonUnsafe(personId: Int) -> [String] {
        let sql = """
        SELECT photoId
        FROM photo_people
        WHERE personId = ?
        ORDER BY photoId ASC;
        """
        var statement: OpaquePointer?
        var ids: [String] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(personId))
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = sqliteOptionalText(statement, column: 0) {
                ids.append(id)
            }
        }
        return ids
    }

    private func findPersonIdByDisplayNameUnsafe(_ displayName: String) -> Int? {
        let sql = """
        SELECT personId FROM people
        WHERE LOWER(TRIM(displayName)) = LOWER(TRIM(?))
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (displayName as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func mapPerson(from statement: OpaquePointer?) -> PersonRecord? {
        guard let displayName = sqliteOptionalText(statement, column: 1),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return PersonRecord(
            personId: Int(sqlite3_column_int(statement, 0)),
            displayName: displayName,
            firstName: sqliteOptionalText(statement, column: 2),
            lastName: sqliteOptionalText(statement, column: 3),
            maidenName: sqliteOptionalText(statement, column: 4)
        )
    }

    private func trimmedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func sqliteOptionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: cString)
    }
}
