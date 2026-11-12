import Foundation
import SQLite3

struct PhotoCropFocusRecord {
    let list: PhotoCropFocus?
    let frame: PhotoCropFocus?
    let width: Int
    let height: Int
    let orientation: String
}

/// SQLite access for the `photos` table and related photo row fields.
final class PhotoRepository {

    static let shared = PhotoRepository()
    static let faceMetricsAlgorithmVersionKey = "faceMetricsAlgorithmVersion"
    static let cropAlgorithmVersionKey = "cropAlgorithmVersion"

    private let database: DatabaseManager
    private let metadata: AppMetadataStore
    private var locations: LocationRepository?

    init(database: DatabaseManager = .shared, metadata: AppMetadataStore? = nil) {
        self.database = database
        self.metadata = metadata ?? AppMetadataStore(database: database)
    }

    func bindLocations(_ locations: LocationRepository) {
        self.locations = locations
    }

    private var db: OpaquePointer? {
        database.connection
    }

    private var queue: DispatchQueue {
        database.queue
    }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if database.isOnQueue { return try work() }
        return try queue.sync(execute: work)
    }

    func upsertPhoto(
        id: String,
        creationDate: String,
        modificationDate: String,
        mediaType: Int,
        mediaSubtype: Int,
        width: Int,
        height: Int,
        isFavorite: Bool,
        isHidden: Bool,
        latitude: Double?,
        longitude: Double?,
        isScreenshot: Bool,
        aspectRatio: Double,
        orientation: String,
        qualityScore: Int,
        duration: Double?
    ) {
        sync {
            upsertPhotoUnsafe(
                id: id,
                creationDate: creationDate,
                modificationDate: modificationDate,
                mediaType: mediaType,
                mediaSubtype: mediaSubtype,
                width: width,
                height: height,
                isFavorite: isFavorite,
                isHidden: isHidden,
                latitude: latitude,
                longitude: longitude,
                isScreenshot: isScreenshot,
                aspectRatio: aspectRatio,
                orientation: orientation,
                qualityScore: qualityScore,
                duration: duration
            )
        }
    }

    func fetchActivePhotoIdSet() -> Set<String> {
        Set(fetchAllActivePhotoIds())
    }

    func markPhotosDeletedIfMissing(currentIds: Set<String>) {
        let existingIds = fetchAllActivePhotoIds()
        let now = ISO8601DateFormatter().string(from: Date())

        for id in existingIds where !currentIds.contains(id) {
            markPhotoDeleted(photoId: id, deletedAt: now)
        }

        print("Soft delete check complete")
    }

    func fetchUnanalyzedPhotoIdsMatchingMonthDayRange(
        start: String,
        end: String
    ) -> PhotoVisionTagMonthDaySelection {
        sync {
            fetchUnanalyzedPhotoIdsMatchingMonthDayRangeUnsafe(start: start, end: end)
        }
    }

    func fetchUnanalyzedPhotoIdsMatchingDateSearch(
        dateSearch: DateSearchDefinition,
        floatingHoliday: FloatingHolidayDefinition?,
        catalogHoliday: HolidayDefinition? = nil
    ) -> PhotoVisionTagMonthDaySelection {
        sync {
            fetchUnanalyzedPhotoIdsMatchingDateSearchUnsafe(
                dateSearch: dateSearch,
                floatingHoliday: floatingHoliday,
                catalogHoliday: catalogHoliday
            )
        }
    }

    func isVisionAnalyzedUnsafe(photoId: String) -> Bool {
        let sql = """
        SELECT COALESCE(visionAnalyzed, 0)
        FROM photos
        WHERE id = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var analyzed = false

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let photoIdNS = photoId as NSString
            sqlite3_bind_text(statement, 1, photoIdNS.utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                analyzed = sqlite3_column_int(statement, 0) != 0
            }
        } else if let db {
            print("isVisionAnalyzed prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
        return analyzed
    }

    func markPhotoVisionAnalyzedUnsafe(photoId: String) {
        let sql = """
        UPDATE photos
        SET visionAnalyzed = 1
        WHERE id = ?;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let photoIdNS = photoId as NSString
            sqlite3_bind_text(statement, 1, photoIdNS.utf8String, -1, nil)
            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to mark photo vision analyzed: \(String(cString: sqlite3_errmsg(db)))")
            }
        } else if let db {
            print("markPhotoVisionAnalyzed prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(statement)
    }

    /// Photos in an MM-DD range for **every year**, newest first.
    ///
    /// Matching uses `substr(effectiveDate, 6, 5)` so `08-12` hits 2005…2024 alike.
    /// Newest-first avoids starving recent years when a wide range has thousands of older shots.
    func fetchUnanalyzedPhotoIdsMatchingMonthDayRangeUnsafe(
        start: String,
        end: String
    ) -> PhotoVisionTagMonthDaySelection {
        let effectiveDateSQL = """
        COALESCE(NULLIF(TRIM(captureDateOverride), ''), creationDate)
        """
        let monthDaySQL = "substr(\(effectiveDateSQL), 6, 5)"
        let yearSQL = "CAST(substr(\(effectiveDateSQL), 1, 4) AS INTEGER)"
        let rangePredicate: String
        if start <= end {
            rangePredicate = "\(monthDaySQL) >= ? AND \(monthDaySQL) <= ?"
        } else {
            rangePredicate = "\(monthDaySQL) >= ? OR \(monthDaySQL) <= ?"
        }

        // Require ISO-ish `YYYY-MM-DD…` so short/malformed dates never match by accident.
        let baseWhere = """
        isDeleted = 0
          AND \(effectiveDateSQL) IS NOT NULL
          AND length(\(effectiveDateSQL)) >= 10
          AND substr(\(effectiveDateSQL), 5, 1) = '-'
          AND substr(\(effectiveDateSQL), 8, 1) = '-'
          AND (\(rangePredicate))
        """

        let countSQL = """
        SELECT
            COUNT(*) AS totalInRange,
            SUM(CASE WHEN COALESCE(visionAnalyzed, 0) != 0 THEN 1 ELSE 0 END) AS alreadyAnalyzed
        FROM photos
        WHERE \(baseWhere);
        """

        let yearSQLQuery = """
        SELECT \(yearSQL) AS y, COUNT(*) AS n
        FROM photos
        WHERE \(baseWhere)
        GROUP BY y
        ORDER BY y ASC;
        """

        let idsSQL = """
        SELECT id
        FROM photos
        WHERE \(baseWhere)
          AND COALESCE(visionAnalyzed, 0) = 0
        ORDER BY \(effectiveDateSQL) DESC, id DESC;
        """

        let startNS = start as NSString
        let endNS = end as NSString

        var totalInRange = 0
        var alreadyAnalyzed = 0
        if let row = queryTwoInts(sql: countSQL, bindStart: startNS, bindEnd: endNS) {
            totalInRange = row.0
            alreadyAnalyzed = row.1
        }

        var photoCountByYear: [Int: Int] = [:]
        var yearStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, yearSQLQuery, -1, &yearStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(yearStatement, 1, startNS.utf8String, -1, nil)
            sqlite3_bind_text(yearStatement, 2, endNS.utf8String, -1, nil)
            while sqlite3_step(yearStatement) == SQLITE_ROW {
                let year = Int(sqlite3_column_int(yearStatement, 0))
                let count = Int(sqlite3_column_int(yearStatement, 1))
                if year > 0, count > 0 {
                    photoCountByYear[year] = count
                }
            }
        } else if let db {
            print("Vision month-day year breakdown prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(yearStatement)

        var photoIds: [String] = []
        var idsStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, idsSQL, -1, &idsStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(idsStatement, 1, startNS.utf8String, -1, nil)
            sqlite3_bind_text(idsStatement, 2, endNS.utf8String, -1, nil)
            while sqlite3_step(idsStatement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(idsStatement, 0) {
                    photoIds.append(String(cString: cString))
                }
            }
        } else if let db {
            print("Vision month-day id fetch prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(idsStatement)

        return PhotoVisionTagMonthDaySelection(
            photoIds: photoIds,
            totalInRange: totalInRange,
            alreadyAnalyzed: alreadyAnalyzed,
            photoCountByYear: photoCountByYear
        )
    }

    func fetchUnanalyzedPhotoIdsMatchingDateSearchUnsafe(
        dateSearch: DateSearchDefinition,
        floatingHoliday: FloatingHolidayDefinition?,
        catalogHoliday: HolidayDefinition? = nil
    ) -> PhotoVisionTagMonthDaySelection {
        switch dateSearch.dateSearchType {
        case .sameDateRangeEveryYear:
            guard let start = dateSearch.rangeStartMonthDay,
                  let end = dateSearch.rangeEndMonthDay else {
                return emptyVisionSelection()
            }
            return fetchUnanalyzedPhotoIdsMatchingMonthDayRangeUnsafe(start: start, end: end)
        case .allDates:
            // Too broad for holiday Vision prep — skip.
            return emptyVisionSelection()
        case .absoluteRange, .sameDateEveryYear, .movingHoliday:
            break
        }

        let effectiveDateSQL = """
        COALESCE(NULLIF(TRIM(captureDateOverride), ''), creationDate)
        """
        let daySQL = "substr(\(effectiveDateSQL), 1, 10)"
        let yearSQL = "CAST(substr(\(effectiveDateSQL), 1, 4) AS INTEGER)"

        let yearsSQL = """
        SELECT DISTINCT \(yearSQL) AS y
        FROM photos
        WHERE isDeleted = 0
          AND \(effectiveDateSQL) IS NOT NULL
          AND length(\(effectiveDateSQL)) >= 10
          AND substr(\(effectiveDateSQL), 5, 1) = '-'
          AND substr(\(effectiveDateSQL), 8, 1) = '-'
        ORDER BY y ASC;
        """

        var years: [Int] = []
        var yearStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, yearsSQL, -1, &yearStatement, nil) == SQLITE_OK {
            while sqlite3_step(yearStatement) == SQLITE_ROW {
                let year = Int(sqlite3_column_int(yearStatement, 0))
                if year > 0 {
                    years.append(year)
                }
            }
        }
        sqlite3_finalize(yearStatement)

        let allowedDays: Set<String>
        switch dateSearch.dateSearchType {
        case .absoluteRange:
            guard let start = dateSearch.absoluteStartDate,
                  let end = dateSearch.absoluteEndDate else {
                return emptyVisionSelection()
            }
            // Expand absolute range into day list via SQL filter instead of IN list.
            return fetchUnanalyzedPhotoIdsMatchingAbsoluteRangeUnsafe(start: start, end: end)
        case .sameDateEveryYear, .movingHoliday:
            allowedDays = PictureSearchDateMatcher.allowedDayISOStrings(
                years: years,
                dateSearch: dateSearch,
                floatingHoliday: floatingHoliday,
                catalogHoliday: catalogHoliday
            )
        default:
            return emptyVisionSelection()
        }

        guard !allowedDays.isEmpty else { return emptyVisionSelection() }

        let sortedDays = allowedDays.sorted()
        let dayNSStrings = sortedDays.map { $0 as NSString }
        let placeholders = Array(repeating: "?", count: dayNSStrings.count).joined(separator: ", ")
        let baseWhere = """
        isDeleted = 0
          AND \(effectiveDateSQL) IS NOT NULL
          AND length(\(effectiveDateSQL)) >= 10
          AND \(daySQL) IN (\(placeholders))
        """

        func bindDays(_ statement: OpaquePointer?) {
            for (index, dayNS) in dayNSStrings.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), dayNS.utf8String, -1, nil)
            }
        }

        let countSQL = """
        SELECT
            COUNT(*) AS totalInRange,
            SUM(CASE WHEN COALESCE(visionAnalyzed, 0) != 0 THEN 1 ELSE 0 END) AS alreadyAnalyzed
        FROM photos
        WHERE \(baseWhere);
        """

        var totalInRange = 0
        var alreadyAnalyzed = 0
        var countStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, countSQL, -1, &countStatement, nil) == SQLITE_OK {
            bindDays(countStatement)
            if sqlite3_step(countStatement) == SQLITE_ROW {
                totalInRange = Int(sqlite3_column_int(countStatement, 0))
                alreadyAnalyzed = Int(sqlite3_column_int(countStatement, 1))
            }
        }
        sqlite3_finalize(countStatement)

        let yearBreakdownSQL = """
        SELECT \(yearSQL) AS y, COUNT(*) AS n
        FROM photos
        WHERE \(baseWhere)
        GROUP BY y
        ORDER BY y ASC;
        """
        var photoCountByYear: [Int: Int] = [:]
        var yearBreakStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, yearBreakdownSQL, -1, &yearBreakStatement, nil) == SQLITE_OK {
            bindDays(yearBreakStatement)
            while sqlite3_step(yearBreakStatement) == SQLITE_ROW {
                let year = Int(sqlite3_column_int(yearBreakStatement, 0))
                let count = Int(sqlite3_column_int(yearBreakStatement, 1))
                if year > 0, count > 0 {
                    photoCountByYear[year] = count
                }
            }
        }
        sqlite3_finalize(yearBreakStatement)

        let idsSQL = """
        SELECT id
        FROM photos
        WHERE \(baseWhere)
          AND COALESCE(visionAnalyzed, 0) = 0
        ORDER BY \(effectiveDateSQL) DESC, id DESC;
        """
        var photoIds: [String] = []
        var idsStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, idsSQL, -1, &idsStatement, nil) == SQLITE_OK {
            bindDays(idsStatement)
            while sqlite3_step(idsStatement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(idsStatement, 0) {
                    photoIds.append(String(cString: cString))
                }
            }
        }
        sqlite3_finalize(idsStatement)

        return PhotoVisionTagMonthDaySelection(
            photoIds: photoIds,
            totalInRange: totalInRange,
            alreadyAnalyzed: alreadyAnalyzed,
            photoCountByYear: photoCountByYear
        )
    }

    private func fetchUnanalyzedPhotoIdsMatchingAbsoluteRangeUnsafe(
        start: String,
        end: String
    ) -> PhotoVisionTagMonthDaySelection {
        let effectiveDateSQL = """
        COALESCE(NULLIF(TRIM(captureDateOverride), ''), creationDate)
        """
        let daySQL = "substr(\(effectiveDateSQL), 1, 10)"
        let yearSQL = "CAST(substr(\(effectiveDateSQL), 1, 4) AS INTEGER)"
        let baseWhere = """
        isDeleted = 0
          AND \(effectiveDateSQL) IS NOT NULL
          AND length(\(effectiveDateSQL)) >= 10
          AND \(daySQL) >= ?
          AND \(daySQL) <= ?
        """

        let countSQL = """
        SELECT
            COUNT(*) AS totalInRange,
            SUM(CASE WHEN COALESCE(visionAnalyzed, 0) != 0 THEN 1 ELSE 0 END) AS alreadyAnalyzed
        FROM photos
        WHERE \(baseWhere);
        """
        let startNS = start as NSString
        let endNS = end as NSString
        var totalInRange = 0
        var alreadyAnalyzed = 0
        if let row = queryTwoInts(sql: countSQL, bindStart: startNS, bindEnd: endNS) {
            totalInRange = row.0
            alreadyAnalyzed = row.1
        }

        var photoCountByYear: [Int: Int] = [:]
        let yearSQLQuery = """
        SELECT \(yearSQL) AS y, COUNT(*) AS n
        FROM photos
        WHERE \(baseWhere)
        GROUP BY y
        ORDER BY y ASC;
        """
        var yearStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, yearSQLQuery, -1, &yearStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(yearStatement, 1, startNS.utf8String, -1, nil)
            sqlite3_bind_text(yearStatement, 2, endNS.utf8String, -1, nil)
            while sqlite3_step(yearStatement) == SQLITE_ROW {
                let year = Int(sqlite3_column_int(yearStatement, 0))
                let count = Int(sqlite3_column_int(yearStatement, 1))
                if year > 0, count > 0 {
                    photoCountByYear[year] = count
                }
            }
        }
        sqlite3_finalize(yearStatement)

        let idsSQL = """
        SELECT id
        FROM photos
        WHERE \(baseWhere)
          AND COALESCE(visionAnalyzed, 0) = 0
        ORDER BY \(effectiveDateSQL) DESC, id DESC;
        """
        var photoIds: [String] = []
        var idsStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, idsSQL, -1, &idsStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(idsStatement, 1, startNS.utf8String, -1, nil)
            sqlite3_bind_text(idsStatement, 2, endNS.utf8String, -1, nil)
            while sqlite3_step(idsStatement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(idsStatement, 0) {
                    photoIds.append(String(cString: cString))
                }
            }
        }
        sqlite3_finalize(idsStatement)

        return PhotoVisionTagMonthDaySelection(
            photoIds: photoIds,
            totalInRange: totalInRange,
            alreadyAnalyzed: alreadyAnalyzed,
            photoCountByYear: photoCountByYear
        )
    }

    private func emptyVisionSelection() -> PhotoVisionTagMonthDaySelection {
        PhotoVisionTagMonthDaySelection(
            photoIds: [],
            totalInRange: 0,
            alreadyAnalyzed: 0,
            photoCountByYear: [:]
        )
    }

    private func queryTwoInts(
        sql: String,
        bindStart: NSString,
        bindEnd: NSString
    ) -> (Int, Int)? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let db {
                print("Vision month-day count prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            return nil
        }
        sqlite3_bind_text(statement, 1, bindStart.utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, bindEnd.utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int(statement, 0)), Int(sqlite3_column_int(statement, 1)))
    }

    func getRecentPhotos(limit: Int = 100) -> [IndexedPhoto] {
        let sql = """
        SELECT id, creationDate, isFavorite, width, height, mediaSubtype,
               latitude, longitude, isScreenshot, aspectRatio, orientation, qualityScore
        FROM photos
        WHERE isDeleted = 0
        ORDER BY creationDate DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        var photos: [IndexedPhoto] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(limit))

            while sqlite3_step(statement) == SQLITE_ROW {
                photos.append(readIndexedPhotoRow(from: statement))
            }
        }

        sqlite3_finalize(statement)
        return photos
    }

    /// Loads indexed photos for a picture browser, preserving `photoIds` order.
    /// Frame / hidden flags come from any linked `photo_events` row.
    func fetchPhotosForBrowser(photoIds: [String]) -> [(photo: IndexedPhoto, mediaType: Int)] {
        sync { fetchPhotosForBrowserUnsafe(photoIds: photoIds) }
    }

    func fetchPhotosForBrowserUnsafe(photoIds: [String]) -> [(photo: IndexedPhoto, mediaType: Int)] {
        guard !photoIds.isEmpty else { return [] }

        let uniqueIds = Array(Set(photoIds))
        let placeholders = Array(repeating: "?", count: uniqueIds.count).joined(separator: ", ")
        let sql = """
        SELECT p.id, p.creationDate, p.isFavorite, p.width, p.height, p.mediaSubtype,
               p.latitude, p.longitude, p.isScreenshot, p.aspectRatio, p.orientation, p.qualityScore,
               p.faceEyesOpenScore, p.faceSmileScore,
               COALESCE((
                   SELECT pe.includeInSlideshow
                   FROM photo_events pe
                   WHERE pe.photoId = p.id
                   ORDER BY pe.includeInSlideshow DESC, pe.eventId ASC
                   LIMIT 1
               ), 0) AS showOnFrame,
               COALESCE((
                   SELECT pe.manuallyExcluded
                   FROM photo_events pe
                   WHERE pe.photoId = p.id
                   ORDER BY pe.manuallyExcluded DESC, pe.eventId ASC
                   LIMIT 1
               ), 0) AS isHiddenInEvent,
               COALESCE(p.mediaType, 0) AS mediaType
        FROM photos p
        WHERE p.isDeleted = 0
          AND p.id IN (\(placeholders));
        """

        var statement: OpaquePointer?
        var byId: [String: (photo: IndexedPhoto, mediaType: Int)] = [:]

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (index, photoId) in uniqueIds.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), (photoId as NSString).utf8String, -1, nil)
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let photo = readBrowserPhotoRow(from: statement)
                let mediaType = Int(sqlite3_column_int(statement, 16))
                byId[photo.id] = (photo, mediaType)
            }
        } else if let db {
            print("fetchPhotosForBrowser failed: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)

        return photoIds.compactMap { byId[$0] }
    }

    /// Every indexed photo for the All Photos grid, including the date it was imported.
    func fetchAllPhotosForBrowser() -> [(photo: IndexedPhoto, mediaType: Int, indexedAt: String)] {
        sync { fetchAllPhotosForBrowserUnsafe(year: nil) }
    }

    /// Photos whose capture date falls in `year` (All Media first paint / year chip).
    func fetchPhotosForBrowserYear(_ year: Int) -> [(photo: IndexedPhoto, mediaType: Int, indexedAt: String)] {
        sync { fetchAllPhotosForBrowserUnsafe(year: year) }
    }

    /// Distinct capture years newest-first for the All Media year bar.
    func fetchDistinctPhotoYearsForBrowser() -> [Int] {
        sync { fetchDistinctPhotoYearsForBrowserUnsafe() }
    }

    func countActivePhotosForBrowser() -> Int {
        sync { countActivePhotosForBrowserUnsafe() }
    }

    func fetchAllPhotosForBrowserUnsafe(
        year: Int?
    ) -> [(photo: IndexedPhoto, mediaType: Int, indexedAt: String)] {
        // One pass over photo_events instead of two correlated subqueries per photo.
        // When scoped to a year, also limit the flags aggregate to that year's photos.
        let yearFilter: String
        let flagsYearFilter: String
        if let year, year >= 1000, year <= 9999 {
            yearFilter = """
              AND p.creationDate >= '\(year)-01-01'
              AND p.creationDate < '\(year + 1)-01-01'
            """
            flagsYearFilter = """
              AND pe.photoId IN (
                SELECT id FROM photos
                WHERE isDeleted = 0
                  AND creationDate >= '\(year)-01-01'
                  AND creationDate < '\(year + 1)-01-01'
              )
            """
        } else {
            yearFilter = ""
            flagsYearFilter = ""
        }

        let sql = """
        SELECT p.id, p.creationDate, p.isFavorite, p.width, p.height, p.mediaSubtype,
               p.latitude, p.longitude, p.isScreenshot, p.aspectRatio, p.orientation, p.qualityScore,
               p.faceEyesOpenScore, p.faceSmileScore,
               COALESCE(flags.showOnFrame, 0) AS showOnFrame,
               COALESCE(flags.isHiddenInEvent, 0) AS isHiddenInEvent,
               COALESCE(p.mediaType, 0) AS mediaType,
               COALESCE(p.indexedAt, '') AS indexedAt
        FROM photos p
        LEFT JOIN (
            SELECT
                pe.photoId AS photoId,
                MAX(COALESCE(pe.includeInSlideshow, 0)) AS showOnFrame,
                MAX(COALESCE(pe.manuallyExcluded, 0)) AS isHiddenInEvent
            FROM photo_events pe
            WHERE 1 = 1
              \(flagsYearFilter)
            GROUP BY pe.photoId
        ) AS flags ON flags.photoId = p.id
        WHERE p.isDeleted = 0
          \(yearFilter)
        ORDER BY p.creationDate DESC, p.id DESC;
        """

        var statement: OpaquePointer?
        var rows: [(photo: IndexedPhoto, mediaType: Int, indexedAt: String)] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let photo = readBrowserPhotoRow(from: statement)
                let mediaType = Int(sqlite3_column_int(statement, 16))
                let indexedAt = sqlite3_column_text(statement, 17).map { String(cString: $0) } ?? ""
                rows.append((photo, mediaType, indexedAt))
            }
        } else if let db {
            print("fetchAllPhotosForBrowser failed: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
        return rows
    }

    private func fetchDistinctPhotoYearsForBrowserUnsafe() -> [Int] {
        let sql = """
        SELECT DISTINCT SUBSTR(creationDate, 1, 4) AS year
        FROM photos
        WHERE isDeleted = 0
          AND LENGTH(creationDate) >= 4
        ORDER BY year DESC;
        """
        var statement: OpaquePointer?
        var years: [Int] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0),
                   let year = Int(String(cString: cString)),
                   year >= 1000 {
                    years.append(year)
                }
            }
        }
        sqlite3_finalize(statement)
        return years
    }

    private func countActivePhotosForBrowserUnsafe() -> Int {
        let sql = "SELECT COUNT(*) FROM photos WHERE isDeleted = 0;"
        var statement: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = Int(sqlite3_column_int(statement, 0))
        }
        sqlite3_finalize(statement)
        return count
    }

    func setPhotosFavorite(photoIds: [String], isFavorite: Bool) {
        sync { setPhotosFavoriteUnsafe(photoIds: photoIds, isFavorite: isFavorite) }
    }

    func setPhotosFavoriteUnsafe(photoIds: [String], isFavorite: Bool) {
        guard !photoIds.isEmpty else { return }

        let sql = """
        UPDATE photos
        SET isFavorite = ?
        WHERE id = ?;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for photoId in photoIds {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
                sqlite3_bind_text(statement, 2, (photoId as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }
        }
        sqlite3_finalize(statement)
    }

    private func readBrowserPhotoRow(from statement: OpaquePointer?) -> IndexedPhoto {
        let base = readIndexedPhotoRow(from: statement)
        let showOnFrame = sqlite3_column_int(statement, 14) == 1
        let isHiddenInEvent = sqlite3_column_int(statement, 15) == 1
        return IndexedPhoto(
            id: base.id,
            creationDate: base.creationDate,
            isFavorite: base.isFavorite,
            width: base.width,
            height: base.height,
            mediaSubtype: base.mediaSubtype,
            latitude: base.latitude,
            longitude: base.longitude,
            isScreenshot: base.isScreenshot,
            aspectRatio: base.aspectRatio,
            orientation: base.orientation,
            qualityScore: base.qualityScore,
            faceEyesOpenScore: base.faceEyesOpenScore,
            faceSmileScore: base.faceSmileScore,
            showOnFrame: showOnFrame,
            isHiddenInEvent: isHiddenInEvent,
            isSimilarGroupPick: false,
            isVideo: sqlite3_column_int(statement, 16) == 2
        )
    }

    func updateFaceMetrics(
        photoId: String,
        eyesOpenScore: Double,
        smileScore: Double
    ) {
        sync {
            let sql = """
            UPDATE photos
            SET faceEyesOpenScore = ?, faceSmileScore = ?
            WHERE id = ?;
            """

            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_double(statement, 1, eyesOpenScore)
                sqlite3_bind_double(statement, 2, smileScore)
                sqlite3_bind_text(statement, 3, (photoId as NSString).utf8String, -1, nil)

                if sqlite3_step(statement) != SQLITE_DONE {
                    print("Failed to update face metrics: \(String(cString: sqlite3_errmsg(db)))")
                }
            }

            sqlite3_finalize(statement)
        }
    }

    func clearFaceMetrics(forPhotoIds photoIds: [String]) {
        guard !photoIds.isEmpty else { return }

        sync {
            let sql = """
            UPDATE photos
            SET faceEyesOpenScore = NULL, faceSmileScore = NULL
            WHERE id = ?;
            """

            var statement: OpaquePointer?

            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                print("Failed to prepare clear face metrics: \(String(cString: sqlite3_errmsg(db)))")
                return
            }

            defer { sqlite3_finalize(statement) }

            for photoId in photoIds {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)

                if sqlite3_step(statement) != SQLITE_DONE {
                    print("Failed to clear face metrics: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
        }
    }

    func getPhotoCropData(photoId: String) -> PhotoCropFocusRecord? {
        sync {
            let sql = """
            SELECT listCropFocusX, listCropFocusY, frameCropFocusX, frameCropFocusY,
                   width, height, orientation
            FROM photos
            WHERE id = ? AND isDeleted = 0;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                return nil
            }

            defer { sqlite3_finalize(statement) }

            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

            let list = readCropFocus(statement, xColumn: 0, yColumn: 1)
            let frame = readCropFocus(statement, xColumn: 2, yColumn: 3)
            let width = Int(sqlite3_column_int(statement, 4))
            let height = Int(sqlite3_column_int(statement, 5))
            let orientation = optionalText(statement, column: 6) ?? "landscape"

            return PhotoCropFocusRecord(
                list: list,
                frame: frame,
                width: width,
                height: height,
                orientation: orientation
            )
        }
    }

    func updateCropFocuses(
        photoId: String,
        list: PhotoCropFocus?,
        frame: PhotoCropFocus?
    ) {
        sync {
            let sql = """
            UPDATE photos
            SET listCropFocusX = ?, listCropFocusY = ?,
                frameCropFocusX = ?, frameCropFocusY = ?
            WHERE id = ?;
            """

            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                bindOptionalDouble(statement, index: 1, value: list?.x)
                bindOptionalDouble(statement, index: 2, value: list?.y)
                bindOptionalDouble(statement, index: 3, value: frame?.x)
                bindOptionalDouble(statement, index: 4, value: frame?.y)
                sqlite3_bind_text(statement, 5, (photoId as NSString).utf8String, -1, nil)

                if sqlite3_step(statement) != SQLITE_DONE {
                    print("Failed to update crop focus: \(String(cString: sqlite3_errmsg(db)))")
                }
            }

            sqlite3_finalize(statement)
        }
    }

    func clearAllCropFocuses() {
        sync {
            sqlite3_exec(
                db,
                """
                UPDATE photos
                SET listCropFocusX = NULL, listCropFocusY = NULL,
                    frameCropFocusX = NULL, frameCropFocusY = NULL;
                """,
                nil,
                nil,
                nil
            )
        }
    }

    func clearCropFocus(photoId: String) {
        updateCropFocuses(photoId: photoId, list: nil, frame: nil)
    }

    func faceMetricsAlgorithmVersion() -> Int {
        Int(metadata.get(key: Self.faceMetricsAlgorithmVersionKey) ?? "") ?? 0
    }

    func setFaceMetricsAlgorithmVersion(_ version: Int) {
        metadata.set(key: Self.faceMetricsAlgorithmVersionKey, value: String(version))
    }

    func cropAlgorithmVersion() -> Int {
        Int(metadata.get(key: Self.cropAlgorithmVersionKey) ?? "") ?? 0
    }

    func setCropAlgorithmVersion(_ version: Int) {
        metadata.set(key: Self.cropAlgorithmVersionKey, value: String(version))
    }

    func countPhotosMissingLocation() -> Int {
        sync {
            countRowsUnsafe(
                """
                photos
                WHERE isDeleted = 0
                  AND isScreenshot = 0
                  AND COALESCE(userLatitude, latitude) IS NULL
                """
            )
        }
    }

    func countActivePhotos() -> Int {
        sync {
            countRowsUnsafe("photos WHERE isDeleted = 0")
        }
    }

    func getLikelyUploadBatches(
        gapSeconds: TimeInterval,
        minPhotos: Int,
        locationMatchMiles: Double
    ) -> [PhotoUploadBatch] {
        sync {
            getLikelyUploadBatchesUnsafe(
                gapSeconds: gapSeconds,
                minPhotos: minPhotos,
                locationMatchMiles: locationMatchMiles
            )
        }
    }

    func applyArchiveBatchMetadata(
        photoIds: [String],
        captureDate: Date,
        latitude: Double,
        longitude: Double
    ) {
        sync {
            applyArchiveBatchMetadataUnsafe(
                photoIds: photoIds,
                captureDate: captureDate,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    func readIndexedPhotoRow(from statement: OpaquePointer?) -> IndexedPhoto {
        let id = String(cString: sqlite3_column_text(statement, 0))
        let creationDate = String(cString: sqlite3_column_text(statement, 1))
        let isFavorite = sqlite3_column_int(statement, 2) == 1
        let width = Int(sqlite3_column_int(statement, 3))
        let height = Int(sqlite3_column_int(statement, 4))
        let mediaSubtype = Int(sqlite3_column_int(statement, 5))

        let latitude: Double? =
            sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, 6)

        let longitude: Double? =
            sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, 7)

        let isScreenshot = sqlite3_column_int(statement, 8) == 1
        let aspectRatio = sqlite3_column_double(statement, 9)
        let orientation = String(cString: sqlite3_column_text(statement, 10))
        let qualityScore = Int(sqlite3_column_int(statement, 11))
        let faceEyesOpenScore = optionalDoubleColumn(statement, index: 12)
        let faceSmileScore = optionalDoubleColumn(statement, index: 13)

        return IndexedPhoto(
            id: id,
            creationDate: creationDate,
            isFavorite: isFavorite,
            width: width,
            height: height,
            mediaSubtype: mediaSubtype,
            latitude: latitude,
            longitude: longitude,
            isScreenshot: isScreenshot,
            aspectRatio: aspectRatio,
            orientation: orientation,
            qualityScore: qualityScore,
            faceEyesOpenScore: faceEyesOpenScore,
            faceSmileScore: faceSmileScore
        )
    }

    // MARK: - Private

    private func countRowsUnsafe(_ tableOrQuery: String) -> Int {
        guard let db else { return 0 }

        let sql = "SELECT COUNT(*) FROM \(tableOrQuery);"
        var statement: OpaquePointer?
        var count = 0

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_ROW {
                count = Int(sqlite3_column_int(statement, 0))
            }
        } else {
            print("Count failed for \(tableOrQuery): \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
        return count
    }

    private func getLikelyUploadBatchesUnsafe(
        gapSeconds: TimeInterval,
        minPhotos: Int,
        locationMatchMiles: Double
    ) -> [PhotoUploadBatch] {
        guard let db else { return [] }

        let sql = """
        SELECT id, creationDate, captureDateOverride, userLatitude, userLongitude
        FROM photos
        WHERE isDeleted = 0
          AND isScreenshot = 0
          AND COALESCE(userLatitude, latitude) IS NULL
        ORDER BY creationDate ASC;
        """

        var statement: OpaquePointer?
        struct Row {
            let id: String
            let importDate: Date
            let captureOverride: Date?
            let userLatitude: Double?
            let userLongitude: Double?
        }

        let iso8601 = ISO8601DateFormatter()
        var rows: [Row] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(statement, 0))
                let creationString = String(cString: sqlite3_column_text(statement, 1))

                guard let importDate = iso8601.date(from: creationString) else {
                    continue
                }

                let captureOverride: Date?
                if sqlite3_column_type(statement, 2) != SQLITE_NULL {
                    let overrideString = String(cString: sqlite3_column_text(statement, 2))
                    captureOverride = iso8601.date(from: overrideString)
                } else {
                    captureOverride = nil
                }

                let userLatitude: Double? =
                    sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 3)

                let userLongitude: Double? =
                    sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 4)

                rows.append(
                    Row(
                        id: id,
                        importDate: importDate,
                        captureOverride: captureOverride,
                        userLatitude: userLatitude,
                        userLongitude: userLongitude
                    )
                )
            }
        }

        sqlite3_finalize(statement)

        guard !rows.isEmpty else { return [] }

        var batches: [[Row]] = []
        var currentBatch: [Row] = [rows[0]]

        for row in rows.dropFirst() {
            let gap = row.importDate.timeIntervalSince(currentBatch.last!.importDate)
            if gap > gapSeconds {
                batches.append(currentBatch)
                currentBatch = [row]
            } else {
                currentBatch.append(row)
            }
        }

        batches.append(currentBatch)

        return batches
            .filter { $0.count >= minPhotos }
            .map { batchRows in
                let importStart = batchRows.first!.importDate
                let importEnd = batchRows.last!.importDate
                let photoIds = batchRows.map(\.id)
                let samplePhotoIds = Array(photoIds.prefix(24))

                let overrides = batchRows.compactMap(\.captureOverride)
                let assignedCaptureDate =
                    overrides.count == batchRows.count ? overrides.first : nil

                let hasAssignedLocation = batchRows.allSatisfy {
                    $0.userLatitude != nil && $0.userLongitude != nil
                }

                let assignedLocationId: Int?
                if hasAssignedLocation,
                   let latitude = batchRows.first?.userLatitude,
                   let longitude = batchRows.first?.userLongitude,
                   let locations {
                    assignedLocationId = locations.findLocationWithinMiles(
                        latitude: latitude,
                        longitude: longitude,
                        maxMiles: locationMatchMiles
                    )
                } else {
                    assignedLocationId = nil
                }

                let id = iso8601.string(from: importStart)

                return PhotoUploadBatch(
                    id: id,
                    importStart: importStart,
                    importEnd: importEnd,
                    photoIds: photoIds,
                    samplePhotoIds: samplePhotoIds,
                    assignedCaptureDate: assignedCaptureDate,
                    assignedLocationId: assignedLocationId,
                    hasAssignedLocation: hasAssignedLocation
                )
            }
            .sorted { $0.importStart > $1.importStart }
    }

    private func applyArchiveBatchMetadataUnsafe(
        photoIds: [String],
        captureDate: Date,
        latitude: Double,
        longitude: Double
    ) {
        guard let db else { return }

        let iso8601 = ISO8601DateFormatter()
        let captureISO = iso8601.string(from: captureDate)
        let now = iso8601.string(from: Date())

        let sql = """
        UPDATE photos
        SET captureDateOverride = ?,
            userLatitude = ?,
            userLongitude = ?,
            eventAssignedAt = NULL,
            eventNeedsReview = 0,
            indexedAt = ?
        WHERE id = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            print("Failed to prepare archive batch update: \(String(cString: sqlite3_errmsg(db)))")
            return
        }

        for photoId in photoIds {
            sqlite3_bind_text(statement, 1, (captureISO as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 2, latitude)
            sqlite3_bind_double(statement, 3, longitude)
            sqlite3_bind_text(statement, 4, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 5, (photoId as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed archive batch update for \(photoId): \(String(cString: sqlite3_errmsg(db)))")
            }

            sqlite3_reset(statement)
        }

        sqlite3_finalize(statement)
        print("Applied archive metadata to \(photoIds.count) photos")
    }

    private func upsertPhotoUnsafe(
        id: String,
        creationDate: String,
        modificationDate: String,
        mediaType: Int,
        mediaSubtype: Int,
        width: Int,
        height: Int,
        isFavorite: Bool,
        isHidden: Bool,
        latitude: Double?,
        longitude: Double?,
        isScreenshot: Bool,
        aspectRatio: Double,
        orientation: String,
        qualityScore: Int,
        duration: Double?
    ) {
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        INSERT INTO photos
        (
            id, creationDate, modificationDate, mediaType, mediaSubtype,
            width, height, isFavorite, isHidden, latitude, longitude,
            isScreenshot, aspectRatio, orientation, qualityScore, duration,
            isDeleted, deletedAt, lastSeenAt, indexedAt
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            creationDate = excluded.creationDate,
            modificationDate = excluded.modificationDate,
            mediaType = excluded.mediaType,
            mediaSubtype = excluded.mediaSubtype,
            width = excluded.width,
            height = excluded.height,
            isFavorite = excluded.isFavorite,
            isHidden = excluded.isHidden,
            latitude = excluded.latitude,
            longitude = excluded.longitude,
            isScreenshot = excluded.isScreenshot,
            aspectRatio = excluded.aspectRatio,
            orientation = excluded.orientation,
            qualityScore = excluded.qualityScore,
            duration = COALESCE(excluded.duration, duration),
            isDeleted = 0,
            deletedAt = NULL,
            lastSeenAt = excluded.lastSeenAt,
            indexedAt = excluded.indexedAt;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (creationDate as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (modificationDate as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 4, Int32(mediaType))
            sqlite3_bind_int(statement, 5, Int32(mediaSubtype))
            sqlite3_bind_int(statement, 6, Int32(width))
            sqlite3_bind_int(statement, 7, Int32(height))
            sqlite3_bind_int(statement, 8, isFavorite ? 1 : 0)
            sqlite3_bind_int(statement, 9, isHidden ? 1 : 0)

            if let latitude = latitude {
                sqlite3_bind_double(statement, 10, latitude)
            } else {
                sqlite3_bind_null(statement, 10)
            }

            if let longitude = longitude {
                sqlite3_bind_double(statement, 11, longitude)
            } else {
                sqlite3_bind_null(statement, 11)
            }

            sqlite3_bind_int(statement, 12, isScreenshot ? 1 : 0)
            sqlite3_bind_double(statement, 13, aspectRatio)
            sqlite3_bind_text(statement, 14, (orientation as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 15, Int32(qualityScore))
            if let duration {
                sqlite3_bind_double(statement, 16, duration)
            } else {
                sqlite3_bind_null(statement, 16)
            }
            sqlite3_bind_text(statement, 17, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 18, (now as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to upsert photo: \(String(cString: sqlite3_errmsg(db)))")
            }
        } else {
            print("Failed to prepare upsert photo: \(String(cString: sqlite3_errmsg(db)))")
        }

        sqlite3_finalize(statement)
    }

    private func fetchAllActivePhotoIds() -> [String] {
        let sql = """
        SELECT id
        FROM photos
        WHERE isDeleted = 0;
        """

        var statement: OpaquePointer?
        var ids: [String] = []

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(statement, 0)))
            }
        }

        sqlite3_finalize(statement)
        return ids
    }

    private func markPhotoDeleted(photoId: String, deletedAt: String) {
        let sql = """
        UPDATE photos
        SET isDeleted = 1,
            deletedAt = ?,
            indexedAt = ?
        WHERE id = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (deletedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (deletedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (photoId as NSString).utf8String, -1, nil)

            if sqlite3_step(statement) != SQLITE_DONE {
                print("Failed to soft delete photo: \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        sqlite3_finalize(statement)
    }

    private func readCropFocus(
        _ statement: OpaquePointer?,
        xColumn: Int32,
        yColumn: Int32
    ) -> PhotoCropFocus? {
        guard let statement else { return nil }
        guard sqlite3_column_type(statement, xColumn) != SQLITE_NULL,
              sqlite3_column_type(statement, yColumn) != SQLITE_NULL else {
            return nil
        }

        return PhotoCropFocus(
            x: sqlite3_column_double(statement, xColumn),
            y: sqlite3_column_double(statement, yColumn)
        )
    }

    private func bindOptionalDouble(
        _ statement: OpaquePointer?,
        index: Int32,
        value: Double?
    ) {
        guard let statement else { return }

        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func optionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let statement else { return nil }
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(statement, column))
    }

    private func optionalDoubleColumn(_ statement: OpaquePointer?, index: Int32) -> Double? {
        guard let statement else { return nil }
        guard sqlite3_column_count(statement) > index else { return nil }
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }
}
