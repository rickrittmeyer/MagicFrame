import Foundation
import SQLite3

/// Assembles a full photo info payload for the preview Info sheet.
final class PhotoInfoRepository {

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

    func fetchDetail(photoId: String) -> PhotoInfoDetail? {
        sync { fetchDetailUnsafe(photoId: photoId) }
    }

    private func fetchDetailUnsafe(photoId: String) -> PhotoInfoDetail? {
        let sql = """
        SELECT
            p.id,
            COALESCE(NULLIF(TRIM(p.captureDateOverride), ''), p.creationDate) AS effectiveCreationDate,
            p.creationDate,
            p.captureDateOverride,
            p.indexedAt,
            p.isFavorite,
            p.width,
            p.height,
            p.orientation,
            p.qualityScore,
            p.duration,
            p.isScreenshot,
            p.mediaType,
            p.latitude,
            p.longitude,
            p.userLatitude,
            p.userLongitude,
            p.faceEyesOpenScore,
            p.faceSmileScore,
            COALESCE(p.visionAnalyzed, 0),
            COALESCE(p.faceRecognitionVersion, 0),
            COALESCE(p.textRecognitionVersion, 0),
            l.nickname,
            l.placeName,
            l.city,
            l.state,
            l.locationType,
            e.cameraMake,
            e.cameraModel,
            e.lensModel,
            m.originalFilename,
            o.fullText,
            o.observationCount,
            (
                SELECT MAX(COALESCE(pe.includeInSlideshow, 0))
                FROM photo_events pe
                WHERE pe.photoId = p.id
            ) AS showOnFrame,
            (
                SELECT MAX(COALESCE(pe.manuallyExcluded, 0))
                FROM photo_events pe
                WHERE pe.photoId = p.id
            ) AS isHiddenInEvent,
            (
                SELECT MAX(COALESCE(pe.isSimilarGroupPick, 0))
                FROM photo_events pe
                WHERE pe.photoId = p.id
            ) AS isSimilarGroupPick
        FROM photos p
        LEFT JOIN locations l ON l.locationId = p.locationId
        LEFT JOIN photo_exif e ON e.photoId = p.id
        LEFT JOIN photo_text_metadata m ON m.photoId = p.id
        LEFT JOIN photo_ocr_text o ON o.photoId = p.id
        WHERE p.id = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let photoIdNS = photoId as NSString
        sqlite3_bind_text(statement, 1, photoIdNS.utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let effectiveCreationDate = optionalText(statement, 1)
        let libraryCreationDate = optionalText(statement, 2)
        let captureDateOverride = optionalText(statement, 3)
        let indexedAt = optionalText(statement, 4)
        let isFavorite = sqlite3_column_int(statement, 5) != 0
        let width = Int(sqlite3_column_int(statement, 6))
        let height = Int(sqlite3_column_int(statement, 7))
        let orientation = optionalText(statement, 8)
        let qualityScore = sqlite3_column_type(statement, 9) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int(statement, 9))
        let duration = sqlite3_column_type(statement, 10) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, 10)
        let isScreenshot = sqlite3_column_int(statement, 11) != 0
        let mediaType = Int(sqlite3_column_int(statement, 12))
        let latitude = preferredCoordinate(
            library: optionalDouble(statement, 13),
            user: optionalDouble(statement, 15)
        )
        let longitude = preferredCoordinate(
            library: optionalDouble(statement, 14),
            user: optionalDouble(statement, 16)
        )
        let faceEyesOpenScore = optionalDouble(statement, 17)
        let faceSmileScore = optionalDouble(statement, 18)
        let visionAnalyzed = sqlite3_column_int(statement, 19) != 0
        let faceRecognitionVersion = Int(sqlite3_column_int(statement, 20))
        let textRecognitionVersion = Int(sqlite3_column_int(statement, 21))
        let nickname = optionalText(statement, 22)
        let placeName = optionalText(statement, 23)
        let city = optionalText(statement, 24)
        let state = optionalText(statement, 25)
        let locationType = optionalText(statement, 26)
        let cameraMake = optionalText(statement, 27)
        let cameraModel = optionalText(statement, 28)
        let lensModel = optionalText(statement, 29)
        let originalFilename = optionalText(statement, 30)
        let ocrFullText = optionalText(statement, 31)
        let ocrObservationCount = sqlite3_column_type(statement, 32) == SQLITE_NULL
            ? 0
            : Int(sqlite3_column_int(statement, 32))
        let showOnFrame = sqlite3_column_int(statement, 33) != 0
        let isHiddenInEvent = sqlite3_column_int(statement, 34) != 0
        let isSimilarGroupPick = sqlite3_column_int(statement, 35) != 0

        let locationLine = PhotoPreviewLocationFormatting.line(
            nickname: nickname,
            placeName: placeName,
            city: city,
            state: state,
            latitude: latitude,
            longitude: longitude
        )

        return PhotoInfoDetail(
            photoId: photoId,
            effectiveCreationDate: effectiveCreationDate,
            libraryCreationDate: libraryCreationDate,
            captureDateOverride: captureDateOverride,
            indexedAt: indexedAt,
            locationLine: locationLine,
            nickname: nickname,
            placeName: placeName,
            city: city,
            state: state,
            locationType: locationType,
            latitude: latitude,
            longitude: longitude,
            isVideo: mediaType == 2,
            isScreenshot: isScreenshot,
            width: width,
            height: height,
            orientation: orientation,
            qualityScore: qualityScore,
            duration: duration,
            isFavorite: isFavorite,
            showOnFrame: showOnFrame,
            isHiddenInEvent: isHiddenInEvent,
            isSimilarGroupPick: isSimilarGroupPick,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            lensModel: lensModel,
            originalFilename: originalFilename,
            albumTitles: fetchAlbumTitlesUnsafe(photoId: photoId),
            peopleNames: fetchPeopleNamesUnsafe(photoId: photoId),
            faceCount: fetchFaceCountUnsafe(photoId: photoId),
            faceEyesOpenScore: faceEyesOpenScore,
            faceSmileScore: faceSmileScore,
            visionAnalyzed: visionAnalyzed,
            visionTags: fetchVisionTagsUnsafe(photoId: photoId),
            ocrScanned: textRecognitionVersion > 0 || ocrFullText != nil,
            ocrFullText: ocrFullText,
            ocrObservationCount: ocrObservationCount,
            events: fetchEventsUnsafe(photoId: photoId),
            faceRecognitionVersion: faceRecognitionVersion,
            textRecognitionVersion: textRecognitionVersion
        )
    }

    private func preferredCoordinate(library: Double?, user: Double?) -> Double? {
        user ?? library
    }

    private func fetchAlbumTitlesUnsafe(photoId: String) -> [String] {
        let sql = """
        SELECT DISTINCT a.title
        FROM photo_albums pa
        JOIN albums a ON a.albumId = pa.albumId
        WHERE pa.photoId = ?
          AND TRIM(COALESCE(a.title, '')) != ''
        ORDER BY a.title COLLATE NOCASE ASC;
        """
        return fetchStringListUnsafe(sql: sql, photoId: photoId)
    }

    private func fetchPeopleNamesUnsafe(photoId: String) -> [String] {
        let sql = """
        SELECT DISTINCT pe.displayName
        FROM photo_people pp
        JOIN people pe ON pe.personId = pp.personId
        WHERE pp.photoId = ?
          AND TRIM(COALESCE(pe.displayName, '')) != ''
        ORDER BY pe.displayName COLLATE NOCASE ASC;
        """
        return fetchStringListUnsafe(sql: sql, photoId: photoId)
    }

    private func fetchFaceCountUnsafe(photoId: String) -> Int {
        let sql = """
        SELECT COUNT(*)
        FROM face_instances
        WHERE photoId = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func fetchVisionTagsUnsafe(photoId: String) -> [PhotoInfoVisionTag] {
        let sql = """
        SELECT objectKey, confidence
        FROM photo_object_tags
        WHERE photoId = ?
        ORDER BY confidence DESC, objectKey COLLATE NOCASE ASC;
        """
        var statement: OpaquePointer?
        var tags: [PhotoInfoVisionTag] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = optionalText(statement, 0) else { continue }
            tags.append(
                PhotoInfoVisionTag(
                    objectKey: key,
                    confidence: sqlite3_column_double(statement, 1)
                )
            )
        }
        return tags
    }

    private func fetchEventsUnsafe(photoId: String) -> [PhotoInfoEventLink] {
        let sql = """
        SELECT e.eventId,
               COALESCE(NULLIF(TRIM(e.name), ''), NULLIF(TRIM(e.childEventName), ''), 'Untitled Event')
        FROM photo_events pe
        JOIN events e ON e.eventId = pe.eventId
        WHERE pe.photoId = ?
          AND COALESCE(e.isDeleted, 0) = 0
        ORDER BY e.startDate DESC, e.eventId DESC;
        """
        var statement: OpaquePointer?
        var events: [PhotoInfoEventLink] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        while sqlite3_step(statement) == SQLITE_ROW {
            let eventId = Int(sqlite3_column_int(statement, 0))
            let title = optionalText(statement, 1) ?? "Untitled Event"
            events.append(
                PhotoInfoEventLink(
                    eventId: eventId,
                    title: title,
                    tags: fetchEventTagsUnsafe(eventId: eventId)
                )
            )
        }
        return events
    }

    private func fetchEventTagsUnsafe(eventId: Int) -> [PhotoInfoEventTag] {
        let sql = """
        SELECT tagCategory, tagValue
        FROM event_tags
        WHERE eventId = ?
          AND COALESCE(isRejected, 0) = 0
          AND TRIM(COALESCE(tagValue, '')) != ''
        ORDER BY tagCategory COLLATE NOCASE ASC, tagValue COLLATE NOCASE ASC;
        """
        var statement: OpaquePointer?
        var tags: [PhotoInfoEventTag] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(eventId))
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let category = optionalText(statement, 0),
                  let value = optionalText(statement, 1) else { continue }
            tags.append(PhotoInfoEventTag(category: category, value: value))
        }
        return tags
    }

    private func fetchStringListUnsafe(sql: String, photoId: String) -> [String] {
        var statement: OpaquePointer?
        var values: [String] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = optionalText(statement, 0) {
                values.append(text)
            }
        }
        return values
    }

    private func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        let value = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func optionalDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }
}
