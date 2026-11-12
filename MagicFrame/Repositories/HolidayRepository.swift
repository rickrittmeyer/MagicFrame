import Foundation
import SQLite3

final class HolidayRepository {

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    private var db: OpaquePointer? { database.connection }

    private func sync<T>(_ work: () -> T) -> T {
        if database.isOnQueue {
            return work()
        }
        return database.sync(work)
    }

    func fetchAllEnabledHolidays() -> [HolidayDefinition] {
        sync { fetchAllEnabledHolidaysUnsafe() }
    }

    func fetchHoliday(named name: String) -> HolidayDefinition? {
        sync { fetchHolidayUnsafe(named: name) }
    }

    func fetchHoliday(holidayId: Int) -> HolidayDefinition? {
        sync { fetchHolidayUnsafe(holidayId: holidayId) }
    }

    /// Returns stored anchor for year, computing and caching if missing.
    func ensureAnchorDateISO(
        holidayId: Int,
        year: Int,
        calendar: Calendar = .current
    ) -> String? {
        sync { ensureAnchorDateISOUnsafe(holidayId: holidayId, year: year, calendar: calendar) }
    }

    func ensureAnchorDate(
        holidayId: Int,
        year: Int,
        calendar: Calendar = .current
    ) -> Date? {
        guard let iso = ensureAnchorDateISO(holidayId: holidayId, year: year, calendar: calendar) else {
            return nil
        }
        return EventDateParser.parseDate(iso)
    }

    func nextOccurrence(
        for holiday: HolidayDefinition,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard let holidayId = holiday.holidayId else {
            return HolidayDateResolver.date(
                for: holiday,
                year: calendar.component(.year, from: referenceDate),
                calendar: calendar
            ).flatMap { date in
                let start = calendar.startOfDay(for: referenceDate)
                if calendar.startOfDay(for: date) >= start { return date }
                return HolidayDateResolver.date(
                    for: holiday,
                    year: calendar.component(.year, from: referenceDate) + 1,
                    calendar: calendar
                )
            }
        }

        let year = calendar.component(.year, from: referenceDate)
        let startOfToday = calendar.startOfDay(for: referenceDate)
        if let thisYear = ensureAnchorDate(holidayId: holidayId, year: year, calendar: calendar),
           calendar.startOfDay(for: thisYear) >= startOfToday {
            return thisYear
        }
        return ensureAnchorDate(holidayId: holidayId, year: year + 1, calendar: calendar)
    }

    /// Inserts or updates a floating (user) holiday in `holidays`.
    func upsertFloatingHoliday(_ holiday: FloatingHolidayDefinition) -> Int {
        sync { upsertFloatingHolidayUnsafe(holiday) }
    }

    /// Inserts or updates a catalog holiday (fixed / floating / computed) and seeds year anchors.
    func upsertHoliday(_ holiday: HolidayDefinition) -> Int {
        sync { upsertHolidayUnsafe(holiday) }
    }

    func fetchFloatingHolidays() -> [FloatingHolidayDefinition] {
        sync {
            fetchAllEnabledHolidaysUnsafe()
                .filter { $0.kind == .floating && !$0.isBuiltIn }
                .compactMap { $0.toFloatingHolidayDefinition() }
        }
    }

    // MARK: - Unsafe

    func fetchAllEnabledHolidaysUnsafe() -> [HolidayDefinition] {
        let sql = """
        SELECT holidayId, name, kind, fixedMonth, fixedDay, ruleKind, month, weekday, weekOrdinal,
               includeWeekendsBefore, isBuiltIn, isEnabled, sortIndex
        FROM holidays
        WHERE isEnabled = 1
        ORDER BY sortIndex ASC, name COLLATE NOCASE ASC;
        """
        var statement: OpaquePointer?
        var rows: [HolidayDefinition] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let holiday = holidayFromRow(statement) {
                    rows.append(holiday)
                }
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    func fetchHolidayUnsafe(named name: String) -> HolidayDefinition? {
        let sql = """
        SELECT holidayId, name, kind, fixedMonth, fixedDay, ruleKind, month, weekday, weekOrdinal,
               includeWeekendsBefore, isBuiltIn, isEnabled, sortIndex
        FROM holidays
        WHERE name = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        var holiday: HolidayDefinition?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                holiday = holidayFromRow(statement)
            }
        }
        sqlite3_finalize(statement)
        return holiday
    }

    func fetchHolidayUnsafe(holidayId: Int) -> HolidayDefinition? {
        let sql = """
        SELECT holidayId, name, kind, fixedMonth, fixedDay, ruleKind, month, weekday, weekOrdinal,
               includeWeekendsBefore, isBuiltIn, isEnabled, sortIndex
        FROM holidays
        WHERE holidayId = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        var holiday: HolidayDefinition?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(holidayId))
            if sqlite3_step(statement) == SQLITE_ROW {
                holiday = holidayFromRow(statement)
            }
        }
        sqlite3_finalize(statement)
        return holiday
    }

    func ensureAnchorDateISOUnsafe(
        holidayId: Int,
        year: Int,
        calendar: Calendar = .current
    ) -> String? {
        if let existing = fetchAnchorDateISOUnsafe(holidayId: holidayId, year: year) {
            return existing
        }
        guard let holiday = fetchHolidayUnsafe(holidayId: holidayId),
              let iso = HolidayDateResolver.dateISO(
                for: holiday,
                year: year,
                calendar: calendar
              ) else {
            return nil
        }
        upsertAnchorDateUnsafe(holidayId: holidayId, year: year, anchorDate: iso)
        return iso
    }

    private func fetchAnchorDateISOUnsafe(holidayId: Int, year: Int) -> String? {
        let sql = """
        SELECT anchorDate
        FROM holiday_dates
        WHERE holidayId = ? AND year = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        var value: String?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(holidayId))
            sqlite3_bind_int(statement, 2, Int32(year))
            if sqlite3_step(statement) == SQLITE_ROW,
               let cString = sqlite3_column_text(statement, 0) {
                value = String(cString: cString)
            }
        }
        sqlite3_finalize(statement)
        return value
    }

    private func upsertAnchorDateUnsafe(holidayId: Int, year: Int, anchorDate: String) {
        let sql = """
        INSERT INTO holiday_dates (holidayId, year, anchorDate)
        VALUES (?, ?, ?)
        ON CONFLICT(holidayId, year) DO UPDATE SET anchorDate = excluded.anchorDate;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(holidayId))
            sqlite3_bind_int(statement, 2, Int32(year))
            sqlite3_bind_text(statement, 3, (anchorDate as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    private func upsertFloatingHolidayUnsafe(_ holiday: FloatingHolidayDefinition) -> Int {
        let definition = HolidayDefinition(
            holidayId: holiday.floatingHolidayId,
            name: holiday.name,
            kind: .floating,
            fixedMonth: nil,
            fixedDay: nil,
            ruleKind: holiday.ruleKind,
            month: holiday.month,
            weekday: holiday.weekday,
            weekOrdinal: holiday.weekOrdinal,
            includeWeekendsBefore: true,
            isBuiltIn: false,
            isEnabled: holiday.isEnabled,
            sortIndex: 1000
        )
        return upsertHolidayUnsafe(definition)
    }

    private func upsertHolidayUnsafe(_ holiday: HolidayDefinition) -> Int {
        let sql = """
        INSERT INTO holidays (
            name, kind, fixedMonth, fixedDay, ruleKind, month, weekday, weekOrdinal,
            includeWeekendsBefore, isBuiltIn, isEnabled, sortIndex
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(name) DO UPDATE SET
            kind = excluded.kind,
            fixedMonth = excluded.fixedMonth,
            fixedDay = excluded.fixedDay,
            ruleKind = excluded.ruleKind,
            month = excluded.month,
            weekday = excluded.weekday,
            weekOrdinal = excluded.weekOrdinal,
            includeWeekendsBefore = excluded.includeWeekendsBefore,
            isBuiltIn = excluded.isBuiltIn,
            isEnabled = excluded.isEnabled,
            sortIndex = excluded.sortIndex;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (holiday.name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (holiday.kind.rawValue as NSString).utf8String, -1, nil)
            bindOptionalInt(statement, 3, holiday.fixedMonth)
            bindOptionalInt(statement, 4, holiday.fixedDay)
            if let ruleKind = holiday.ruleKind {
                sqlite3_bind_text(statement, 5, (ruleKind as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 5)
            }
            bindOptionalInt(statement, 6, holiday.month)
            bindOptionalInt(statement, 7, holiday.weekday)
            bindOptionalInt(statement, 8, holiday.weekOrdinal)
            sqlite3_bind_int(statement, 9, holiday.includeWeekendsBefore ? 1 : 0)
            sqlite3_bind_int(statement, 10, holiday.isBuiltIn ? 1 : 0)
            sqlite3_bind_int(statement, 11, holiday.isEnabled ? 1 : 0)
            sqlite3_bind_int(statement, 12, Int32(holiday.sortIndex))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)

        if holiday.kind == .floating,
           let ruleKind = holiday.ruleKind,
           let month = holiday.month,
           let weekday = holiday.weekday,
           let weekOrdinal = holiday.weekOrdinal {
            syncLegacyFloatingHolidayUnsafe(
                name: holiday.name,
                ruleKind: ruleKind,
                month: month,
                weekday: weekday,
                weekOrdinal: weekOrdinal,
                isEnabled: holiday.isEnabled
            )
        }

        guard let saved = fetchHolidayUnsafe(named: holiday.name),
              let holidayId = saved.holidayId else {
            return -1
        }
        seedHolidayDatesUnsafe(for: saved)
        return holidayId
    }

    private func syncLegacyFloatingHolidayUnsafe(
        name: String,
        ruleKind: String,
        month: Int,
        weekday: Int,
        weekOrdinal: Int,
        isEnabled: Bool
    ) {
        let legacySQL = """
        INSERT INTO floating_holidays (name, ruleKind, month, weekday, weekOrdinal, isEnabled)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(name) DO UPDATE SET
            ruleKind = excluded.ruleKind,
            month = excluded.month,
            weekday = excluded.weekday,
            weekOrdinal = excluded.weekOrdinal,
            isEnabled = excluded.isEnabled;
        """
        var legacyStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, legacySQL, -1, &legacyStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(legacyStatement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(legacyStatement, 2, (ruleKind as NSString).utf8String, -1, nil)
            sqlite3_bind_int(legacyStatement, 3, Int32(month))
            sqlite3_bind_int(legacyStatement, 4, Int32(weekday))
            sqlite3_bind_int(legacyStatement, 5, Int32(weekOrdinal))
            sqlite3_bind_int(legacyStatement, 6, isEnabled ? 1 : 0)
            sqlite3_step(legacyStatement)
        }
        sqlite3_finalize(legacyStatement)
    }

    private func seedHolidayDatesUnsafe(
        for holiday: HolidayDefinition,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        guard let holidayId = holiday.holidayId else { return }
        let yearRange = HolidayDateResolver.seededYearRange
        for year in yearRange {
            guard let iso = HolidayDateResolver.dateISO(
                for: holiday,
                year: year,
                calendar: calendar
            ) else {
                continue
            }
            upsertAnchorDateUnsafe(holidayId: holidayId, year: year, anchorDate: iso)
        }
    }

    private func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(statement, index, Int32(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func holidayFromRow(_ statement: OpaquePointer?) -> HolidayDefinition? {
        guard let kindRaw = sqlite3_column_text(statement, 2),
              let kind = HolidayKind(rawValue: String(cString: kindRaw)) else {
            return nil
        }
        return HolidayDefinition(
            holidayId: Int(sqlite3_column_int(statement, 0)),
            name: String(cString: sqlite3_column_text(statement, 1)),
            kind: kind,
            fixedMonth: optionalIntColumn(statement, 3),
            fixedDay: optionalIntColumn(statement, 4),
            ruleKind: optionalTextColumn(statement, 5),
            month: optionalIntColumn(statement, 6),
            weekday: optionalIntColumn(statement, 7),
            weekOrdinal: optionalIntColumn(statement, 8),
            includeWeekendsBefore: sqlite3_column_int(statement, 9) != 0,
            isBuiltIn: sqlite3_column_int(statement, 10) != 0,
            isEnabled: sqlite3_column_int(statement, 11) != 0,
            sortIndex: Int(sqlite3_column_int(statement, 12))
        )
    }

    private func optionalIntColumn(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, index))
    }

    private func optionalTextColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }
}
