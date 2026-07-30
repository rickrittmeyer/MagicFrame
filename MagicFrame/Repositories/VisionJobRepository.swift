import Foundation
import SQLite3

final class VisionJobRepository {

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    private var db: OpaquePointer? { database.connection }

    func enqueueUnsafe(
        jobType: VisionJobType,
        priority: Int,
        photoId: String? = nil,
        eventId: Int? = nil,
        occasionKey: String? = nil,
        algorithmVersion: Int,
        payload: VisionJobPayload,
        dedupeKey: String,
        createdAt: String
    ) -> Bool {
        let payloadJSON = encodePayload(payload)
        let sql = """
        INSERT OR IGNORE INTO vision_jobs (
            jobType, status, priority, photoId, eventId, occasionKey,
            algorithmVersion, payloadJSON, dedupeKey, createdAt
        ) VALUES (?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (jobType.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(priority))
        bindOptionalText(statement, 3, photoId)
        bindOptionalInt(statement, 4, eventId)
        bindOptionalText(statement, 5, occasionKey)
        sqlite3_bind_int(statement, 6, Int32(algorithmVersion))
        sqlite3_bind_text(statement, 7, (payloadJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 8, (dedupeKey as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 9, (createdAt as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    func claimPendingJobsUnsafe(limit: Int, algorithmVersion: Int) -> [VisionJob] {
        resetStaleRunningJobsUnsafe()

        let sql = """
        SELECT
            visionJobId, jobType, status, priority, photoId, eventId, occasionKey,
            algorithmVersion, payloadJSON, dedupeKey, attempts, maxAttempts,
            lastError, createdAt, startedAt, finishedAt
        FROM vision_jobs
        WHERE status = 'pending'
          AND algorithmVersion = ?
        ORDER BY priority DESC, createdAt ASC
        LIMIT ?;
        """

        var candidates: [VisionJob] = []
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(algorithmVersion))
        sqlite3_bind_int(statement, 2, Int32(limit))

        while sqlite3_step(statement) == SQLITE_ROW {
            if let job = mapJob(from: statement) {
                candidates.append(job)
            }
        }

        let startedAt = ISO8601DateFormatter().string(from: Date())
        var claimed: [VisionJob] = []
        for job in candidates {
            if job.jobType == .objectEventFinalize,
               let eventId = job.eventId,
               hasPendingPhotoScanJobsUnsafe(eventId: eventId, algorithmVersion: algorithmVersion) {
                continue
            }

            guard markRunningUnsafe(jobId: job.id, startedAt: startedAt) else { continue }
            claimed.append(
                VisionJob(
                    id: job.id,
                    jobType: job.jobType,
                    status: .running,
                    priority: job.priority,
                    photoId: job.photoId,
                    eventId: job.eventId,
                    occasionKey: job.occasionKey,
                    algorithmVersion: job.algorithmVersion,
                    payload: job.payload,
                    dedupeKey: job.dedupeKey,
                    attempts: job.attempts,
                    maxAttempts: job.maxAttempts,
                    lastError: job.lastError,
                    createdAt: job.createdAt,
                    startedAt: startedAt,
                    finishedAt: job.finishedAt
                )
            )
            if claimed.count >= limit { break }
        }
        return claimed
    }

    func markCompletedUnsafe(jobId: Int, finishedAt: String) {
        let sql = """
        UPDATE vision_jobs
        SET status = 'completed', finishedAt = ?, lastError = NULL
        WHERE visionJobId = ?;
        """
        runUpdate(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, (finishedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(jobId))
        }
    }

    func markFailedUnsafe(jobId: Int, error: String, finishedAt: String) {
        let sql = """
        UPDATE vision_jobs
        SET status = CASE
                WHEN attempts + 1 >= maxAttempts THEN 'failed'
                ELSE 'pending'
            END,
            attempts = attempts + 1,
            lastError = ?,
            finishedAt = CASE
                WHEN attempts + 1 >= maxAttempts THEN ?
                ELSE finishedAt
            END,
            startedAt = CASE
                WHEN attempts + 1 >= maxAttempts THEN startedAt
                ELSE NULL
            END
        WHERE visionJobId = ?;
        """
        runUpdate(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, (error as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (finishedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(jobId))
        }
    }

    func purgeJobsForEventsUnsafe(eventIds: [Int]) {
        guard !eventIds.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: eventIds.count).joined(separator: ", ")
        let sql = "DELETE FROM vision_jobs WHERE eventId IN (\(placeholders));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (index, eventId) in eventIds.enumerated() {
            sqlite3_bind_int(statement, Int32(index + 1), Int32(eventId))
        }
        sqlite3_step(statement)
    }

    func cancelPendingPhotoScansForEventUnsafe(eventId: Int, algorithmVersion: Int) {
        let finishedAt = ISO8601DateFormatter().string(from: Date())
        let sql = """
        UPDATE vision_jobs
        SET status = 'cancelled', finishedAt = ?
        WHERE status IN ('pending', 'running')
          AND jobType = ?
          AND eventId = ?
          AND algorithmVersion = ?;
        """
        runUpdate(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, (finishedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_text(
                statement,
                2,
                (VisionJobType.objectPhotoScan.rawValue as NSString).utf8String,
                -1,
                nil
            )
            sqlite3_bind_int(statement, 3, Int32(eventId))
            sqlite3_bind_int(statement, 4, Int32(algorithmVersion))
        }
    }

    func completePendingFinalizeJobsForEventUnsafe(eventId: Int, algorithmVersion: Int) {
        let finishedAt = ISO8601DateFormatter().string(from: Date())
        let sql = """
        UPDATE vision_jobs
        SET status = 'completed', finishedAt = ?
        WHERE status IN ('pending', 'running')
          AND jobType = ?
          AND eventId = ?
          AND algorithmVersion = ?;
        """
        runUpdate(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, (finishedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_text(
                statement,
                2,
                (VisionJobType.objectEventFinalize.rawValue as NSString).utf8String,
                -1,
                nil
            )
            sqlite3_bind_int(statement, 3, Int32(eventId))
            sqlite3_bind_int(statement, 4, Int32(algorithmVersion))
        }
    }

    func cancelScopeUnsafe(scopeKey: String) {
        let pattern = "%\"scopeKey\":\"\(scopeKey)\"%"
        let sql = """
        UPDATE vision_jobs
        SET status = 'cancelled', finishedAt = ?
        WHERE status IN ('pending', 'running')
          AND payloadJSON LIKE ?;
        """
        let finishedAt = ISO8601DateFormatter().string(from: Date())
        runUpdate(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, (finishedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (pattern as NSString).utf8String, -1, nil)
        }
    }

    func countPendingUnsafe(
        scopeKey: String? = nil,
        eventId: Int? = nil,
        algorithmVersion: Int? = nil
    ) -> Int {
        var clauses = ["status IN ('pending', 'running')"]
        if scopeKey != nil {
            clauses.append("payloadJSON LIKE ?")
        }
        if eventId != nil {
            clauses.append("eventId = ?")
        }
        if algorithmVersion != nil {
            clauses.append("algorithmVersion = ?")
        }

        let sql = "SELECT COUNT(*) FROM vision_jobs WHERE \(clauses.joined(separator: " AND "));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        if let scopeKey {
            let pattern = "%\"scopeKey\":\"\(scopeKey)\"%"
            sqlite3_bind_text(statement, bindIndex, (pattern as NSString).utf8String, -1, nil)
            bindIndex += 1
        }
        if let eventId {
            sqlite3_bind_int(statement, bindIndex, Int32(eventId))
            bindIndex += 1
        }
        if let algorithmVersion {
            sqlite3_bind_int(statement, bindIndex, Int32(algorithmVersion))
        }

        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    func hasPendingPhotoScanJobsUnsafe(eventId: Int, algorithmVersion: Int) -> Bool {
        let sql = """
        SELECT 1 FROM vision_jobs
        WHERE status IN ('pending', 'running')
          AND jobType = ?
          AND eventId = ?
          AND algorithmVersion = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(
            statement,
            1,
            (VisionJobType.objectPhotoScan.rawValue as NSString).utf8String,
            -1,
            nil
        )
        sqlite3_bind_int(statement, 2, Int32(eventId))
        sqlite3_bind_int(statement, 3, Int32(algorithmVersion))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func markRunningUnsafe(jobId: Int, startedAt: String) -> Bool {
        let sql = """
        UPDATE vision_jobs
        SET status = 'running', startedAt = ?
        WHERE visionJobId = ? AND status = 'pending';
        """
        runUpdate(sql: sql) { statement in
            sqlite3_bind_text(statement, 1, (startedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(jobId))
        }
        return sqlite3_changes(db) > 0
    }

    private func resetStaleRunningJobsUnsafe() {
        let sql = """
        UPDATE vision_jobs
        SET status = 'pending', startedAt = NULL
        WHERE status = 'running'
          AND startedAt IS NOT NULL
          AND startedAt < datetime('now', '-10 minutes');
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func mapJob(from statement: OpaquePointer?) -> VisionJob? {
        guard let statement else { return nil }

        let id = Int(sqlite3_column_int(statement, 0))
        guard let jobTypeRaw = sqlite3_column_text(statement, 1),
              let jobType = VisionJobType(rawValue: String(cString: jobTypeRaw)),
              let statusRaw = sqlite3_column_text(statement, 2),
              let status = VisionJobStatus(rawValue: String(cString: statusRaw)),
              let payloadJSON = sqlite3_column_text(statement, 8),
              let dedupeKey = sqlite3_column_text(statement, 9),
              let createdAt = sqlite3_column_text(statement, 13) else {
            return nil
        }

        let payload = decodePayload(String(cString: payloadJSON))
        let photoId = optionalString(statement, 4)
        let eventId = sqlite3_column_type(statement, 5) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int(statement, 5))
        let occasionKey = optionalString(statement, 6)
        let lastError = optionalString(statement, 12)
        let startedAt = optionalString(statement, 14)
        let finishedAt = optionalString(statement, 15)

        return VisionJob(
            id: id,
            jobType: jobType,
            status: status,
            priority: Int(sqlite3_column_int(statement, 3)),
            photoId: photoId,
            eventId: eventId,
            occasionKey: occasionKey,
            algorithmVersion: Int(sqlite3_column_int(statement, 7)),
            payload: payload,
            dedupeKey: String(cString: dedupeKey),
            attempts: Int(sqlite3_column_int(statement, 10)),
            maxAttempts: Int(sqlite3_column_int(statement, 11)),
            lastError: lastError,
            createdAt: String(cString: createdAt),
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    private func encodePayload(_ payload: VisionJobPayload) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func decodePayload(_ json: String) -> VisionJobPayload {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(VisionJobPayload.self, from: data) else {
            return VisionJobPayload()
        }
        return payload
    }

    private func optionalString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(statement, index, Int32(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func runUpdate(sql: String, bind: (OpaquePointer?) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        sqlite3_step(statement)
    }
}
