import Foundation
import SQLite3

/// SQLite access for `event_tags` (event classification / people tags).
final class EventTagRepository {

    static let holidayCategory = "holiday"

    /// TEMP troubleshooting: ignore / don't write AI-rejection tombstones so scoring can re-apply tags.
    /// Set back to `false` when re-enabling user reject-AI-tag behavior.
    static let temporarilyIgnoreAITagRejections = true

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

        let parentIdsMissingMilestone = events
            .filter {
                $0.parentEventId == nil
                    && !(tagsByEventId[$0.eventId]?.contains { $0.category == .milestoneType } ?? false)
            }
            .map(\.eventId)
        if !parentIdsMissingMilestone.isEmpty {
            let fromChildren = fetchMilestoneTagsFromDescendantsUnsafe(
                parentEventIds: parentIdsMissingMilestone
            )
            for (parentId, milestoneTag) in fromChildren {
                var tags = tagsByEventId[parentId] ?? []
                guard !tags.contains(where: { $0.category == .milestoneType }) else { continue }
                tags.append(milestoneTag)
                tagsByEventId[parentId] = tags
            }
        }

        return events.map { event in
            eventWithAttributeTags(event, tags: tagsByEventId[event.eventId] ?? [])
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

    func fetchSimilarEventAlternatives(
        tagCategory: String,
        tagValue: String
    ) -> [SimilarEventTagAlternative] {
        sync {
            fetchSimilarEventAlternativesUnsafe(
                tagCategory: tagCategory,
                tagValue: tagValue
            )
        }
    }

    func fetchSimilarEventAlternativesUnsafe(
        tagCategory: String,
        tagValue: String
    ) -> [SimilarEventTagAlternative] {
        let sql = """
        SELECT
            similarEventTagId,
            tagCategory,
            tagValue,
            possibleTagCategory,
            possibleTagValue,
            possibleNumberOfEventMainPeople
        FROM similar_event_tags
        WHERE tagCategory = ? COLLATE NOCASE
          AND tagValue = ? COLLATE NOCASE
        ORDER BY similarEventTagId ASC;
        """

        var statement: OpaquePointer?
        var rows: [SimilarEventTagAlternative] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (tagCategory as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (tagValue as NSString).utf8String, -1, nil)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let sourceCategory = sqliteOptionalText(statement, column: 1),
                      let sourceValue = sqliteOptionalText(statement, column: 2),
                      let possibleCategory = sqliteOptionalText(statement, column: 3),
                      let possibleValue = sqliteOptionalText(statement, column: 4) else {
                    continue
                }
                rows.append(
                    SimilarEventTagAlternative(
                        similarEventTagId: Int(sqlite3_column_int(statement, 0)),
                        tagCategory: sourceCategory,
                        tagValue: sourceValue,
                        possibleTagCategory: possibleCategory,
                        possibleTagValue: possibleValue,
                        possibleNumberOfEventMainPeople: Int(sqlite3_column_int(statement, 5))
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return rows
    }

    /// Moves milestone values that were incorrectly stored as `eventType` into `milestoneType`.
    func migrateMisclassifiedMilestoneEventTypesIfNeeded() {
        sync { migrateMisclassifiedMilestoneEventTypesIfNeededUnsafe() }
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

    /// Writes a user tag using category/value from `similar_event_tags` (or any raw pair).
    func applySimilarEventUserTag(
        eventId: Int,
        tagCategory: String,
        tagValue: String
    ) {
        sync {
            applySimilarEventUserTagUnsafe(
                eventId: eventId,
                tagCategory: tagCategory,
                tagValue: tagValue
            )
        }
    }

    func fetchEventNameTemplate(
        tagCategory: String,
        tagValue: String
    ) -> EventNameTemplate? {
        sync {
            fetchEventNameTemplateUnsafe(tagCategory: tagCategory, tagValue: tagValue)
        }
    }

    func fetchAllEventNameTemplates() -> [EventNameTemplate] {
        sync { fetchAllEventNameTemplatesUnsafe() }
    }

    func upsertEventNameTemplate(
        tagCategory: String,
        tagValue: String,
        nameTemplate: String,
        personCount: Int
    ) -> EventNameTemplate? {
        sync {
            upsertEventNameTemplateUnsafe(
                tagCategory: tagCategory,
                tagValue: tagValue,
                nameTemplate: nameTemplate,
                personCount: personCount
            )
        }
    }

    func fetchAllSimilarEventTags() -> [SimilarEventTagAlternative] {
        sync { fetchAllSimilarEventTagsUnsafe() }
    }

    @discardableResult
    func insertSimilarEventTag(
        tagCategory: String,
        tagValue: String,
        possibleTagCategory: String,
        possibleTagValue: String,
        possibleNumberOfEventMainPeople: Int
    ) -> SimilarEventTagAlternative? {
        sync {
            insertSimilarEventTagUnsafe(
                tagCategory: tagCategory,
                tagValue: tagValue,
                possibleTagCategory: possibleTagCategory,
                possibleTagValue: possibleTagValue,
                possibleNumberOfEventMainPeople: possibleNumberOfEventMainPeople
            )
        }
    }

    func fetchEventNameTemplateUnsafe(
        tagCategory: String,
        tagValue: String
    ) -> EventNameTemplate? {
        let sql = """
        SELECT eventNameTemplateId, tagCategory, tagValue, nameTemplate, personCount
        FROM event_name_templates
        WHERE tagCategory = ?
          AND tagValue = ? COLLATE NOCASE
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var template: EventNameTemplate?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let categoryNS = tagCategory as NSString
            let valueNS = tagValue as NSString
            sqlite3_bind_text(statement, 1, categoryNS.utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, valueNS.utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                template = readEventNameTemplateRow(statement)
            }
        }
        sqlite3_finalize(statement)
        return template
    }

    func fetchAllEventNameTemplatesUnsafe() -> [EventNameTemplate] {
        let sql = """
        SELECT eventNameTemplateId, tagCategory, tagValue, nameTemplate, personCount
        FROM event_name_templates
        ORDER BY tagCategory COLLATE NOCASE ASC, tagValue COLLATE NOCASE ASC;
        """

        var statement: OpaquePointer?
        var rows: [EventNameTemplate] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let row = readEventNameTemplateRow(statement) {
                    rows.append(row)
                }
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    func upsertEventNameTemplateUnsafe(
        tagCategory: String,
        tagValue: String,
        nameTemplate: String,
        personCount: Int
    ) -> EventNameTemplate? {
        let category = tagCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = nameTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty, !value.isEmpty, !template.isEmpty else { return nil }

        let count = max(0, min(2, personCount))
        let sql = """
        INSERT INTO event_name_templates (tagCategory, tagValue, nameTemplate, personCount)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(tagCategory, tagValue) DO UPDATE SET
            nameTemplate = excluded.nameTemplate,
            personCount = excluded.personCount;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        let categoryNS = category as NSString
        let valueNS = value as NSString
        let templateNS = template as NSString
        sqlite3_bind_text(statement, 1, categoryNS.utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, valueNS.utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, templateNS.utf8String, -1, nil)
        sqlite3_bind_int(statement, 4, Int32(count))
        let ok = sqlite3_step(statement) == SQLITE_DONE
        sqlite3_finalize(statement)
        guard ok else { return nil }
        return fetchEventNameTemplateUnsafe(tagCategory: category, tagValue: value)
    }

    func fetchAllSimilarEventTagsUnsafe() -> [SimilarEventTagAlternative] {
        let sql = """
        SELECT
            similarEventTagId,
            tagCategory,
            tagValue,
            possibleTagCategory,
            possibleTagValue,
            possibleNumberOfEventMainPeople
        FROM similar_event_tags
        ORDER BY tagCategory COLLATE NOCASE ASC,
                 tagValue COLLATE NOCASE ASC,
                 possibleTagValue COLLATE NOCASE ASC;
        """

        var statement: OpaquePointer?
        var rows: [SimilarEventTagAlternative] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let sourceCategory = sqliteOptionalText(statement, column: 1),
                      let sourceValue = sqliteOptionalText(statement, column: 2),
                      let possibleCategory = sqliteOptionalText(statement, column: 3),
                      let possibleValue = sqliteOptionalText(statement, column: 4) else {
                    continue
                }
                rows.append(
                    SimilarEventTagAlternative(
                        similarEventTagId: Int(sqlite3_column_int(statement, 0)),
                        tagCategory: sourceCategory,
                        tagValue: sourceValue,
                        possibleTagCategory: possibleCategory,
                        possibleTagValue: possibleValue,
                        possibleNumberOfEventMainPeople: Int(sqlite3_column_int(statement, 5))
                    )
                )
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    func insertSimilarEventTagUnsafe(
        tagCategory: String,
        tagValue: String,
        possibleTagCategory: String,
        possibleTagValue: String,
        possibleNumberOfEventMainPeople: Int
    ) -> SimilarEventTagAlternative? {
        let sourceCategory = tagCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceValue = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let possibleCategory = possibleTagCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        let possibleValue = possibleTagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceCategory.isEmpty,
              !sourceValue.isEmpty,
              !possibleCategory.isEmpty,
              !possibleValue.isEmpty else {
            return nil
        }

        let people = max(0, min(2, possibleNumberOfEventMainPeople))
        let sql = """
        INSERT OR IGNORE INTO similar_event_tags (
            tagCategory, tagValue, possibleTagCategory, possibleTagValue,
            possibleNumberOfEventMainPeople
        )
        VALUES (?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        let sourceCategoryNS = sourceCategory as NSString
        let sourceValueNS = sourceValue as NSString
        let possibleCategoryNS = possibleCategory as NSString
        let possibleValueNS = possibleValue as NSString
        sqlite3_bind_text(statement, 1, sourceCategoryNS.utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, sourceValueNS.utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, possibleCategoryNS.utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, possibleValueNS.utf8String, -1, nil)
        sqlite3_bind_int(statement, 5, Int32(people))
        let step = sqlite3_step(statement)
        sqlite3_finalize(statement)
        guard step == SQLITE_DONE else { return nil }

        // INSERT OR IGNORE: changes == 0 means the row already existed.
        if sqlite3_changes(db) == 0 {
            return fetchSimilarEventAlternativesUnsafe(
                tagCategory: sourceCategory,
                tagValue: sourceValue
            ).first {
                $0.possibleTagCategory.compare(possibleCategory, options: .caseInsensitive) == .orderedSame
                    && $0.possibleTagValue.compare(possibleValue, options: .caseInsensitive) == .orderedSame
            }
        }

        return fetchSimilarEventAlternativesUnsafe(
            tagCategory: sourceCategory,
            tagValue: sourceValue
        ).last {
            $0.possibleTagCategory.compare(possibleCategory, options: .caseInsensitive) == .orderedSame
                && $0.possibleTagValue.compare(possibleValue, options: .caseInsensitive) == .orderedSame
        }
    }

    private func readEventNameTemplateRow(_ statement: OpaquePointer?) -> EventNameTemplate? {
        guard let statement else { return nil }
        guard let category = sqliteOptionalText(statement, column: 1),
              let value = sqliteOptionalText(statement, column: 2),
              let template = sqliteOptionalText(statement, column: 3) else {
            return nil
        }
        return EventNameTemplate(
            eventNameTemplateId: Int(sqlite3_column_int(statement, 0)),
            tagCategory: category,
            tagValue: value,
            nameTemplate: template,
            personCount: Int(sqlite3_column_int(statement, 4))
        )
    }

    func applySimilarEventUserTagUnsafe(
        eventId: Int,
        tagCategory: String,
        tagValue: String
    ) {
        let trimmedValue = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return }

        // Prefer canonical category when we recognize it (e.g. "MilestoneType" → milestoneType).
        let category = EventAttributeField.fromTagCategory(tagCategory)?.tagCategory
            ?? tagCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty else { return }

        upsertAttributeTagUnsafe(
            eventId: eventId,
            category: category,
            tagValue: trimmedValue,
            source: .user,
            totalScore: nil
        )
    }

    func syncUserAttributeTagUnsafe(
        eventId: Int,
        field: EventAttributeField,
        tagValue: String?
    ) {
        let trimmed = tagValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            deleteAttributeTagUnsafe(eventId: eventId, category: field.tagCategory, source: .user)
            return
        }

        upsertAttributeTagUnsafe(
            eventId: eventId,
            category: field.tagCategory,
            tagValue: trimmed,
            source: .user,
            totalScore: nil
        )
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
        totalScore: Double
    ) {
        upsertAttributeTagUnsafe(
            eventId: eventId,
            category: Self.holidayCategory,
            tagValue: tagValue,
            source: .ai,
            totalScore: totalScore
        )
    }

    func deleteAIHolidayTagUnsafe(eventId: Int) {
        deleteAttributeTagUnsafe(eventId: eventId, category: Self.holidayCategory, source: .ai)
    }

    func isAIHolidayTagRejected(eventId: Int) -> Bool {
        sync { isAIHolidayTagRejectedUnsafe(eventId: eventId) }
    }

    func isAIAttributeTagRejectedUnsafe(eventId: Int, field: EventAttributeField) -> Bool {
        if Self.temporarilyIgnoreAITagRejections { return false }
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

    /// True when this exact AI tag value was rejected (tombstone row still present).
    func isAIAttributeTagValueRejectedUnsafe(
        eventId: Int,
        category: String,
        tagValue: String
    ) -> Bool {
        if Self.temporarilyIgnoreAITagRejections { return false }
        let sql = """
        SELECT 1
        FROM event_tags
        WHERE eventId = ?
          AND tagCategory = ?
          AND tagValue = ? COLLATE NOCASE
          AND isRejected = 1
        LIMIT 1;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let categoryNS = category as NSString
            let tagValueNS = tagValue as NSString
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_text(statement, 2, categoryNS.utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, tagValueNS.utf8String, -1, nil)
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
        totalScore: Double? = nil,
        mirrorColumn: Bool = true
    ) {
        _ = mirrorColumn
        // Never resurrect a user-rejected AI value (e.g. Possible Wedding after Remove).
        if isAIAttributeTagValueRejectedUnsafe(
            eventId: eventId,
            category: field.tagCategory,
            tagValue: tagValue
        ) {
            return
        }
        upsertAttributeTagUnsafe(
            eventId: eventId,
            category: field.tagCategory,
            tagValue: tagValue,
            source: .ai,
            totalScore: totalScore
        )
    }

    /// Replaces all `eventMainPerson` tags with these user-confirmed names (Bride, Groom, etc.).
    func replaceUserEventMainPeople(eventId: Int, names: [String]) {
        sync { replaceUserEventMainPeopleUnsafe(eventId: eventId, names: names) }
    }

    func replaceUserEventMainPeopleUnsafe(eventId: Int, names: [String]) {
        let trimmedNames = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        deleteAttributeTagCategoryUnsafe(
            eventId: eventId,
            category: EventAttributeField.mainPerson.tagCategory
        )
        deleteAttributeTagCategoryUnsafe(
            eventId: eventId,
            category: EventAttributeField.secondaryMainPerson.tagCategory
        )

        // Wedding-style couple: bride → mainPerson, groom → mainPerson2.
        if trimmedNames.count >= 2 {
            upsertAttributeTagUnsafe(
                eventId: eventId,
                category: EventAttributeField.mainPerson.tagCategory,
                tagValue: trimmedNames[0],
                source: .user,
                totalScore: nil
            )
            upsertAttributeTagUnsafe(
                eventId: eventId,
                category: EventAttributeField.secondaryMainPerson.tagCategory,
                tagValue: trimmedNames[1],
                source: .user,
                totalScore: nil
            )
            return
        }

        for name in trimmedNames {
            upsertAttributeTagUnsafe(
                eventId: eventId,
                category: EventAttributeField.mainPerson.tagCategory,
                tagValue: name,
                source: .user,
                totalScore: nil
            )
        }
    }

    /// Writes one or two `eventMainPerson` tag rows (same category, different values).
    @discardableResult
    func upsertAIEventMainPeopleUnsafe(
        eventId: Int,
        primaryName: String?,
        secondaryName: String?,
        totalScore: Double?
    ) -> (primaryWritten: Bool, secondaryWritten: Bool) {
        // Legacy callers passed primary=groom, secondary=bride.
        let result = applyAIWeddingCouplePeopleUnsafe(
            eventId: eventId,
            brideName: secondaryName,
            groomName: primaryName
        )
        return (primaryWritten: result.groomWritten, secondaryWritten: result.brideWritten)
    }

    /// Birthday: AI `eventMainPerson` when no user main-person tag exists.
    @discardableResult
    func applyAIBirthdayMainPersonUnsafe(
        eventId: Int,
        personName: String,
        totalScore: Double?
    ) -> Bool {
        let trimmed = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !hasUserSourcedAttributeTagUnsafe(eventId: eventId, field: .mainPerson) else {
            return false
        }
        deleteAttributeTagUnsafe(
            eventId: eventId,
            category: EventAttributeField.mainPerson.tagCategory,
            source: .ai
        )
        upsertAIAttributeTagUnsafe(
            eventId: eventId,
            field: .mainPerson,
            tagValue: trimmed,
            totalScore: totalScore
        )
        return true
    }

    /// Bride → `eventMainPerson`, Groom → `eventMainPerson2`. Skips categories that already have user tags.
    @discardableResult
    func applyAIWeddingCouplePeopleUnsafe(
        eventId: Int,
        brideName: String?,
        groomName: String?
    ) -> (brideWritten: Bool, groomWritten: Bool) {
        let bride = brideName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let groom = groomName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var brideWritten = false
        var groomWritten = false

        if !bride.isEmpty,
           !hasUserSourcedAttributeTagUnsafe(eventId: eventId, field: .mainPerson) {
            deleteAttributeTagUnsafe(
                eventId: eventId,
                category: EventAttributeField.mainPerson.tagCategory,
                source: .ai
            )
            upsertAIAttributeTagUnsafe(
                eventId: eventId,
                field: .mainPerson,
                tagValue: bride,
                totalScore: nil
            )
            brideWritten = true
        }

        if !groom.isEmpty,
           !hasUserSourcedAttributeTagUnsafe(eventId: eventId, field: .secondaryMainPerson) {
            deleteAttributeTagUnsafe(
                eventId: eventId,
                category: EventAttributeField.secondaryMainPerson.tagCategory,
                source: .ai
            )
            upsertAIAttributeTagUnsafe(
                eventId: eventId,
                field: .secondaryMainPerson,
                tagValue: groom,
                totalScore: nil
            )
            groomWritten = true
        }

        return (brideWritten, groomWritten)
    }

    private func hasUserSourcedAttributeTagUnsafe(
        eventId: Int,
        field: EventAttributeField
    ) -> Bool {
        let sql = """
        SELECT 1
        FROM event_tags
        WHERE eventId = ?
          AND tagCategory = ?
          AND source = 'user'
          AND COALESCE(isRejected, 0) = 0
          AND TRIM(tagValue) != ''
        LIMIT 1;
        """
        var statement: OpaquePointer?
        var found = false
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_text(
                statement,
                2,
                (field.tagCategory as NSString).utf8String,
                -1,
                nil
            )
            found = sqlite3_step(statement) == SQLITE_ROW
        }
        sqlite3_finalize(statement)
        return found
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

    /// Removes an AI or user tag row. AI removals are marked rejected so they are not re-applied.
    func removeEventAttributeTag(eventId: Int, tag: EventAttributeTag) {
        sync { removeEventAttributeTagUnsafe(eventId: eventId, tag: tag) }
    }

    /// Testing hard-clear: deletes user + AI + rejected tombstone for one category/value.
    @discardableResult
    func purgeEventAttributeTag(
        eventId: Int,
        category: String,
        tagValue: String
    ) -> Int {
        sync {
            purgeEventAttributeTagUnsafe(
                eventId: eventId,
                category: category,
                tagValue: tagValue
            )
        }
    }

    /// Testing: remove all rejected tombstones on an event so AI can re-apply tags.
    @discardableResult
    func purgeRejectedAttributeTags(eventId: Int) -> Int {
        sync { purgeRejectedAttributeTagsUnsafe(eventId: eventId) }
    }

    /// All tag rows for an event including rejected (for developer tools).
    func fetchAllAttributeTagRowsForEvent(eventId: Int) -> [(
        category: String,
        tagValue: String,
        source: String,
        isRejected: Bool
    )] {
        sync { fetchAllAttributeTagRowsForEventUnsafe(eventId: eventId) }
    }

    func removeEventAttributeTagUnsafe(eventId: Int, tag: EventAttributeTag) {
        if tag.source == .ai {
            deleteAttributeTagValueUnsafe(
                eventId: eventId,
                category: tag.category.tagCategory,
                tagValue: tag.tagValue,
                source: .ai
            )
            // For singular categories, also clear any other AI row on that category.
            if !tag.category.allowsMultipleTagValues {
                deleteAttributeTagUnsafe(
                    eventId: eventId,
                    category: tag.category.tagCategory,
                    source: .ai
                )
            }
            upsertRejectedAttributeTagUnsafe(
                eventId: eventId,
                field: tag.category,
                tagValue: tag.tagValue
            )
            return
        }

        deleteAttributeTagValueUnsafe(
            eventId: eventId,
            category: tag.category.tagCategory,
            tagValue: tag.tagValue,
            source: .user
        )
        if !tag.category.allowsMultipleTagValues {
            deleteAttributeTagUnsafe(
                eventId: eventId,
                category: tag.category.tagCategory,
                source: .user
            )
        }
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
        let totalScore: Double?
    }

    func fetchAttributeTagScoringMetadataUnsafe(
        eventId: Int,
        field: EventAttributeField
    ) -> AttributeTagScoringMetadata? {
        let sql = """
        SELECT tagValue, source, totalScore
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
                let totalScore: Double? =
                    sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 2)
                sqlite3_finalize(statement)
                return AttributeTagScoringMetadata(
                    tagValue: tagValue,
                    source: source,
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
        SELECT eventId, tagCategory, tagValue, source, totalScore
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
                let totalScore: Double? =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 4)
                var tags = tagsByEventId[eventId] ?? []
                if field.allowsMultipleTagValues {
                    tags.removeAll {
                        $0.category == field
                            && $0.tagValue.compare(tagValue, options: .caseInsensitive) == .orderedSame
                    }
                } else {
                    tags.removeAll { $0.category == field }
                }
                tags.append(
                    EventAttributeTag(
                        category: field,
                        tagValue: tagValue,
                        source: source,
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
        let alreadyMarked = getAppMetadataUnsafe(key: metadataKey) == "1"

        // Legacy: "Trip" is not an eventType tag (trips use isTripEvent + Trips tag).
        sqlite3_exec(
            db,
            """
            DELETE FROM event_tags
            WHERE tagCategory = 'eventType'
              AND LOWER(TRIM(tagValue)) = 'trip';
            """,
            nil,
            nil,
            nil
        )

        let now = ISO8601DateFormatter().string(from: Date())
        var anyColumnPresent = false
        for field in EventAttributeField.allCases {
            let column = field.legacyColumnName
            guard eventsColumnExistsUnsafe(column) else { continue }
            anyColumnPresent = true
            let category = field.tagCategory
            // For multi-value person tags, only skip an exact value match.
            let existsClause: String
            if field.allowsMultipleTagValues {
                existsClause = """
                  AND NOT EXISTS (
                    SELECT 1
                    FROM event_tags t
                    WHERE t.eventId = e.eventId
                      AND t.tagCategory = ?
                      AND t.tagValue = TRIM(e.\(column)) COLLATE NOCASE
                  )
                """
            } else {
                existsClause = """
                  AND NOT EXISTS (
                    SELECT 1
                    FROM event_tags t
                    WHERE t.eventId = e.eventId
                      AND t.tagCategory = ?
                  )
                """
            }
            let sql = """
            INSERT INTO event_tags (
                eventId, tagCategory, tagValue, source, totalScore,
                isRejected, createdAt, updatedAt
            )
            SELECT
                e.eventId,
                ?,
                TRIM(e.\(column)),
                'user',
                NULL,
                0,
                ?,
                ?
            FROM events e
            WHERE e.isDeleted = 0
              AND TRIM(COALESCE(e.\(column), '')) != ''
              \(existsClause);
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

        if anyColumnPresent || alreadyMarked {
            setAppMetadataUnsafe(key: metadataKey, value: "1")
        }
    }

    func migrateMisclassifiedMilestoneEventTypesIfNeededUnsafe() {
        let metadataKey = "milestoneEventTypesMigratedFromEventTypeV1"
        guard getAppMetadataUnsafe(key: metadataKey) != "1" else { return }

        let milestoneValues = EventAttributeField.milestoneType.builtInOptions
        guard !milestoneValues.isEmpty else {
            setAppMetadataUnsafe(key: metadataKey, value: "1")
            return
        }

        let valueList = milestoneValues
            .map { "'\(escapeSQLLiteral($0.lowercased()))'" }
            .joined(separator: ", ")
        let now = escapeSQLLiteral(ISO8601DateFormatter().string(from: Date()))

        // Promote eventType → milestoneType when the event has no milestone yet.
        sqlite3_exec(
            db,
            """
            INSERT INTO event_tags (
                eventId, tagCategory, tagValue, source, totalScore,
                isRejected, createdAt, updatedAt
            )
            SELECT
                et.eventId,
                'milestoneType',
                et.tagValue,
                et.source,
                et.totalScore,
                et.isRejected,
                '\(now)',
                '\(now)'
            FROM event_tags et
            WHERE et.tagCategory = 'eventType'
              AND LOWER(TRIM(et.tagValue)) IN (\(valueList))
              AND NOT EXISTS (
                  SELECT 1
                  FROM event_tags m
                  WHERE m.eventId = et.eventId
                    AND m.tagCategory = 'milestoneType'
                    AND m.isRejected = 0
              );
            """,
            nil,
            nil,
            nil
        )

        // Drop the duplicate / misplaced eventType rows (including when milestone already existed).
        sqlite3_exec(
            db,
            """
            DELETE FROM event_tags
            WHERE tagCategory = 'eventType'
              AND LOWER(TRIM(tagValue)) IN (\(valueList));
            """,
            nil,
            nil,
            nil
        )

        // Clear legacy columns so a future backfill cannot recreate eventType=Wedding chips.
        for column in ["eventType", "XeventType"] where eventsColumnExistsUnsafe(column) {
            sqlite3_exec(
                db,
                """
                UPDATE events
                SET \(column) = NULL
                WHERE LOWER(TRIM(COALESCE(\(column), ''))) IN (\(valueList));
                """,
                nil,
                nil,
                nil
            )
        }

        setAppMetadataUnsafe(key: metadataKey, value: "1")
        print("Migrated misclassified milestone values out of eventType tags")
    }

    /// Removes leftover `eventType` rows that duplicate a milestone value (e.g. Wedding).
    func deleteMisclassifiedEventTypeForMilestoneUnsafe(eventId: Int, tagValue: String) {
        let trimmed = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let sql = """
        DELETE FROM event_tags
        WHERE eventId = ?
          AND tagCategory = 'eventType'
          AND LOWER(TRIM(tagValue)) = LOWER(?);
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_text(statement, 2, (trimmed as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)

        for column in ["eventType", "XeventType"] where eventsColumnExistsUnsafe(column) {
            let updateSQL = """
            UPDATE events
            SET \(column) = NULL
            WHERE eventId = ?
              AND LOWER(TRIM(COALESCE(\(column), ''))) = LOWER(?);
            """
            var updateStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK {
                sqlite3_bind_int(updateStatement, 1, Int32(eventId))
                sqlite3_bind_text(updateStatement, 2, (trimmed as NSString).utf8String, -1, nil)
                sqlite3_step(updateStatement)
            }
            sqlite3_finalize(updateStatement)
        }
    }

    private func escapeSQLLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func eventsColumnExistsUnsafe(_ column: String) -> Bool {
        let sql = "PRAGMA table_info(events);"
        var statement: OpaquePointer?
        var found = false
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(statement, 1))
                if name == column {
                    found = true
                    break
                }
            }
        }
        sqlite3_finalize(statement)
        return found
    }

    func fetchHolidayTagsUnsafe(eventIds: [Int]) -> [Int: EventHolidayTag] {
        guard !eventIds.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ", ")
        let sql = """
        SELECT eventId, tagValue, source
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
                tags[eventId] = EventHolidayTag(
                    tagValue: tagValue,
                    source: source
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
            ht.source
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
                tags[parentId] = EventHolidayTag(
                    tagValue: tagValue,
                    source: source,
                    owningEventId: childEventId
                )
            }
        }

        sqlite3_finalize(statement)
        return tags
    }

    func fetchMilestoneTagsFromDescendantsUnsafe(
        parentEventIds: [Int]
    ) -> [Int: EventAttributeTag] {
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
            ht.totalScore
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
        var tags: [Int: EventAttributeTag] = [:]
        let category = EventAttributeField.milestoneType.tagCategory

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (index, eventId) in parentEventIds.enumerated() {
                sqlite3_bind_int(statement, Int32(index + 1), Int32(eventId))
            }
            sqlite3_bind_text(
                statement,
                Int32(parentEventIds.count + 1),
                (category as NSString).utf8String,
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
                let totalScore: Double? =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 4)
                tags[parentId] = EventAttributeTag(
                    category: .milestoneType,
                    tagValue: tagValue,
                    source: source,
                    totalScore: totalScore,
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
            videoCount: event.videoCount,
            latitude: event.latitude,
            longitude: event.longitude,
            city: event.city,
            state: event.state,
            placeName: event.placeName,
            people: event.people,
            coverPhotoId: event.coverPhotoId,
            showOnFrame: event.showOnFrame,
            isFavorite: event.isFavorite,
            userEditedName: event.userEditedName,
            locationNickname: event.locationNickname,
            locationId: event.locationId,
            parentEventId: event.parentEventId,
            isTripEvent: event.isTripEvent,
            attributeTags: tags,
            weddingDate: event.weddingDate,
            childEventName: event.childEventName,
            userEditedChildEventName: event.userEditedChildEventName,
            isUserHidden: event.isUserHidden
        )
    }

    private func upsertHolidayTagUnsafe(
        eventId: Int,
        tagValue: String,
        source: EventTagSource,
        totalScore: Double?
    ) {
        upsertAttributeTagUnsafe(
            eventId: eventId,
            category: Self.holidayCategory,
            tagValue: tagValue,
            source: source,
            totalScore: totalScore
        )
    }

    private func upsertAttributeTagUnsafe(
        eventId: Int,
        category: String,
        tagValue: String,
        source: EventTagSource,
        totalScore: Double?
    ) {
        let field = EventAttributeField.fromTagCategory(category)
        // Singular categories keep one value: clear other values for this category first.
        if field?.allowsMultipleTagValues != true {
            deleteOtherTagValuesUnsafe(
                eventId: eventId,
                category: category,
                keepingTagValue: tagValue
            )
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
        INSERT INTO event_tags (
            eventId, tagCategory, tagValue, source, totalScore,
            isRejected, createdAt, updatedAt
        )
        VALUES (?, ?, ?, ?, ?, 0, ?, ?)
        ON CONFLICT(eventId, tagCategory, tagValue) DO UPDATE SET
            source = CASE
                WHEN event_tags.source = 'user' AND excluded.source = 'ai' THEN event_tags.source
                ELSE excluded.source
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

        if let totalScore {
            sqlite3_bind_double(statement, 5, totalScore)
        } else {
            sqlite3_bind_null(statement, 5)
        }

        sqlite3_bind_text(statement, 6, (now as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (now as NSString).utf8String, -1, nil)
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
        // TEMP: do not write rejection tombstones while troubleshooting AI tagging.
        if Self.temporarilyIgnoreAITagRejections { return }

        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
        INSERT INTO event_tags (
            eventId, tagCategory, tagValue, source, totalScore,
            isRejected, createdAt, updatedAt
        )
        VALUES (?, ?, ?, 'ai', NULL, 1, ?, ?)
        ON CONFLICT(eventId, tagCategory, tagValue) DO UPDATE SET
            source = 'ai',
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

    private func deleteOtherTagValuesUnsafe(
        eventId: Int,
        category: String,
        keepingTagValue: String
    ) {
        // Keep rejected AI tombstones (isRejected = 1) so e.g. Wedding cannot be
        // re-suggested after the user removes it and applies Prom / Engagement / etc.
        let sql = """
        DELETE FROM event_tags
        WHERE eventId = ?
          AND tagCategory = ?
          AND LOWER(tagValue) != LOWER(?)
          AND COALESCE(isRejected, 0) = 0;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let categoryNS = category as NSString
            let keepingNS = keepingTagValue as NSString
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_text(statement, 2, categoryNS.utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, keepingNS.utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
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

    @discardableResult
    func purgeEventAttributeTagUnsafe(
        eventId: Int,
        category: String,
        tagValue: String
    ) -> Int {
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard eventId > 0, !trimmedCategory.isEmpty, !trimmedValue.isEmpty else { return 0 }

        let sql = """
        DELETE FROM event_tags
        WHERE eventId = ?
          AND tagCategory = ? COLLATE NOCASE
          AND tagValue = ? COLLATE NOCASE;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_int(statement, 1, Int32(eventId))
        sqlite3_bind_text(statement, 2, (trimmedCategory as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (trimmedValue as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
        let deleted = Int(sqlite3_changes(db))
        sqlite3_finalize(statement)
        return deleted
    }

    @discardableResult
    func purgeRejectedAttributeTagsUnsafe(eventId: Int) -> Int {
        guard eventId > 0 else { return 0 }
        let sql = """
        DELETE FROM event_tags
        WHERE eventId = ?
          AND COALESCE(isRejected, 0) = 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_int(statement, 1, Int32(eventId))
        sqlite3_step(statement)
        let deleted = Int(sqlite3_changes(db))
        sqlite3_finalize(statement)
        return deleted
    }

    func fetchAllAttributeTagRowsForEventUnsafe(eventId: Int) -> [(
        category: String,
        tagValue: String,
        source: String,
        isRejected: Bool
    )] {
        let sql = """
        SELECT tagCategory, tagValue, source, COALESCE(isRejected, 0)
        FROM event_tags
        WHERE eventId = ?
        ORDER BY tagCategory COLLATE NOCASE, tagValue COLLATE NOCASE, source COLLATE NOCASE;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(eventId))
        var rows: [(category: String, tagValue: String, source: String, isRejected: Bool)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let categoryC = sqlite3_column_text(statement, 0),
                  let valueC = sqlite3_column_text(statement, 1),
                  let sourceC = sqlite3_column_text(statement, 2) else {
                continue
            }
            rows.append(
                (
                    category: String(cString: categoryC),
                    tagValue: String(cString: valueC),
                    source: String(cString: sourceC),
                    isRejected: sqlite3_column_int(statement, 3) == 1
                )
            )
        }
        return rows
    }

    private func deleteAttributeTagValueUnsafe(
        eventId: Int,
        category: String,
        tagValue: String,
        source: EventTagSource
    ) {
        let sql = """
        DELETE FROM event_tags
        WHERE eventId = ?
          AND tagCategory = ?
          AND tagValue = ? COLLATE NOCASE
          AND source = ?;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_text(statement, 2, (category as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (tagValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 4, (source.rawValue as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    private func deleteAttributeTagCategoryUnsafe(eventId: Int, category: String) {
        let sql = """
        DELETE FROM event_tags
        WHERE eventId = ?
          AND tagCategory = ?;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_text(statement, 2, (category as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    private func deleteHolidayTagUnsafe(eventId: Int, source: EventTagSource) {
        deleteAttributeTagUnsafe(eventId: eventId, category: Self.holidayCategory, source: source)
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
