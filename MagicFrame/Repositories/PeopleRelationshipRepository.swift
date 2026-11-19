import Foundation
import SQLite3

/// SQLite access for `people_relationships`.
final class PeopleRelationshipRepository {

    private let database: DatabaseManager

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    private var db: OpaquePointer? { database.connection }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if database.isOnQueue {
            return try work()
        }
        return try database.sync(work)
    }

    private var nowISO: String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - Public

    @discardableResult
    func upsertMarriedCouple(
        bridePersonId: Int,
        groomPersonId: Int,
        weddingDateISO: String,
        sourceEventId: Int?,
        source: String = "user"
    ) -> PeopleRelationship? {
        sync {
            upsertMarriedCoupleUnsafe(
                bridePersonId: bridePersonId,
                groomPersonId: groomPersonId,
                weddingDateISO: weddingDateISO,
                sourceEventId: sourceEventId,
                source: source
            )
        }
    }

    func fetchRelationships(involvingPersonId personId: Int) -> [PeopleRelationship] {
        sync { fetchRelationshipsUnsafe(involvingPersonId: personId) }
    }

    func fetchActiveMarriedRelationship(
        personIdA: Int,
        personIdB: Int
    ) -> PeopleRelationship? {
        sync {
            fetchActiveRomanticPairUnsafe(
                personIdA: personIdA,
                personIdB: personIdB,
                type: .married
            )
        }
    }

    func fetchAllRelationships() -> [PeopleRelationship] {
        sync { fetchAllRelationshipsUnsafe() }
    }

    @discardableResult
    func upsertParentChild(
        parentPersonId: Int,
        childPersonId: Int,
        parentRole: PeopleRelationshipRole,
        source: String = "user"
    ) -> PeopleRelationship? {
        sync {
            upsertDirectedPairUnsafe(
                personIdA: parentPersonId,
                personIdB: childPersonId,
                relationshipClass: .family,
                relationshipType: .parent,
                roleA: parentRole,
                roleB: .child,
                source: source
            )
        }
    }

    @discardableResult
    func upsertSibling(
        personIdA: Int,
        personIdB: Int,
        roleA: PeopleRelationshipRole = .sibling,
        roleB: PeopleRelationshipRole = .sibling,
        source: String = "user"
    ) -> PeopleRelationship? {
        sync {
            upsertDirectedPairUnsafe(
                personIdA: personIdA,
                personIdB: personIdB,
                relationshipClass: .family,
                relationshipType: .sibling,
                roleA: roleA,
                roleB: roleB,
                source: source
            )
        }
    }

    @discardableResult
    func upsertRomanticPair(
        personIdA: Int,
        personIdB: Int,
        relationshipType: PeopleRelationshipType,
        roleA: PeopleRelationshipRole,
        roleB: PeopleRelationshipRole,
        source: String = "user"
    ) -> PeopleRelationship? {
        sync {
            upsertDirectedPairUnsafe(
                personIdA: personIdA,
                personIdB: personIdB,
                relationshipClass: .romantic,
                relationshipType: relationshipType,
                roleA: roleA,
                roleB: roleB,
                source: source
            )
        }
    }

    func deleteRelationship(relationshipId: Int) {
        sync { deleteRelationshipUnsafe(relationshipId: relationshipId) }
    }

    /// One-time backfill from `events.weddingDate` + event main people tags.
    func backfillFromEventWeddingDatesIfNeeded() {
        sync { backfillFromEventWeddingDatesIfNeededUnsafe() }
    }

    // MARK: - Unsafe

    @discardableResult
    func upsertMarriedCoupleUnsafe(
        bridePersonId: Int,
        groomPersonId: Int,
        weddingDateISO: String,
        sourceEventId: Int?,
        source: String
    ) -> PeopleRelationship? {
        guard bridePersonId > 0, groomPersonId > 0, bridePersonId != groomPersonId else {
            return nil
        }
        let trimmedDate = weddingDateISO.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDate.isEmpty else { return nil }

        if let existing = fetchActiveRomanticPairUnsafe(
            personIdA: bridePersonId,
            personIdB: groomPersonId,
            type: .married
        ) {
            return updateRelationshipUnsafe(
                relationshipId: existing.relationshipId,
                personIdA: bridePersonId,
                personIdB: groomPersonId,
                relationshipClass: .romantic,
                relationshipType: .married,
                roleA: .bride,
                roleB: .groom,
                status: .active,
                startDate: trimmedDate,
                endDate: nil,
                sourceEventId: sourceEventId ?? existing.sourceEventId,
                source: source,
                notes: existing.notes
            )
        }

        return insertRelationshipUnsafe(
            personIdA: bridePersonId,
            personIdB: groomPersonId,
            relationshipClass: .romantic,
            relationshipType: .married,
            roleA: .bride,
            roleB: .groom,
            status: .active,
            startDate: trimmedDate,
            endDate: nil,
            sourceEventId: sourceEventId,
            source: source,
            notes: nil
        )
    }

    private func insertRelationshipUnsafe(
        personIdA: Int,
        personIdB: Int,
        relationshipClass: PeopleRelationshipClass,
        relationshipType: PeopleRelationshipType,
        roleA: PeopleRelationshipRole,
        roleB: PeopleRelationshipRole,
        status: PeopleRelationshipStatus,
        startDate: String?,
        endDate: String?,
        sourceEventId: Int?,
        source: String,
        notes: String?
    ) -> PeopleRelationship? {
        let timestamp = nowISO
        let sql = """
        INSERT INTO people_relationships (
            personIdA, personIdB, relationshipClass, relationshipType,
            roleA, roleB, status, startDate, endDate,
            sourceEventId, source, notes, createdAt, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(personIdA))
        sqlite3_bind_int(statement, 2, Int32(personIdB))
        sqlite3_bind_text(statement, 3, (relationshipClass.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (relationshipType.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, (roleA.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 6, (roleB.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (status.rawValue as NSString).utf8String, -1, nil)
        bindOptionalText(statement, 8, startDate)
        bindOptionalText(statement, 9, endDate)
        if let sourceEventId {
            sqlite3_bind_int(statement, 10, Int32(sourceEventId))
        } else {
            sqlite3_bind_null(statement, 10)
        }
        sqlite3_bind_text(statement, 11, (source as NSString).utf8String, -1, nil)
        bindOptionalText(statement, 12, notes)
        sqlite3_bind_text(statement, 13, (timestamp as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 14, (timestamp as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        let id = Int(sqlite3_last_insert_rowid(db))
        return fetchRelationshipUnsafe(relationshipId: id)
    }

    private func updateRelationshipUnsafe(
        relationshipId: Int,
        personIdA: Int,
        personIdB: Int,
        relationshipClass: PeopleRelationshipClass,
        relationshipType: PeopleRelationshipType,
        roleA: PeopleRelationshipRole,
        roleB: PeopleRelationshipRole,
        status: PeopleRelationshipStatus,
        startDate: String?,
        endDate: String?,
        sourceEventId: Int?,
        source: String,
        notes: String?
    ) -> PeopleRelationship? {
        let timestamp = nowISO
        let sql = """
        UPDATE people_relationships SET
            personIdA = ?, personIdB = ?,
            relationshipClass = ?, relationshipType = ?,
            roleA = ?, roleB = ?, status = ?,
            startDate = ?, endDate = ?,
            sourceEventId = ?, source = ?, notes = ?,
            updatedAt = ?
        WHERE relationshipId = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(personIdA))
        sqlite3_bind_int(statement, 2, Int32(personIdB))
        sqlite3_bind_text(statement, 3, (relationshipClass.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (relationshipType.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, (roleA.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 6, (roleB.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (status.rawValue as NSString).utf8String, -1, nil)
        bindOptionalText(statement, 8, startDate)
        bindOptionalText(statement, 9, endDate)
        if let sourceEventId {
            sqlite3_bind_int(statement, 10, Int32(sourceEventId))
        } else {
            sqlite3_bind_null(statement, 10)
        }
        sqlite3_bind_text(statement, 11, (source as NSString).utf8String, -1, nil)
        bindOptionalText(statement, 12, notes)
        sqlite3_bind_text(statement, 13, (timestamp as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 14, Int32(relationshipId))

        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return fetchRelationshipUnsafe(relationshipId: relationshipId)
    }

    private func upsertDirectedPairUnsafe(
        personIdA: Int,
        personIdB: Int,
        relationshipClass: PeopleRelationshipClass,
        relationshipType: PeopleRelationshipType,
        roleA: PeopleRelationshipRole,
        roleB: PeopleRelationshipRole,
        source: String
    ) -> PeopleRelationship? {
        guard personIdA > 0, personIdB > 0, personIdA != personIdB else { return nil }

        if let existing = fetchActivePairUnsafe(
            personIdA: personIdA,
            personIdB: personIdB,
            type: relationshipType
        ) {
            return updateRelationshipUnsafe(
                relationshipId: existing.relationshipId,
                personIdA: personIdA,
                personIdB: personIdB,
                relationshipClass: relationshipClass,
                relationshipType: relationshipType,
                roleA: roleA,
                roleB: roleB,
                status: .active,
                startDate: existing.startDate,
                endDate: nil,
                sourceEventId: existing.sourceEventId,
                source: source,
                notes: existing.notes
            )
        }

        return insertRelationshipUnsafe(
            personIdA: personIdA,
            personIdB: personIdB,
            relationshipClass: relationshipClass,
            relationshipType: relationshipType,
            roleA: roleA,
            roleB: roleB,
            status: .active,
            startDate: nil,
            endDate: nil,
            sourceEventId: nil,
            source: source,
            notes: nil
        )
    }

    private func deleteRelationshipUnsafe(relationshipId: Int) {
        guard relationshipId > 0 else { return }
        let sql = "DELETE FROM people_relationships WHERE relationshipId = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(relationshipId))
        sqlite3_step(statement)
    }

    private func fetchActiveRomanticPairUnsafe(
        personIdA: Int,
        personIdB: Int,
        type: PeopleRelationshipType
    ) -> PeopleRelationship? {
        fetchActivePairUnsafe(personIdA: personIdA, personIdB: personIdB, type: type)
    }

    private func fetchActivePairUnsafe(
        personIdA: Int,
        personIdB: Int,
        type: PeopleRelationshipType
    ) -> PeopleRelationship? {
        let sql = """
        SELECT relationshipId
        FROM people_relationships
        WHERE relationshipType = ?
          AND status = 'active'
          AND (
            (personIdA = ? AND personIdB = ?)
            OR (personIdA = ? AND personIdB = ?)
          )
        ORDER BY relationshipId ASC
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (type.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(personIdA))
        sqlite3_bind_int(statement, 3, Int32(personIdB))
        sqlite3_bind_int(statement, 4, Int32(personIdB))
        sqlite3_bind_int(statement, 5, Int32(personIdA))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return fetchRelationshipUnsafe(relationshipId: Int(sqlite3_column_int(statement, 0)))
    }

    private func fetchRelationshipsUnsafe(involvingPersonId personId: Int) -> [PeopleRelationship] {
        let sql = """
        SELECT relationshipId
        FROM people_relationships
        WHERE personIdA = ? OR personIdB = ?
        ORDER BY updatedAt DESC, relationshipId DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(personId))
        sqlite3_bind_int(statement, 2, Int32(personId))
        var ids: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(Int(sqlite3_column_int(statement, 0)))
        }
        return ids.compactMap { fetchRelationshipUnsafe(relationshipId: $0) }
    }

    private func fetchAllRelationshipsUnsafe() -> [PeopleRelationship] {
        let sql = """
        SELECT relationshipId
        FROM people_relationships
        ORDER BY updatedAt DESC, relationshipId DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var ids: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(Int(sqlite3_column_int(statement, 0)))
        }
        return ids.compactMap { fetchRelationshipUnsafe(relationshipId: $0) }
    }

    private func fetchRelationshipUnsafe(relationshipId: Int) -> PeopleRelationship? {
        let sql = """
        SELECT relationshipId, personIdA, personIdB, relationshipClass, relationshipType,
               roleA, roleB, status, startDate, endDate, sourceEventId, source, notes,
               createdAt, updatedAt
        FROM people_relationships
        WHERE relationshipId = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(relationshipId))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        guard let relationshipClass = PeopleRelationshipClass(
            rawValue: String(cString: sqlite3_column_text(statement, 3))
        ),
        let relationshipType = PeopleRelationshipType(
            rawValue: String(cString: sqlite3_column_text(statement, 4))
        ),
        let roleA = PeopleRelationshipRole(
            rawValue: String(cString: sqlite3_column_text(statement, 5))
        ),
        let roleB = PeopleRelationshipRole(
            rawValue: String(cString: sqlite3_column_text(statement, 6))
        ),
        let status = PeopleRelationshipStatus(
            rawValue: String(cString: sqlite3_column_text(statement, 7))
        ) else {
            return nil
        }

        return PeopleRelationship(
            relationshipId: Int(sqlite3_column_int(statement, 0)),
            personIdA: Int(sqlite3_column_int(statement, 1)),
            personIdB: Int(sqlite3_column_int(statement, 2)),
            relationshipClass: relationshipClass,
            relationshipType: relationshipType,
            roleA: roleA,
            roleB: roleB,
            status: status,
            startDate: optionalString(statement, 8),
            endDate: optionalString(statement, 9),
            sourceEventId: sqlite3_column_type(statement, 10) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int(statement, 10)),
            source: String(cString: sqlite3_column_text(statement, 11)),
            notes: optionalString(statement, 12),
            createdAt: String(cString: sqlite3_column_text(statement, 13)),
            updatedAt: String(cString: sqlite3_column_text(statement, 14))
        )
    }

    private func backfillFromEventWeddingDatesIfNeededUnsafe() {
        let flagKey = "peopleRelationshipsBackfillFromWeddingDate_v1"
        let checkSql = "SELECT value FROM app_metadata WHERE key = ? LIMIT 1;"
        var checkStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, checkSql, -1, &checkStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(checkStatement, 1, (flagKey as NSString).utf8String, -1, nil)
            if sqlite3_step(checkStatement) == SQLITE_ROW {
                sqlite3_finalize(checkStatement)
                return
            }
        }
        sqlite3_finalize(checkStatement)

        let sql = """
        SELECT eventId, weddingDate
        FROM events
        WHERE weddingDate IS NOT NULL
          AND TRIM(weddingDate) != ''
          AND COALESCE(isDeleted, 0) = 0;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let eventId = Int(sqlite3_column_int(statement, 0))
                guard let weddingDateC = sqlite3_column_text(statement, 1) else { continue }
                let weddingDate = String(cString: weddingDateC)

                let mainPeople = fetchMainPersonNamesUnsafe(eventId: eventId)
                guard mainPeople.count >= 2 else { continue }

                let brideName = mainPeople[0]
                let groomName = mainPeople[1]
                guard let brideId = findPersonIdByDisplayNameUnsafe(brideName),
                      let groomId = findPersonIdByDisplayNameUnsafe(groomName) else {
                    continue
                }

                _ = upsertMarriedCoupleUnsafe(
                    bridePersonId: brideId,
                    groomPersonId: groomId,
                    weddingDateISO: weddingDate,
                    sourceEventId: eventId,
                    source: "backfill"
                )
            }
        }
        sqlite3_finalize(statement)

        let setSql = """
        INSERT OR REPLACE INTO app_metadata (key, value) VALUES (?, ?);
        """
        var setStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, setSql, -1, &setStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(setStatement, 1, (flagKey as NSString).utf8String, -1, nil)
            sqlite3_bind_text(setStatement, 2, (nowISO as NSString).utf8String, -1, nil)
            sqlite3_step(setStatement)
        }
        sqlite3_finalize(setStatement)
    }

    private func fetchMainPersonNamesUnsafe(eventId: Int) -> [String] {
        let mainCategory = EventAttributeField.mainPerson.tagCategory
        let secondaryCategory = EventAttributeField.secondaryMainPerson.tagCategory
        let sql = """
        SELECT tagCategory, tagValue
        FROM event_tags
        WHERE eventId = ?
          AND COALESCE(isRejected, 0) = 0
          AND (
            tagCategory = ? COLLATE NOCASE
            OR tagCategory = ? COLLATE NOCASE
          )
        ORDER BY
            CASE WHEN tagCategory = ? COLLATE NOCASE THEN 0 ELSE 1 END,
            eventTagId ASC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(eventId))
        sqlite3_bind_text(statement, 2, (mainCategory as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (secondaryCategory as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (mainCategory as NSString).utf8String, -1, nil)

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let valueC = sqlite3_column_text(statement, 1) else { continue }
            let name = String(cString: valueC).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !names.contains(where: {
                $0.compare(name, options: .caseInsensitive) == .orderedSame
            }) else { continue }
            names.append(name)
            if names.count >= 2 { break }
        }
        return names
    }

    private func findPersonIdByDisplayNameUnsafe(_ name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sql = """
        SELECT personId FROM people
        WHERE displayName = ? COLLATE NOCASE
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (trimmed as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value, !value.isEmpty {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func optionalString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }
}
