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
        qualityScore: Int
    ) {
        queue.sync {
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
                qualityScore: qualityScore
            )
        }
    }

    func markPhotosDeletedIfMissing(currentIds: Set<String>) {
        let existingIds = fetchAllActivePhotoIds()
        let now = ISO8601DateFormatter().string(from: Date())

        for id in existingIds where !currentIds.contains(id) {
            markPhotoDeleted(photoId: id, deletedAt: now)
        }

        print("Soft delete check complete")
    }

    func setPhotoFavorite(photoId: String, isFavorite: Bool) {
        let sql = """
        UPDATE photos
        SET isFavorite = ?
        WHERE id = ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
            sqlite3_bind_text(statement, 2, (photoId as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func softDeletePhotos(photoIds: [String]) {
        guard !photoIds.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        for photoId in photoIds {
            markPhotoDeleted(photoId: photoId, deletedAt: now)
        }
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

    func updateFaceMetrics(
        photoId: String,
        eyesOpenScore: Double,
        smileScore: Double
    ) {
        queue.sync {
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

        queue.sync {
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
        queue.sync {
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
        queue.sync {
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
        queue.sync {
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
        queue.sync {
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
        queue.sync {
            countRowsUnsafe("photos WHERE isDeleted = 0")
        }
    }

    func getLikelyUploadBatches(
        gapSeconds: TimeInterval,
        minPhotos: Int,
        locationMatchMiles: Double
    ) -> [PhotoUploadBatch] {
        queue.sync {
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
        queue.sync {
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
        qualityScore: Int
    ) {
        let now = ISO8601DateFormatter().string(from: Date())

        let sql = """
        INSERT INTO photos
        (
            id, creationDate, modificationDate, mediaType, mediaSubtype,
            width, height, isFavorite, isHidden, latitude, longitude,
            isScreenshot, aspectRatio, orientation, qualityScore,
            isDeleted, deletedAt, lastSeenAt, indexedAt
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)
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
            sqlite3_bind_text(statement, 16, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 17, (now as NSString).utf8String, -1, nil)

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
