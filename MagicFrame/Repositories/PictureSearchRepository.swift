import Foundation
import SQLite3

final class PictureSearchRepository {

    private let database: DatabaseManager
    private let holidays: HolidayRepository?

    init(database: DatabaseManager, holidays: HolidayRepository? = nil) {
        self.database = database
        self.holidays = holidays
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

    func savePictureSearch(_ definition: PictureSearchDefinition) -> Int {
        sync { savePictureSearchUnsafe(definition) }
    }

    func fetchPictureSearch(pictureSearchId: Int) -> PictureSearchDefinition? {
        sync { fetchPictureSearchUnsafe(pictureSearchId: pictureSearchId) }
    }

    func fetchAllPictureSearches() -> [PictureSearchDefinition] {
        sync { fetchAllPictureSearchesUnsafe() }
    }

    func fetchFloatingHolidays() -> [FloatingHolidayDefinition] {
        sync { fetchFloatingHolidaysUnsafe() }
    }

    func upsertFloatingHoliday(_ holiday: FloatingHolidayDefinition) -> Int {
        sync { upsertFloatingHolidayUnsafe(holiday) }
    }

    func runPictureSearch(pictureSearchId: Int) -> PictureSearchRunReport? {
        sync {
            guard let definition = fetchPictureSearchUnsafe(pictureSearchId: pictureSearchId) else {
                return nil
            }
            return runPictureSearchUnsafe(definition)
        }
    }

    func runPictureSearch(_ definition: PictureSearchDefinition) -> PictureSearchRunReport {
        sync {
            let id = savePictureSearchUnsafe(definition)
            guard let saved = fetchPictureSearchUnsafe(pictureSearchId: id) else {
                return PictureSearchRunReport(
                    pictureSearchRunId: -1,
                    pictureSearchId: id,
                    targetEventType: definition.targetEventType,
                    photoMatches: [],
                    eventCandidateCount: 0
                )
            }
            return runPictureSearchUnsafe(saved)
        }
    }

    func fetchLatestRunMatches(pictureSearchId: Int) -> PictureSearchRunReport? {
        sync { fetchLatestRunMatchesUnsafe(pictureSearchId: pictureSearchId) }
    }

    /// Loads the tile-named Event Score Card, creating defaults from the Picture Search when missing.
    func ensureEventScoreCardSettings(
        for definition: PictureSearchDefinition,
        personNamesById: [Int: String] = [:]
    ) -> PictureSearchEventScoreCardSettings {
        sync {
            ensureEventScoreCardSettingsUnsafe(
                for: definition,
                personNamesById: personNamesById
            )
        }
    }

    @discardableResult
    func saveEventScoreCardSettings(
        _ settings: PictureSearchEventScoreCardSettings
    ) -> PictureSearchEventScoreCardSettings {
        sync { saveEventScoreCardSettingsUnsafe(settings) }
    }

    func fetchEventScoreCardSettings(named name: String) -> PictureSearchEventScoreCardSettings? {
        sync { fetchEventScoreCardSettingsUnsafe(named: name) }
    }

    func fetchEventScoreCardSettings(
        tagCategory: String,
        tagValue: String
    ) -> PictureSearchEventScoreCardSettings? {
        sync {
            fetchEventScoreCardSettingsUnsafe(tagCategory: tagCategory, tagValue: tagValue)
        }
    }

    func fetchAllEventScoreCardSettings() -> [PictureSearchEventScoreCardSettings] {
        sync { fetchAllEventScoreCardSettingsUnsafe() }
    }

    /// Looks up by tag; seeds from a matching Picture Search when possible; otherwise creates a blank card.
    @discardableResult
    func ensureEventScoreCardSettings(
        tagCategory: String,
        tagValue: String,
        personNamesById: [Int: String] = [:]
    ) -> PictureSearchEventScoreCardSettings {
        sync {
            ensureEventScoreCardSettingsUnsafe(
                tagCategory: tagCategory,
                tagValue: tagValue,
                personNamesById: personNamesById
            )
        }
    }

    /// Finds the saved “Weddings” Picture Search, creating the default definition if missing.
    func ensureWeddingPictureSearch() -> PictureSearchDefinition {
        sync { ensureWeddingPictureSearchUnsafe() }
    }

    /// Ensures the wedding search is saved, runs it, and returns definition + report.
    func runWeddingPictureSearch() -> (definition: PictureSearchDefinition, report: PictureSearchRunReport) {
        sync {
            let definition = ensureWeddingPictureSearchUnsafe()
            let report = runPictureSearchUnsafe(definition)
            let refreshed = fetchPictureSearchUnsafe(pictureSearchId: report.pictureSearchId)
                ?? definition
            return (refreshed, report)
        }
    }

    func ensureChristmasPictureSearch() -> PictureSearchDefinition {
        ensureHolidayPictureSearch(tagValue: "Christmas")
            ?? .christmasDefault()
    }

    func runChristmasPictureSearch() -> (definition: PictureSearchDefinition, report: PictureSearchRunReport) {
        runHolidayPictureSearch(tagValue: "Christmas")
            ?? (
                .christmasDefault(),
                PictureSearchRunReport(
                    pictureSearchRunId: -1,
                    pictureSearchId: -1,
                    targetEventType: "Christmas",
                    photoMatches: [],
                    eventCandidateCount: 0
                )
            )
    }

    func ensureHolidayPictureSearch(tagValue: String) -> PictureSearchDefinition? {
        sync { ensureHolidayPictureSearchUnsafe(tagValue: tagValue) }
    }

    func runHolidayPictureSearch(
        tagValue: String
    ) -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)? {
        sync {
            guard let definition = ensureHolidayPictureSearchUnsafe(tagValue: tagValue) else {
                return nil
            }
            let report = runPictureSearchUnsafe(definition)
            let refreshed = fetchPictureSearchUnsafe(pictureSearchId: report.pictureSearchId)
                ?? definition
            return (refreshed, report)
        }
    }

    func ensureMilestonePictureSearch(topicId: String) -> PictureSearchDefinition? {
        sync { ensureMilestonePictureSearchUnsafe(topicId: topicId) }
    }

    func runMilestonePictureSearch(
        topicId: String
    ) -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)? {
        sync {
            guard let definition = ensureMilestonePictureSearchUnsafe(topicId: topicId) else {
                return nil
            }
            let report = runPictureSearchUnsafe(definition)
            let refreshed = fetchPictureSearchUnsafe(pictureSearchId: report.pictureSearchId)
                ?? definition
            return (refreshed, report)
        }
    }

    func ensureOutingPictureSearch(topicId: String) -> PictureSearchDefinition? {
        sync { ensureOutingPictureSearchUnsafe(topicId: topicId) }
    }

    func runOutingPictureSearch(
        topicId: String
    ) -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)? {
        sync {
            guard let definition = ensureOutingPictureSearchUnsafe(topicId: topicId) else {
                return nil
            }
            let report = runPictureSearchUnsafe(definition)
            let refreshed = fetchPictureSearchUnsafe(pictureSearchId: report.pictureSearchId)
                ?? definition
            return (refreshed, report)
        }
    }

    func ensurePersonBirthdayPictureSearch(
        person: PeopleRepository.PersonBirthdayRecord
    ) -> PictureSearchDefinition? {
        sync { ensurePersonBirthdayPictureSearchUnsafe(person: person) }
    }

    func runPersonBirthdayPictureSearch(
        person: PeopleRepository.PersonBirthdayRecord
    ) -> (definition: PictureSearchDefinition, report: PictureSearchRunReport)? {
        sync {
            guard let definition = ensurePersonBirthdayPictureSearchUnsafe(person: person) else {
                return nil
            }
            let report = runPictureSearchUnsafe(definition)
            let refreshed = fetchPictureSearchUnsafe(pictureSearchId: report.pictureSearchId)
                ?? definition
            return (refreshed, report)
        }
    }

    private func ensureWeddingPictureSearchUnsafe() -> PictureSearchDefinition {
        if let topic = MilestoneTopicCatalog.topic(id: "weddings") {
            return ensureNamedPictureSearchSyncedUnsafe(
                defaults: MilestonePictureSearchDefaults.defaultDefinition(for: topic),
                legacyNames: MilestonePictureSearchDefaults.legacyPictureSearchNames(for: topic)
            )
        }
        return ensureNamedPictureSearchSyncedUnsafe(
            defaults: .weddingDefault(),
            legacyNames: ["Wedding Picture Search", "Wedding"]
        )
    }

    private func ensureMilestonePictureSearchUnsafe(topicId: String) -> PictureSearchDefinition? {
        guard let topic = MilestoneTopicCatalog.topic(id: topicId) else { return nil }
        return ensureNamedPictureSearchSyncedUnsafe(
            defaults: MilestonePictureSearchDefaults.defaultDefinition(for: topic),
            legacyNames: MilestonePictureSearchDefaults.legacyPictureSearchNames(for: topic)
        )
    }

    private func ensureOutingPictureSearchUnsafe(topicId: String) -> PictureSearchDefinition? {
        guard let topic = OutingTopicCatalog.topic(id: topicId) else { return nil }
        return ensureNamedPictureSearchSyncedUnsafe(
            defaults: OutingPictureSearchDefaults.defaultDefinition(for: topic),
            legacyNames: OutingPictureSearchDefaults.legacyPictureSearchNames(for: topic)
        )
    }

    /// Creates the named search if missing; otherwise refreshes seeded Vision tags from defaults
    /// so catalog key fixes (e.g. `graduation` vs `Graduation Cap`) apply to saved searches.
    /// Keeps a single canonical row (tile title); retires legacy “… Picture Search” duplicates.
    /// Never replaces a customized non-empty Vision tag list with empty defaults (that wiped
    /// Developer-edited Outing searches such as Sporting Events → Stadium).
    private func ensureNamedPictureSearchSyncedUnsafe(
        defaults: PictureSearchDefinition,
        legacyNames: [String] = []
    ) -> PictureSearchDefinition {
        var existing = resolveCanonicalPictureSearchUnsafe(
            canonicalName: defaults.name,
            legacyNames: legacyNames
        )

        if existing == nil {
            let id = savePictureSearchUnsafe(defaults)
            return fetchPictureSearchUnsafe(pictureSearchId: id) ?? defaults
        }

        var row = existing!
        let existingKeys = Set(
            row.visionTagSearch.tags.map {
                $0.objectKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
        )
        let defaultKeys = Set(
            defaults.visionTagSearch.tags.map {
                $0.objectKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
        )
        // Catalog defaults may push key renames, but empty defaults must not erase user tags.
        let shouldApplyVisionDefaults = !defaultKeys.isEmpty
        let needsVisionSync = shouldApplyVisionDefaults
            && (
                existingKeys != defaultKeys
                    || row.visionTagSearch.matchMode != defaults.visionTagSearch.matchMode
            )
        let needsTargetSync =
            row.targetEventType != defaults.targetEventType
            || row.targetTagCategory != defaults.targetTagCategory
        let needsRename =
            row.name.compare(defaults.name, options: .caseInsensitive) != .orderedSame
        let needsFaceDetectSync = row.performFaceDetect != defaults.performFaceDetect

        guard needsVisionSync || needsTargetSync || needsRename || needsFaceDetectSync else {
            return row
        }

        row.name = defaults.name
        if needsVisionSync {
            row.visionTagSearch.tags = defaults.visionTagSearch.tags
            row.visionTagSearch.matchMode = defaults.visionTagSearch.matchMode
        }
        row.targetEventType = defaults.targetEventType
        row.targetTagCategory = defaults.targetTagCategory
        row.performFaceDetect = defaults.performFaceDetect
        let id = savePictureSearchUnsafe(row)
        return fetchPictureSearchUnsafe(pictureSearchId: id) ?? row
    }

    /// Ensures a person birthday search exists and keeps the date anchor synced to birth month/day.
    private func ensurePersonBirthdayPictureSearchUnsafe(
        person: PeopleRepository.PersonBirthdayRecord
    ) -> PictureSearchDefinition? {
        guard var defaults = MilestonePictureSearchDefaults.personBirthdayDefinition(for: person) else {
            return nil
        }
        let legacy = MilestonePictureSearchDefaults.legacyPictureSearchNames(forPersonBirthday: person)
        if let existing = resolveCanonicalPictureSearchUnsafe(
            canonicalName: defaults.name,
            legacyNames: legacy
        ) {
            defaults.pictureSearchId = existing.pictureSearchId
            defaults.dateSearch.dateSearchId = existing.dateSearch.dateSearchId
            defaults.visionTagSearch.visionTagSearchId = existing.visionTagSearch.visionTagSearchId
            defaults.locationSearch.locationSearchId = existing.locationSearch.locationSearchId
            defaults.peopleSearch.peopleSearchId = existing.peopleSearch.peopleSearchId
            // Always re-apply birth-month/day + person filter from the people record.
            let id = savePictureSearchUnsafe(defaults)
            return fetchPictureSearchUnsafe(pictureSearchId: id) ?? defaults
        }
        let id = savePictureSearchUnsafe(defaults)
        return fetchPictureSearchUnsafe(pictureSearchId: id) ?? defaults
    }

    private func ensureHolidayPictureSearchUnsafe(tagValue: String) -> PictureSearchDefinition? {
        let defaults: PictureSearchDefinition
        if let holiday = holidays?.fetchHolidayUnsafe(named: tagValue) {
            defaults = HolidayPictureSearchDefaults.defaultDefinition(for: holiday)
        } else if let fallback = PictureSearchDefinition.holidayDefault(tagValue: tagValue) {
            defaults = fallback
        } else {
            return nil
        }
        return ensureNamedPictureSearchSyncedUnsafe(
            defaults: defaults,
            legacyNames: HolidayPictureSearchDefaults.legacyPictureSearchNames(forTagValue: tagValue)
        )
    }

    private func ensureNamedPictureSearchUnsafe(
        defaults: PictureSearchDefinition
    ) -> PictureSearchDefinition {
        ensureNamedPictureSearchSyncedUnsafe(defaults: defaults, legacyNames: [])
    }

    /// Prefer the newest row whose name matches the canonical tile title or a legacy alias.
    /// Retires older duplicates so programmatic lookup stays one-name-one-search.
    private func resolveCanonicalPictureSearchUnsafe(
        canonicalName: String,
        legacyNames: [String]
    ) -> PictureSearchDefinition? {
        let canonical = canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return nil }

        var aliases = Set(legacyNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        aliases.insert(canonical)
        aliases = Set(aliases.filter { !$0.isEmpty })

        let matches = fetchAllPictureSearchesUnsafe()
            .filter { search in
                aliases.contains { alias in
                    search.name.compare(alias, options: .caseInsensitive) == .orderedSame
                }
            }
            .sorted { ($0.pictureSearchId ?? 0) > ($1.pictureSearchId ?? 0) }

        guard let keeper = matches.first else { return nil }

        for duplicate in matches.dropFirst() {
            guard let duplicateId = duplicate.pictureSearchId, duplicateId > 0 else { continue }
            retireDuplicatePictureSearchUnsafe(
                pictureSearchId: duplicateId,
                canonicalName: canonical
            )
        }

        return keeper
    }

    private func retireDuplicatePictureSearchUnsafe(pictureSearchId: Int, canonicalName: String) {
        let archivedName = "\(canonicalName) (archived \(pictureSearchId))"
        let sql = """
        UPDATE picture_searches
        SET name = ?,
            isEnabled = 0,
            updatedAt = ?
        WHERE pictureSearchId = ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (archivedName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (nowISO as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(pictureSearchId))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Save

    private func savePictureSearchUnsafe(_ definition: PictureSearchDefinition) -> Int {
        var definition = definition
        // One row per display name: saving “Weddings” again updates the existing search.
        if definition.pictureSearchId == nil || (definition.pictureSearchId ?? 0) <= 0 {
            if let existing = fetchAllPictureSearchesUnsafe().first(where: {
                $0.name.compare(definition.name, options: .caseInsensitive) == .orderedSame
            }) {
                definition.pictureSearchId = existing.pictureSearchId
                if definition.dateSearch.dateSearchId == nil {
                    definition.dateSearch.dateSearchId = existing.dateSearch.dateSearchId
                }
                if definition.visionTagSearch.visionTagSearchId == nil {
                    definition.visionTagSearch.visionTagSearchId = existing.visionTagSearch.visionTagSearchId
                }
                if definition.locationSearch.locationSearchId == nil {
                    definition.locationSearch.locationSearchId = existing.locationSearch.locationSearchId
                }
                if definition.peopleSearch.peopleSearchId == nil {
                    definition.peopleSearch.peopleSearchId = existing.peopleSearch.peopleSearchId
                }
            }
        }

        let timestamp = nowISO
        let dateSearchId = upsertDateSearchUnsafe(definition.dateSearch, timestamp: timestamp)
        let visionTagSearchId = upsertVisionTagSearchUnsafe(
            definition.visionTagSearch,
            timestamp: timestamp
        )
        let locationSearchId = upsertLocationSearchUnsafe(
            definition.locationSearch,
            timestamp: timestamp
        )
        let peopleSearchId = upsertPeopleSearchUnsafe(
            definition.peopleSearch,
            timestamp: timestamp
        )

        let resolvedCategory = definition.targetTagCategory
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            ? definition.targetAttributeField.tagCategory
            : definition.targetTagCategory

        if let existingId = definition.pictureSearchId, existingId > 0 {
            let sql = """
            UPDATE picture_searches
            SET name = ?,
                targetTagCategory = ?,
                targetEventType = ?,
                dateSearchId = ?,
                visionTagSearchId = ?,
                locationSearchId = ?,
                peopleSearchId = ?,
                isEnabled = ?,
                performFaceDetect = ?,
                updatedAt = ?
            WHERE pictureSearchId = ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (definition.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 2, (resolvedCategory as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (definition.targetEventType as NSString).utf8String, -1, nil)
                bindOptionalInt(statement, 4, dateSearchId)
                bindOptionalInt(statement, 5, visionTagSearchId)
                bindOptionalInt(statement, 6, locationSearchId)
                bindOptionalInt(statement, 7, peopleSearchId)
                sqlite3_bind_int(statement, 8, definition.isEnabled ? 1 : 0)
                sqlite3_bind_int(statement, 9, definition.performFaceDetect ? 1 : 0)
                sqlite3_bind_text(statement, 10, (timestamp as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 11, Int32(existingId))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            return existingId
        }

        let sql = """
        INSERT INTO picture_searches (
            name, targetTagCategory, targetEventType, dateSearchId, visionTagSearchId,
            locationSearchId, peopleSearchId, isEnabled, performFaceDetect, createdAt, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (definition.name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (resolvedCategory as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (definition.targetEventType as NSString).utf8String, -1, nil)
            bindOptionalInt(statement, 4, dateSearchId)
            bindOptionalInt(statement, 5, visionTagSearchId)
            bindOptionalInt(statement, 6, locationSearchId)
            bindOptionalInt(statement, 7, peopleSearchId)
            sqlite3_bind_int(statement, 8, definition.isEnabled ? 1 : 0)
            sqlite3_bind_int(statement, 9, definition.performFaceDetect ? 1 : 0)
            sqlite3_bind_text(statement, 10, (timestamp as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 11, (timestamp as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        return Int(sqlite3_last_insert_rowid(db))
    }

    private func isDateSearchReferencedByPictureSearchUnsafe(dateSearchId: Int) -> Bool {
        let sql = """
        SELECT 1
        FROM picture_searches
        WHERE dateSearchId = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(dateSearchId))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func upsertDateSearchUnsafe(
        _ definition: DateSearchDefinition,
        timestamp: String
    ) -> Int? {
        if let existingId = definition.dateSearchId, existingId > 0 {
            let sql = """
            UPDATE date_searches SET
                name = ?, dateSearchType = ?, sameDateSearchDate = ?,
                movingHolidayKey = ?, floatingHolidayId = ?, holidayId = ?,
                rangeStartMonthDay = ?, rangeEndMonthDay = ?,
                absoluteStartDate = ?, absoluteEndDate = ?,
                includeWeekendsBefore = ?, includeWeekendsAfter = ?,
                includeDaysBefore = ?, includeDaysAfter = ?,
                includeXDaysBefore = ?, includeYDaysAfter = ?,
                updatedAt = ?
            WHERE dateSearchId = ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                bindDateSearchValues(statement, definition, timestamp: timestamp, updating: true)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            return existingId
        }

        let sql = """
        INSERT INTO date_searches (
            name, dateSearchType, sameDateSearchDate, movingHolidayKey, floatingHolidayId, holidayId,
            rangeStartMonthDay, rangeEndMonthDay, absoluteStartDate, absoluteEndDate,
            includeWeekendsBefore, includeWeekendsAfter, includeDaysBefore, includeDaysAfter,
            includeXDaysBefore, includeYDaysAfter, createdAt, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindDateSearchValues(statement, definition, timestamp: timestamp, updating: false)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        let id = Int(sqlite3_last_insert_rowid(db))
        return id > 0 ? id : nil
    }

    private func bindDateSearchValues(
        _ statement: OpaquePointer?,
        _ definition: DateSearchDefinition,
        timestamp: String,
        updating: Bool
    ) {
        sqlite3_bind_text(statement, 1, optionalUTF8(definition.name), -1, nil)
        sqlite3_bind_text(statement, 2, (definition.dateSearchType.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, optionalUTF8(definition.sameDateSearchDate), -1, nil)
        sqlite3_bind_text(statement, 4, optionalUTF8(definition.movingHolidayKey), -1, nil)
        bindOptionalInt(statement, 5, definition.floatingHolidayId)
        bindOptionalInt(statement, 6, definition.holidayId)
        sqlite3_bind_text(statement, 7, optionalUTF8(definition.rangeStartMonthDay), -1, nil)
        sqlite3_bind_text(statement, 8, optionalUTF8(definition.rangeEndMonthDay), -1, nil)
        sqlite3_bind_text(statement, 9, optionalUTF8(definition.absoluteStartDate), -1, nil)
        sqlite3_bind_text(statement, 10, optionalUTF8(definition.absoluteEndDate), -1, nil)
        sqlite3_bind_int(statement, 11, definition.includeWeekendsBefore ? 1 : 0)
        sqlite3_bind_int(statement, 12, definition.includeWeekendsAfter ? 1 : 0)
        sqlite3_bind_int(statement, 13, definition.includeDaysBefore ? 1 : 0)
        sqlite3_bind_int(statement, 14, definition.includeDaysAfter ? 1 : 0)
        bindOptionalInt(statement, 15, definition.includeXDaysBefore)
        bindOptionalInt(statement, 16, definition.includeYDaysAfter)
        if updating {
            sqlite3_bind_text(statement, 17, (timestamp as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 18, Int32(definition.dateSearchId ?? 0))
        } else {
            sqlite3_bind_text(statement, 17, (timestamp as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 18, (timestamp as NSString).utf8String, -1, nil)
        }
    }

    private func upsertVisionTagSearchUnsafe(
        _ definition: VisionTagSearchDefinition,
        timestamp: String
    ) -> Int? {
        let searchId: Int
        if let existingId = definition.visionTagSearchId, existingId > 0 {
            let sql = """
            UPDATE vision_tag_searches
            SET name = ?, matchMode = ?
            WHERE visionTagSearchId = ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, optionalUTF8(definition.name), -1, nil)
                sqlite3_bind_text(statement, 2, (definition.matchMode as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 3, Int32(existingId))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            searchId = existingId
            execSQL("DELETE FROM vision_tag_search_tags WHERE visionTagSearchId = \(searchId);")
        } else {
            let sql = """
            INSERT INTO vision_tag_searches (name, matchMode, createdAt)
            VALUES (?, ?, ?);
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, optionalUTF8(definition.name), -1, nil)
                sqlite3_bind_text(statement, 2, (definition.matchMode as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (timestamp as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            searchId = Int(sqlite3_last_insert_rowid(db))
        }

        let insertSQL = """
        INSERT OR IGNORE INTO vision_tag_search_tags (visionTagSearchId, objectKey, minConfidence)
        VALUES (?, ?, ?);
        """
        for tag in definition.tags {
            let trimmed = tag.objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let minConfidence = max(0, min(1, tag.minConfidence))
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(searchId))
                sqlite3_bind_text(statement, 2, (trimmed as NSString).utf8String, -1, nil)
                sqlite3_bind_double(statement, 3, minConfidence)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
        return searchId > 0 ? searchId : nil
    }

    private func upsertLocationSearchUnsafe(
        _ definition: LocationSearchDefinition,
        timestamp: String
    ) -> Int? {
        let terms = definition.searchTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty || definition.locationSearchId != nil else { return nil }

        let searchId: Int
        if let existingId = definition.locationSearchId, existingId > 0 {
            let sql = """
            UPDATE location_searches SET name = ?, matchMode = ?
            WHERE locationSearchId = ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, optionalUTF8(definition.name), -1, nil)
                sqlite3_bind_text(statement, 2, (definition.matchMode as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 3, Int32(existingId))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            searchId = existingId
            execSQL("DELETE FROM location_search_terms WHERE locationSearchId = \(searchId);")
        } else {
            guard !terms.isEmpty else { return nil }
            let sql = """
            INSERT INTO location_searches (name, matchMode, createdAt)
            VALUES (?, ?, ?);
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, optionalUTF8(definition.name), -1, nil)
                sqlite3_bind_text(statement, 2, (definition.matchMode as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (timestamp as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            searchId = Int(sqlite3_last_insert_rowid(db))
        }

        let insertSQL = """
        INSERT INTO location_search_terms (locationSearchId, searchTerm, sortOrder)
        VALUES (?, ?, ?);
        """
        for (index, term) in terms.enumerated() {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(searchId))
                sqlite3_bind_text(statement, 2, (term as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 3, Int32(index))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
        return searchId > 0 ? searchId : nil
    }

    private func upsertPeopleSearchUnsafe(
        _ definition: PeopleSearchDefinition,
        timestamp: String
    ) -> Int? {
        guard !definition.personIds.isEmpty || definition.peopleSearchId != nil else { return nil }

        let searchId: Int
        if let existingId = definition.peopleSearchId, existingId > 0 {
            let sql = """
            UPDATE people_searches SET name = ?, matchMode = ?
            WHERE peopleSearchId = ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, optionalUTF8(definition.name), -1, nil)
                sqlite3_bind_text(statement, 2, (definition.matchMode as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 3, Int32(existingId))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            searchId = existingId
            execSQL("DELETE FROM people_search_people WHERE peopleSearchId = \(searchId);")
        } else {
            guard !definition.personIds.isEmpty else { return nil }
            let sql = """
            INSERT INTO people_searches (name, matchMode, createdAt)
            VALUES (?, ?, ?);
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, optionalUTF8(definition.name), -1, nil)
                sqlite3_bind_text(statement, 2, (definition.matchMode as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 3, (timestamp as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            searchId = Int(sqlite3_last_insert_rowid(db))
        }

        let insertSQL = """
        INSERT OR IGNORE INTO people_search_people (peopleSearchId, personId)
        VALUES (?, ?);
        """
        for personId in definition.personIds {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(searchId))
                sqlite3_bind_int(statement, 2, Int32(personId))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
        return searchId > 0 ? searchId : nil
    }

    // MARK: - Fetch

    private func fetchAllPictureSearchesUnsafe() -> [PictureSearchDefinition] {
        let sql = """
        SELECT pictureSearchId FROM picture_searches
        ORDER BY updatedAt DESC, pictureSearchId DESC;
        """
        var statement: OpaquePointer?
        var ids: [Int] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.append(Int(sqlite3_column_int(statement, 0)))
            }
        }
        sqlite3_finalize(statement)
        return ids.compactMap { fetchPictureSearchUnsafe(pictureSearchId: $0) }
    }

    private func fetchPictureSearchUnsafe(pictureSearchId: Int) -> PictureSearchDefinition? {
        let sql = """
        SELECT pictureSearchId, name, targetTagCategory, targetEventType, dateSearchId,
               visionTagSearchId, locationSearchId, peopleSearchId, isEnabled,
               COALESCE(performFaceDetect, 0)
        FROM picture_searches
        WHERE pictureSearchId = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int(statement, 1, Int32(pictureSearchId))

        guard sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            return nil
        }

        let id = Int(sqlite3_column_int(statement, 0))
        let name = String(cString: sqlite3_column_text(statement, 1))
        let storedCategory = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? ""
            : String(cString: sqlite3_column_text(statement, 2))
        let targetEventType = String(cString: sqlite3_column_text(statement, 3))
        let dateSearchId = optionalInt(statement, 4)
        let visionTagSearchId = optionalInt(statement, 5)
        let locationSearchId = optionalInt(statement, 6)
        let peopleSearchId = optionalInt(statement, 7)
        let isEnabled = sqlite3_column_int(statement, 8) != 0
        let performFaceDetect = sqlite3_column_int(statement, 9) != 0
        sqlite3_finalize(statement)

        let targetTagCategory = storedCategory
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            ? EventAttributeField.pictureSearchCategory(forTargetValue: targetEventType).tagCategory
            : storedCategory

        return PictureSearchDefinition(
            pictureSearchId: id,
            name: name,
            targetTagCategory: targetTagCategory,
            targetEventType: targetEventType,
            dateSearch: dateSearchId.flatMap { fetchDateSearchUnsafe(dateSearchId: $0) }
                ?? .weddingDefault(),
            visionTagSearch: visionTagSearchId.flatMap { fetchVisionTagSearchUnsafe(id: $0) }
                ?? .weddingDefault(),
            locationSearch: locationSearchId.flatMap { fetchLocationSearchUnsafe(id: $0) }
                ?? .empty(),
            peopleSearch: peopleSearchId.flatMap { fetchPeopleSearchUnsafe(id: $0) }
                ?? .empty(),
            isEnabled: isEnabled,
            performFaceDetect: performFaceDetect
        )
    }

    private func fetchDateSearchUnsafe(dateSearchId: Int) -> DateSearchDefinition? {
        let hasHolidayId = Self.dateSearchesHasHolidayIdColumn(db)
        let sql: String
        if hasHolidayId {
            sql = """
            SELECT dateSearchId, name, dateSearchType, sameDateSearchDate, movingHolidayKey,
                   floatingHolidayId, holidayId, rangeStartMonthDay, rangeEndMonthDay,
                   absoluteStartDate, absoluteEndDate,
                   includeWeekendsBefore, includeWeekendsAfter,
                   includeDaysBefore, includeDaysAfter,
                   includeXDaysBefore, includeYDaysAfter
            FROM date_searches
            WHERE dateSearchId = ?
            LIMIT 1;
            """
        } else {
            sql = """
            SELECT dateSearchId, name, dateSearchType, sameDateSearchDate, movingHolidayKey,
                   floatingHolidayId, rangeStartMonthDay, rangeEndMonthDay,
                   absoluteStartDate, absoluteEndDate,
                   includeWeekendsBefore, includeWeekendsAfter,
                   includeDaysBefore, includeDaysAfter,
                   includeXDaysBefore, includeYDaysAfter
            FROM date_searches
            WHERE dateSearchId = ?
            LIMIT 1;
            """
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int(statement, 1, Int32(dateSearchId))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            return nil
        }

        let typeRaw = String(cString: sqlite3_column_text(statement, 2))
        let definition: DateSearchDefinition
        if hasHolidayId {
            definition = DateSearchDefinition(
                dateSearchId: Int(sqlite3_column_int(statement, 0)),
                name: optionalString(statement, 1),
                dateSearchType: PictureDateSearchType(rawValue: typeRaw) ?? .allDates,
                sameDateSearchDate: optionalString(statement, 3),
                movingHolidayKey: optionalString(statement, 4),
                floatingHolidayId: optionalInt(statement, 5),
                holidayId: optionalInt(statement, 6),
                rangeStartMonthDay: optionalString(statement, 7),
                rangeEndMonthDay: optionalString(statement, 8),
                absoluteStartDate: optionalString(statement, 9),
                absoluteEndDate: optionalString(statement, 10),
                includeWeekendsBefore: sqlite3_column_int(statement, 11) != 0,
                includeWeekendsAfter: sqlite3_column_int(statement, 12) != 0,
                includeDaysBefore: sqlite3_column_int(statement, 13) != 0,
                includeDaysAfter: sqlite3_column_int(statement, 14) != 0,
                includeXDaysBefore: optionalInt(statement, 15),
                includeYDaysAfter: optionalInt(statement, 16)
            )
        } else {
            definition = DateSearchDefinition(
                dateSearchId: Int(sqlite3_column_int(statement, 0)),
                name: optionalString(statement, 1),
                dateSearchType: PictureDateSearchType(rawValue: typeRaw) ?? .allDates,
                sameDateSearchDate: optionalString(statement, 3),
                movingHolidayKey: optionalString(statement, 4),
                floatingHolidayId: optionalInt(statement, 5),
                holidayId: nil,
                rangeStartMonthDay: optionalString(statement, 6),
                rangeEndMonthDay: optionalString(statement, 7),
                absoluteStartDate: optionalString(statement, 8),
                absoluteEndDate: optionalString(statement, 9),
                includeWeekendsBefore: sqlite3_column_int(statement, 10) != 0,
                includeWeekendsAfter: sqlite3_column_int(statement, 11) != 0,
                includeDaysBefore: sqlite3_column_int(statement, 12) != 0,
                includeDaysAfter: sqlite3_column_int(statement, 13) != 0,
                includeXDaysBefore: optionalInt(statement, 14),
                includeYDaysAfter: optionalInt(statement, 15)
            )
        }
        sqlite3_finalize(statement)
        return definition
    }

    private static func dateSearchesHasHolidayIdColumn(_ db: OpaquePointer?) -> Bool {
        guard let db else { return false }
        return SQLiteMigrations.columnExists(table: "date_searches", column: "holidayId", on: db)
    }

    private func fetchVisionTagSearchUnsafe(id: Int) -> VisionTagSearchDefinition? {
        let sql = """
        SELECT visionTagSearchId, name, matchMode
        FROM vision_tag_searches
        WHERE visionTagSearchId = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int(statement, 1, Int32(id))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            return nil
        }
        let searchId = Int(sqlite3_column_int(statement, 0))
        let name = optionalString(statement, 1)
        let matchMode = String(cString: sqlite3_column_text(statement, 2))
        sqlite3_finalize(statement)

        let tagsSQL = """
        SELECT objectKey, COALESCE(minConfidence, 0.12)
        FROM vision_tag_search_tags
        WHERE visionTagSearchId = ?
        ORDER BY objectKey COLLATE NOCASE ASC;
        """
        var tagsStatement: OpaquePointer?
        var tags: [VisionTagCriterion] = []
        if sqlite3_prepare_v2(db, tagsSQL, -1, &tagsStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(tagsStatement, 1, Int32(searchId))
            while sqlite3_step(tagsStatement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(tagsStatement, 0) {
                    tags.append(
                        VisionTagCriterion(
                            objectKey: String(cString: cString),
                            minConfidence: sqlite3_column_double(tagsStatement, 1)
                        )
                    )
                }
            }
        }
        sqlite3_finalize(tagsStatement)

        return VisionTagSearchDefinition(
            visionTagSearchId: searchId,
            name: name,
            matchMode: matchMode,
            tags: tags
        )
    }

    private func fetchLocationSearchUnsafe(id: Int) -> LocationSearchDefinition? {
        let sql = """
        SELECT locationSearchId, name, matchMode
        FROM location_searches
        WHERE locationSearchId = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int(statement, 1, Int32(id))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            return nil
        }
        let searchId = Int(sqlite3_column_int(statement, 0))
        let name = optionalString(statement, 1)
        let matchMode = String(cString: sqlite3_column_text(statement, 2))
        sqlite3_finalize(statement)

        let termsSQL = """
        SELECT searchTerm FROM location_search_terms
        WHERE locationSearchId = ?
        ORDER BY sortOrder ASC, locationSearchTermId ASC;
        """
        var termsStatement: OpaquePointer?
        var terms: [String] = []
        if sqlite3_prepare_v2(db, termsSQL, -1, &termsStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(termsStatement, 1, Int32(searchId))
            while sqlite3_step(termsStatement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(termsStatement, 0) {
                    terms.append(String(cString: cString))
                }
            }
        }
        sqlite3_finalize(termsStatement)

        return LocationSearchDefinition(
            locationSearchId: searchId,
            name: name,
            matchMode: matchMode,
            searchTerms: terms
        )
    }

    private func fetchPeopleSearchUnsafe(id: Int) -> PeopleSearchDefinition? {
        let sql = """
        SELECT peopleSearchId, name, matchMode
        FROM people_searches
        WHERE peopleSearchId = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int(statement, 1, Int32(id))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            return nil
        }
        let searchId = Int(sqlite3_column_int(statement, 0))
        let name = optionalString(statement, 1)
        let matchMode = String(cString: sqlite3_column_text(statement, 2))
        sqlite3_finalize(statement)

        let peopleSQL = """
        SELECT personId FROM people_search_people
        WHERE peopleSearchId = ?
        ORDER BY personId ASC;
        """
        var peopleStatement: OpaquePointer?
        var personIds: [Int] = []
        if sqlite3_prepare_v2(db, peopleSQL, -1, &peopleStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(peopleStatement, 1, Int32(searchId))
            while sqlite3_step(peopleStatement) == SQLITE_ROW {
                personIds.append(Int(sqlite3_column_int(peopleStatement, 0)))
            }
        }
        sqlite3_finalize(peopleStatement)

        return PeopleSearchDefinition(
            peopleSearchId: searchId,
            name: name,
            matchMode: matchMode,
            personIds: personIds
        )
    }

    private func fetchFloatingHolidaysUnsafe() -> [FloatingHolidayDefinition] {
        let sql = """
        SELECT floatingHolidayId, name, ruleKind, month, weekday, weekOrdinal, isEnabled
        FROM floating_holidays
        WHERE isEnabled = 1
        ORDER BY name COLLATE NOCASE ASC;
        """
        var statement: OpaquePointer?
        var holidays: [FloatingHolidayDefinition] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                holidays.append(
                    FloatingHolidayDefinition(
                        floatingHolidayId: Int(sqlite3_column_int(statement, 0)),
                        name: String(cString: sqlite3_column_text(statement, 1)),
                        ruleKind: String(cString: sqlite3_column_text(statement, 2)),
                        month: Int(sqlite3_column_int(statement, 3)),
                        weekday: Int(sqlite3_column_int(statement, 4)),
                        weekOrdinal: Int(sqlite3_column_int(statement, 5)),
                        isEnabled: sqlite3_column_int(statement, 6) != 0
                    )
                )
            }
        }
        sqlite3_finalize(statement)
        return holidays
    }

    private func upsertFloatingHolidayUnsafe(_ holiday: FloatingHolidayDefinition) -> Int {
        let sql = """
        INSERT INTO floating_holidays (name, ruleKind, month, weekday, weekOrdinal, isEnabled)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(name) DO UPDATE SET
            ruleKind = excluded.ruleKind,
            month = excluded.month,
            weekday = excluded.weekday,
            weekOrdinal = excluded.weekOrdinal,
            isEnabled = excluded.isEnabled;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (holiday.name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (holiday.ruleKind as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(holiday.month))
            sqlite3_bind_int(statement, 4, Int32(holiday.weekday))
            sqlite3_bind_int(statement, 5, Int32(holiday.weekOrdinal))
            sqlite3_bind_int(statement, 6, holiday.isEnabled ? 1 : 0)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)

        let selectSQL = "SELECT floatingHolidayId FROM floating_holidays WHERE name = ? LIMIT 1;"
        var selectStatement: OpaquePointer?
        var id = -1
        if sqlite3_prepare_v2(db, selectSQL, -1, &selectStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(selectStatement, 1, (holiday.name as NSString).utf8String, -1, nil)
            if sqlite3_step(selectStatement) == SQLITE_ROW {
                id = Int(sqlite3_column_int(selectStatement, 0))
            }
        }
        sqlite3_finalize(selectStatement)
        return id
    }

    // MARK: - Run

    private func runPictureSearchUnsafe(_ definition: PictureSearchDefinition) -> PictureSearchRunReport {
        let pictureSearchId = definition.pictureSearchId ?? savePictureSearchUnsafe(definition)
        let startedAt = nowISO
        let runId = insertRunUnsafe(
            pictureSearchId: pictureSearchId,
            startedAt: startedAt,
            status: "running"
        )

        let floatingHoliday: FloatingHolidayDefinition? = {
            guard let floatingId = definition.dateSearch.floatingHolidayId else { return nil }
            return fetchFloatingHolidaysUnsafe().first { $0.floatingHolidayId == floatingId }
        }()
        let catalogHoliday: HolidayDefinition? = {
            if let holidayId = definition.dateSearch.holidayId {
                return holidays?.fetchHolidayUnsafe(holidayId: holidayId)
            }
            // Older UI stored catalog floating holidays in floatingHolidayId.
            if let floatingId = definition.dateSearch.floatingHolidayId,
               let holiday = holidays?.fetchHolidayUnsafe(holidayId: floatingId) {
                return holiday
            }
            return nil
        }()

        let candidates = fetchCandidatePhotosUnsafe(definition)
        var matches: [PictureSearchPhotoMatch] = []

        for candidate in candidates {
            let dateOK = PictureSearchDateMatcher.matches(
                photoDateISO: candidate.effectiveDate,
                dateSearch: definition.dateSearch,
                floatingHoliday: floatingHoliday,
                catalogHoliday: catalogHoliday
            )
            guard dateOK else { continue }
            matches.append(
                PictureSearchPhotoMatch(
                    photoId: candidate.photoId,
                    eventId: candidate.eventId,
                    confidence: candidate.confidence
                )
            )
        }

        let eventIds = Set(matches.compactMap(\.eventId))
        persistMatchesUnsafe(runId: runId, matches: matches)
        finishRunUnsafe(
            runId: runId,
            finishedAt: nowISO,
            status: "completed",
            photoHitCount: matches.count,
            eventCandidateCount: eventIds.count
        )

        return PictureSearchRunReport(
            pictureSearchRunId: runId,
            pictureSearchId: pictureSearchId,
            targetEventType: definition.targetEventType,
            photoMatches: matches,
            eventCandidateCount: eventIds.count
        )
    }

    private struct CandidatePhoto {
        let photoId: String
        let effectiveDate: String
        let eventId: Int?
        let confidence: Double?
    }

    private func fetchCandidatePhotosUnsafe(
        _ definition: PictureSearchDefinition
    ) -> [CandidatePhoto] {
        let visionTags = definition.visionTagSearch.tags
            .map {
                VisionTagCriterion(
                    objectKey: $0.objectKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    minConfidence: max(0, min(1, $0.minConfidence))
                )
            }
            .filter { !$0.objectKey.isEmpty }
        let objectKeys = visionTags.map(\.objectKey)
        let personIds = definition.peopleSearch.personIds
        let locationTerms = definition.locationSearch.searchTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var clauses: [String] = ["p.isDeleted = 0"]
        var binds: [BindValue] = []

        if !visionTags.isEmpty {
            if definition.visionTagSearch.matchMode == "all" {
                var allParts: [String] = []
                for _ in visionTags {
                    allParts.append(
                        """
                        EXISTS (
                            SELECT 1 FROM photo_object_tags pot
                            WHERE pot.photoId = p.id
                              AND pot.objectKey = ?
                              AND pot.confidence >= ?
                        )
                        """
                    )
                }
                clauses.append("(\(allParts.joined(separator: " AND ")))")
                for tag in visionTags {
                    binds.append(.text(tag.objectKey))
                    binds.append(.double(tag.minConfidence))
                }
            } else {
                var anyParts: [String] = []
                for _ in visionTags {
                    anyParts.append(
                        """
                        (
                            pot.objectKey = ?
                            AND pot.confidence >= ?
                        )
                        """
                    )
                }
                clauses.append(
                    """
                    EXISTS (
                        SELECT 1 FROM photo_object_tags pot
                        WHERE pot.photoId = p.id
                          AND (\(anyParts.joined(separator: " OR ")))
                    )
                    """
                )
                for tag in visionTags {
                    binds.append(.text(tag.objectKey))
                    binds.append(.double(tag.minConfidence))
                }
            }
        }

        if !personIds.isEmpty {
            let placeholders = Array(repeating: "?", count: personIds.count).joined(separator: ", ")
            if definition.peopleSearch.matchMode == "all" {
                clauses.append(
                    """
                    (
                        SELECT COUNT(DISTINCT pp2.personId)
                        FROM photo_people pp2
                        WHERE pp2.photoId = p.id
                          AND pp2.personId IN (\(placeholders))
                    ) = \(personIds.count)
                    """
                )
                binds.append(contentsOf: personIds.map { .int($0) })
            } else {
                clauses.append(
                    """
                    EXISTS (
                        SELECT 1 FROM photo_people pp
                        WHERE pp.photoId = p.id
                          AND pp.personId IN (\(placeholders))
                    )
                    """
                )
                binds.append(contentsOf: personIds.map { .int($0) })
            }
        }

        if !locationTerms.isEmpty {
            var locationOrs: [String] = []
            for _ in locationTerms {
                locationOrs.append(
                    """
                    (
                        IFNULL(e.city, '') LIKE ? ESCAPE '#'
                        OR IFNULL(e.state, '') LIKE ? ESCAPE '#'
                        OR IFNULL(e.placeName, '') LIKE ? ESCAPE '#'
                        OR IFNULL(l.city, '') LIKE ? ESCAPE '#'
                        OR IFNULL(l.state, '') LIKE ? ESCAPE '#'
                        OR IFNULL(l.placeName, '') LIKE ? ESCAPE '#'
                        OR IFNULL(l.nickname, '') LIKE ? ESCAPE '#'
                    )
                    """
                )
            }
            let joiner = definition.locationSearch.matchMode == "all" ? " AND " : " OR "
            clauses.append(
                """
                EXISTS (
                    SELECT 1
                    FROM photo_events pe_loc
                    JOIN events e ON e.eventId = pe_loc.eventId AND e.isDeleted = 0
                    LEFT JOIN locations l ON l.locationId = e.locationId
                    WHERE pe_loc.photoId = p.id
                      AND (\(locationOrs.joined(separator: joiner)))
                )
                """
            )
            for term in locationTerms {
                let pattern = "%\(escapeLike(term))%"
                binds.append(contentsOf: Array(repeating: .text(pattern), count: 7))
            }
        }

        // Without vision/people/location filters, avoid scanning the whole library unless all-dates browse.
        if objectKeys.isEmpty && personIds.isEmpty && locationTerms.isEmpty {
            // Date-only search still allowed.
        }

        let sql = """
        SELECT
            p.id,
            COALESCE(NULLIF(TRIM(p.captureDateOverride), ''), p.creationDate) AS effectiveDate,
            (
                SELECT pe.eventId
                FROM photo_events pe
                JOIN events e ON e.eventId = pe.eventId AND e.isDeleted = 0
                WHERE pe.photoId = p.id
                ORDER BY pe.eventId ASC
                LIMIT 1
            ) AS eventId,
            (
                SELECT MAX(pot.confidence)
                FROM photo_object_tags pot
                WHERE pot.photoId = p.id
                \(visionTags.isEmpty ? "" : "AND (\(visionTags.map { _ in "(pot.objectKey = ? AND pot.confidence >= ?)" }.joined(separator: " OR ")))")
            ) AS confidence
        FROM photos p
        WHERE \(clauses.joined(separator: "\n          AND "))
        ORDER BY confidence DESC, effectiveDate DESC, p.id ASC
        LIMIT 5000;
        """

        // Confidence subquery `?`s appear first in the SQL text (SELECT list), then WHERE binds.
        // People/location filters must not be inserted between identical vision bind groups or
        // person IDs get bound into objectKey slots and matches drop to zero.
        var confidenceBinds: [BindValue] = []
        for tag in visionTags {
            confidenceBinds.append(.text(tag.objectKey))
            confidenceBinds.append(.double(tag.minConfidence))
        }
        let allBinds = confidenceBinds + binds

        var statement: OpaquePointer?
        var rows: [CandidatePhoto] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (index, bind) in allBinds.enumerated() {
                switch bind {
                case .text(let value):
                    sqlite3_bind_text(
                        statement,
                        Int32(index + 1),
                        (value as NSString).utf8String,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self) // SQLITE_TRANSIENT
                    )
                case .int(let value):
                    sqlite3_bind_int(statement, Int32(index + 1), Int32(value))
                case .double(let value):
                    sqlite3_bind_double(statement, Int32(index + 1), value)
                }
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let photoIdC = sqlite3_column_text(statement, 0),
                      let dateC = sqlite3_column_text(statement, 1) else {
                    continue
                }
                let eventId = sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(statement, 2))
                let confidence = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 3)
                rows.append(
                    CandidatePhoto(
                        photoId: String(cString: photoIdC),
                        effectiveDate: String(cString: dateC),
                        eventId: eventId,
                        confidence: confidence
                    )
                )
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    private enum BindValue {
        case text(String)
        case int(Int)
        case double(Double)
    }

    private func insertRunUnsafe(
        pictureSearchId: Int,
        startedAt: String,
        status: String
    ) -> Int {
        let sql = """
        INSERT INTO picture_search_runs (
            pictureSearchId, startedAt, status, photoHitCount, eventCandidateCount
        ) VALUES (?, ?, ?, 0, 0);
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(pictureSearchId))
            sqlite3_bind_text(statement, 2, (startedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (status as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        return Int(sqlite3_last_insert_rowid(db))
    }

    private func persistMatchesUnsafe(runId: Int, matches: [PictureSearchPhotoMatch]) {
        let sql = """
        INSERT OR REPLACE INTO picture_search_photo_matches (
            pictureSearchRunId, photoId, eventId, confidence
        ) VALUES (?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        for match in matches {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int(statement, 1, Int32(runId))
            sqlite3_bind_text(statement, 2, (match.photoId as NSString).utf8String, -1, nil)
            if let eventId = match.eventId {
                sqlite3_bind_int(statement, 3, Int32(eventId))
            } else {
                sqlite3_bind_null(statement, 3)
            }
            if let confidence = match.confidence {
                sqlite3_bind_double(statement, 4, confidence)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_step(statement)
        }
    }

    private func finishRunUnsafe(
        runId: Int,
        finishedAt: String,
        status: String,
        photoHitCount: Int,
        eventCandidateCount: Int
    ) {
        let sql = """
        UPDATE picture_search_runs
        SET finishedAt = ?, status = ?, photoHitCount = ?, eventCandidateCount = ?
        WHERE pictureSearchRunId = ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (finishedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (status as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(photoHitCount))
            sqlite3_bind_int(statement, 4, Int32(eventCandidateCount))
            sqlite3_bind_int(statement, 5, Int32(runId))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    private func fetchLatestRunMatchesUnsafe(pictureSearchId: Int) -> PictureSearchRunReport? {
        let sql = """
        SELECT pictureSearchRunId, photoHitCount, eventCandidateCount
        FROM picture_search_runs
        WHERE pictureSearchId = ?
        ORDER BY startedAt DESC, pictureSearchRunId DESC
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int(statement, 1, Int32(pictureSearchId))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            return nil
        }
        let runId = Int(sqlite3_column_int(statement, 0))
        let eventCandidateCount = Int(sqlite3_column_int(statement, 2))
        sqlite3_finalize(statement)

        let matchesSQL = """
        SELECT photoId, eventId, confidence
        FROM picture_search_photo_matches
        WHERE pictureSearchRunId = ?
        ORDER BY (confidence IS NULL), confidence DESC, photoId ASC;
        """
        var matchesStatement: OpaquePointer?
        var matches: [PictureSearchPhotoMatch] = []
        if sqlite3_prepare_v2(db, matchesSQL, -1, &matchesStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(matchesStatement, 1, Int32(runId))
            while sqlite3_step(matchesStatement) == SQLITE_ROW {
                guard let photoIdC = sqlite3_column_text(matchesStatement, 0) else { continue }
                let eventId = sqlite3_column_type(matchesStatement, 1) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(matchesStatement, 1))
                let confidence = sqlite3_column_type(matchesStatement, 2) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(matchesStatement, 2)
                matches.append(
                    PictureSearchPhotoMatch(
                        photoId: String(cString: photoIdC),
                        eventId: eventId,
                        confidence: confidence
                    )
                )
            }
        }
        sqlite3_finalize(matchesStatement)

        let targetEventType = fetchPictureSearchUnsafe(pictureSearchId: pictureSearchId)?
            .targetEventType ?? "Wedding"
        return PictureSearchRunReport(
            pictureSearchRunId: runId,
            pictureSearchId: pictureSearchId,
            targetEventType: targetEventType,
            photoMatches: matches,
            eventCandidateCount: eventCandidateCount
        )
    }

    // MARK: - Helpers

    private func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(statement, index, Int32(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    // MARK: - Event score cards

    private func ensureEventScoreCardSettingsUnsafe(
        tagCategory: String,
        tagValue: String,
        personNamesById: [Int: String]
    ) -> PictureSearchEventScoreCardSettings {
        let category = tagCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = fetchEventScoreCardSettingsUnsafe(
            tagCategory: category,
            tagValue: value
        ) {
            return existing
        }

        if let definition = fetchAllPictureSearchesUnsafe().first(where: {
            $0.targetTagCategory.compare(category, options: .caseInsensitive) == .orderedSame
                && $0.targetEventType.compare(value, options: .caseInsensitive) == .orderedSame
        }) {
            return ensureEventScoreCardSettingsUnsafe(
                for: definition,
                personNamesById: personNamesById
            )
        }

        var blank = PictureSearchEventScoreCardSettings.blank(
            tagCategory: category,
            tagValue: value
        )
        // Avoid UNIQUE name collisions with unrelated cards.
        if fetchEventScoreCardSettingsUnsafe(named: blank.name) != nil {
            blank.name = "\(value) · \(category)"
        }
        return saveEventScoreCardSettingsUnsafe(blank)
    }

    private func ensureEventScoreCardSettingsUnsafe(
        for definition: PictureSearchDefinition,
        personNamesById: [Int: String]
    ) -> PictureSearchEventScoreCardSettings {
        let desired = PictureSearchEventScoreCardSettings.fromPictureSearch(
            definition,
            personNamesById: personNamesById
        )

        var existing =
            fetchEventScoreCardSettingsUnsafe(named: definition.name)
            ?? fetchEventScoreCardSettingsUnsafe(
                tagCategory: definition.targetTagCategory,
                tagValue: definition.targetEventType
            )

        // Legacy person birthday cards used "Vince Birthday" / target "Birthday".
        if existing == nil,
           MilestonePictureSearchDefaults.isPersonBirthdayTagValue(definition.targetEventType) {
            let legacyPlain = definition.targetEventType
                .replacingOccurrences(of: "'s Birthday", with: " Birthday", options: .caseInsensitive)
            if legacyPlain.compare(definition.targetEventType, options: .caseInsensitive) != .orderedSame {
                existing = fetchEventScoreCardSettingsUnsafe(named: legacyPlain)
            }
        }

        if var existing {
            var didMutate = false
            if existing.name.compare(desired.name, options: .caseInsensitive) != .orderedSame {
                // Keep UNIQUE name: only rename when the desired name is free.
                if fetchEventScoreCardSettingsUnsafe(named: desired.name) == nil
                    || fetchEventScoreCardSettingsUnsafe(named: desired.name)?.eventScoreCardId
                        == existing.eventScoreCardId {
                    existing.name = desired.name
                    didMutate = true
                }
            }
            if existing.targetEventType != desired.targetEventType
                || existing.targetTagCategory != desired.targetTagCategory {
                existing.targetEventType = desired.targetEventType
                existing.targetTagCategory = desired.targetTagCategory
                didMutate = true
            }
            let existingKeys = Set(existing.visionTags.map { $0.objectKey.lowercased() })
            for tag in desired.visionTags {
                let key = tag.objectKey.lowercased()
                guard !existingKeys.contains(key) else { continue }
                existing.visionTags.append(tag)
                didMutate = true
            }
            let existingPeople = Set(existing.people.map(\.personId))
            for person in desired.people where !existingPeople.contains(person.personId) {
                existing.people.append(person)
                didMutate = true
            }
            // Keep birthday date window synced from Picture Search values, not its dateSearchId.
            if MilestonePictureSearchDefaults.isPersonBirthdayTagValue(desired.targetEventType) {
                let before = existing.dateSearch
                existing.dateSearch.copyCalendarFields(from: desired.dateSearch)
                if existing.dateSearch != before {
                    didMutate = true
                }
            }
            if didMutate {
                return saveEventScoreCardSettingsUnsafe(existing)
            }
            return existing
        }

        return saveEventScoreCardSettingsUnsafe(desired)
    }

    private func saveEventScoreCardSettingsUnsafe(
        _ settings: PictureSearchEventScoreCardSettings
    ) -> PictureSearchEventScoreCardSettings {
        let timestamp = nowISO
        var dateSearch = settings.dateSearch
        if dateSearch.name == nil || dateSearch.name?.isEmpty == true {
            dateSearch.name = "\(settings.name) Score Card Dates"
        }
        // Never mutate a date_searches row still owned by a Picture Search.
        if let sharedId = dateSearch.dateSearchId,
           sharedId > 0,
           isDateSearchReferencedByPictureSearchUnsafe(dateSearchId: sharedId) {
            dateSearch = dateSearch.detachedCopy(named: dateSearch.name)
        }
        let dateSearchId = upsertDateSearchUnsafe(dateSearch, timestamp: timestamp)

        let cardId: Int
        if let existingId = settings.eventScoreCardId, existingId > 0 {
            let sql = """
            UPDATE event_score_cards SET
                name = ?, targetTagCategory = ?, targetEventType = ?,
                dateSearchId = ?, onDatePoints = ?, pointsPerDayFromAnchor = ?,
                minimumScoreForAI = ?, updatedAt = ?
            WHERE eventScoreCardId = ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (settings.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(
                    statement,
                    2,
                    (settings.targetTagCategory as NSString).utf8String,
                    -1,
                    nil
                )
                sqlite3_bind_text(
                    statement,
                    3,
                    (settings.targetEventType as NSString).utf8String,
                    -1,
                    nil
                )
                bindOptionalInt(statement, 4, dateSearchId)
                sqlite3_bind_double(statement, 5, settings.onDatePoints)
                sqlite3_bind_double(statement, 6, settings.pointsPerDayFromAnchor)
                sqlite3_bind_double(statement, 7, settings.minimumScoreForAI)
                sqlite3_bind_text(statement, 8, (timestamp as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 9, Int32(existingId))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            cardId = existingId
        } else if let existingId = fetchEventScoreCardIdUnsafe(named: settings.name) {
            let sql = """
            UPDATE event_score_cards SET
                targetTagCategory = ?, targetEventType = ?,
                dateSearchId = ?, onDatePoints = ?, pointsPerDayFromAnchor = ?,
                minimumScoreForAI = ?, updatedAt = ?
            WHERE eventScoreCardId = ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(
                    statement,
                    1,
                    (settings.targetTagCategory as NSString).utf8String,
                    -1,
                    nil
                )
                sqlite3_bind_text(
                    statement,
                    2,
                    (settings.targetEventType as NSString).utf8String,
                    -1,
                    nil
                )
                bindOptionalInt(statement, 3, dateSearchId)
                sqlite3_bind_double(statement, 4, settings.onDatePoints)
                sqlite3_bind_double(statement, 5, settings.pointsPerDayFromAnchor)
                sqlite3_bind_double(statement, 6, settings.minimumScoreForAI)
                sqlite3_bind_text(statement, 7, (timestamp as NSString).utf8String, -1, nil)
                sqlite3_bind_int(statement, 8, Int32(existingId))
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            cardId = existingId
        } else {
            let sql = """
            INSERT INTO event_score_cards (
                name, targetTagCategory, targetEventType, dateSearchId,
                onDatePoints, pointsPerDayFromAnchor, minimumScoreForAI,
                createdAt, updatedAt
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (settings.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(
                    statement,
                    2,
                    (settings.targetTagCategory as NSString).utf8String,
                    -1,
                    nil
                )
                sqlite3_bind_text(
                    statement,
                    3,
                    (settings.targetEventType as NSString).utf8String,
                    -1,
                    nil
                )
                bindOptionalInt(statement, 4, dateSearchId)
                sqlite3_bind_double(statement, 5, settings.onDatePoints)
                sqlite3_bind_double(statement, 6, settings.pointsPerDayFromAnchor)
                sqlite3_bind_double(statement, 7, settings.minimumScoreForAI)
                sqlite3_bind_text(statement, 8, (timestamp as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 9, (timestamp as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            cardId = Int(sqlite3_last_insert_rowid(db))
        }

        replaceEventScoreCardChildrenUnsafe(cardId: cardId, settings: settings)

        return fetchEventScoreCardSettingsUnsafe(named: settings.name)
            ?? settings
    }

    private func replaceEventScoreCardChildrenUnsafe(
        cardId: Int,
        settings: PictureSearchEventScoreCardSettings
    ) {
        execSQL("DELETE FROM event_score_card_vision_tags WHERE eventScoreCardId = \(cardId);")
        execSQL("DELETE FROM event_score_card_people WHERE eventScoreCardId = \(cardId);")
        execSQL("DELETE FROM event_score_card_locations WHERE eventScoreCardId = \(cardId);")

        let visionSQL = """
        INSERT INTO event_score_card_vision_tags (
            eventScoreCardId, objectKey, minConfidence, points
        ) VALUES (?, ?, ?, ?);
        """
        for tag in settings.visionTags {
            let key = tag.objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, visionSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(cardId))
                sqlite3_bind_text(statement, 2, (key as NSString).utf8String, -1, nil)
                sqlite3_bind_double(statement, 3, tag.minConfidence)
                sqlite3_bind_double(statement, 4, tag.points)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }

        let peopleSQL = """
        INSERT INTO event_score_card_people (eventScoreCardId, personId, points)
        VALUES (?, ?, ?);
        """
        for person in settings.people {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, peopleSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(cardId))
                sqlite3_bind_int(statement, 2, Int32(person.personId))
                sqlite3_bind_double(statement, 3, person.points)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }

        let locationSQL = """
        INSERT INTO event_score_card_locations (eventScoreCardId, searchTerm, points)
        VALUES (?, ?, ?);
        """
        for location in settings.locations {
            let term = location.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, locationSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(cardId))
                sqlite3_bind_text(statement, 2, (term as NSString).utf8String, -1, nil)
                sqlite3_bind_double(statement, 3, location.points)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }

    private func fetchEventScoreCardIdUnsafe(named name: String) -> Int? {
        let sql = """
        SELECT eventScoreCardId FROM event_score_cards
        WHERE name = ? COLLATE NOCASE
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func fetchAllEventScoreCardSettingsUnsafe() -> [PictureSearchEventScoreCardSettings] {
        let sql = """
        SELECT eventScoreCardId
        FROM event_score_cards
        ORDER BY targetTagCategory COLLATE NOCASE, targetEventType COLLATE NOCASE, name COLLATE NOCASE;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var ids: [Int] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(Int(sqlite3_column_int(statement, 0)))
        }
        return ids.compactMap { fetchEventScoreCardSettingsUnsafe(cardId: $0) }
    }

    private func fetchEventScoreCardSettingsUnsafe(
        tagCategory: String,
        tagValue: String
    ) -> PictureSearchEventScoreCardSettings? {
        let sql = """
        SELECT eventScoreCardId
        FROM event_score_cards
        WHERE COALESCE(targetTagCategory, '') = ? COLLATE NOCASE
          AND targetEventType = ? COLLATE NOCASE
        ORDER BY eventScoreCardId ASC
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, (tagCategory as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (tagValue as NSString).utf8String, -1, nil)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return fetchEventScoreCardSettingsUnsafe(cardId: Int(sqlite3_column_int(statement, 0)))
    }

    private func fetchEventScoreCardSettingsUnsafe(
        named name: String
    ) -> PictureSearchEventScoreCardSettings? {
        let sql = """
        SELECT eventScoreCardId
        FROM event_score_cards
        WHERE name = ? COLLATE NOCASE
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return fetchEventScoreCardSettingsUnsafe(cardId: Int(sqlite3_column_int(statement, 0)))
    }

    private func fetchEventScoreCardSettingsUnsafe(
        cardId: Int
    ) -> PictureSearchEventScoreCardSettings? {
        let sql = """
        SELECT eventScoreCardId, name, targetTagCategory, targetEventType, dateSearchId,
               onDatePoints, pointsPerDayFromAnchor, minimumScoreForAI
        FROM event_score_cards
        WHERE eventScoreCardId = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int(statement, 1, Int32(cardId))
        guard sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_finalize(statement)
            return nil
        }

        let loadedCardId = Int(sqlite3_column_int(statement, 0))
        let cardName = String(cString: sqlite3_column_text(statement, 1))
        let targetTagCategory = optionalString(statement, 2) ?? "Milestone"
        let targetEventType = String(cString: sqlite3_column_text(statement, 3))
        let dateSearchId = optionalInt(statement, 4)
        let onDatePoints = sqlite3_column_double(statement, 5)
        let pointsPerDayFromAnchor = sqlite3_column_double(statement, 6)
        let minimumScoreForAI = sqlite3_column_double(statement, 7)
        sqlite3_finalize(statement)

        let dateSearch = dateSearchId.flatMap { fetchDateSearchUnsafe(dateSearchId: $0) }
            ?? .weddingDefault()
        let visionTags = fetchEventScoreCardVisionTagsUnsafe(cardId: loadedCardId)
        let people = fetchEventScoreCardPeopleUnsafe(cardId: loadedCardId)
        let locations = fetchEventScoreCardLocationsUnsafe(cardId: loadedCardId)

        return PictureSearchEventScoreCardSettings(
            name: cardName,
            eventScoreCardId: loadedCardId,
            targetTagCategory: targetTagCategory,
            targetEventType: targetEventType,
            visionTags: visionTags,
            dateSearch: dateSearch,
            onDatePoints: onDatePoints,
            pointsPerDayFromAnchor: pointsPerDayFromAnchor,
            minimumScoreForAI: minimumScoreForAI,
            people: people,
            locations: locations
        )
    }

    private func fetchEventScoreCardVisionTagsUnsafe(
        cardId: Int
    ) -> [PictureSearchEventScoreCardSettings.VisionTagRule] {
        let sql = """
        SELECT objectKey, minConfidence, points
        FROM event_score_card_vision_tags
        WHERE eventScoreCardId = ?
        ORDER BY objectKey COLLATE NOCASE;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(cardId))
        var tags: [PictureSearchEventScoreCardSettings.VisionTagRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            tags.append(
                .init(
                    objectKey: String(cString: sqlite3_column_text(statement, 0)),
                    minConfidence: sqlite3_column_double(statement, 1),
                    points: sqlite3_column_double(statement, 2)
                )
            )
        }
        sqlite3_finalize(statement)
        return tags
    }

    private func fetchEventScoreCardPeopleUnsafe(
        cardId: Int
    ) -> [PictureSearchEventScoreCardSettings.PersonRule] {
        let sql = """
        SELECT esc.personId, COALESCE(p.displayName, ''), esc.points
        FROM event_score_card_people esc
        LEFT JOIN people p ON p.personId = esc.personId
        WHERE esc.eventScoreCardId = ?
        ORDER BY COALESCE(p.displayName, '') COLLATE NOCASE;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(cardId))
        var people: [PictureSearchEventScoreCardSettings.PersonRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let personId = Int(sqlite3_column_int(statement, 0))
            let name = String(cString: sqlite3_column_text(statement, 1))
            people.append(
                .init(
                    personId: personId,
                    name: name.isEmpty ? "Person \(personId)" : name,
                    points: sqlite3_column_double(statement, 2)
                )
            )
        }
        sqlite3_finalize(statement)
        return people
    }

    private func fetchEventScoreCardLocationsUnsafe(
        cardId: Int
    ) -> [PictureSearchEventScoreCardSettings.LocationRule] {
        let sql = """
        SELECT searchTerm, points
        FROM event_score_card_locations
        WHERE eventScoreCardId = ?
        ORDER BY searchTerm COLLATE NOCASE;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(cardId))
        var locations: [PictureSearchEventScoreCardSettings.LocationRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            locations.append(
                .init(
                    searchTerm: String(cString: sqlite3_column_text(statement, 0)),
                    points: sqlite3_column_double(statement, 1)
                )
            )
        }
        sqlite3_finalize(statement)
        return locations
    }

    private func optionalUTF8(_ value: String?) -> UnsafePointer<CChar>? {
        guard let value, !value.isEmpty else { return nil }
        return (value as NSString).utf8String
    }

    private func optionalString(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: cString)
    }

    private func optionalInt(_ statement: OpaquePointer?, _ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, column))
    }

    private func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "#", with: "##")
            .replacingOccurrences(of: "%", with: "#%")
            .replacingOccurrences(of: "_", with: "#_")
    }

    private func execSQL(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
