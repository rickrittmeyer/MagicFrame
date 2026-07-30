import Foundation
import SQLite3

/// Occasions catalog, per-year dates, and default seed data.
final class OccasionRepository {

    static let seedMetadataKey = "occasionsSeedVersion"
    static let seedMetadataValue = "1"
    static let scoringRulesSeedMetadataKey = "occasionScoringRulesSeedVersion"
    static let scoringRulesSeedMetadataValue = "1"

    private let database: DatabaseManager
    private let metadata: AppMetadataStore
    private let people: PeopleRepository

    private var db: OpaquePointer? {
        database.connection
    }

    init(database: DatabaseManager, metadata: AppMetadataStore) {
        self.database = database
        self.metadata = metadata
        self.people = PeopleRepository(database: database)
    }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if database.isOnQueue {
            return try work()
        }
        return try database.sync(work)
    }

    /// Idempotent: core occasions, birthdates on people, and occasion_dates through future years.
    func ensureDefaultSeedData() {
        sync {
            ensureDefaultSeedDataUnsafe()
        }
    }

    private struct BirthdaySeed {
        let occasionKey: String
        let displayName: String
        let birthDateISO: String
        let searchNames: [String]
    }

    private struct FixedHolidaySeed {
        let occasionKey: String
        let displayName: String
        let month: Int
        let day: Int
        let windowDaysBefore: Int
        let windowDaysAfter: Int
        let weekendBoost: Double
    }

    private enum FloatingHolidayRule {
        case secondSundayInMay
        case thirdSundayInJune
        case westernEasterSunday
    }

    private struct FloatingHolidaySeed {
        let occasionKey: String
        let displayName: String
        let rule: FloatingHolidayRule
        let windowDaysBefore: Int
        let windowDaysAfter: Int
        let weekendBoost: Double
    }

    /// Default date window for new holiday seeds (Christmas gets a wider season).
    static let defaultHolidayWindowDays = 3
    static let christmasWindowDaysBefore = 35
    static let christmasWindowDaysAfter = 10
    static let christmasDefaultDaysAfterThanksgiving = 0
    static let defaultHolidayWeekendBoost = 0.1
    static let defaultBirthdayWeekendBoost = 0.1

    func ensureDefaultSeedDataUnsafe() {
        guard db != nil else { return }

        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let startYear = currentYear - 100
        let endYear = currentYear + 50

        let holidays: [FixedHolidaySeed] = [
            FixedHolidaySeed(
                occasionKey: "christmas",
                displayName: "Christmas",
                month: 12,
                day: 25,
                windowDaysBefore: Self.christmasWindowDaysBefore,
                windowDaysAfter: Self.christmasWindowDaysAfter,
                weekendBoost: Self.defaultHolidayWeekendBoost
            ),
            FixedHolidaySeed(
                occasionKey: "halloween",
                displayName: "Halloween",
                month: 10,
                day: 31,
                windowDaysBefore: Self.defaultHolidayWindowDays,
                windowDaysAfter: Self.defaultHolidayWindowDays,
                weekendBoost: Self.defaultHolidayWeekendBoost
            ),
        ]

        let floatingHolidays: [FloatingHolidaySeed] = [
            FloatingHolidaySeed(
                occasionKey: "mothers_day",
                displayName: "Mother's Day",
                rule: .secondSundayInMay,
                windowDaysBefore: Self.defaultHolidayWindowDays,
                windowDaysAfter: Self.defaultHolidayWindowDays,
                weekendBoost: Self.defaultHolidayWeekendBoost
            ),
            FloatingHolidaySeed(
                occasionKey: "fathers_day",
                displayName: "Father's Day",
                rule: .thirdSundayInJune,
                windowDaysBefore: Self.defaultHolidayWindowDays,
                windowDaysAfter: Self.defaultHolidayWindowDays,
                weekendBoost: Self.defaultHolidayWeekendBoost
            ),
            FloatingHolidaySeed(
                occasionKey: "easter",
                displayName: "Easter",
                rule: .westernEasterSunday,
                windowDaysBefore: Self.defaultHolidayWindowDays,
                windowDaysAfter: Self.defaultHolidayWindowDays,
                weekendBoost: Self.defaultHolidayWeekendBoost
            ),
        ]

        let birthdays: [BirthdaySeed] = [
            BirthdaySeed(
                occasionKey: "rick_birthday",
                displayName: "Rick Birthday",
                birthDateISO: "1968-12-22",
                searchNames: ["Rick"]
            ),
            BirthdaySeed(
                occasionKey: "lory_birthday",
                displayName: "Lory Birthday",
                birthDateISO: "1966-02-25",
                searchNames: ["Lory"]
            ),
            BirthdaySeed(
                occasionKey: "rachel_birthday",
                displayName: "Rachel Birthday",
                birthDateISO: "2000-05-02",
                searchNames: ["Rachel"]
            ),
            BirthdaySeed(
                occasionKey: "jc_birthday",
                displayName: "JC Birthday",
                birthDateISO: "1997-11-30",
                searchNames: ["JC", "J.C.", "J C"]
            ),
            BirthdaySeed(
                occasionKey: "vince_birthday",
                displayName: "Vince Birthday",
                birthDateISO: "2003-10-13",
                searchNames: ["Vince"]
            ),
            BirthdaySeed(
                occasionKey: "bea_birthday",
                displayName: "Bea Birthday",
                birthDateISO: "1943-06-09",
                searchNames: ["Bea"]
            ),
        ]

        var dateRowsInserted = 0

        for holiday in holidays {
            let occasionId = upsertOccasionUnsafe(
                occasionKey: holiday.occasionKey,
                name: holiday.displayName,
                occasionType: "holiday",
                personId: nil,
                windowDaysBefore: holiday.windowDaysBefore,
                windowDaysAfter: holiday.windowDaysAfter,
                weekendBoost: holiday.weekendBoost
            )
            guard occasionId > 0 else { continue }

            updateOccasionAnchorUnsafe(
                occasionId: occasionId,
                anchorMonth: holiday.month,
                anchorDay: holiday.day
            )
            dateRowsInserted += insertFixedHolidayDatesUnsafe(
                occasionId: occasionId,
                month: holiday.month,
                day: holiday.day,
                fromYear: startYear,
                throughYear: endYear
            )
        }

        for holiday in floatingHolidays {
            let occasionId = upsertOccasionUnsafe(
                occasionKey: holiday.occasionKey,
                name: holiday.displayName,
                occasionType: "holiday",
                personId: nil,
                windowDaysBefore: holiday.windowDaysBefore,
                windowDaysAfter: holiday.windowDaysAfter,
                weekendBoost: holiday.weekendBoost
            )
            guard occasionId > 0 else { continue }

            dateRowsInserted += insertFloatingHolidayDatesUnsafe(
                occasionId: occasionId,
                rule: holiday.rule,
                fromYear: startYear,
                throughYear: endYear
            )
        }

        for birthday in birthdays {
            let personId = resolvePersonIdUnsafe(searchNames: birthday.searchNames)
            if let personId, personId > 0 {
                people.setBirthDateUnsafe(
                    personId: personId,
                    birthDateISO: birthday.birthDateISO
                )
            } else {
                print(
                    "Occasion seed: no people row for \(birthday.displayName)"
                    + " (tried \(birthday.searchNames.joined(separator: ", ")))"
                )
            }

            dateRowsInserted += seedBirthdayOccasionUnsafe(
                occasionKey: birthday.occasionKey,
                displayName: birthday.displayName,
                birthDateISO: birthday.birthDateISO,
                personId: personId.flatMap { $0 > 0 ? $0 : nil },
                endYear: endYear
            )
        }

        let peopleBirthdayCount = seedAllPeopleBirthdaysUnsafe(endYear: endYear)
        dateRowsInserted += peopleBirthdayCount

        metadata.set(key: Self.seedMetadataKey, value: Self.seedMetadataValue)
        ensureDefaultScoringRulesSeedDataUnsafe()
        repairMissingOccasionDatesUnsafe(
            holidays: holidays,
            floatingHolidays: floatingHolidays,
            birthdays: birthdays,
            currentYear: currentYear,
            endYear: endYear
        )

        print(
            "Occasion seed complete: \(holidays.count) fixed holidays,"
            + " \(floatingHolidays.count) floating holidays,"
            + " \(birthdays.count) seeded birthdays + people table,"
            + " \(dateRowsInserted.formatted()) occasion_dates rows ensured"
            + " (holidays \(startYear)–\(endYear), birthdays birth year–\(endYear))"
        )
    }

    func ensureDefaultScoringRulesSeedData() {
        sync {
            ensureDefaultScoringRulesSeedDataUnsafe()
        }
    }

    private struct ScoringRuleSeed {
        let occasionKey: String
        let signalType: String
        let signalValue: String
        let score: Double
    }

    func ensureDefaultScoringRulesSeedDataUnsafe() {
        guard db != nil else { return }

        let rules: [ScoringRuleSeed] = [
            ScoringRuleSeed(
                occasionKey: "christmas",
                signalType: "keyword",
                signalValue: "filename_contains:christmas",
                score: 0.35
            ),
            ScoringRuleSeed(
                occasionKey: "christmas",
                signalType: "keyword",
                signalValue: "title_contains:christmas",
                score: 0.4
            ),
            ScoringRuleSeed(
                occasionKey: "christmas",
                signalType: "album",
                signalValue: "title_contains:christmas",
                score: 0.45
            ),
            ScoringRuleSeed(
                occasionKey: "christmas",
                signalType: "object",
                signalValue: "christmas_tree",
                score: 0.45
            ),
            ScoringRuleSeed(
                occasionKey: "christmas",
                signalType: "object",
                signalValue: "ornament",
                score: 0.35
            ),
            ScoringRuleSeed(
                occasionKey: "christmas",
                signalType: "object",
                signalValue: "santa",
                score: 0.30
            ),
            ScoringRuleSeed(
                occasionKey: "halloween",
                signalType: "keyword",
                signalValue: "filename_contains:halloween",
                score: 0.35
            ),
            ScoringRuleSeed(
                occasionKey: "halloween",
                signalType: "keyword",
                signalValue: "title_contains:halloween",
                score: 0.4
            ),
            ScoringRuleSeed(
                occasionKey: "halloween",
                signalType: "album",
                signalValue: "title_contains:halloween",
                score: 0.45
            ),
            ScoringRuleSeed(
                occasionKey: "halloween",
                signalType: "object",
                signalValue: "pumpkin",
                score: 0.45
            ),
            ScoringRuleSeed(
                occasionKey: "halloween",
                signalType: "object",
                signalValue: "jack_o_lantern",
                score: 0.40
            ),
            ScoringRuleSeed(
                occasionKey: "halloween",
                signalType: "object",
                signalValue: "costume",
                score: 0.30
            ),
            ScoringRuleSeed(
                occasionKey: "easter",
                signalType: "keyword",
                signalValue: "filename_contains:easter",
                score: 0.35
            ),
            ScoringRuleSeed(
                occasionKey: "easter",
                signalType: "keyword",
                signalValue: "title_contains:easter",
                score: 0.4
            ),
            ScoringRuleSeed(
                occasionKey: "easter",
                signalType: "album",
                signalValue: "title_contains:easter",
                score: 0.45
            ),
            ScoringRuleSeed(
                occasionKey: "mothers_day",
                signalType: "keyword",
                signalValue: "filename_contains:mother",
                score: 0.3
            ),
            ScoringRuleSeed(
                occasionKey: "mothers_day",
                signalType: "keyword",
                signalValue: "title_contains:mother",
                score: 0.35
            ),
            ScoringRuleSeed(
                occasionKey: "mothers_day",
                signalType: "album",
                signalValue: "title_contains:mother",
                score: 0.4
            ),
            ScoringRuleSeed(
                occasionKey: "mothers_day",
                signalType: "object",
                signalValue: "flower",
                score: 0.40
            ),
            ScoringRuleSeed(
                occasionKey: "mothers_day",
                signalType: "object",
                signalValue: "bouquet",
                score: 0.35
            ),
            ScoringRuleSeed(
                occasionKey: "fathers_day",
                signalType: "keyword",
                signalValue: "filename_contains:father",
                score: 0.3
            ),
            ScoringRuleSeed(
                occasionKey: "fathers_day",
                signalType: "keyword",
                signalValue: "title_contains:father",
                score: 0.35
            ),
            ScoringRuleSeed(
                occasionKey: "fathers_day",
                signalType: "album",
                signalValue: "title_contains:father",
                score: 0.4
            ),
            ScoringRuleSeed(
                occasionKey: "fathers_day",
                signalType: "object",
                signalValue: "gift",
                score: 0.35
            ),
        ]

        var inserted = 0
        for rule in rules {
            let occasionId = occasionIdUnsafe(occasionKey: rule.occasionKey)
            guard occasionId > 0 else { continue }
            if insertScoringRuleUnsafe(
                occasionId: occasionId,
                signalType: rule.signalType,
                signalValue: rule.signalValue,
                score: rule.score
            ) {
                inserted += 1
            }
        }

        metadata.set(key: Self.scoringRulesSeedMetadataKey, value: Self.scoringRulesSeedMetadataValue)
        print("Occasion scoring rules seed: \(inserted.formatted()) new rules ensured")
    }

    // MARK: - Developer editing

    func fetchEditableOccasions() -> [EditableOccasion] {
        sync { fetchEditableOccasionsUnsafe() }
    }

    func saveEditableOccasions(_ occasions: [EditableOccasion]) {
        sync {
            for occasion in occasions {
                saveEditableOccasionUnsafe(occasion)
            }
        }
    }

    func fetchEditableOccasionsUnsafe() -> [EditableOccasion] {
        let sql = """
        SELECT
            occasionId,
            occasionKey,
            name,
            occasionType,
            defaultWindowDaysBefore,
            defaultWindowDaysAfter,
            COALESCE(christmasWindowUsesThanksgivingStart, 0),
            COALESCE(windowDaysAfterThanksgiving, 0),
            COALESCE(weekendBoost, 0),
            isEnabled
        FROM occasions
        ORDER BY occasionType, name;
        """

        var statement: OpaquePointer?
        var rows: [EditableOccasion] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    EditableOccasion(
                        occasionId: Int(sqlite3_column_int(statement, 0)),
                        occasionKey: String(cString: sqlite3_column_text(statement, 1)),
                        name: String(cString: sqlite3_column_text(statement, 2)),
                        occasionType: String(cString: sqlite3_column_text(statement, 3)),
                        windowDaysBefore: Int(sqlite3_column_int(statement, 4)),
                        windowDaysAfter: Int(sqlite3_column_int(statement, 5)),
                        usesThanksgivingRelativeStart: sqlite3_column_int(statement, 6) != 0,
                        windowDaysAfterThanksgiving: Int(sqlite3_column_int(statement, 7)),
                        weekendBoost: clampWeekendBoost(sqlite3_column_double(statement, 8)),
                        isEnabled: sqlite3_column_int(statement, 9) != 0
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return rows
    }

    func saveEditableOccasionUnsafe(_ occasion: EditableOccasion) {
        let sql = """
        UPDATE occasions
        SET
            name = ?,
            defaultWindowDaysBefore = ?,
            defaultWindowDaysAfter = ?,
            christmasWindowUsesThanksgivingStart = ?,
            windowDaysAfterThanksgiving = ?,
            weekendBoost = ?,
            isEnabled = ?
        WHERE occasionId = ?;
        """

        let before = clampWindowDays(occasion.windowDaysBefore)
        let after = clampWindowDays(occasion.windowDaysAfter)
        let afterThanksgiving = clampWindowDays(occasion.windowDaysAfterThanksgiving)
        let usesThanksgivingStart = occasion.occasionKey == "christmas"
            && occasion.usesThanksgivingRelativeStart
        let weekendBoost = clampWeekendBoost(occasion.weekendBoost)

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (occasion.name as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(before))
            sqlite3_bind_int(statement, 3, Int32(after))
            sqlite3_bind_int(statement, 4, usesThanksgivingStart ? 1 : 0)
            sqlite3_bind_int(statement, 5, Int32(afterThanksgiving))
            sqlite3_bind_double(statement, 6, weekendBoost)
            sqlite3_bind_int(statement, 7, occasion.isEnabled ? 1 : 0)
            sqlite3_bind_int(statement, 8, Int32(occasion.occasionId))
            if sqlite3_step(statement) != SQLITE_DONE {
                print(
                    "Failed saving occasion \(occasion.occasionKey):"
                        + " \(String(cString: sqlite3_errmsg(db!)))"
                )
            }
        }

        sqlite3_finalize(statement)
    }

    func updateOccasionDateScoringSettings(
        occasionId: Int,
        edit: OccasionDateScoringEdit
    ) {
        sync {
            updateOccasionDateScoringSettingsUnsafe(
                occasionId: occasionId,
                edit: edit
            )
        }
    }

    func updateOccasionDateScoringSettingsUnsafe(
        occasionId: Int,
        edit: OccasionDateScoringEdit
    ) {
        let calendar = Calendar.current
        let month = min(12, max(1, calendar.component(.month, from: edit.anchorDate)))
        let day = min(31, max(1, calendar.component(.day, from: edit.anchorDate)))
        let before = clampWindowDays(edit.windowDaysBefore)
        let after = clampWindowDays(edit.windowDaysAfter)
        let afterThanksgiving = clampWindowDays(edit.windowDaysAfterThanksgiving)
        let occasionKey = fetchOccasionByIdUnsafe(occasionId: occasionId)?.scoring.occasionKey
        let usesThanksgivingStart = occasionKey == "christmas" && edit.usesThanksgivingRelativeStart

        let sql = """
        UPDATE occasions
        SET
            anchorMonth = ?,
            anchorDay = ?,
            defaultWindowDaysBefore = ?,
            defaultWindowDaysAfter = ?,
            christmasWindowUsesThanksgivingStart = ?,
            windowDaysAfterThanksgiving = ?
        WHERE occasionId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(month))
            sqlite3_bind_int(statement, 2, Int32(day))
            sqlite3_bind_int(statement, 3, Int32(before))
            sqlite3_bind_int(statement, 4, Int32(after))
            sqlite3_bind_int(statement, 5, usesThanksgivingStart ? 1 : 0)
            sqlite3_bind_int(statement, 6, Int32(afterThanksgiving))
            sqlite3_bind_int(statement, 7, Int32(occasionId))
            if sqlite3_step(statement) != SQLITE_DONE {
                print(
                    "Failed updating occasion date scoring settings \(occasionId):"
                        + " \(String(cString: sqlite3_errmsg(db!)))"
                )
            }
        }

        sqlite3_finalize(statement)
        syncOccasionDatesFromAnchorUnsafe(
            occasionId: occasionId,
            anchorMonth: month,
            anchorDay: day
        )
    }

    private func updateOccasionAnchorUnsafe(
        occasionId: Int,
        anchorMonth: Int,
        anchorDay: Int
    ) {
        let sql = """
        UPDATE occasions
        SET anchorMonth = ?, anchorDay = ?
        WHERE occasionId = ? AND (anchorMonth IS NULL OR anchorDay IS NULL);
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(anchorMonth))
            sqlite3_bind_int(statement, 2, Int32(anchorDay))
            sqlite3_bind_int(statement, 3, Int32(occasionId))
            sqlite3_step(statement)
        }

        sqlite3_finalize(statement)
    }

    private func syncOccasionDatesFromAnchorUnsafe(
        occasionId: Int,
        anchorMonth: Int,
        anchorDay: Int
    ) {
        let selectSQL = """
        SELECT year
        FROM occasion_dates
        WHERE occasionId = ?;
        """

        var selectStatement: OpaquePointer?
        var years: [Int] = []

        if sqlite3_prepare_v2(db, selectSQL, -1, &selectStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(selectStatement, 1, Int32(occasionId))
            while sqlite3_step(selectStatement) == SQLITE_ROW {
                years.append(Int(sqlite3_column_int(selectStatement, 0)))
            }
        }

        sqlite3_finalize(selectStatement)

        let updateSQL = """
        UPDATE occasion_dates
        SET date = ?, observedDate = NULL
        WHERE occasionId = ? AND year = ?;
        """

        for year in years {
            guard let dateISO = dateISO(year: year, month: anchorMonth, day: anchorDay) else {
                continue
            }

            var updateStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK {
                sqlite3_bind_text(updateStatement, 1, (dateISO as NSString).utf8String, -1, nil)
                sqlite3_bind_int(updateStatement, 2, Int32(occasionId))
                sqlite3_bind_int(updateStatement, 3, Int32(year))
                if sqlite3_step(updateStatement) != SQLITE_DONE {
                    print(
                        "Failed syncing occasion date for \(occasionId) year \(year):"
                            + " \(String(cString: sqlite3_errmsg(db!)))"
                    )
                }
            }
            sqlite3_finalize(updateStatement)
        }
    }

    private func clampWindowDays(_ days: Int) -> Int {
        min(60, max(0, days))
    }

    private func clampWeekendBoost(_ boost: Double) -> Double {
        min(0.5, max(0, boost))
    }

    // MARK: - Scoring reads / writes

    func fetchEnabledOccasions(occasionType: String?) -> [OccasionForScoring] {
        sync { fetchEnabledOccasionsUnsafe(occasionType: occasionType) }
    }

    func fetchEnabledOccasionsUnsafe(occasionType: String?) -> [OccasionForScoring] {
        var sql = """
        SELECT occasionId, occasionKey, occasionType,
               defaultWindowDaysBefore, defaultWindowDaysAfter,
               COALESCE(christmasWindowUsesThanksgivingStart, 0),
               COALESCE(windowDaysAfterThanksgiving, 0),
               COALESCE(weekendBoost, 0)
        FROM occasions
        WHERE isEnabled = 1
        """
        if occasionType != nil {
            sql += " AND occasionType = ?"
        }
        sql += " ORDER BY occasionKey;"

        var statement: OpaquePointer?
        var rows: [OccasionForScoring] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if let occasionType {
                sqlite3_bind_text(statement, 1, (occasionType as NSString).utf8String, -1, nil)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    OccasionForScoring(
                        occasionId: Int(sqlite3_column_int(statement, 0)),
                        occasionKey: String(cString: sqlite3_column_text(statement, 1)),
                        occasionType: String(cString: sqlite3_column_text(statement, 2)),
                        windowDaysBefore: Int(sqlite3_column_int(statement, 3)),
                        windowDaysAfter: Int(sqlite3_column_int(statement, 4)),
                        usesThanksgivingRelativeStart: sqlite3_column_int(statement, 5) != 0,
                        windowDaysAfterThanksgiving: Int(sqlite3_column_int(statement, 6)),
                        weekendBoost: clampWeekendBoost(sqlite3_column_double(statement, 7))
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return rows
    }

    func fetchOccasionDateUnsafe(occasionId: Int, year: Int) -> OccasionDateForScoring? {
        let sql = """
        SELECT year, date, observedDate, startDate, endDate
        FROM occasion_dates
        WHERE occasionId = ? AND year = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var row: OccasionDateForScoring?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(occasionId))
            sqlite3_bind_int(statement, 2, Int32(year))
            if sqlite3_step(statement) == SQLITE_ROW {
                row = OccasionDateForScoring(
                    year: Int(sqlite3_column_int(statement, 0)),
                    dateISO: String(cString: sqlite3_column_text(statement, 1)),
                    observedDateISO: sqliteOptionalText(statement, column: 2),
                    explicitStartISO: sqliteOptionalText(statement, column: 3),
                    explicitEndISO: sqliteOptionalText(statement, column: 4)
                )
            }
        }

        sqlite3_finalize(statement)
        return row
    }

    struct OccasionRecord: Sendable {
        let name: String
        let scoring: OccasionForScoring
    }

    struct EventOccasionScoreRow: Sendable {
        let dateScore: Double
        let objectScore: Double
        let albumScore: Double
        let weekendScore: Double
        let totalScore: Double
        let confidence: String?
    }

    struct EventHolidayScoreMatch: Sendable {
        let occasionId: Int
        let occasionKey: String
        let occasionName: String
        let year: Int
        let dateScore: Double
        let objectScore: Double
        let albumScore: Double
        let weekendScore: Double
        let totalScore: Double
        let confidence: String?

        var scoreRow: EventOccasionScoreRow {
            EventOccasionScoreRow(
                dateScore: dateScore,
                objectScore: objectScore,
                albumScore: albumScore,
                weekendScore: weekendScore,
                totalScore: totalScore,
                confidence: confidence
            )
        }
    }

    func fetchEventHolidayScoreMatchesUnsafe(eventId: Int) -> [EventHolidayScoreMatch] {
        let sql = """
        SELECT
            s.occasionId,
            o.occasionKey,
            o.name,
            s.year,
            s.dateScore,
            s.objectScore,
            s.albumScore,
            COALESCE(s.weekendScore, 0),
            s.totalScore,
            s.confidence
        FROM event_occasion_scores s
        JOIN occasions o ON o.occasionId = s.occasionId
        WHERE s.eventId = ?
          AND o.occasionType = 'holiday'
          AND COALESCE(s.isRejected, 0) = 0
        ORDER BY s.totalScore DESC, s.year DESC, o.name ASC;
        """

        var statement: OpaquePointer?
        var rows: [EventHolidayScoreMatch] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    EventHolidayScoreMatch(
                        occasionId: Int(sqlite3_column_int(statement, 0)),
                        occasionKey: String(cString: sqlite3_column_text(statement, 1)),
                        occasionName: String(cString: sqlite3_column_text(statement, 2)),
                        year: Int(sqlite3_column_int(statement, 3)),
                        dateScore: sqlite3_column_double(statement, 4),
                        objectScore: sqlite3_column_double(statement, 5),
                        albumScore: sqlite3_column_double(statement, 6),
                        weekendScore: sqlite3_column_double(statement, 7),
                        totalScore: sqlite3_column_double(statement, 8),
                        confidence: sqliteOptionalText(statement, column: 9)
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return rows
    }

    func fetchOccasionByIdUnsafe(occasionId: Int) -> OccasionRecord? {
        let sql = """
        SELECT occasionId, occasionKey, name, occasionType,
               defaultWindowDaysBefore, defaultWindowDaysAfter,
               COALESCE(christmasWindowUsesThanksgivingStart, 0),
               COALESCE(windowDaysAfterThanksgiving, 0),
               COALESCE(weekendBoost, 0)
        FROM occasions
        WHERE occasionId = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(occasionId))
            if sqlite3_step(statement) == SQLITE_ROW {
                let record = OccasionRecord(
                    name: String(cString: sqlite3_column_text(statement, 2)),
                    scoring: OccasionForScoring(
                        occasionId: Int(sqlite3_column_int(statement, 0)),
                        occasionKey: String(cString: sqlite3_column_text(statement, 1)),
                        occasionType: String(cString: sqlite3_column_text(statement, 3)),
                        windowDaysBefore: Int(sqlite3_column_int(statement, 4)),
                        windowDaysAfter: Int(sqlite3_column_int(statement, 5)),
                        usesThanksgivingRelativeStart: sqlite3_column_int(statement, 6) != 0,
                        windowDaysAfterThanksgiving: Int(sqlite3_column_int(statement, 7)),
                        weekendBoost: clampWeekendBoost(sqlite3_column_double(statement, 8))
                    )
                )
                sqlite3_finalize(statement)
                return record
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    func fetchEventOccasionScoreUnsafe(
        eventId: Int,
        occasionId: Int,
        year: Int
    ) -> EventOccasionScoreRow? {
        let sql = """
        SELECT dateScore, objectScore, albumScore, COALESCE(weekendScore, 0), totalScore, confidence
        FROM event_occasion_scores
        WHERE eventId = ?
          AND occasionId = ?
          AND year = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_int(statement, 2, Int32(occasionId))
            sqlite3_bind_int(statement, 3, Int32(year))
            if sqlite3_step(statement) == SQLITE_ROW {
                let row = EventOccasionScoreRow(
                    dateScore: sqlite3_column_double(statement, 0),
                    objectScore: sqlite3_column_double(statement, 1),
                    albumScore: sqlite3_column_double(statement, 2),
                    weekendScore: sqlite3_column_double(statement, 3),
                    totalScore: sqlite3_column_double(statement, 4),
                    confidence: sqliteOptionalText(statement, column: 5)
                )
                sqlite3_finalize(statement)
                return row
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    func fetchScoringRulesUnsafe(occasionId: Int) -> [OccasionScoringRule] {
        let sql = """
        SELECT signalType, signalValue, score
        FROM occasion_scoring_rules
        WHERE occasionId = ?
        ORDER BY signalType, signalValue;
        """

        var statement: OpaquePointer?
        var rules: [OccasionScoringRule] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(occasionId))
            while sqlite3_step(statement) == SQLITE_ROW {
                rules.append(
                    OccasionScoringRule(
                        signalType: String(cString: sqlite3_column_text(statement, 0)),
                        signalValue: String(cString: sqlite3_column_text(statement, 1)),
                        score: sqlite3_column_double(statement, 2)
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return rules
    }

    func deleteAllHolidayScoresUnsafe() {
        let sql = """
        DELETE FROM event_occasion_scores
        WHERE occasionId IN (
            SELECT occasionId
            FROM occasions
            WHERE occasionType = 'holiday'
        );
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) != SQLITE_DONE {
                print(
                    "Failed clearing all holiday scores:"
                        + " \(String(cString: sqlite3_errmsg(db!)))"
                )
            }
        }

        sqlite3_finalize(statement)
    }

    func deleteHolidayScoresForEventOccasionKeysUnsafe(
        eventId: Int,
        occasionKeys: [String]
    ) {
        guard !occasionKeys.isEmpty else { return }

        let escaped = occasionKeys
            .map { $0.replacingOccurrences(of: "'", with: "''") }
            .map { "'\($0)'" }
            .joined(separator: ", ")
        let sql = """
        DELETE FROM event_occasion_scores
        WHERE eventId = ?
          AND occasionId IN (
              SELECT occasionId
              FROM occasions
              WHERE occasionType = 'holiday'
                AND occasionKey IN (\(escaped))
          );
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if sqlite3_step(statement) != SQLITE_DONE {
                print(
                    "Failed clearing holiday scores for event \(eventId):"
                        + " \(String(cString: sqlite3_errmsg(db!)))"
                )
            }
        }

        sqlite3_finalize(statement)
    }

    func deleteHolidayScoresForEventUnsafe(eventId: Int) {
        let sql = """
        DELETE FROM event_occasion_scores
        WHERE eventId = ?
          AND occasionId IN (
              SELECT occasionId
              FROM occasions
              WHERE occasionType = 'holiday'
          );
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if sqlite3_step(statement) != SQLITE_DONE {
                print(
                    "Failed clearing holiday scores for event \(eventId):"
                        + " \(String(cString: sqlite3_errmsg(db!)))"
                )
            }
        }

        sqlite3_finalize(statement)
    }

    func upsertEventOccasionScoreUnsafe(_ draft: EventOccasionScoreDraft, scoredAt: String) {
        let sql = """
        INSERT INTO event_occasion_scores (
            eventId, occasionId, year,
            dateScore, objectScore, albumScore, peopleScore, locationScore, userScore,
            weekendScore, totalScore, confidence, isConfirmed, isRejected, scoredAt
        )
        VALUES (?, ?, ?, ?, ?, ?, 0, 0, 0, ?, ?, ?, 0, 0, ?)
        ON CONFLICT(eventId, occasionId, year) DO UPDATE SET
            dateScore = excluded.dateScore,
            objectScore = excluded.objectScore,
            albumScore = excluded.albumScore,
            weekendScore = excluded.weekendScore,
            totalScore = excluded.totalScore,
            confidence = excluded.confidence,
            scoredAt = excluded.scoredAt;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_int(statement, 1, Int32(draft.eventId))
        sqlite3_bind_int(statement, 2, Int32(draft.occasionId))
        sqlite3_bind_int(statement, 3, Int32(draft.year))
        sqlite3_bind_double(statement, 4, draft.dateScore)
        sqlite3_bind_double(statement, 5, draft.objectScore)
        sqlite3_bind_double(statement, 6, draft.albumScore)
        sqlite3_bind_double(statement, 7, draft.weekendScore)
        sqlite3_bind_double(statement, 8, draft.totalScore)
        if let confidence = draft.confidence {
            sqlite3_bind_text(statement, 9, (confidence as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 9)
        }
        sqlite3_bind_text(statement, 10, (scoredAt as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    func fetchTopHolidayScoresUnsafe(limit: Int) -> [OccasionScoringTopMatch] {
        let sql = """
        SELECT
            s.eventId,
            s.year,
            s.dateScore,
            s.objectScore,
            s.albumScore,
            COALESCE(s.weekendScore, 0),
            s.totalScore,
            s.confidence,
            o.occasionKey,
            o.name,
            e.name,
            e.startDate,
            e.endDate
        FROM event_occasion_scores s
        JOIN occasions o ON o.occasionId = s.occasionId
        JOIN events e ON e.eventId = s.eventId
        WHERE o.occasionType = 'holiday'
          AND COALESCE(s.isRejected, 0) = 0
        ORDER BY s.totalScore DESC, s.dateScore DESC, s.eventId ASC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        var rows: [OccasionScoringTopMatch] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
            var rank = 0
            while sqlite3_step(statement) == SQLITE_ROW {
                rank += 1
                rows.append(
                    OccasionScoringTopMatch(
                        rank: rank,
                        occasionKey: String(cString: sqlite3_column_text(statement, 8)),
                        occasionName: String(cString: sqlite3_column_text(statement, 9)),
                        year: Int(sqlite3_column_int(statement, 1)),
                        totalScore: sqlite3_column_double(statement, 6),
                        dateScore: sqlite3_column_double(statement, 2),
                        objectScore: sqlite3_column_double(statement, 3),
                        albumScore: sqlite3_column_double(statement, 4),
                        weekendScore: sqlite3_column_double(statement, 5),
                        confidence: sqliteOptionalText(statement, column: 7),
                        eventId: Int(sqlite3_column_int(statement, 0)),
                        eventName: sqliteOptionalText(statement, column: 10) ?? "",
                        startDateISO: sqliteOptionalText(statement, column: 11) ?? "",
                        endDateISO: sqliteOptionalText(statement, column: 12) ?? ""
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return rows
    }

    func occasionScoringCountsUnsafe() -> OccasionScoringCounts {
        let holidayOccasions = countRowsUnsafe(
            "occasions WHERE isEnabled = 1 AND occasionType = 'holiday'"
        )
        let scoringRules = countRowsUnsafe("occasion_scoring_rules")
        let scoredRows = countRowsUnsafe("event_occasion_scores")
        let highConfidence = countRowsUnsafe(
            "event_occasion_scores WHERE confidence = 'high'"
        )
        let mediumConfidence = countRowsUnsafe(
            "event_occasion_scores WHERE confidence = 'medium'"
        )
        let lowConfidence = countRowsUnsafe(
            "event_occasion_scores WHERE confidence = 'low'"
        )

        return OccasionScoringCounts(
            holidayOccasions: holidayOccasions,
            scoringRules: scoringRules,
            scoredRows: scoredRows,
            highConfidence: highConfidence,
            mediumConfidence: mediumConfidence,
            lowConfidence: lowConfidence
        )
    }

    struct QualifyingHolidayScore: Sendable {
        let occasionId: Int
        let occasionKey: String
        let totalScore: Double
    }

    func fetchEventIdsQualifyingForOccasionUnsafe(
        occasionId: Int,
        minimumTotalScore: Double
    ) -> [Int] {
        let sql = """
        SELECT DISTINCT s.eventId
        FROM event_occasion_scores s
        JOIN events e ON e.eventId = s.eventId
        WHERE s.occasionId = ?
          AND s.totalScore >= ?
          AND COALESCE(s.isRejected, 0) = 0
          AND e.isDeleted = 0
        ORDER BY s.eventId ASC;
        """

        var statement: OpaquePointer?
        var eventIds: [Int] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(occasionId))
            sqlite3_bind_double(statement, 2, minimumTotalScore)
            while sqlite3_step(statement) == SQLITE_ROW {
                eventIds.append(Int(sqlite3_column_int(statement, 0)))
            }
        }

        sqlite3_finalize(statement)
        return eventIds
    }

    func fetchQualifyingHolidayScoresUnsafe(
        eventId: Int,
        minimumTotalScore: Double
    ) -> [QualifyingHolidayScore] {
        let sql = """
        SELECT
            s.occasionId,
            o.occasionKey,
            MAX(s.totalScore)
        FROM event_occasion_scores s
        JOIN occasions o ON o.occasionId = s.occasionId
        WHERE s.eventId = ?
          AND o.occasionType = 'holiday'
          AND COALESCE(o.isEnabled, 1) = 1
          AND s.totalScore >= ?
        GROUP BY s.occasionId, o.occasionKey
        ORDER BY MAX(s.totalScore) DESC;
        """

        var statement: OpaquePointer?
        var rows: [QualifyingHolidayScore] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_double(statement, 2, minimumTotalScore)
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    QualifyingHolidayScore(
                        occasionId: Int(sqlite3_column_int(statement, 0)),
                        occasionKey: String(cString: sqlite3_column_text(statement, 1)),
                        totalScore: sqlite3_column_double(statement, 2)
                    )
                )
            }
        }

        sqlite3_finalize(statement)
        return rows
    }

    func fetchObjectScoringRulesUnsafe(occasionId: Int) -> [EditableObjectScoringRule] {
        fetchScoringRulesUnsafe(occasionId: occasionId)
            .filter { $0.signalType.lowercased() == "object" }
            .map {
                EditableObjectScoringRule(
                    occasionId: occasionId,
                    objectKey: $0.signalValue,
                    score: $0.score
                )
            }
    }

    func fetchObjectScoringRules(occasionId: Int) -> [EditableObjectScoringRule] {
        sync { fetchObjectScoringRulesUnsafe(occasionId: occasionId) }
    }

    func saveObjectScoringRulesUnsafe(
        occasionId: Int,
        rules: [EditableObjectScoringRule]
    ) {
        let deleteSQL = """
        DELETE FROM occasion_scoring_rules
        WHERE occasionId = ? AND signalType = 'object';
        """
        var deleteStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(deleteStatement, 1, Int32(occasionId))
            sqlite3_step(deleteStatement)
        }
        sqlite3_finalize(deleteStatement)

        for rule in rules {
            guard let objectKey = OccasionObjectKeyFormatter.canonical(from: rule.objectKey) else {
                continue
            }
            upsertScoringRuleUnsafe(
                occasionId: occasionId,
                signalType: "object",
                signalValue: objectKey,
                score: min(1.0, max(0, rule.score))
            )
        }
    }

    func saveObjectScoringRules(
        occasionId: Int,
        rules: [EditableObjectScoringRule]
    ) {
        sync {
            saveObjectScoringRulesUnsafe(occasionId: occasionId, rules: rules)
        }
    }

    func eventMatchesScoringSignalUnsafe(
        eventId: Int,
        signalType: String,
        signalValue: String,
        includesDescendantPhotos: Bool = false,
        minObjectConfidence: Double = 0.45
    ) -> Bool {
        let normalizedType = signalType.lowercased()
        let normalizedValue = signalValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalizedType {
        case "keyword":
            return eventMatchesKeywordSignalUnsafe(
                eventId: eventId,
                signalValue: normalizedValue,
                includesDescendantPhotos: includesDescendantPhotos
            )
        case "album":
            return eventMatchesAlbumSignalUnsafe(
                eventId: eventId,
                signalValue: normalizedValue,
                includesDescendantPhotos: includesDescendantPhotos
            )
        case "object":
            return eventObjectPhotoCountUnsafe(
                eventId: eventId,
                objectKey: normalizedValue,
                includesDescendantPhotos: includesDescendantPhotos,
                minConfidence: minObjectConfidence
            ) > 0
        default:
            return false
        }
    }

    private func photoEventScopeSQL(includesDescendantPhotos: Bool) -> String {
        if includesDescendantPhotos {
            return """
            FROM events e
            JOIN photo_events pe ON pe.eventId = e.eventId
            JOIN photos p ON pe.photoId = p.id
            WHERE e.isDeleted = 0
              AND p.isDeleted = 0
              AND (e.eventId = ? OR e.parentEventId = ?)
            """
        }

        return """
        FROM photo_events pe
        JOIN photos p ON pe.photoId = p.id
        WHERE pe.eventId = ?
          AND p.isDeleted = 0
        """
    }

    private func eventMatchesKeywordSignalUnsafe(
        eventId: Int,
        signalValue: String,
        includesDescendantPhotos: Bool
    ) -> Bool {
        guard let needle = keywordNeedle(from: signalValue) else { return false }

        let sql = """
        SELECT 1
        \(photoEventScopeSQL(includesDescendantPhotos: includesDescendantPhotos))
        LEFT JOIN photo_text_metadata m ON m.photoId = p.id
        WHERE (
            LOWER(COALESCE(m.originalFilename, '')) LIKE ?
            OR LOWER(COALESCE(m.assetTitle, '')) LIKE ?
            OR LOWER(COALESCE(m.keywordsJson, '')) LIKE ?
          )
        LIMIT 1;
        """

        let pattern = "%\(needle)%"
        var statement: OpaquePointer?
        var matched = false

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindPhotoEventScope(statement, eventId: eventId, includesDescendantPhotos: includesDescendantPhotos)
            sqlite3_bind_text(statement, bindIndex(afterScope: includesDescendantPhotos, position: 1), (pattern as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, bindIndex(afterScope: includesDescendantPhotos, position: 2), (pattern as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, bindIndex(afterScope: includesDescendantPhotos, position: 3), (pattern as NSString).utf8String, -1, nil)
            matched = sqlite3_step(statement) == SQLITE_ROW
        }

        sqlite3_finalize(statement)
        return matched
    }

    func eventObjectPhotoCountUnsafe(
        eventId: Int,
        objectKey: String,
        includesDescendantPhotos: Bool,
        minConfidence: Double
    ) -> Int {
        guard !objectKey.isEmpty else { return 0 }

        let sql: String
        if includesDescendantPhotos {
            sql = """
            SELECT COUNT(DISTINCT pot.photoId)
            FROM photo_object_tags pot
            JOIN photo_events pe ON pe.photoId = pot.photoId
            JOIN photos p ON p.id = pot.photoId AND p.isDeleted = 0
            WHERE pot.objectKey = ?
              AND pot.confidence >= ?
              AND (
                pe.eventId = ?
                OR pe.eventId IN (
                    SELECT child.eventId
                    FROM events child
                    WHERE child.parentEventId = ?
                      AND child.isDeleted = 0
                )
              );
            """
        } else {
            sql = """
            SELECT COUNT(DISTINCT pot.photoId)
            FROM photo_object_tags pot
            JOIN photo_events pe ON pe.photoId = pot.photoId
            JOIN photos p ON p.id = pot.photoId AND p.isDeleted = 0
            WHERE pot.objectKey = ?
              AND pot.confidence >= ?
              AND pe.eventId = ?;
            """
        }

        var statement: OpaquePointer?
        var photoCount = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if includesDescendantPhotos {
                sqlite3_bind_text(statement, 1, (objectKey as NSString).utf8String, -1, nil)
                sqlite3_bind_double(statement, 2, minConfidence)
                sqlite3_bind_int(statement, 3, Int32(eventId))
                sqlite3_bind_int(statement, 4, Int32(eventId))
            } else {
                sqlite3_bind_text(statement, 1, (objectKey as NSString).utf8String, -1, nil)
                sqlite3_bind_double(statement, 2, minConfidence)
                sqlite3_bind_int(statement, 3, Int32(eventId))
            }
            if sqlite3_step(statement) == SQLITE_ROW {
                photoCount = Int(sqlite3_column_int(statement, 0))
            }
        }

        sqlite3_finalize(statement)
        return photoCount
    }

    private func eventMatchesAlbumSignalUnsafe(
        eventId: Int,
        signalValue: String,
        includesDescendantPhotos: Bool
    ) -> Bool {
        guard signalValue.hasPrefix("title_contains:") else { return false }
        let needle = String(signalValue.dropFirst("title_contains:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }

        let sql = """
        SELECT 1
        \(photoEventScopeSQL(includesDescendantPhotos: includesDescendantPhotos))
        JOIN photo_albums pa ON pa.photoId = p.id
        JOIN albums a ON a.albumId = pa.albumId
          AND COALESCE(a.isHighCardinality, 0) = 0
          AND LOWER(a.title) LIKE ?
        LIMIT 1;
        """

        let pattern = "%\(needle)%"
        var statement: OpaquePointer?
        var matched = false

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bindPhotoEventScope(statement, eventId: eventId, includesDescendantPhotos: includesDescendantPhotos)
            sqlite3_bind_text(statement, bindIndex(afterScope: includesDescendantPhotos, position: 1), (pattern as NSString).utf8String, -1, nil)
            matched = sqlite3_step(statement) == SQLITE_ROW
        }

        sqlite3_finalize(statement)
        return matched
    }

    private func bindPhotoEventScope(
        _ statement: OpaquePointer?,
        eventId: Int,
        includesDescendantPhotos: Bool
    ) {
        sqlite3_bind_int(statement, 1, Int32(eventId))
        if includesDescendantPhotos {
            sqlite3_bind_int(statement, 2, Int32(eventId))
        }
    }

    private func bindIndex(afterScope includesDescendantPhotos: Bool, position: Int32) -> Int32 {
        let scopeSlots: Int32 = includesDescendantPhotos ? 2 : 1
        return scopeSlots + position
    }

    private func keywordNeedle(from signalValue: String) -> String? {
        for prefix in ["filename_contains:", "title_contains:", "keyword:"] {
            if signalValue.hasPrefix(prefix) {
                let needle = String(signalValue.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return needle.isEmpty ? nil : needle
            }
        }
        return nil
    }

    private func sqliteOptionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    private func countRowsUnsafe(_ tableOrQuery: String) -> Int {
        let sql = "SELECT COUNT(*) FROM \(tableOrQuery);"
        var statement: OpaquePointer?
        var count = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = Int(sqlite3_column_int(statement, 0))
        }

        sqlite3_finalize(statement)
        return count
    }

    private func upsertScoringRuleUnsafe(
        occasionId: Int,
        signalType: String,
        signalValue: String,
        score: Double
    ) {
        let sql = """
        INSERT INTO occasion_scoring_rules (
            occasionId, signalType, signalValue, score
        )
        VALUES (?, ?, ?, ?)
        ON CONFLICT(occasionId, signalType, signalValue) DO UPDATE SET
            score = excluded.score;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_int(statement, 1, Int32(occasionId))
        sqlite3_bind_text(statement, 2, (signalType as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (signalValue as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 4, score)

        if sqlite3_step(statement) != SQLITE_DONE {
            print(
                "Failed upserting scoring rule \(signalType)/\(signalValue) for occasion \(occasionId):"
                    + " \(String(cString: sqlite3_errmsg(db!)))"
            )
        }
        sqlite3_finalize(statement)
    }

    private func insertScoringRuleUnsafe(
        occasionId: Int,
        signalType: String,
        signalValue: String,
        score: Double
    ) -> Bool {
        let sql = """
        INSERT OR IGNORE INTO occasion_scoring_rules (
            occasionId, signalType, signalValue, score
        )
        VALUES (?, ?, ?, ?);
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        sqlite3_bind_int(statement, 1, Int32(occasionId))
        sqlite3_bind_text(statement, 2, (signalType as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (signalValue as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 4, score)

        let ok = sqlite3_step(statement) == SQLITE_DONE
        sqlite3_finalize(statement)
        return ok && sqlite3_changes(db) > 0
    }

    // MARK: - People helpers (seed)

    private func resolvePersonIdUnsafe(searchNames: [String]) -> Int? {
        for name in searchNames {
            if let personId = people.findPersonIdUnsafe(matchingName: name), personId > 0 {
                return personId
            }
        }
        return nil
    }

    // MARK: - Occasions

    @discardableResult
    private func upsertOccasionUnsafe(
        occasionKey: String,
        name: String,
        occasionType: String,
        personId: Int?,
        windowDaysBefore: Int = 3,
        windowDaysAfter: Int = 3,
        weekendBoost: Double = 0
    ) -> Int {
        let before = clampWindowDays(windowDaysBefore)
        let after = clampWindowDays(windowDaysAfter)
        let boost = clampWeekendBoost(weekendBoost)

        let sql = """
        INSERT INTO occasions (
            occasionKey, name, occasionType, personId,
            defaultWindowDaysBefore, defaultWindowDaysAfter, weekendBoost, isEnabled
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, 1)
        ON CONFLICT(occasionKey) DO UPDATE SET
            name = excluded.name,
            occasionType = excluded.occasionType,
            personId = excluded.personId;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (occasionKey as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (occasionType as NSString).utf8String, -1, nil)

            if let personId, personId > 0 {
                sqlite3_bind_int(statement, 4, Int32(personId))
            } else {
                sqlite3_bind_null(statement, 4)
            }

            sqlite3_bind_int(statement, 5, Int32(before))
            sqlite3_bind_int(statement, 6, Int32(after))
            sqlite3_bind_double(statement, 7, boost)

            if sqlite3_step(statement) != SQLITE_DONE {
                print(
                    "Failed upserting occasion \(occasionKey):"
                        + " \(String(cString: sqlite3_errmsg(db!)))"
                )
            }
        }

        sqlite3_finalize(statement)
        return occasionIdUnsafe(occasionKey: occasionKey)
    }

    func fetchOccasionPersonId(occasionKey: String) -> Int? {
        sync {
            fetchOccasionPersonIdUnsafe(occasionKey: occasionKey)
        }
    }

    func fetchOccasionPersonIdUnsafe(occasionKey: String) -> Int? {
        let sql = """
        SELECT personId FROM occasions WHERE occasionKey = ? LIMIT 1;
        """

        var statement: OpaquePointer?
        var personId: Int?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (occasionKey as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW,
               sqlite3_column_type(statement, 0) != SQLITE_NULL {
                personId = Int(sqlite3_column_int(statement, 0))
            }
        }

        sqlite3_finalize(statement)
        return personId
    }

    func fetchOccasionIdForKeyUnsafe(occasionKey: String) -> Int? {
        let occasionId = occasionIdUnsafe(occasionKey: occasionKey)
        return occasionId > 0 ? occasionId : nil
    }

    private func occasionIdUnsafe(occasionKey: String) -> Int {
        let sql = """
        SELECT occasionId FROM occasions WHERE occasionKey = ? LIMIT 1;
        """

        var statement: OpaquePointer?
        var occasionId = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (occasionKey as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                occasionId = Int(sqlite3_column_int(statement, 0))
            }
        }

        sqlite3_finalize(statement)
        return occasionId
    }

    // MARK: - Occasion dates

    @discardableResult
    private func seedBirthdayOccasionUnsafe(
        occasionKey: String,
        displayName: String,
        birthDateISO: String,
        personId: Int?,
        endYear: Int
    ) -> Int {
        guard let parts = parseBirthDateISO(birthDateISO) else { return 0 }

        let occasionId = upsertOccasionUnsafe(
            occasionKey: occasionKey,
            name: displayName,
            occasionType: "birthday",
            personId: personId,
            weekendBoost: Self.defaultBirthdayWeekendBoost
        )
        guard occasionId > 0 else { return 0 }

        deleteBirthdayDatesBeforeBirthUnsafe(occasionId: occasionId, birthYear: parts.year)
        return insertBirthdayDatesUnsafe(
            occasionId: occasionId,
            month: parts.month,
            day: parts.day,
            fromYear: parts.year,
            throughYear: endYear
        )
    }

    @discardableResult
    private func seedAllPeopleBirthdaysUnsafe(endYear: Int) -> Int {
        var dateRowsInserted = 0

        for person in people.fetchPeopleWithBirthDatesUnsafe() {
            let occasionKey = birthdayOccasionKey(forName: person.name)
            let displayName = "\(person.name) Birthday"
            dateRowsInserted += seedBirthdayOccasionUnsafe(
                occasionKey: occasionKey,
                displayName: displayName,
                birthDateISO: person.birthDateISO,
                personId: person.personId,
                endYear: endYear
            )
        }

        return dateRowsInserted
    }

    private func birthdayOccasionKey(forName name: String) -> String {
        let slug = name
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return slug.isEmpty ? "birthday" : "\(slug)_birthday"
    }

    @discardableResult
    private func insertFloatingHolidayDatesUnsafe(
        occasionId: Int,
        rule: FloatingHolidayRule,
        fromYear: Int,
        throughYear: Int
    ) -> Int {
        guard fromYear <= throughYear else { return 0 }

        var inserted = 0
        for year in fromYear...throughYear {
            guard let dateISO = floatingHolidayDateISO(year: year, rule: rule) else { continue }
            if insertOccasionDateUnsafe(occasionId: occasionId, year: year, dateISO: dateISO) {
                inserted += 1
            }
        }
        return inserted
    }

    private func floatingHolidayDateISO(year: Int, rule: FloatingHolidayRule) -> String? {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = year
        components.weekday = 1

        switch rule {
        case .secondSundayInMay:
            components.month = 5
            components.weekdayOrdinal = 2
        case .thirdSundayInJune:
            components.month = 6
            components.weekdayOrdinal = 3
        case .westernEasterSunday:
            guard let date = EasterDate.date(forYear: year) else { return nil }
            return Self.landingReferenceDateISO(date)
        }

        guard rule != .westernEasterSunday,
              let date = components.date else { return nil }
        return Self.landingReferenceDateISO(date)
    }

    @discardableResult
    private func insertFixedHolidayDatesUnsafe(
        occasionId: Int,
        month: Int,
        day: Int,
        fromYear: Int,
        throughYear: Int
    ) -> Int {
        guard fromYear <= throughYear else { return 0 }

        var inserted = 0
        for year in fromYear...throughYear {
            guard let dateISO = dateISO(year: year, month: month, day: day) else { continue }
            if insertOccasionDateUnsafe(occasionId: occasionId, year: year, dateISO: dateISO) {
                inserted += 1
            }
        }
        return inserted
    }

    private func deleteBirthdayDatesBeforeBirthUnsafe(occasionId: Int, birthYear: Int) {
        let sql = "DELETE FROM occasion_dates WHERE occasionId = ? AND year < ?;"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_int(statement, 1, Int32(occasionId))
        sqlite3_bind_int(statement, 2, Int32(birthYear))
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    @discardableResult
    private func insertBirthdayDatesUnsafe(
        occasionId: Int,
        month: Int,
        day: Int,
        fromYear: Int,
        throughYear: Int
    ) -> Int {
        guard fromYear <= throughYear else { return 0 }

        var inserted = 0
        for year in fromYear...throughYear {
            guard let dateISO = dateISO(year: year, month: month, day: day) else { continue }
            if insertOccasionDateUnsafe(occasionId: occasionId, year: year, dateISO: dateISO) {
                inserted += 1
            }
        }
        return inserted
    }

    @discardableResult
    private func insertOccasionDateUnsafe(
        occasionId: Int,
        year: Int,
        dateISO: String
    ) -> Bool {
        let sql = """
        INSERT OR IGNORE INTO occasion_dates (
            occasionId, year, date, observedDate, startDate, endDate
        )
        VALUES (?, ?, ?, NULL, NULL, NULL);
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        sqlite3_bind_int(statement, 1, Int32(occasionId))
        sqlite3_bind_int(statement, 2, Int32(year))
        sqlite3_bind_text(statement, 3, (dateISO as NSString).utf8String, -1, nil)

        let ok = sqlite3_step(statement) == SQLITE_DONE
        sqlite3_finalize(statement)
        return ok && sqlite3_changes(db) > 0
    }

    private func parseBirthDateISO(_ iso: String) -> (year: Int, month: Int, day: Int)? {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        return (year, month, day)
    }

    private func dateISO(year: Int, month: Int, day: Int) -> String? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.calendar = Calendar.current
        guard let date = components.date else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func fetchAllHolidayVisionLandingConfigs() -> [HolidayVisionLandingConfig] {
        sync { fetchAllHolidayVisionLandingConfigsUnsafe() }
    }

    func fetchAllHolidayVisionLandingConfigsUnsafe() -> [HolidayVisionLandingConfig] {
        fetchLandingOccasionsUnsafe(includeDisabled: false)
            .filter { $0.occasionType == "holiday" }
            .compactMap { row -> HolidayVisionLandingConfig? in
                let occasionId = occasionIdUnsafe(occasionKey: row.occasionKey)
                guard occasionId > 0 else { return nil }
                guard !fetchObjectScoringRulesUnsafe(occasionId: occasionId).isEmpty else { return nil }
                let tagValue = OccasionHolidayTagService.holidayTagValue(
                    occasionKey: row.occasionKey,
                    displayName: row.name
                )
                return HolidayVisionLandingConfig(
                    occasionKey: row.occasionKey,
                    tagValue: tagValue,
                    displayName: row.name
                )
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    /// Holiday collection that supports Vision landing: enabled occasion with object scoring rules.
    func holidayVisionLandingConfig(tagValue: String) -> HolidayVisionLandingConfig? {
        sync { holidayVisionLandingConfigUnsafe(tagValue: tagValue) }
    }

    func holidayVisionLandingConfigUnsafe(tagValue: String) -> HolidayVisionLandingConfig? {
        let trimmedTag = tagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTag.isEmpty else { return nil }

        for row in fetchLandingOccasionsUnsafe(includeDisabled: false) {
            guard row.occasionType == "holiday" else { continue }

            let resolvedTag = OccasionHolidayTagService.holidayTagValue(
                occasionKey: row.occasionKey,
                displayName: row.name
            )
            guard resolvedTag == trimmedTag else { continue }
            let occasionId = occasionIdUnsafe(occasionKey: row.occasionKey)
            guard occasionId > 0 else { continue }
            guard !fetchObjectScoringRulesUnsafe(occasionId: occasionId).isEmpty else { continue }

            return HolidayVisionLandingConfig(
                occasionKey: row.occasionKey,
                tagValue: resolvedTag,
                displayName: row.name
            )
        }

        return nil
    }

    // MARK: - Holidays landing

    func fetchOccasionLandingCatalog(referenceDate: Date = Date()) -> [OccasionLandingCatalogRow] {
        sync { fetchOccasionLandingCatalogUnsafe(referenceDate: referenceDate) }
    }

    func fetchOccasionLandingCatalogUnsafe(
        referenceDate: Date = Date()
    ) -> [OccasionLandingCatalogRow] {
        var occasions = fetchLandingOccasionsUnsafe(includeDisabled: false)
        if occasions.isEmpty {
            ensureDefaultSeedDataUnsafe()
            occasions = fetchLandingOccasionsUnsafe(includeDisabled: false)
        }
        if occasions.isEmpty {
            occasions = fetchLandingOccasionsUnsafe(includeDisabled: true)
        }
        var rows: [OccasionLandingCatalogRow] = []

        for occasion in occasions {
            guard let nextISO = nextOccurrenceISOUnsafe(
                occasionId: occasion.occasionId,
                referenceDate: referenceDate
            ) else {
                continue
            }
            rows.append(
                OccasionLandingCatalogRow(
                    occasionId: occasion.occasionId,
                    occasionKey: occasion.occasionKey,
                    name: occasion.name,
                    occasionType: occasion.occasionType,
                    nextOccurrenceISO: nextISO
                )
            )
        }

        return rows.sorted {
            if $0.nextOccurrenceISO == $1.nextOccurrenceISO {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.nextOccurrenceISO < $1.nextOccurrenceISO
        }
    }

    private struct LandingOccasionRow: Sendable {
        let occasionId: Int
        let occasionKey: String
        let name: String
        let occasionType: String
    }

    private func fetchLandingOccasionsUnsafe(includeDisabled: Bool) -> [LandingOccasionRow] {
        var sql = """
        SELECT occasionId, occasionKey, name, occasionType
        FROM occasions
        WHERE occasionType IN ('holiday', 'birthday')
        """
        if !includeDisabled {
            sql += " AND COALESCE(isEnabled, 1) = 1"
        }
        sql += " ORDER BY name;"

        var statement: OpaquePointer?
        var rows: [LandingOccasionRow] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let occasionKey = sqliteOptionalText(statement, column: 1),
                      let name = sqliteOptionalText(statement, column: 2),
                      let occasionType = sqliteOptionalText(statement, column: 3) else {
                    continue
                }
                rows.append(
                    LandingOccasionRow(
                        occasionId: Int(sqlite3_column_int(statement, 0)),
                        occasionKey: occasionKey,
                        name: name,
                        occasionType: occasionType
                    )
                )
            }
        } else if let db {
            print(
                "Failed to fetch landing occasions:"
                    + " \(String(cString: sqlite3_errmsg(db)))"
            )
        }

        sqlite3_finalize(statement)
        return rows
    }

    private func nextOccurrenceISOUnsafe(
        occasionId: Int,
        referenceDate: Date
    ) -> String? {
        let todayISO = Self.landingReferenceDateISO(referenceDate)
        if let futureISO = minOccasionDateISOUnsafe(
            occasionId: occasionId,
            onOrAfter: todayISO
        ) {
            return futureISO
        }

        guard let anchorISO = minOccasionDateISOUnsafe(occasionId: occasionId, onOrAfter: nil) else {
            return nil
        }

        return Self.nextAnnualOccurrenceISO(
            anchorISO: anchorISO,
            referenceDate: referenceDate
        )
    }

    private func minOccasionDateISOUnsafe(
        occasionId: Int,
        onOrAfter lowerBoundISO: String?
    ) -> String? {
        var sql = """
        SELECT MIN(COALESCE(observedDate, date))
        FROM occasion_dates
        WHERE occasionId = ?
        """
        if lowerBoundISO != nil {
            sql += " AND COALESCE(observedDate, date) >= ?"
        }
        sql += ";"

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(occasionId))
            if let lowerBoundISO {
                sqlite3_bind_text(statement, 2, (lowerBoundISO as NSString).utf8String, -1, nil)
            }
            if sqlite3_step(statement) == SQLITE_ROW {
                let value = sqliteOptionalText(statement, column: 0)
                sqlite3_finalize(statement)
                return value
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    private func occasionDateCountUnsafe(occasionId: Int) -> Int {
        let sql = "SELECT COUNT(*) FROM occasion_dates WHERE occasionId = ?;"
        var statement: OpaquePointer?
        var count = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(occasionId))
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        }

        sqlite3_finalize(statement)
        return count
    }

    private func repairMissingOccasionDatesUnsafe(
        holidays: [FixedHolidaySeed],
        floatingHolidays: [FloatingHolidaySeed],
        birthdays: [BirthdaySeed],
        currentYear: Int,
        endYear: Int
    ) {
        for holiday in holidays {
            let occasionId = occasionIdUnsafe(occasionKey: holiday.occasionKey)
            guard occasionId > 0, occasionDateCountUnsafe(occasionId: occasionId) == 0 else {
                continue
            }
            _ = insertFixedHolidayDatesUnsafe(
                occasionId: occasionId,
                month: holiday.month,
                day: holiday.day,
                fromYear: currentYear - 1,
                throughYear: endYear
            )
        }

        for holiday in floatingHolidays {
            let occasionId = occasionIdUnsafe(occasionKey: holiday.occasionKey)
            guard occasionId > 0, occasionDateCountUnsafe(occasionId: occasionId) == 0 else {
                continue
            }
            _ = insertFloatingHolidayDatesUnsafe(
                occasionId: occasionId,
                rule: holiday.rule,
                fromYear: currentYear - 1,
                throughYear: endYear
            )
        }

        for birthday in birthdays {
            let occasionId = occasionIdUnsafe(occasionKey: birthday.occasionKey)
            guard occasionId > 0,
                  occasionDateCountUnsafe(occasionId: occasionId) == 0,
                  let parts = parseBirthDateISO(birthday.birthDateISO) else {
                continue
            }
            _ = insertBirthdayDatesUnsafe(
                occasionId: occasionId,
                month: parts.month,
                day: parts.day,
                fromYear: parts.year,
                throughYear: endYear
            )
        }

        for person in people.fetchPeopleWithBirthDatesUnsafe() {
            let occasionKey = birthdayOccasionKey(forName: person.name)
            let occasionId = occasionIdUnsafe(occasionKey: occasionKey)
            guard occasionId > 0,
                  occasionDateCountUnsafe(occasionId: occasionId) == 0,
                  let parts = parseBirthDateISO(person.birthDateISO) else {
                continue
            }
            _ = insertBirthdayDatesUnsafe(
                occasionId: occasionId,
                month: parts.month,
                day: parts.day,
                fromYear: parts.year,
                throughYear: endYear
            )
        }
    }

    private static func landingReferenceDateISO(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func nextAnnualOccurrenceISO(
        anchorISO: String,
        referenceDate: Date
    ) -> String? {
        let parts = anchorISO.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        let calendar = Calendar.current
        let year = calendar.component(.year, from: referenceDate)
        var components = DateComponents(year: year, month: month, day: day)
        components.calendar = calendar

        guard var candidate = components.date else { return nil }

        let startOfToday = calendar.startOfDay(for: referenceDate)
        if candidate < startOfToday {
            components.year = year + 1
            guard let nextYear = components.date else { return nil }
            candidate = nextYear
        }

        return landingReferenceDateISO(candidate)
    }
}
