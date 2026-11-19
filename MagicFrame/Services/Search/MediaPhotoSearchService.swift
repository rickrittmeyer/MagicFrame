import Foundation
import SQLite3

/// Evaluates ad-hoc All Media picture queries (AND/OR/NOT) to photo id sets.
final class MediaPhotoSearchService {

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

    func search(_ query: MediaSearchQuery) -> MediaPhotoSearchReport {
        sync { searchUnsafe(query) }
    }

    /// Caller must already be on the database queue (avoids nested `sync` deadlocks).
    func searchAssumingOnDatabaseQueue(_ query: MediaSearchQuery) -> MediaPhotoSearchReport {
        searchUnsafe(query)
    }

    func suggestionValues(
        field: MediaSearchField,
        query: String,
        limit: Int = 30
    ) -> [String] {
        sync { suggestionValuesUnsafe(field: field, query: query, limit: limit) }
    }

    // MARK: - Unsafe

    private func searchUnsafe(_ query: MediaSearchQuery) -> MediaPhotoSearchReport {
        let valid = query.criteria.filter(\.isValid)
        guard !valid.isEmpty,
              let tokens = MediaSearchExpressionBuilder.tokens(from: valid) else {
            return MediaPhotoSearchReport(photoIds: [], matchCount: 0)
        }

        let universe = fetchActivePhotoIdsUnsafe()
        let termSets: [UUID: Set<String>] = Dictionary(
            uniqueKeysWithValues: valid.map { criterion in
                var matched = matchCriterionUnsafe(criterion)
                if criterion.isNegated {
                    matched = universe.subtracting(matched)
                }
                return (criterion.id, matched)
            }
        )

        guard let combined = evaluateExpression(tokens, termSets: termSets) else {
            return MediaPhotoSearchReport(photoIds: [], matchCount: 0)
        }

        let ids = Array(combined).sorted()
        return MediaPhotoSearchReport(photoIds: ids, matchCount: ids.count)
    }

    /// Evaluates a parenthesized AND/OR expression left-to-right within each group.
    private func evaluateExpression(
        _ tokens: [MediaSearchExpressionToken],
        termSets: [UUID: Set<String>]
    ) -> Set<String>? {
        var index = 0
        return parseExpression(tokens, index: &index, termSets: termSets, stopAtClose: false)
    }

    private func parseExpression(
        _ tokens: [MediaSearchExpressionToken],
        index: inout Int,
        termSets: [UUID: Set<String>],
        stopAtClose: Bool
    ) -> Set<String>? {
        guard let first = parseTerm(tokens, index: &index, termSets: termSets) else {
            return nil
        }
        var result = first

        while index < tokens.count {
            if case .close = tokens[index] {
                if stopAtClose {
                    return result
                }
                return nil
            }
            guard case .join(let mode) = tokens[index] else {
                return nil
            }
            index += 1
            guard let next = parseTerm(tokens, index: &index, termSets: termSets) else {
                return nil
            }
            switch mode {
            case .all:
                result.formIntersection(next)
            case .any:
                result.formUnion(next)
            }
        }

        return result
    }

    private func parseTerm(
        _ tokens: [MediaSearchExpressionToken],
        index: inout Int,
        termSets: [UUID: Set<String>]
    ) -> Set<String>? {
        guard index < tokens.count else { return nil }

        switch tokens[index] {
        case .open:
            index += 1
            guard let value = parseExpression(
                tokens,
                index: &index,
                termSets: termSets,
                stopAtClose: true
            ) else {
                return nil
            }
            guard index < tokens.count, case .close = tokens[index] else {
                return nil
            }
            index += 1
            return value
        case .term(let id):
            index += 1
            return termSets[id]
        case .close, .join:
            return nil
        }
    }

    private func matchCriterionUnsafe(_ criterion: MediaSearchCriterion) -> Set<String> {
        let trimmed = criterion.value.trimmingCharacters(in: .whitespacesAndNewlines)

        switch criterion.field {
        case .filename:
            return matchTextColumnUnsafe(
                sql: """
                SELECT p.id
                FROM photos p
                JOIN photo_text_metadata m ON m.photoId = p.id
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND \(textPredicateSQL(column: "m.originalFilename", op: criterion.op))
                """,
                value: trimmed,
                op: criterion.op
            )
        case .albumName:
            return matchTextColumnUnsafe(
                sql: """
                SELECT DISTINCT pa.photoId
                FROM photo_albums pa
                JOIN albums a ON a.albumId = pa.albumId
                JOIN photos p ON p.id = pa.photoId
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND \(textPredicateSQL(column: "a.title", op: criterion.op))
                """,
                value: trimmed,
                op: criterion.op
            )
        case .ocrText:
            return matchTextColumnUnsafe(
                sql: """
                SELECT p.id
                FROM photos p
                JOIN photo_ocr_text o ON o.photoId = p.id
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND \(textPredicateSQL(column: "o.fullText", op: criterion.op))
                """,
                value: trimmed,
                op: criterion.op
            )
        case .visionTag:
            return matchVisionTagUnsafe(criterion: criterion, value: trimmed)
        case .locationNickname:
            return matchLocationColumnUnsafe(column: "l.nickname", value: trimmed, op: criterion.op)
        case .locationPlaceName:
            return matchLocationColumnUnsafe(column: "l.placeName", value: trimmed, op: criterion.op)
        case .locationCity:
            return matchLocationColumnUnsafe(column: "l.city", value: trimmed, op: criterion.op)
        case .locationState:
            return matchLocationColumnUnsafe(column: "l.state", value: trimmed, op: criterion.op)
        case .person:
            return matchPersonUnsafe(criterion: criterion, trimmedName: trimmed)
        case .eventName:
            return matchTextColumnUnsafe(
                sql: """
                SELECT DISTINCT pe.photoId
                FROM photo_events pe
                JOIN events e ON e.eventId = pe.eventId
                JOIN photos p ON p.id = pe.photoId
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND COALESCE(e.isDeleted, 0) = 0
                  AND (
                    \(textPredicateSQL(column: "e.name", op: criterion.op))
                    OR \(textPredicateSQL(column: "e.childEventName", op: criterion.op))
                  )
                """,
                value: trimmed,
                op: criterion.op,
                bindCount: 2
            )
        case .eventTag:
            return matchTextColumnUnsafe(
                sql: """
                SELECT DISTINCT pe.photoId
                FROM photo_events pe
                JOIN events e ON e.eventId = pe.eventId
                JOIN event_tags t ON t.eventId = e.eventId
                JOIN photos p ON p.id = pe.photoId
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND COALESCE(e.isDeleted, 0) = 0
                  AND COALESCE(t.isRejected, 0) = 0
                  AND \(textPredicateSQL(column: "t.tagValue", op: criterion.op))
                """,
                value: trimmed,
                op: criterion.op
            )
        case .eventTagCategory:
            return matchTextColumnUnsafe(
                sql: """
                SELECT DISTINCT pe.photoId
                FROM photo_events pe
                JOIN events e ON e.eventId = pe.eventId
                JOIN event_tags t ON t.eventId = e.eventId
                JOIN photos p ON p.id = pe.photoId
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND COALESCE(e.isDeleted, 0) = 0
                  AND COALESCE(t.isRejected, 0) = 0
                  AND \(textPredicateSQL(column: "t.tagCategory", op: criterion.op))
                """,
                value: trimmed,
                op: criterion.op
            )
        case .dateTaken:
            return matchDateTakenUnsafe(criterion: criterion, day: trimmed)
        case .mediaKind:
            return matchMediaKindUnsafe(trimmed)
        case .favorite:
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT id
                FROM photos
                WHERE COALESCE(isDeleted, 0) = 0
                  AND COALESCE(isFavorite, 0) = 1
                """,
                binds: []
            )
        case .onFrame:
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT DISTINCT pe.photoId
                FROM photo_events pe
                JOIN photos p ON p.id = pe.photoId
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND COALESCE(pe.includeInSlideshow, 0) = 1
                """,
                binds: []
            )
        case .camera:
            return matchCameraUnsafe(value: trimmed, op: criterion.op)
        case .hasFaces:
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT DISTINCT fi.photoId
                FROM face_instances fi
                JOIN photos p ON p.id = fi.photoId
                WHERE COALESCE(p.isDeleted, 0) = 0
                """,
                binds: []
            )
        case .faceCount:
            return matchFaceCountUnsafe(value: trimmed, op: criterion.op)
        }
    }

    private static let effectiveDateSQL =
        "COALESCE(NULLIF(TRIM(p.captureDateOverride), ''), p.creationDate)"

    private func matchDateTakenUnsafe(
        criterion: MediaSearchCriterion,
        day: String
    ) -> Set<String> {
        let dateExpr = Self.effectiveDateSQL
        let isoShapeSQL = """
        length(\(dateExpr)) >= 10
          AND substr(\(dateExpr), 5, 1) = '-'
          AND substr(\(dateExpr), 8, 1) = '-'
        """
        switch criterion.op {
        case .on:
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT p.id
                FROM photos p
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND substr(\(dateExpr), 1, 10) = ?
                """,
                binds: [day]
            )
        case .after:
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT p.id
                FROM photos p
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND substr(\(dateExpr), 1, 10) > ?
                """,
                binds: [day]
            )
        case .before:
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT p.id
                FROM photos p
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND substr(\(dateExpr), 1, 10) < ?
                """,
                binds: [day]
            )
        case .between:
            let end = criterion.secondaryValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT p.id
                FROM photos p
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND substr(\(dateExpr), 1, 10) >= ?
                  AND substr(\(dateExpr), 1, 10) <= ?
                """,
                binds: [day, end]
            )
        case .inMonth:
            guard let month = MediaSearchCriterion.normalizedMonth(day) else { return [] }
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT p.id
                FROM photos p
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND \(isoShapeSQL)
                  AND substr(\(dateExpr), 6, 2) = ?
                """,
                binds: [month]
            )
        case .anyYear:
            return matchAnyYearDateTakenUnsafe(
                criterion: criterion,
                day: day,
                dateExpr: dateExpr,
                isoShapeSQL: isoShapeSQL
            )
        default:
            return matchDateTakenUnsafe(
                criterion: MediaSearchCriterion(
                    field: .dateTaken,
                    op: .on,
                    value: day,
                    secondaryValue: criterion.secondaryValue
                ),
                day: day
            )
        }
    }

    private func matchMediaKindUnsafe(_ value: String) -> Set<String> {
        // Photos framework: image = 1, video = 2
        let mediaType: Int
        switch value.lowercased() {
        case "video", "videos":
            mediaType = 2
        default:
            mediaType = 1
        }
        return runPhotoIdQueryUnsafe(
            sql: """
            SELECT id
            FROM photos
            WHERE COALESCE(isDeleted, 0) = 0
              AND mediaType = ?
            """,
            binds: [],
            intBinds: [mediaType]
        )
    }

    private func matchCameraUnsafe(value: String, op: MediaSearchOperator) -> Set<String> {
        matchTextColumnUnsafe(
            sql: """
            SELECT p.id
            FROM photos p
            JOIN photo_exif e ON e.photoId = p.id
            WHERE COALESCE(p.isDeleted, 0) = 0
              AND (
                \(textPredicateSQL(column: "e.cameraMake", op: op))
                OR \(textPredicateSQL(column: "e.cameraModel", op: op))
                OR \(textPredicateSQL(column: "e.lensModel", op: op))
              )
            """,
            value: value,
            op: op,
            bindCount: 3
        )
    }

    private func matchFaceCountUnsafe(value: String, op: MediaSearchOperator) -> Set<String> {
        guard let count = Int(value), count >= 0 else { return [] }
        switch op {
        case .atLeast:
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT fi.photoId
                FROM face_instances fi
                JOIN photos p ON p.id = fi.photoId
                WHERE COALESCE(p.isDeleted, 0) = 0
                GROUP BY fi.photoId
                HAVING COUNT(*) >= ?
                """,
                binds: [],
                intBinds: [count]
            )
        case .is:
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT fi.photoId
                FROM face_instances fi
                JOIN photos p ON p.id = fi.photoId
                WHERE COALESCE(p.isDeleted, 0) = 0
                GROUP BY fi.photoId
                HAVING COUNT(*) = ?
                """,
                binds: [],
                intBinds: [count]
            )
        default:
            return matchFaceCountUnsafe(value: value, op: .is)
        }
    }

    private func matchLocationColumnUnsafe(
        column: String,
        value: String,
        op: MediaSearchOperator
    ) -> Set<String> {
        matchTextColumnUnsafe(
            sql: """
            SELECT p.id
            FROM photos p
            JOIN locations l ON l.locationId = p.locationId
            WHERE COALESCE(p.isDeleted, 0) = 0
              AND \(textPredicateSQL(column: column, op: op))
            """,
            value: value,
            op: op
        )
    }

    private func matchAnyYearDateTakenUnsafe(
        criterion: MediaSearchCriterion,
        day: String,
        dateExpr: String,
        isoShapeSQL: String
    ) -> Set<String> {
        if let holidayId = criterion.holidayId, holidayId > 0 {
            let holiday = fetchHolidayUnsafe(holidayId: holidayId)
            if criterion.usesYearAwareDayExpansion {
                let anchors: [String]
                if let holiday, holiday.isFixed, let monthDay = holiday.fixedMonthDay {
                    return matchAbsoluteDaysAnyYearUnsafe(
                        days: MediaSearchCriterion.absoluteISODays(
                            monthDay: monthDay,
                            daysBefore: criterion.daysBefore,
                            daysAfter: criterion.daysAfter,
                            includeWeekendsBefore: criterion.includeWeekendsBefore,
                            includeWeekendsAfter: criterion.includeWeekendsAfter
                        ),
                        dateExpr: dateExpr,
                        isoShapeSQL: isoShapeSQL
                    )
                }
                anchors = fetchHolidayAnchorDatesUnsafe(holidayId: holidayId)
                return matchAbsoluteDaysAnyYearUnsafe(
                    days: MediaSearchCriterion.absoluteISODays(
                        aroundAnchors: anchors,
                        daysBefore: criterion.daysBefore,
                        daysAfter: criterion.daysAfter,
                        includeWeekendsBefore: criterion.includeWeekendsBefore,
                        includeWeekendsAfter: criterion.includeWeekendsAfter
                    ),
                    dateExpr: dateExpr,
                    isoShapeSQL: isoShapeSQL
                )
            }
            if let holiday, holiday.isFixed, let monthDay = holiday.fixedMonthDay {
                return matchMonthDayAnyYearUnsafe(
                    monthDay: monthDay,
                    daysBefore: criterion.daysBefore,
                    daysAfter: criterion.daysAfter,
                    dateExpr: dateExpr,
                    isoShapeSQL: isoShapeSQL
                )
            }
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT DISTINCT p.id
                FROM photos p
                JOIN holiday_dates hd ON hd.holidayId = ?
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND \(isoShapeSQL)
                  AND julianday(substr(\(dateExpr), 1, 10))
                      >= julianday(substr(hd.anchorDate, 1, 10)) - ?
                  AND julianday(substr(\(dateExpr), 1, 10))
                      <= julianday(substr(hd.anchorDate, 1, 10)) + ?
                """,
                intBinds: [holidayId],
                doubleBinds: [
                    Double(max(0, criterion.daysBefore)),
                    Double(max(0, criterion.daysAfter)),
                ]
            )
        }

        if criterion.usesYearAwareDayExpansion {
            return matchAbsoluteDaysAnyYearUnsafe(
                days: MediaSearchCriterion.absoluteISODays(
                    monthDay: day,
                    daysBefore: criterion.daysBefore,
                    daysAfter: criterion.daysAfter,
                    includeWeekendsBefore: criterion.includeWeekendsBefore,
                    includeWeekendsAfter: criterion.includeWeekendsAfter
                ),
                dateExpr: dateExpr,
                isoShapeSQL: isoShapeSQL
            )
        }

        return matchMonthDayAnyYearUnsafe(
            monthDay: day,
            daysBefore: criterion.daysBefore,
            daysAfter: criterion.daysAfter,
            dateExpr: dateExpr,
            isoShapeSQL: isoShapeSQL
        )
    }

    private func fetchHolidayAnchorDatesUnsafe(holidayId: Int) -> [String] {
        let sql = """
        SELECT anchorDate
        FROM holiday_dates
        WHERE holidayId = ?
        ORDER BY year ASC;
        """
        var statement: OpaquePointer?
        var anchors: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(holidayId))
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0) {
                    let value = String(cString: cString)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        anchors.append(value)
                    }
                }
            }
        }
        sqlite3_finalize(statement)
        return anchors
    }

    private func matchAbsoluteDaysAnyYearUnsafe(
        days: [String],
        dateExpr: String,
        isoShapeSQL: String
    ) -> Set<String> {
        guard !days.isEmpty else { return [] }
        var combined = Set<String>()
        let chunkSize = 400
        var start = days.startIndex
        while start < days.endIndex {
            let end = days.index(start, offsetBy: chunkSize, limitedBy: days.endIndex) ?? days.endIndex
            let chunk = Array(days[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let ids = runPhotoIdQueryUnsafe(
                sql: """
                SELECT p.id
                FROM photos p
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND \(isoShapeSQL)
                  AND substr(\(dateExpr), 1, 10) IN (\(placeholders))
                """,
                binds: chunk
            )
            combined.formUnion(ids)
            start = end
        }
        return combined
    }

    private func matchMonthDayAnyYearUnsafe(
        monthDay: String,
        daysBefore: Int,
        daysAfter: Int,
        dateExpr: String,
        isoShapeSQL: String
    ) -> Set<String> {
        let monthDays = MediaSearchCriterion.monthDayWindow(
            monthDay: monthDay,
            daysBefore: daysBefore,
            daysAfter: daysAfter
        )
        guard !monthDays.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: monthDays.count).joined(separator: ", ")
        return runPhotoIdQueryUnsafe(
            sql: """
            SELECT p.id
            FROM photos p
            WHERE COALESCE(p.isDeleted, 0) = 0
              AND \(isoShapeSQL)
              AND substr(\(dateExpr), 6, 5) IN (\(placeholders))
            """,
            binds: monthDays
        )
    }

    private func fetchHolidayUnsafe(holidayId: Int) -> HolidayDefinition? {
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
                holiday = holidayDefinitionFromRow(statement)
            }
        }
        sqlite3_finalize(statement)
        return holiday
    }

    private func holidayDefinitionFromRow(_ statement: OpaquePointer?) -> HolidayDefinition? {
        guard let statement,
              let namePtr = sqlite3_column_text(statement, 1),
              let kindPtr = sqlite3_column_text(statement, 2),
              let kind = HolidayKind(rawValue: String(cString: kindPtr)) else {
            return nil
        }
        func optionalInt(_ index: Int32) -> Int? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int(statement, index))
        }
        func optionalText(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                  let cString = sqlite3_column_text(statement, index) else {
                return nil
            }
            return String(cString: cString)
        }
        return HolidayDefinition(
            holidayId: Int(sqlite3_column_int(statement, 0)),
            name: String(cString: namePtr),
            kind: kind,
            fixedMonth: optionalInt(3),
            fixedDay: optionalInt(4),
            ruleKind: optionalText(5),
            month: optionalInt(6),
            weekday: optionalInt(7),
            weekOrdinal: optionalInt(8),
            includeWeekendsBefore: sqlite3_column_int(statement, 9) != 0,
            isBuiltIn: sqlite3_column_int(statement, 10) != 0,
            isEnabled: sqlite3_column_int(statement, 11) != 0,
            sortIndex: Int(sqlite3_column_int(statement, 12))
        )
    }

    private func matchVisionTagUnsafe(
        criterion: MediaSearchCriterion,
        value: String
    ) -> Set<String> {
        let minConfidence = criterion.minConfidence
        let sql: String
        let resolvedOp: MediaSearchOperator
        switch criterion.op {
        case .contains:
            resolvedOp = .contains
            sql = """
            SELECT DISTINCT pot.photoId
            FROM photo_object_tags pot
            JOIN photos p ON p.id = pot.photoId
            WHERE COALESCE(p.isDeleted, 0) = 0
              AND LOWER(pot.objectKey) LIKE LOWER(?) ESCAPE '#'
              AND pot.confidence >= ?
            """
        case .is, .on, .after, .before, .between, .atLeast, .inMonth, .anyYear:
            resolvedOp = .is
            sql = """
            SELECT DISTINCT pot.photoId
            FROM photo_object_tags pot
            JOIN photos p ON p.id = pot.photoId
            WHERE COALESCE(p.isDeleted, 0) = 0
              AND LOWER(TRIM(pot.objectKey)) = LOWER(TRIM(?))
              AND pot.confidence >= ?
            """
        }
        return runPhotoIdQueryUnsafe(
            sql: sql,
            binds: [bindValue(value, op: resolvedOp)],
            doubleBinds: [minConfidence]
        )
    }

    private func matchPersonUnsafe(
        criterion: MediaSearchCriterion,
        trimmedName: String
    ) -> Set<String> {
        if let personId = criterion.personId, personId > 0 {
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT DISTINCT pp.photoId
                FROM photo_people pp
                JOIN photos p ON p.id = pp.photoId
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND pp.personId = ?
                """,
                intBinds: [personId]
            )
        }

        switch criterion.op {
        case .contains:
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT DISTINCT pp.photoId
                FROM photo_people pp
                JOIN people pe ON pe.personId = pp.personId
                JOIN photos p ON p.id = pp.photoId
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND LOWER(pe.displayName) LIKE LOWER(?) ESCAPE '#'
                """,
                binds: [likeContainsPattern(trimmedName)]
            )
        case .is, .on, .after, .before, .between, .atLeast, .inMonth, .anyYear:
            return runPhotoIdQueryUnsafe(
                sql: """
                SELECT DISTINCT pp.photoId
                FROM photo_people pp
                JOIN people pe ON pe.personId = pp.personId
                JOIN photos p ON p.id = pp.photoId
                WHERE COALESCE(p.isDeleted, 0) = 0
                  AND LOWER(TRIM(pe.displayName)) = LOWER(TRIM(?))
                """,
                binds: [trimmedName]
            )
        }
    }

    private func textPredicateSQL(column: String, op: MediaSearchOperator) -> String {
        switch op {
        case .contains:
            return "LOWER(\(column)) LIKE LOWER(?) ESCAPE '#'"
        case .is, .on, .after, .before, .between, .atLeast, .inMonth, .anyYear:
            return "LOWER(TRIM(COALESCE(\(column), ''))) = LOWER(TRIM(?))"
        }
    }

    private func matchTextColumnUnsafe(
        sql: String,
        value: String,
        op: MediaSearchOperator,
        bindCount: Int = 1
    ) -> Set<String> {
        let bound = bindValue(value, op: op)
        let binds = Array(repeating: bound, count: max(1, bindCount))
        return runPhotoIdQueryUnsafe(sql: sql, binds: binds)
    }

    private func bindValue(_ value: String, op: MediaSearchOperator) -> String {
        switch op {
        case .contains: return likeContainsPattern(value)
        case .is, .on, .after, .before, .between, .atLeast, .inMonth, .anyYear: return value
        }
    }

    private func likeContainsPattern(_ value: String) -> String {
        "%\(escapeLike(value))%"
    }

    private func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "#", with: "##")
            .replacingOccurrences(of: "%", with: "#%")
            .replacingOccurrences(of: "_", with: "#_")
    }

    private func fetchActivePhotoIdsUnsafe() -> Set<String> {
        runPhotoIdQueryUnsafe(
            sql: """
            SELECT id
            FROM photos
            WHERE COALESCE(isDeleted, 0) = 0
            """,
            binds: []
        )
    }

    private func runPhotoIdQueryUnsafe(
        sql: String,
        binds: [String] = [],
        intBinds: [Int] = [],
        doubleBinds: [Double] = []
    ) -> Set<String> {
        var statement: OpaquePointer?
        var ids = Set<String>()
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let db {
                print("Media photo search prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            return []
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        for value in binds {
            let ns = value as NSString
            sqlite3_bind_text(statement, index, ns.utf8String, -1, nil)
            index += 1
        }
        for value in intBinds {
            sqlite3_bind_int(statement, index, Int32(value))
            index += 1
        }
        for value in doubleBinds {
            sqlite3_bind_double(statement, index, value)
            index += 1
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                ids.insert(String(cString: cString))
            }
        }
        return ids
    }

    private func suggestionValuesUnsafe(
        field: MediaSearchField,
        query: String,
        limit: Int
    ) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = trimmed.isEmpty ? "%" : likeContainsPattern(trimmed)
        let sql: String

        switch field {
        case .albumName:
            sql = """
            SELECT DISTINCT a.title
            FROM albums a
            WHERE TRIM(COALESCE(a.title, '')) != ''
              AND LOWER(a.title) LIKE LOWER(?) ESCAPE '#'
            ORDER BY a.title COLLATE NOCASE ASC
            LIMIT ?;
            """
        case .visionTag:
            sql = """
            SELECT DISTINCT pot.objectKey
            FROM photo_object_tags pot
            WHERE TRIM(COALESCE(pot.objectKey, '')) != ''
              AND LOWER(pot.objectKey) LIKE LOWER(?) ESCAPE '#'
            ORDER BY pot.objectKey COLLATE NOCASE ASC
            LIMIT ?;
            """
        case .locationNickname:
            sql = """
            SELECT DISTINCT nickname FROM locations
            WHERE TRIM(COALESCE(nickname, '')) != ''
              AND LOWER(nickname) LIKE LOWER(?) ESCAPE '#'
            ORDER BY nickname COLLATE NOCASE ASC LIMIT ?;
            """
        case .locationPlaceName:
            sql = """
            SELECT DISTINCT placeName FROM locations
            WHERE TRIM(COALESCE(placeName, '')) != ''
              AND LOWER(placeName) LIKE LOWER(?) ESCAPE '#'
            ORDER BY placeName COLLATE NOCASE ASC LIMIT ?;
            """
        case .locationCity:
            sql = """
            SELECT DISTINCT city FROM locations
            WHERE TRIM(COALESCE(city, '')) != ''
              AND LOWER(city) LIKE LOWER(?) ESCAPE '#'
            ORDER BY city COLLATE NOCASE ASC LIMIT ?;
            """
        case .locationState:
            sql = """
            SELECT DISTINCT state FROM locations
            WHERE TRIM(COALESCE(state, '')) != ''
              AND LOWER(state) LIKE LOWER(?) ESCAPE '#'
            ORDER BY state COLLATE NOCASE ASC LIMIT ?;
            """
        case .eventTag:
            sql = """
            SELECT DISTINCT tagValue FROM event_tags
            WHERE COALESCE(isRejected, 0) = 0
              AND TRIM(COALESCE(tagValue, '')) != ''
              AND LOWER(tagValue) LIKE LOWER(?) ESCAPE '#'
            ORDER BY tagValue COLLATE NOCASE ASC LIMIT ?;
            """
        case .eventTagCategory:
            sql = """
            SELECT DISTINCT tagCategory FROM event_tags
            WHERE COALESCE(isRejected, 0) = 0
              AND TRIM(COALESCE(tagCategory, '')) != ''
              AND LOWER(tagCategory) LIKE LOWER(?) ESCAPE '#'
            ORDER BY tagCategory COLLATE NOCASE ASC LIMIT ?;
            """
        case .camera:
            sql = """
            SELECT DISTINCT label FROM (
                SELECT cameraMake AS label FROM photo_exif
                WHERE TRIM(COALESCE(cameraMake, '')) != ''
                UNION
                SELECT cameraModel AS label FROM photo_exif
                WHERE TRIM(COALESCE(cameraModel, '')) != ''
            )
            WHERE LOWER(label) LIKE LOWER(?) ESCAPE '#'
            ORDER BY label COLLATE NOCASE ASC
            LIMIT ?;
            """
        case .filename, .ocrText, .person, .eventName, .dateTaken,
             .mediaKind, .favorite, .onFrame, .hasFaces, .faceCount:
            return []
        }

        var statement: OpaquePointer?
        var values: [String] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        let patternNS = pattern as NSString
        sqlite3_bind_text(statement, 1, patternNS.utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(limit))

        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                values.append(String(cString: cString))
            }
        }
        return values
    }
}
