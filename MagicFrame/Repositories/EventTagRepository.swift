import Foundation
import SQLite3

/// SQLite access for `event_tags` and holiday mirror on `events.holidayType`.
final class EventTagRepository {

    static let holidayCategory = "holiday"

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

    func attachAttributeTags(to events: [IndexedEvent]) -> [IndexedEvent] {
        sync { attachAttributeTagsUnsafe(to: events) }
    }

    func attachAttributeTagsUnsafe(to events: [IndexedEvent]) -> [IndexedEvent] {
        guard !events.isEmpty else { return events }

        let eventIds = events.map(\.eventId)
        var tagsByEventId = fetchAttributeTagsUnsafe(eventIds: eventIds)

        let parentIdsMissingHoliday = events
            .filter {
                $0.parentEventId == nil
                    && !(tagsByEventId[$0.eventId]?.contains { $0.category == .holidayType } ?? false)
            }
            .map(\.eventId)
        if !parentIdsMissingHoliday.isEmpty {
            let fromChildren = fetchHolidayTagsFromDescendantsUnsafe(
                parentEventIds: parentIdsMissingHoliday
            )
            for (parentId, holidayTag) in fromChildren {
                var tags = tagsByEventId[parentId] ?? []
                guard !tags.contains(where: { $0.category == .holidayType }) else { continue }
                tags.append(EventAttributeTag(holidayTag: holidayTag))
                tagsByEventId[parentId] = tags
            }
        }

        return events.map { event in
            var tags = tagsByEventId[event.eventId] ?? []
            for field in EventAttributeField.columnBackedTagFields {
                guard !tags.contains(where: { $0.category == field }) else { continue }
                let trimmed = event.attributeColumnValue(for: field)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !trimmed.isEmpty else { continue }
                tags.append(
                    EventAttributeTag(
                        category: field,
                        tagValue: trimmed,
                        source: .user
                    )
                )
            }

            return eventWithAttributeTags(event, tags: tags)
        }
    }

    func attachHolidayTags(to events: [IndexedEvent]) -> [IndexedEvent] {
        attachAttributeTags(to: events)
    }

    func attachHolidayTagsUnsafe(to events: [IndexedEvent]) -> [IndexedEvent] {
        attachAttributeTagsUnsafe(to: events)
    }

    func backfillAttributeTagsFromColumnsIfNeeded() {
        sync { backfillAttributeTagsFromColumnsIfNeededUnsafe() }
    }

    func syncUserAttributeTag(
        eventId: Int,
        field: EventAttributeField,
        tagValue: String?
    ) {
        sync {
            syncUserAttributeTagUnsafe(eventId: eventId, field: field, tagValue: tagValue)
        }
    }

    func syncUserAttributeTagUnsafe(
        eventId: Int,
        field: EventAttributeField,
        tagValue: String?
    ) {
        let trimmed = tagValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            deleteAttributeTagUnsafe(eventId: eventId, category: field.tagCategory, source: .user)
            mirrorAttributeColumnUnsafe(eventId: eventId, field: field, value: nil)
            return
        }

        upsertAttributeTagUnsafe(
            eventId: eventId,
            category: field.tagCategory,
            tagValue: trimmed,
            source: .user,
            appliedPhase: nil,
            occasionId: nil,
            scoringYear: nil,
            confidence: nil,
            totalScore: nil
        )
        mirrorAttributeColumnUnsafe(eventId: eventId, field: field, value: trimmed)
    }

    func syncUserHolidayTag(eventId: Int, tagValue: String?) {
        syncUserAttributeTag(eventId: eventId, field: .holidayType, tagValue: tagValue)
    }

    func syncUserHolidayTagUnsafe(eventId: Int, tagValue: String?) {
        syncUserAttributeTagUnsafe(eventId: eventId, field: .holidayType, tagValue: tagValue)
    }

    func upsertAIHolidayTagUnsafe(
        eventId: Int,
        tagValue: String,
        appliedPhase: EventTagAppliedPhase,
        occasionId: Int,
        scoringYear: Int,
        confidence: String?,
        totalScore: Double
    ) {
        upsertAttributeTagUnsafe(
            eventId: eventId,
            category: Self.holidayCategory,
            tagValue: tagValue,
            source: .ai,
            appliedPhase: appliedPhase,
            occasionId: occasionId,
            scoringYear: scoringYear,
            confidence: confidence,
            totalScore: totalScore
        )
        mirrorAttributeColumnUnsafe(eventId: eventId, field: .holidayType, value: tagValue)
    }

    func deleteAIHolidayTagUnsafe(eventId: Int) {
        deleteAttributeTagUnsafe(eventId: eventId, category: Self.holidayCategory, source: .ai)
        if fetchAttributeTagRowUnsafe(eventId: eventId, field: .holidayType)?.source != .user {
            mirrorAttributeColumnUnsafe(eventId: eventId, field: .holidayType, value: nil)
        }
    }

    func isAIHolidayTagRejected(eventId: Int) -> Bool {
        sync { isAIHolidayTagRejectedUnsafe(eventId: eventId) }
    }

    func isAIAttributeTagRejectedUnsafe(eventId: Int, field: EventAttributeField) -> Bool {
        let sql = """
        SELECT 1
        FROM event_tags
        WHERE eventId = ?
          AND tagCategory = ?
          AND isRejected = 1
        LIMIT 1;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_text(
                statement,
                2,
                (field.tagCategory as NSString).utf8String,
                -1,
                nil
            )
            let found = sqlite3_step(statement) == SQLITE_ROW
            sqlite3_finalize(statement)
            return found
        }

        sqlite3_finalize(statement)
        return false
    }

    func isAIHolidayTagRejectedUnsafe(eventId: Int) -> Bool {
        isAIAttributeTagRejectedUnsafe(eventId: eventId, field: .holidayType)
    }

    func upsertAIAttributeTagUnsafe(
        eventId: Int,
        field: EventAttributeField,
        tagValue: String,
        appliedPhase: EventTagAppliedPhase? = .postObject
    ) {
        upsertAttributeTagUnsafe(
            eventId: eventId,
            category: field.tagCategory,
            tagValue: tagValue,
            source: .ai,
            appliedPhase: appliedPhase,
            occasionId: nil,
            scoringYear: nil,
            confidence: nil,
            totalScore: nil
        )
    }

    func confirmAIAttributeTag(eventId: Int, field: EventAttributeField) {
        sync { confirmAIAttributeTagUnsafe(eventId: eventId, field: field) }
    }

    func confirmAIAttributeTagUnsafe(eventId: Int, field: EventAttributeField) {
        guard let row = fetchAttributeTagRowUnsafe(eventId: eventId, field: field),
              row.source == .ai else {
            return
        }
        syncUserAttributeTagUnsafe(eventId: eventId, field: field, tagValue: row.tagValue)
    }

    func rejectAIAttributeTag(eventId: Int, field: EventAttributeField) {
        sync { rejectAIAttributeTagUnsafe(eventId: eventId, field: field) }
    }

    func rejectAIAttributeTagUnsafe(eventId: Int, field: EventAttributeField) {
        let tagValue = fetchAttributeTagRowUnsafe(eventId: eventId, field: field)?.tagValue
            ?? fetchStoredAttributeTagValueUnsafe(eventId: eventId, field: field)
            ?? field.menuTitle
        deleteAttributeTagUnsafe(eventId: eventId, category: field.tagCategory, source: .ai)
        upsertRejectedAttributeTagUnsafe(
            eventId: eventId,
            field: field,
            tagValue: tagValue
        )
        mirrorAttributeColumnUnsafe(eventId: eventId, field: field, value: nil)
    }

    func confirmAIHolidayTag(eventId: Int) {
        confirmAIAttributeTag(eventId: eventId, field: .holidayType)
    }

    func confirmAIHolidayTagUnsafe(eventId: Int) {
        confirmAIAttributeTagUnsafe(eventId: eventId, field: .holidayType)
    }

    func rejectAIHolidayTag(eventId: Int) {
        rejectAIAttributeTag(eventId: eventId, field: .holidayType)
    }

    func rejectAIHolidayTagUnsafe(eventId: Int) {
        rejectAIAttributeTagUnsafe(eventId: eventId, field: .holidayType)
    }

    func fetchHolidayTagValuesForEventUnsafe(eventId: Int) -> [String] {
        var tagValues: [String] = []

        if let row = fetchHolidayTagRowUnsafe(eventId: eventId) {
            tagValues.append(row.tagValue)
        }

        let sql = """
        SELECT DISTINCT ht.tagValue
        FROM events child
        JOIN event_tags ht
            ON ht.eventId = child.eventId
           AND ht.tagCategory = ?
           AND ht.isRejected = 0
        WHERE child.parentEventId = ?
          AND child.isDeleted = 0;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(
                statement,
                1,
                (Self.holidayCategory as NSString).utf8String,
                -1,
                nil
            )
            sqlite3_bind_int(statement, 2, Int32(eventId))
            while sqlite3_step(statement) == SQLITE_ROW,
                  let tagValue = sqliteOptionalText(statement, column: 0) {
                tagValues.append(tagValue)
            }
        }

        sqlite3_finalize(statement)
        return Array(Set(tagValues))
    }

    struct AttributeTagScoringMetadata: Sendable {
        let tagValue: String
        let source: EventTagSource
        let appliedPhase: EventTagAppliedPhase?
        let occasionId: Int?
        let scoringYear: Int?
        let confidence: String?
        let totalScore: Double?
    }

    func fetchAttributeTagScoringMetadataUnsafe(
        eventId: Int,
        field: EventAttributeField
    ) -> AttributeTagScoringMetadata? {
        let sql = """
        SELECT tagValue, source, appliedPhase, occasionId, scoringYear, confidence, totalScore
        FROM event_tags
        WHERE eventId = ?
          AND tagCategory = ?
          AND isRejected = 0
        LIMIT 1;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_text(
                statement,
                2,
                (field.tagCategory as NSString).utf8String,
                -1,
                nil
            )
            if sqlite3_step(statement) == SQLITE_ROW,
               let tagValue = sqliteOptionalText(statement, column: 0),
               let sourceRaw = sqliteOptionalText(statement, column: 1),
               let source = EventTagSource(rawValue: sourceRaw) {
                let phaseRaw = sqliteOptionalText(statement, column: 2)
                let phase = phaseRaw.flatMap { EventTagAppliedPhase(rawValue: $0) }
                let occasionId: Int? =
                    sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(statement, 3))
                let scoringYear: Int? =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(statement, 4))
                let confidence = sqliteOptionalText(statement, column: 5)
                let totalScore: Double? =
                    sqlite3_column_type(statement, 6) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 6)
                sqlite3_finalize(statement)
                return AttributeTagScoringMetadata(
                    tagValue: tagValue,
                    source: source,
                    appliedPhase: phase,
                    occasionId: occasionId,
                    scoringYear: scoringYear,
                    confidence: confidence,
                    totalScore: totalScore
                )
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    func fetchAttributeTagRowUnsafe(
        eventId: Int,
        field: EventAttributeField
    ) -> (source: EventTagSource, tagValue: String)? {
        let sql = """
        SELECT source, tagValue
        FROM event_tags
        WHERE eventId = ?
          AND tagCategory = ?
          AND isRejected = 0
        LIMIT 1;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_text(
                statement,
                2,
                (field.tagCategory as NSString).utf8String,
                -1,
                nil
            )
            if sqlite3_step(statement) == SQLITE_ROW,
               let sourceRaw = sqliteOptionalText(statement, column: 0),
               let tagValue = sqliteOptionalText(statement, column: 1),
               let source = EventTagSource(rawValue: sourceRaw) {
                sqlite3_finalize(statement)
                return (source, tagValue)
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    func fetchHolidayTagRowUnsafe(eventId: Int) -> (source: EventTagSource, tagValue: String)? {
        fetchAttributeTagRowUnsafe(eventId: eventId, field: .holidayType)
    }

    func fetchAttributeTagsUnsafe(eventIds: [Int]) -> [Int: [EventAttributeTag]] {
        guard !eventIds.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ", ")
        let sql = """
        SELECT eventId, tagCategory, tagValue, source, appliedPhase, totalScore
        FROM event_tags
        WHERE isRejected = 0
          AND eventId IN (\(placeholders));
        """

        var statement: OpaquePointer?
        var tagsByEventId: [Int: [EventAttributeTag]] = [:]

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_int(statement, Int32(index + 1), Int32(eventId))
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let eventId = Int(sqlite3_column_int(statement, 0))
                guard let categoryRaw = sqliteOptionalText(statement, column: 1),
                      let field = EventAttributeField.fromTagCategory(categoryRaw),
                      let tagValue = sqliteOptionalText(statement, column: 2),
                      let sourceRaw = sqliteOptionalText(statement, column: 3),
                      let source = EventTagSource(rawValue: sourceRaw) else {
                    continue
                }
                let phaseRaw = sqliteOptionalText(statement, column: 4)
                let phase = phaseRaw.flatMap { EventTagAppliedPhase(rawValue: $0) }
                let totalScore: Double? =
                    sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 5)
                var tags = tagsByEventId[eventId] ?? []
                tags.removeAll { $0.category == field }
                tags.append(
                    EventAttributeTag(
                        category: field,
                        tagValue: tagValue,
                        source: source,
                        appliedPhase: phase,
                        totalScore: totalScore
                    )
                )
                tagsByEventId[eventId] = tags
            }
        }

        sqlite3_finalize(statement)
        return tagsByEventId
    }

    func backfillAttributeTagsFromColumnsIfNeededUnsafe() {
        let metadataKey = "eventAttributeTagsBackfilledV1"
        guard getAppMetadataUnsafe(key: metadataKey) != "1" else { return }

        let now = ISO8601DateFormatter().string(from: Date())
        for field in EventAttributeField.allCases {
            let column = field.sqlColumn
            let category = field.tagCategory
            let sql = """
            INSERT INTO event_tags (
                eventId, tagCategory, tagValue, source, appliedPhase,
                occasionId, scoringYear, confidence, totalScore,
                isRejected, createdAt, updatedAt
            )
            SELECT
                e.eventId,
                ?,
                TRIM(e.\(column)),
                'user',
                NULL,
                NULL,
                NULL,
                NULL,
                NULL,
                0,
                ?,
                ?
            FROM events e
            WHERE e.isDeleted = 0
              AND TRIM(COALESCE(e.\(column), '')) != ''
              AND NOT EXISTS (
                SELECT 1
                FROM event_tags t
                WHERE t.eventId = e.eventId
                  AND t.tagCategory = ?
              );
            """

            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (category as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (now as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 4, (category as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }

        setAppMetadataUnsafe(key: metadataKey, value: "1")
    }

    func fetchHolidayTagsUnsafe(eventIds: [Int]) -> [Int: EventHolidayTag] {
        guard !eventIds.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ", ")
        let sql = """
        SELECT eventId, tagValue, source, appliedPhase
        FROM event_tags
        WHERE tagCategory = ?
          AND isRejected = 0
          AND eventId IN (\(placeholders));
        """

        var statement: OpaquePointer?
        var tags: [Int: EventHolidayTag] = [:]

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(
                statement,
                1,
                (Self.holidayCategory as NSString).utf8String,
                -1,
                nil
            )
            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_int(statement, Int32(index + 2), Int32(eventId))
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let eventId = Int(sqlite3_column_int(statement, 0))
                guard let tagValue = sqliteOptionalText(statement, column: 1),
                      let sourceRaw = sqliteOptionalText(statement, column: 2),
                      let source = EventTagSource(rawValue: sourceRaw) else {
                    continue
                }
                let phaseRaw = sqliteOptionalText(statement, column: 3)
                let phase = phaseRaw.flatMap { EventTagAppliedPhase(rawValue: $0) }
                tags[eventId] = EventHolidayTag(
                    tagValue: tagValue,
                    source: source,
                    appliedPhase: phase
                )
            }
        }

        sqlite3_finalize(statement)
        return tags
    }

    /// Holiday tags stored on trip day children, surfaced on the parent list row.
    func fetchHolidayTagsFromDescendantsUnsafe(
        parentEventIds: [Int]
    ) -> [Int: EventHolidayTag] {
        guard !parentEventIds.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: parentEventIds.count).joined(
            separator: ", "
        )
        let sql = """
        SELECT
            child.parentEventId,
            child.eventId,
            ht.tagValue,
            ht.source,
            ht.appliedPhase
        FROM events child
        JOIN event_tags ht
            ON ht.eventId = child.eventId
        WHERE child.isDeleted = 0
          AND child.parentEventId IN (\(placeholders))
          AND ht.tagCategory = ?
          AND ht.isRejected = 0
        ORDER BY
            child.parentEventId,
            CASE ht.source WHEN 'user' THEN 0 ELSE 1 END,
            COALESCE(ht.totalScore, 0) DESC;
        """

        var statement: OpaquePointer?
        var tags: [Int: EventHolidayTag] = [:]

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (index, eventId) in parentEventIds.enumerated() {
                sqlite3_bind_int(statement, Int32(index + 1), Int32(eventId))
            }
            sqlite3_bind_text(
                statement,
                Int32(parentEventIds.count + 1),
                (Self.holidayCategory as NSString).utf8String,
                -1,
                nil
            )
            while sqlite3_step(statement) == SQLITE_ROW {
                let parentId = Int(sqlite3_column_int(statement, 0))
                guard tags[parentId] == nil,
                      let tagValue = sqliteOptionalText(statement, column: 2),
                      let sourceRaw = sqliteOptionalText(statement, column: 3),
                      let source = EventTagSource(rawValue: sourceRaw) else {
                    continue
                }
                let childEventId = Int(sqlite3_column_int(statement, 1))
                let phaseRaw = sqliteOptionalText(statement, column: 4)
                let phase = phaseRaw.flatMap { EventTagAppliedPhase(rawValue: $0) }
                tags[parentId] = EventHolidayTag(
                    tagValue: tagValue,
                    source: source,
                    appliedPhase: phase,
                    owningEventId: childEventId
                )
            }
        }

        sqlite3_finalize(statement)
        return tags
    }

    func fetchEventIdsWithAIHolidayTagsUnsafe() -> [Int] {
        let sql = """
        SELECT eventId
        FROM event_tags
        WHERE tagCategory = ?
          AND source = 'ai'
          AND isRejected = 0;
        """

        var statement: OpaquePointer?
        var ids: [Int] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(
                statement,
                1,
                (Self.holidayCategory as NSString).utf8String,
                -1,
                nil
            )
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.append(Int(sqlite3_column_int(statement, 0)))
            }
        }

        sqlite3_finalize(statement)
        return ids
    }

    func anyAITaggedHolidayEventsNeedObjectRecognitionUnsafe(
        eventIds: [Int],
        tagValue: String,
        includeHidden: Bool,
        algorithmVersion: Int
    ) -> Bool {
        guard !eventIds.isEmpty else { return false }

        let hiddenFilter = includeHidden
            ? "AND COALESCE(e.isUserHidden, 0) = 1"
            : "AND COALESCE(e.isUserHidden, 0) = 0"
        let escapedTag = tagValue.replacingOccurrences(of: "'", with: "''")
        let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ", ")
        let sql = """
        SELECT 1
        FROM events e
        JOIN event_tags ht ON ht.eventId = e.eventId
        WHERE e.isDeleted = 0
          AND e.parentEventId IS NULL
          AND e.eventId IN (\(placeholders))
          \(hiddenFilter)
          AND ht.tagCategory = 'holiday'
          AND ht.tagValue = '\(escapedTag)'
          AND ht.source = 'ai'
          AND ht.isRejected = 0
          AND (
              COALESCE(e.objectRecognitionCompleted, 0) = 0
              OR COALESCE(e.objectRecognitionAlgorithmVersion, 0) < ?
          )
          AND EXISTS (
              SELECT 1
              FROM photo_events pe
              JOIN photos ph ON ph.id = pe.photoId AND ph.isDeleted = 0
              WHERE pe.eventId = e.eventId
                 OR pe.eventId IN (
                     SELECT child.eventId
                     FROM events child
                     WHERE child.parentEventId = e.eventId
                       AND child.isDeleted = 0
                 )
          )
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var needsScan = false

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_int(statement, Int32(index + 1), Int32(eventId))
            }
            sqlite3_bind_int(statement, Int32(eventIds.count + 1), Int32(algorithmVersion))
            needsScan = sqlite3_step(statement) == SQLITE_ROW
        }

        sqlite3_finalize(statement)
        return needsScan
    }

    func fetchAITaggedHolidayEventIdsNeedingObjectRecognitionUnsafe(
        eventIds: [Int],
        tagValue: String,
        includeHidden: Bool,
        algorithmVersion: Int
    ) -> [Int] {
        guard !eventIds.isEmpty else { return [] }

        let hiddenFilter = includeHidden
            ? "AND COALESCE(e.isUserHidden, 0) = 1"
            : "AND COALESCE(e.isUserHidden, 0) = 0"
        let escapedTag = tagValue.replacingOccurrences(of: "'", with: "''")
        let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ", ")
        let sql = """
        SELECT DISTINCT e.eventId
        FROM events e
        JOIN event_tags ht ON ht.eventId = e.eventId
        WHERE e.isDeleted = 0
          AND e.parentEventId IS NULL
          AND e.eventId IN (\(placeholders))
          \(hiddenFilter)
          AND ht.tagCategory = 'holiday'
          AND ht.tagValue = '\(escapedTag)'
          AND ht.source = 'ai'
          AND ht.isRejected = 0
          AND (
              COALESCE(e.objectRecognitionCompleted, 0) = 0
              OR COALESCE(e.objectRecognitionAlgorithmVersion, 0) < ?
          )
          AND EXISTS (
              SELECT 1
              FROM photo_events pe
              JOIN photos ph ON ph.id = pe.photoId AND ph.isDeleted = 0
              WHERE pe.eventId = e.eventId
                 OR pe.eventId IN (
                     SELECT child.eventId
                     FROM events child
                     WHERE child.parentEventId = e.eventId
                       AND child.isDeleted = 0
                 )
          )
        ORDER BY e.startDate DESC, e.eventId ASC;
        """

        var statement: OpaquePointer?
        var matched: [Int] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_int(statement, Int32(index + 1), Int32(eventId))
            }
            sqlite3_bind_int(statement, Int32(eventIds.count + 1), Int32(algorithmVersion))
            while sqlite3_step(statement) == SQLITE_ROW {
                matched.append(Int(sqlite3_column_int(statement, 0)))
            }
        }

        sqlite3_finalize(statement)
        return matched
    }

    func fetchAITaggedHolidayEventIdsNeedingObjectRecognitionUnsafe(
        tagValue: String,
        includeHidden: Bool,
        algorithmVersion: Int
    ) -> [Int] {
        let hiddenFilter = includeHidden
            ? "AND COALESCE(e.isUserHidden, 0) = 1"
            : "AND COALESCE(e.isUserHidden, 0) = 0"
        let escapedTag = tagValue.replacingOccurrences(of: "'", with: "''")
        let sql = """
        SELECT DISTINCT e.eventId
        FROM events e
        JOIN event_tags ht ON ht.eventId = e.eventId
        WHERE e.isDeleted = 0
          AND e.parentEventId IS NULL
          \(hiddenFilter)
          AND ht.tagCategory = 'holiday'
          AND ht.tagValue = '\(escapedTag)'
          AND ht.source = 'ai'
          AND ht.isRejected = 0
          AND (
              COALESCE(e.objectRecognitionCompleted, 0) = 0
              OR COALESCE(e.objectRecognitionAlgorithmVersion, 0) < ?
          )
          AND EXISTS (
              SELECT 1
              FROM photo_events pe
              JOIN photos ph ON ph.id = pe.photoId AND ph.isDeleted = 0
              WHERE pe.eventId = e.eventId
                 OR pe.eventId IN (
                     SELECT child.eventId
                     FROM events child
                     WHERE child.parentEventId = e.eventId
                       AND child.isDeleted = 0
                 )
          )
        ORDER BY e.startDate DESC, e.eventId ASC;
        """

        var statement: OpaquePointer?
        var eventIds: [Int] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(algorithmVersion))
            while sqlite3_step(statement) == SQLITE_ROW {
                eventIds.append(Int(sqlite3_column_int(statement, 0)))
            }
        }

        sqlite3_finalize(statement)
        return eventIds
    }

    func clearObjectRecognitionForEventsUnsafe(eventIds: [Int]) {
        guard !eventIds.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ", ")
        let sql = """
        UPDATE events
        SET objectRecognitionCompleted = 0,
            objectRecognitionCompletedAt = NULL,
            objectRecognitionAlgorithmVersion = 0
        WHERE eventId IN (\(placeholders));
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (index, eventId) in eventIds.enumerated() {
                sqlite3_bind_int(statement, Int32(index + 1), Int32(eventId))
            }
            if sqlite3_step(statement) != SQLITE_DONE {
                print(
                    "Failed clearing object recognition for events:"
                        + " \(String(cString: sqlite3_errmsg(db!)))"
                )
            }
        }

        sqlite3_finalize(statement)
    }

    func markObjectRecognitionCompletedUnsafe(
        eventId: Int,
        completedAt: String,
        algorithmVersion: Int
    ) {
        let sql = """
        UPDATE events
        SET objectRecognitionCompleted = 1,
            objectRecognitionCompletedAt = ?,
            objectRecognitionAlgorithmVersion = ?
        WHERE eventId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (completedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(algorithmVersion))
            sqlite3_bind_int(statement, 3, Int32(eventId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    // MARK: - Private

    private func eventWithAttributeTags(
        _ event: IndexedEvent,
        tags: [EventAttributeTag]
    ) -> IndexedEvent {
        IndexedEvent(
            eventId: event.eventId,
            name: event.name,
            startDate: event.startDate,
            endDate: event.endDate,
            photoCount: event.photoCount,
            latitude: event.latitude,
            longitude: event.longitude,
            city: event.city,
            state: event.state,
            placeName: event.placeName,
            people: event.people,
            coverPhotoId: event.coverPhotoId,
            showOnFrame: event.showOnFrame,
            userEditedName: event.userEditedName,
            locationNickname: event.locationNickname,
            locationId: event.locationId,
            parentEventId: event.parentEventId,
            isTripEvent: event.isTripEvent,
            eventType: event.eventType,
            activityType: event.activityType,
            milestoneType: event.milestoneType,
            holidayType: event.holidayType,
            attributeTags: tags,
            eventMainPerson: event.eventMainPerson,
            eventMainPerson2: event.eventMainPerson2,
            weddingDate: event.weddingDate,
            tripType: event.tripType,
            childEventName: event.childEventName,
            userEditedChildEventName: event.userEditedChildEventName,
            isUserHidden: event.isUserHidden
        )
    }

    private func upsertHolidayTagUnsafe(
        eventId: Int,
        tagValue: String,
        source: EventTagSource,
        appliedPhase: EventTagAppliedPhase?,
        occasionId: Int?,
        scoringYear: Int?,
        confidence: String?,
        totalScore: Double?
    ) {
        upsertAttributeTagUnsafe(
            eventId: eventId,
            category: Self.holidayCategory,
            tagValue: tagValue,
            source: source,
            appliedPhase: appliedPhase,
            occasionId: occasionId,
            scoringYear: scoringYear,
            confidence: confidence,
            totalScore: totalScore
        )
    }

    private func upsertAttributeTagUnsafe(
        eventId: Int,
        category: String,
        tagValue: String,
        source: EventTagSource,
        appliedPhase: EventTagAppliedPhase?,
        occasionId: Int?,
        scoringYear: Int?,
        confidence: String?,
        totalScore: Double?
    ) {
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
        INSERT INTO event_tags (
            eventId, tagCategory, tagValue, source, appliedPhase,
            occasionId, scoringYear, confidence, totalScore,
            isRejected, createdAt, updatedAt
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
        ON CONFLICT(eventId, tagCategory) DO UPDATE SET
            tagValue = CASE
                WHEN event_tags.source = 'user' AND excluded.source = 'ai' THEN event_tags.tagValue
                ELSE excluded.tagValue
            END,
            source = CASE
                WHEN event_tags.source = 'user' AND excluded.source = 'ai' THEN event_tags.source
                ELSE excluded.source
            END,
            appliedPhase = CASE
                WHEN event_tags.source = 'user' AND excluded.source = 'ai' THEN event_tags.appliedPhase
                ELSE excluded.appliedPhase
            END,
            occasionId = CASE
                WHEN event_tags.source = 'user' AND excluded.source = 'ai' THEN event_tags.occasionId
                ELSE excluded.occasionId
            END,
            scoringYear = CASE
                WHEN event_tags.source = 'user' AND excluded.source = 'ai' THEN event_tags.scoringYear
                ELSE excluded.scoringYear
            END,
            confidence = CASE
                WHEN event_tags.source = 'user' AND excluded.source = 'ai' THEN event_tags.confidence
                ELSE excluded.confidence
            END,
            totalScore = CASE
                WHEN event_tags.source = 'user' AND excluded.source = 'ai' THEN event_tags.totalScore
                ELSE excluded.totalScore
            END,
            isRejected = CASE
                WHEN event_tags.isRejected = 1 AND excluded.source = 'ai' THEN 1
                WHEN excluded.source = 'user' THEN 0
                ELSE COALESCE(excluded.isRejected, 0)
            END,
            updatedAt = excluded.updatedAt;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_int(statement, 1, Int32(eventId))
        sqlite3_bind_text(statement, 2, (category as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (tagValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (source.rawValue as NSString).utf8String, -1, nil)

        if let appliedPhase {
            sqlite3_bind_text(
                statement,
                5,
                (appliedPhase.rawValue as NSString).utf8String,
                -1,
                nil
            )
        } else {
            sqlite3_bind_null(statement, 5)
        }

        if let occasionId {
            sqlite3_bind_int(statement, 6, Int32(occasionId))
        } else {
            sqlite3_bind_null(statement, 6)
        }

        if let scoringYear {
            sqlite3_bind_int(statement, 7, Int32(scoringYear))
        } else {
            sqlite3_bind_null(statement, 7)
        }

        bindOptionalText(confidence, to: statement, index: 8)

        if let totalScore {
            sqlite3_bind_double(statement, 9, totalScore)
        } else {
            sqlite3_bind_null(statement, 9)
        }

        sqlite3_bind_text(statement, 10, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 11, (now as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func fetchStoredAttributeTagValueUnsafe(
        eventId: Int,
        field: EventAttributeField
    ) -> String? {
        let sql = """
        SELECT tagValue
        FROM event_tags
        WHERE eventId = ?
          AND tagCategory = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_text(
                statement,
                2,
                (field.tagCategory as NSString).utf8String,
                -1,
                nil
            )
            if sqlite3_step(statement) == SQLITE_ROW,
               let tagValue = sqliteOptionalText(statement, column: 0) {
                sqlite3_finalize(statement)
                return tagValue
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    private func fetchStoredHolidayTagValueUnsafe(eventId: Int) -> String? {
        fetchStoredAttributeTagValueUnsafe(eventId: eventId, field: .holidayType)
    }

    private func upsertRejectedAttributeTagUnsafe(
        eventId: Int,
        field: EventAttributeField,
        tagValue: String
    ) {
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
        INSERT INTO event_tags (
            eventId, tagCategory, tagValue, source, appliedPhase,
            occasionId, scoringYear, confidence, totalScore,
            isRejected, createdAt, updatedAt
        )
        VALUES (?, ?, ?, 'ai', NULL, NULL, NULL, NULL, NULL, 1, ?, ?)
        ON CONFLICT(eventId, tagCategory) DO UPDATE SET
            tagValue = excluded.tagValue,
            source = 'ai',
            appliedPhase = NULL,
            occasionId = NULL,
            scoringYear = NULL,
            confidence = NULL,
            totalScore = NULL,
            isRejected = 1,
            updatedAt = excluded.updatedAt;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_int(statement, 1, Int32(eventId))
        sqlite3_bind_text(statement, 2, (field.tagCategory as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (tagValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, (now as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func upsertRejectedHolidayTagUnsafe(eventId: Int, tagValue: String) {
        upsertRejectedAttributeTagUnsafe(
            eventId: eventId,
            field: .holidayType,
            tagValue: tagValue
        )
    }

    private func deleteAttributeTagUnsafe(
        eventId: Int,
        category: String,
        source: EventTagSource
    ) {
        let sql = """
        DELETE FROM event_tags
        WHERE eventId = ?
          AND tagCategory = ?
          AND source = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_text(statement, 2, (category as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (source.rawValue as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    private func deleteHolidayTagUnsafe(eventId: Int, source: EventTagSource) {
        deleteAttributeTagUnsafe(eventId: eventId, category: Self.holidayCategory, source: source)
    }

    private func mirrorAttributeColumnUnsafe(
        eventId: Int,
        field: EventAttributeField,
        value: String?
    ) {
        let column = field.sqlColumn
        let sql = """
        UPDATE events
        SET \(column) = ?,
            updatedAt = ?
        WHERE eventId = ?;
        """

        let now = ISO8601DateFormatter().string(from: Date())
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindOptionalText(value, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(eventId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    private func mirrorHolidayTypeUnsafe(eventId: Int, value: String?) {
        mirrorAttributeColumnUnsafe(eventId: eventId, field: .holidayType, value: value)
    }

    private func getAppMetadataUnsafe(key: String) -> String? {
        let sql = "SELECT value FROM app_metadata WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        var value: String?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (key as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                value = sqliteOptionalText(statement, column: 0)
            }
        }

        sqlite3_finalize(statement)
        return value
    }

    private func setAppMetadataUnsafe(key: String, value: String) {
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

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
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
