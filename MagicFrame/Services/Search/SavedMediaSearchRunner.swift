import Foundation
import SQLite3

/// Runs a persisted Media Saved Search and writes Picture Search run/match rows for scoring.
final class SavedMediaSearchRunner {

    private let database: DatabaseManager
    private let mediaSearch: MediaPhotoSearchService

    init(database: DatabaseManager) {
        self.database = database
        self.mediaSearch = MediaPhotoSearchService(database: database)
    }

    private var db: OpaquePointer? { database.connection }

    private func sync<T>(_ work: () -> T) -> T {
        if database.isOnQueue {
            return work()
        }
        return database.sync(work)
    }

    private var nowISO: String {
        ISO8601DateFormatter().string(from: Date())
    }

    func run(_ search: MediaSavedSearch) -> PictureSearchRunReport {
        sync { runUnsafe(search) }
    }

    private func runUnsafe(_ search: MediaSavedSearch) -> PictureSearchRunReport {
        let pictureSearchId = search.legacyPictureSearchId ?? 0
        let mediaSavedSearchId = search.mediaSavedSearchId
        let startedAt = nowISO
        let runId = insertRunUnsafe(
            pictureSearchId: pictureSearchId,
            mediaSavedSearchId: mediaSavedSearchId,
            startedAt: startedAt,
            status: "running"
        )

        let report = mediaSearch.searchAssumingOnDatabaseQueue(search.query)
        let eventByPhoto = fetchPrimaryEventIdsUnsafe(photoIds: report.photoIds)
        let matches: [PictureSearchPhotoMatch] = report.photoIds.map { photoId in
            PictureSearchPhotoMatch(
                photoId: photoId,
                eventId: eventByPhoto[photoId],
                confidence: nil
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
            targetEventType: search.targetTagValue,
            photoMatches: matches,
            eventCandidateCount: eventIds.count
        )
    }

    private func fetchPrimaryEventIdsUnsafe(photoIds: [String]) -> [String: Int] {
        guard !photoIds.isEmpty else { return [:] }
        var map: [String: Int] = [:]
        let chunkSize = 400
        var start = photoIds.startIndex
        while start < photoIds.endIndex {
            let end = photoIds.index(start, offsetBy: chunkSize, limitedBy: photoIds.endIndex)
                ?? photoIds.endIndex
            let chunk = Array(photoIds[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let sql = """
            SELECT pe.photoId, pe.eventId
            FROM photo_events pe
            JOIN events e ON e.eventId = pe.eventId
            WHERE pe.photoId IN (\(placeholders))
              AND COALESCE(e.isDeleted, 0) = 0
              AND COALESCE(e.parentEventId, 0) = 0
            ORDER BY pe.photoId ASC, pe.eventId ASC;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                for (index, photoId) in chunk.enumerated() {
                    sqlite3_bind_text(
                        statement,
                        Int32(index + 1),
                        (photoId as NSString).utf8String,
                        -1,
                        nil
                    )
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let cString = sqlite3_column_text(statement, 0) else { continue }
                    let photoId = String(cString: cString)
                    if map[photoId] == nil {
                        map[photoId] = Int(sqlite3_column_int(statement, 1))
                    }
                }
            }
            sqlite3_finalize(statement)
            start = end
        }
        return map
    }

    private func insertRunUnsafe(
        pictureSearchId: Int,
        mediaSavedSearchId: Int?,
        startedAt: String,
        status: String
    ) -> Int {
        let sql = """
        INSERT INTO picture_search_runs (
            pictureSearchId, startedAt, status, photoHitCount, eventCandidateCount, mediaSavedSearchId
        ) VALUES (?, ?, ?, 0, 0, ?);
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(max(0, pictureSearchId)))
            sqlite3_bind_text(statement, 2, (startedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (status as NSString).utf8String, -1, nil)
            if let mediaSavedSearchId {
                sqlite3_bind_int(statement, 4, Int32(mediaSavedSearchId))
            } else {
                sqlite3_bind_null(statement, 4)
            }
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
}
