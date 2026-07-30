import Foundation
import SQLite3

/// Persists landing collection / on-frame counts and tracks which events belong to each occasion.
final class OccasionLandingMetricsCache {

    static let generationMetadataKey = "occasionLandingMetricsGeneration"

    struct CachedMetrics: Sendable {
        let collectionCount: Int
        let onFramePhotoCount: Int
    }

    private let database: DatabaseManager
    private let metadata: AppMetadataStore

    init(database: DatabaseManager, metadata: AppMetadataStore) {
        self.database = database
        self.metadata = metadata
    }

    private var db: OpaquePointer? {
        database.connection
    }

    func invalidate() {
        if database.isOnQueue {
            invalidateUnsafe()
        } else {
            database.sync { invalidateUnsafe() }
        }
    }

    func invalidateUnsafe() {
        let nextGeneration = currentGenerationUnsafe() + 1
        metadata.set(key: Self.generationMetadataKey, value: String(nextGeneration))
    }

    func currentGenerationUnsafe() -> Int {
        guard let raw = metadata.get(key: Self.generationMetadataKey),
              let generation = Int(raw) else {
            return 0
        }
        return generation
    }

    func hasMetricsUnsafe(tagValue: String) -> Bool {
        fetchCachedUnsafe(tagValue: tagValue) != nil
    }

    func fetchCachedUnsafe(tagValue: String) -> CachedMetrics? {
        let sql = """
        SELECT collectionCount, onFramePhotoCount
        FROM occasion_landing_metrics
        WHERE tagValue = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (tagValue as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                let metrics = CachedMetrics(
                    collectionCount: Int(sqlite3_column_int(statement, 0)),
                    onFramePhotoCount: Int(sqlite3_column_int(statement, 1))
                )
                sqlite3_finalize(statement)
                return metrics
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    func saveUnsafe(
        tagValue: String,
        collectionCount: Int,
        onFramePhotoCount: Int
    ) {
        let generation = currentGenerationUnsafe()
        let sql = """
        INSERT INTO occasion_landing_metrics (
            tagValue, collectionCount, onFramePhotoCount, metricsGeneration
        )
        VALUES (?, ?, ?, ?)
        ON CONFLICT(tagValue) DO UPDATE SET
            collectionCount = excluded.collectionCount,
            onFramePhotoCount = excluded.onFramePhotoCount,
            metricsGeneration = excluded.metricsGeneration;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_text(statement, 1, (tagValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(collectionCount))
        sqlite3_bind_int(statement, 3, Int32(onFramePhotoCount))
        sqlite3_bind_int(statement, 4, Int32(generation))
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    func adjustCountsUnsafe(
        tagValue: String,
        collectionDelta: Int = 0,
        onFrameDelta: Int = 0
    ) {
        guard collectionDelta != 0 || onFrameDelta != 0 else { return }

        let sql = """
        UPDATE occasion_landing_metrics
        SET collectionCount = MAX(0, collectionCount + ?),
            onFramePhotoCount = MAX(0, onFramePhotoCount + ?)
        WHERE tagValue = ?;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_int(statement, 1, Int32(collectionDelta))
        sqlite3_bind_int(statement, 2, Int32(onFrameDelta))
        sqlite3_bind_text(statement, 3, (tagValue as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    func updateOnFrameCountUnsafe(tagValue: String, onFramePhotoCount: Int) {
        let sql = """
        UPDATE occasion_landing_metrics
        SET onFramePhotoCount = ?
        WHERE tagValue = ?;
        """

        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_int(statement, 1, Int32(max(0, onFramePhotoCount)))
        sqlite3_bind_text(statement, 2, (tagValue as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    // MARK: - Collection membership (incremental collection counts)

    func hasCollectionMembershipUnsafe(occasionId: Int, listEventId: Int) -> Bool {
        let sql = """
        SELECT 1
        FROM occasion_collection_events
        WHERE occasionId = ?
          AND eventId = ?
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var exists = false

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(occasionId))
            sqlite3_bind_int(statement, 2, Int32(listEventId))
            exists = sqlite3_step(statement) == SQLITE_ROW
        }

        sqlite3_finalize(statement)
        return exists
    }

    func setCollectionMembershipUnsafe(
        occasionId: Int,
        listEventId: Int,
        isMember: Bool,
        tagValue: String
    ) {
        if isMember {
            let insertSQL = """
            INSERT OR IGNORE INTO occasion_collection_events (occasionId, eventId)
            VALUES (?, ?);
            """

            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(occasionId))
                sqlite3_bind_int(statement, 2, Int32(listEventId))
                if sqlite3_step(statement) == SQLITE_DONE,
                   sqlite3_changes(db) > 0,
                   hasMetricsUnsafe(tagValue: tagValue) {
                    adjustCountsUnsafe(tagValue: tagValue, collectionDelta: 1)
                }
            }

            sqlite3_finalize(statement)
            return
        }

        let deleteSQL = """
        DELETE FROM occasion_collection_events
        WHERE occasionId = ?
          AND eventId = ?;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(occasionId))
            sqlite3_bind_int(statement, 2, Int32(listEventId))
            if sqlite3_step(statement) == SQLITE_DONE,
               sqlite3_changes(db) > 0,
               hasMetricsUnsafe(tagValue: tagValue) {
                adjustCountsUnsafe(tagValue: tagValue, collectionDelta: -1)
            }
        }

        sqlite3_finalize(statement)
    }

    func replaceCollectionMembershipForOccasionUnsafe(
        occasionId: Int,
        listEventIds: [Int],
        tagValue: String
    ) {
        let deleteSQL = "DELETE FROM occasion_collection_events WHERE occasionId = ?;"
        var deleteStatement: OpaquePointer?

        if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(deleteStatement, 1, Int32(occasionId))
            sqlite3_step(deleteStatement)
        }

        sqlite3_finalize(deleteStatement)

        let insertSQL = """
        INSERT OR IGNORE INTO occasion_collection_events (occasionId, eventId)
        VALUES (?, ?);
        """

        for listEventId in listEventIds {
            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(occasionId))
                sqlite3_bind_int(statement, 2, Int32(listEventId))
                sqlite3_step(statement)
            }

            sqlite3_finalize(statement)
        }

        if hasMetricsUnsafe(tagValue: tagValue) {
            let sql = """
            UPDATE occasion_landing_metrics
            SET collectionCount = ?
            WHERE tagValue = ?;
            """

            var statement: OpaquePointer?

            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(listEventIds.count))
                sqlite3_bind_text(statement, 2, (tagValue as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }

            sqlite3_finalize(statement)
        }
    }

    func clearAllCollectionMembershipUnsafe() {
        sqlite3_exec(db, "DELETE FROM occasion_collection_events;", nil, nil, nil)
    }
}
