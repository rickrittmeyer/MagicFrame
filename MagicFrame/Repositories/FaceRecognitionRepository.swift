import CoreGraphics
import Foundation
import SQLite3

struct FaceInstanceRecord: Sendable, Identifiable {
    let faceInstanceId: Int
    let photoId: String
    let bboxX: Double
    let bboxY: Double
    let bboxWidth: Double
    let bboxHeight: Double
    let quality: Double?
    let embeddingBlob: Data
    let embeddingVersion: Int
    let clusterId: Int?
    let personId: Int?

    var id: Int { faceInstanceId }

    /// Vision-normalized face box (origin bottom-left).
    var faceBoundingBox: CGRect {
        CGRect(x: bboxX, y: bboxY, width: bboxWidth, height: bboxHeight)
    }
}

/// Lightweight face row for photo preview overlays (no embedding blob).
struct PhotoFaceAnnotation: Sendable, Identifiable, Hashable {
    let faceInstanceId: Int
    let photoId: String
    let bboxX: Double
    let bboxY: Double
    let bboxWidth: Double
    let bboxHeight: Double
    let clusterId: Int?
    let personId: Int?
    let personDisplayName: String?
    /// High-confidence named-person suggestion for confirm UI (`Rick?`). Nil when unnamed with no clear match.
    let suggestedPersonId: Int?
    let suggestedDisplayName: String?
    let suggestedFirstName: String?
    let suggestedLastName: String?
    let suggestedMaidenName: String?

    var id: Int { faceInstanceId }

    /// Vision-normalized face box (origin bottom-left).
    var faceBoundingBox: CGRect {
        CGRect(x: bboxX, y: bboxY, width: bboxWidth, height: bboxHeight)
    }

    var isNamed: Bool {
        !(personDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var hasConfidentNameSuggestion: Bool {
        guard !isNamed, suggestedPersonId != nil else { return false }
        let name = suggestedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !name.isEmpty
    }

    /// Idle chrome title: confirmed name, `Name?` suggestion, or plain `Name`.
    var idleNameChipTitle: String {
        if isNamed {
            return personDisplayName ?? "Named"
        }
        if let suggested = suggestedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            return "\(suggested)?"
        }
        return "Name"
    }
}

struct PersonClusterRecord: Sendable, Identifiable {
    let clusterId: Int
    let representativeFaceInstanceId: Int?
    let faceCount: Int
    /// Distinct photos contributing faces to this cluster (what users think of as “how many photos”).
    let photoCount: Int
    let personId: Int?
    let ignored: Bool
    let representativePhotoId: String?
    /// Vision-normalized face box (origin bottom-left) for the clearest face in the cluster.
    let faceBoundingBox: CGRect?

    var id: Int { clusterId }
}

struct FaceRecognitionProgress: Sendable {
    let photosScanned: Int
    let photosRemaining: Int
    let photosTotal: Int
    let facesDetected: Int
    let clustersIdentified: Int
}

/// SQLite access for `face_instances`, `person_clusters`, and faceRecognitionVersion.
final class FaceRecognitionRepository {

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    private var db: OpaquePointer? { database.connection }

    // MARK: - Photo version

    func faceRecognitionVersionUnsafe(photoId: String) -> Int {
        let sql = """
        SELECT COALESCE(faceRecognitionVersion, 0)
        FROM photos
        WHERE id = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Confirmed people on this event and its child days. Suggestions do not count.
    func fetchConfirmedPersonIdsForEventUnsafe(eventId: Int) -> Set<Int> {
        let sql = """
        SELECT DISTINCT pp.personId
        FROM photo_events pev
        JOIN photo_people pp ON pp.photoId = pev.photoId
        JOIN people p ON p.personId = pp.personId
        WHERE (
            pev.eventId = ?
            OR pev.eventId IN (
                SELECT child.eventId
                FROM events child
                WHERE child.parentEventId = ?
                  AND child.isDeleted = 0
            )
        )
          AND TRIM(COALESCE(p.displayName, '')) != '';
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(eventId))
        sqlite3_bind_int(statement, 2, Int32(eventId))
        var ids: Set<Int> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.insert(Int(sqlite3_column_int(statement, 0)))
        }
        return ids
    }

    func markPhotoFaceRecognitionVersionUnsafe(photoId: String, version: Int) {
        let sql = """
        UPDATE photos
        SET faceRecognitionVersion = ?
        WHERE id = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(version))
        sqlite3_bind_text(statement, 2, (photoId as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
    }

    func clearFaceRecognitionVersionsUnsafe() {
        _ = sqlite3_exec(
            db,
            "UPDATE photos SET faceRecognitionVersion = 0;",
            nil,
            nil,
            nil
        )
    }

    /// Wipes face instances + clusters. Callers should also clear face `photo_people` / orphan people and jobs.
    func wipeAllFaceRecognitionDataUnsafe() {
        _ = sqlite3_exec(db, "DELETE FROM face_instances;", nil, nil, nil)
        _ = sqlite3_exec(db, "DELETE FROM person_clusters;", nil, nil, nil)
        clearFaceRecognitionVersionsUnsafe()
    }

    /// After an accidental force-rescan clears versions, restore stamps for photos that already have faces.
    func restoreFaceRecognitionVersionsForPhotosWithFacesUnsafe(algorithmVersion: Int) -> Int {
        let sql = """
        UPDATE photos
        SET faceRecognitionVersion = ?
        WHERE COALESCE(isDeleted, 0) = 0
          AND id IN (SELECT DISTINCT photoId FROM face_instances);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(algorithmVersion))
        guard sqlite3_step(statement) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    func fetchPhotoIdsNeedingFaceRecognitionUnsafe(
        algorithmVersion: Int,
        limit: Int
    ) -> [String] {
        let sql = """
        SELECT id
        FROM photos
        WHERE COALESCE(isDeleted, 0) = 0
          AND COALESCE(faceRecognitionVersion, 0) < ?
        ORDER BY creationDate DESC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        var ids: [String] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(algorithmVersion))
        sqlite3_bind_int(statement, 2, Int32(limit))
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                ids.append(String(cString: cString))
            }
        }
        return ids
    }

    /// Subset of `photoIds` that still need face detect at `algorithmVersion`.
    func filterPhotoIdsNeedingFaceRecognitionUnsafe(
        photoIds: [String],
        algorithmVersion: Int
    ) -> [String] {
        let unique = Array(Set(photoIds.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [] }

        var needing: [String] = []
        needing.reserveCapacity(unique.count)
        // Chunk IN-lists to stay well under SQLite variable limits.
        let chunkSize = 400
        var start = 0
        while start < unique.count {
            let end = min(start + chunkSize, unique.count)
            let chunk = Array(unique[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
            SELECT id
            FROM photos
            WHERE COALESCE(isDeleted, 0) = 0
              AND COALESCE(faceRecognitionVersion, 0) < ?
              AND id IN (\(placeholders));
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, Int32(algorithmVersion))
                for (index, photoId) in chunk.enumerated() {
                    sqlite3_bind_text(
                        statement,
                        Int32(index + 2),
                        (photoId as NSString).utf8String,
                        -1,
                        nil
                    )
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let cString = sqlite3_column_text(statement, 0) {
                        needing.append(String(cString: cString))
                    }
                }
            }
            sqlite3_finalize(statement)
            start = end
        }
        return needing
    }

    func countPhotosNeedingFaceRecognitionUnsafe(algorithmVersion: Int) -> Int {
        let sql = """
        SELECT COUNT(*)
        FROM photos
        WHERE COALESCE(isDeleted, 0) = 0
          AND COALESCE(faceRecognitionVersion, 0) < ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(algorithmVersion))
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Photos already stamped at/above the current face-recognition algorithm version.
    func countPhotosWithFaceRecognitionUnsafe(algorithmVersion: Int) -> Int {
        let sql = """
        SELECT COUNT(*)
        FROM photos
        WHERE COALESCE(isDeleted, 0) = 0
          AND COALESCE(faceRecognitionVersion, 0) >= ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(algorithmVersion))
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    func faceRecognitionProgressUnsafe(algorithmVersion: Int) -> FaceRecognitionProgress {
        let photoSQL = """
        SELECT
            SUM(CASE WHEN COALESCE(faceRecognitionVersion, 0) >= ? THEN 1 ELSE 0 END) AS scanned,
            SUM(CASE WHEN COALESCE(faceRecognitionVersion, 0) < ? THEN 1 ELSE 0 END) AS remaining,
            COUNT(*) AS total
        FROM photos
        WHERE COALESCE(isDeleted, 0) = 0;
        """
        var photosScanned = 0
        var photosRemaining = 0
        var photosTotal = 0
        var photoStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, photoSQL, -1, &photoStatement, nil) == SQLITE_OK {
            defer { sqlite3_finalize(photoStatement) }
            sqlite3_bind_int(photoStatement, 1, Int32(algorithmVersion))
            sqlite3_bind_int(photoStatement, 2, Int32(algorithmVersion))
            if sqlite3_step(photoStatement) == SQLITE_ROW {
                photosScanned = Int(sqlite3_column_int(photoStatement, 0))
                photosRemaining = Int(sqlite3_column_int(photoStatement, 1))
                photosTotal = Int(sqlite3_column_int(photoStatement, 2))
            }
        }

        return FaceRecognitionProgress(
            photosScanned: photosScanned,
            photosRemaining: photosRemaining,
            photosTotal: photosTotal,
            facesDetected: countFaceInstancesUnsafe(),
            clustersIdentified: countActiveClustersUnsafe()
        )
    }

    func countFaceInstancesUnsafe() -> Int {
        let sql = "SELECT COUNT(*) FROM face_instances;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    func countActiveClustersUnsafe() -> Int {
        let sql = """
        SELECT COUNT(*)
        FROM person_clusters
        WHERE COALESCE(ignored, 0) = 0
          AND faceCount > 0;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    // MARK: - Face instances

    func fetchFaceAnnotationsForPhotoUnsafe(photoId: String) -> [PhotoFaceAnnotation] {
        let sql = """
        SELECT fi.faceInstanceId, fi.photoId, fi.bboxX, fi.bboxY, fi.bboxWidth, fi.bboxHeight,
               fi.clusterId, fi.personId, p.displayName
        FROM face_instances fi
        LEFT JOIN people p ON p.personId = fi.personId
        WHERE fi.photoId = ?
        ORDER BY fi.bboxX ASC, (fi.bboxY + fi.bboxHeight) DESC;
        """
        var statement: OpaquePointer?
        var rows: [PhotoFaceAnnotation] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        while sqlite3_step(statement) == SQLITE_ROW {
            let faceInstanceId = Int(sqlite3_column_int(statement, 0))
            guard let photoCString = sqlite3_column_text(statement, 1) else { continue }
            let clusterId = sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int(statement, 6))
            let personId = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int(statement, 7))
            let personName = sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(statement, 8))
            rows.append(
                PhotoFaceAnnotation(
                    faceInstanceId: faceInstanceId,
                    photoId: String(cString: photoCString),
                    bboxX: sqlite3_column_double(statement, 2),
                    bboxY: sqlite3_column_double(statement, 3),
                    bboxWidth: sqlite3_column_double(statement, 4),
                    bboxHeight: sqlite3_column_double(statement, 5),
                    clusterId: clusterId,
                    personId: personId,
                    personDisplayName: personName,
                    suggestedPersonId: nil,
                    suggestedDisplayName: nil,
                    suggestedFirstName: nil,
                    suggestedLastName: nil,
                    suggestedMaidenName: nil
                )
            )
        }
        return rows
    }

    func fetchFaceInstanceUnsafe(faceInstanceId: Int) -> FaceInstanceRecord? {
        let sql = """
        SELECT faceInstanceId, photoId, bboxX, bboxY, bboxWidth, bboxHeight,
               quality, embeddingBlob, embeddingVersion, clusterId, personId
        FROM face_instances
        WHERE faceInstanceId = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(faceInstanceId))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Self.faceInstanceRecord(from: statement)
    }

    /// All face rows for a photo, including embeddings (for cross-photo matching).
    func fetchFaceInstancesForPhotoUnsafe(photoId: String) -> [FaceInstanceRecord] {
        let sql = """
        SELECT faceInstanceId, photoId, bboxX, bboxY, bboxWidth, bboxHeight,
               quality, embeddingBlob, embeddingVersion, clusterId, personId
        FROM face_instances
        WHERE photoId = ?
        ORDER BY COALESCE(quality, 0) DESC, faceInstanceId ASC;
        """
        var statement: OpaquePointer?
        var rows: [FaceInstanceRecord] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        while sqlite3_step(statement) == SQLITE_ROW {
            if let row = Self.faceInstanceRecord(from: statement) {
                rows.append(row)
            }
        }
        return rows
    }

    private static func faceInstanceRecord(from statement: OpaquePointer?) -> FaceInstanceRecord? {
        guard let statement,
              let photoCString = sqlite3_column_text(statement, 1) else {
            return nil
        }

        let blobLength = Int(sqlite3_column_bytes(statement, 7))
        let embedding: Data
        if blobLength > 0, let bytes = sqlite3_column_blob(statement, 7) {
            embedding = Data(bytes: bytes, count: blobLength)
        } else {
            embedding = Data()
        }

        let quality = sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, 6)
        let clusterId = sqlite3_column_type(statement, 9) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int(statement, 9))
        let personId = sqlite3_column_type(statement, 10) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int(statement, 10))

        return FaceInstanceRecord(
            faceInstanceId: Int(sqlite3_column_int(statement, 0)),
            photoId: String(cString: photoCString),
            bboxX: sqlite3_column_double(statement, 2),
            bboxY: sqlite3_column_double(statement, 3),
            bboxWidth: sqlite3_column_double(statement, 4),
            bboxHeight: sqlite3_column_double(statement, 5),
            quality: quality,
            embeddingBlob: embedding,
            embeddingVersion: Int(sqlite3_column_int(statement, 8)),
            clusterId: clusterId,
            personId: personId
        )
    }

    func deleteFaceInstancesForPhotoUnsafe(photoId: String) {
        let sql = "DELETE FROM face_instances WHERE photoId = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        sqlite3_step(statement)
    }

    func insertFaceInstanceUnsafe(
        photoId: String,
        bboxX: Double,
        bboxY: Double,
        bboxWidth: Double,
        bboxHeight: Double,
        quality: Double?,
        embeddingBlob: Data,
        embeddingVersion: Int,
        clusterId: Int?,
        personId: Int?,
        createdAt: String
    ) -> Int {
        let sql = """
        INSERT INTO face_instances (
            photoId, bboxX, bboxY, bboxWidth, bboxHeight, quality,
            embeddingBlob, embeddingVersion, clusterId, personId, createdAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 2, bboxX)
        sqlite3_bind_double(statement, 3, bboxY)
        sqlite3_bind_double(statement, 4, bboxWidth)
        sqlite3_bind_double(statement, 5, bboxHeight)
        if let quality {
            sqlite3_bind_double(statement, 6, quality)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        embeddingBlob.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                sqlite3_bind_blob(statement, 7, base, Int32(embeddingBlob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(statement, 7)
            }
        }
        sqlite3_bind_int(statement, 8, Int32(embeddingVersion))
        if let clusterId {
            sqlite3_bind_int(statement, 9, Int32(clusterId))
        } else {
            sqlite3_bind_null(statement, 9)
        }
        if let personId {
            sqlite3_bind_int(statement, 10, Int32(personId))
        } else {
            sqlite3_bind_null(statement, 10)
        }
        sqlite3_bind_text(statement, 11, (createdAt as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_DONE else { return -1 }
        return Int(sqlite3_last_insert_rowid(db))
    }

    func updateFaceInstanceAssignmentUnsafe(
        faceInstanceId: Int,
        clusterId: Int?,
        personId: Int?
    ) {
        let sql = """
        UPDATE face_instances
        SET clusterId = ?, personId = ?
        WHERE faceInstanceId = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        if let clusterId {
            sqlite3_bind_int(statement, 1, Int32(clusterId))
        } else {
            sqlite3_bind_null(statement, 1)
        }
        if let personId {
            sqlite3_bind_int(statement, 2, Int32(personId))
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_int(statement, 3, Int32(faceInstanceId))
        sqlite3_step(statement)
    }

    struct FaceInstanceForClustering: Sendable {
        let faceInstanceId: Int
        let photoId: String
        let embedding: Data
        let quality: Double
    }

    /// IDs only (tiny) so rebuild can page embeddings without OFFSET skew when rows are named mid-pass.
    func fetchUnnamedFaceInstanceIdsForReclusterUnsafe() -> [Int] {
        let sql = """
        SELECT faceInstanceId
        FROM face_instances
        WHERE personId IS NULL
          AND embeddingBlob IS NOT NULL
        ORDER BY COALESCE(quality, 0) DESC, faceInstanceId ASC;
        """
        var statement: OpaquePointer?
        var ids: [Int] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(Int(sqlite3_column_int(statement, 0)))
        }
        return ids
    }

    func fetchFaceInstancesForClusteringByIdsUnsafe(
        ids: [Int]
    ) -> [FaceInstanceForClustering] {
        guard !ids.isEmpty else { return [] }
        var rows: [FaceInstanceForClustering] = []
        rows.reserveCapacity(ids.count)
        let sql = """
        SELECT faceInstanceId, photoId, embeddingBlob, COALESCE(quality, 0)
        FROM face_instances
        WHERE faceInstanceId = ?;
        """
        for id in ids {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(id))
            guard sqlite3_step(statement) == SQLITE_ROW else { continue }
            let faceId = Int(sqlite3_column_int(statement, 0))
            guard let photoCString = sqlite3_column_text(statement, 1) else { continue }
            guard let blob = sqliteBlob(statement, column: 2) else { continue }
            rows.append(
                FaceInstanceForClustering(
                    faceInstanceId: faceId,
                    photoId: String(cString: photoCString),
                    embedding: blob,
                    quality: sqlite3_column_double(statement, 3)
                )
            )
        }
        return rows
    }

    /// Extra exemplars for specific clusters (keeps mid-scan identities in the matching cache).
    func fetchExemplarsForClusterIdsUnsafe(
        clusterIds: [Int],
        limitPerCluster: Int = 3
    ) -> [(clusterId: Int, embedding: Data)] {
        guard !clusterIds.isEmpty, limitPerCluster > 0 else { return [] }
        var results: [(clusterId: Int, embedding: Data)] = []
        var counts: [Int: Int] = [:]
        let sql = """
        SELECT clusterId, embeddingBlob
        FROM face_instances
        WHERE clusterId = ?
          AND embeddingBlob IS NOT NULL
        ORDER BY COALESCE(quality, 0) DESC, faceInstanceId DESC
        LIMIT ?;
        """
        for clusterId in clusterIds {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(clusterId))
            sqlite3_bind_int(statement, 2, Int32(limitPerCluster))
            while sqlite3_step(statement) == SQLITE_ROW {
                let used = counts[clusterId, default: 0]
                guard used < limitPerCluster else { break }
                guard let blob = sqliteBlob(statement, column: 1) else { continue }
                results.append((clusterId, blob))
                counts[clusterId] = used + 1
            }
        }
        return results
    }

    func dissolveUnnamedClustersUnsafe(updatedAt: String) {
        _ = sqlite3_exec(
            db,
            """
            UPDATE face_instances
            SET clusterId = NULL
            WHERE personId IS NULL;

            UPDATE person_clusters
            SET ignored = 1,
                faceCount = 0,
                representativeFaceInstanceId = NULL,
                updatedAt = '\(updatedAt.replacingOccurrences(of: "'", with: "''"))'
            WHERE personId IS NULL;
            """,
            nil,
            nil,
            nil
        )
    }

    func fetchNamedPersonExemplarsUnsafe(
        limitPerPerson: Int = 8,
        maxPeople: Int = 200
    ) -> [(personId: Int, embedding: Data)] {
        // Best-quality faces per named person (gallery for aging). Hard caps keep
        // live matching memory bounded during long library scans.
        let sql = """
        SELECT personId, embeddingBlob, quality
        FROM face_instances
        WHERE personId IS NOT NULL
          AND embeddingBlob IS NOT NULL
          AND length(embeddingBlob) > 0
        ORDER BY personId ASC, COALESCE(quality, 0) DESC, faceInstanceId DESC;
        """
        var statement: OpaquePointer?
        var results: [(personId: Int, embedding: Data)] = []
        var counts: [Int: Int] = [:]
        var peopleSeen = 0
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let personId = Int(sqlite3_column_int(statement, 0))
            let used = counts[personId, default: 0]
            if used == 0 {
                guard peopleSeen < maxPeople else { break }
                peopleSeen += 1
            }
            guard used < limitPerPerson else { continue }
            guard let blob = sqliteBlob(statement, column: 1) else { continue }
            results.append((personId, blob))
            counts[personId] = used + 1
        }
        return results
    }

    /// One representative embedding per unnamed cluster (largest / newest first).
    /// Avoids scanning every face_instance row on each photo during live matching.
    func fetchUnassignedClusterExemplarsUnsafe(
        limitPerCluster: Int = 1,
        maxClusters: Int = 600
    ) -> [(clusterId: Int, embedding: Data)] {
        if limitPerCluster <= 1 {
            let sql = """
            SELECT c.clusterId, fi.embeddingBlob
            FROM person_clusters c
            JOIN face_instances fi ON fi.faceInstanceId = c.representativeFaceInstanceId
            WHERE COALESCE(c.ignored, 0) = 0
              AND c.personId IS NULL
              AND c.faceCount > 0
              AND fi.embeddingBlob IS NOT NULL
            ORDER BY c.faceCount DESC, c.updatedAt DESC
            LIMIT ?;
            """
            var statement: OpaquePointer?
            var results: [(clusterId: Int, embedding: Data)] = []
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(maxClusters))
            while sqlite3_step(statement) == SQLITE_ROW {
                let clusterId = Int(sqlite3_column_int(statement, 0))
                guard let blob = sqliteBlob(statement, column: 1) else { continue }
                results.append((clusterId, blob))
            }
            return results
        }

        let sql = """
        SELECT fi.clusterId, fi.embeddingBlob, COALESCE(fi.quality, 0) AS q
        FROM face_instances fi
        JOIN person_clusters c ON c.clusterId = fi.clusterId
        WHERE COALESCE(c.ignored, 0) = 0
          AND c.personId IS NULL
          AND fi.embeddingBlob IS NOT NULL
          AND fi.clusterId IS NOT NULL
        ORDER BY c.faceCount DESC, c.updatedAt DESC, q DESC, fi.faceInstanceId DESC;
        """
        var statement: OpaquePointer?
        var results: [(clusterId: Int, embedding: Data)] = []
        var counts: [Int: Int] = [:]
        var clustersSeen = 0
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            let clusterId = Int(sqlite3_column_int(statement, 0))
            let used = counts[clusterId, default: 0]
            if used == 0 {
                guard clustersSeen < maxClusters else { break }
                clustersSeen += 1
            }
            guard used < limitPerCluster else { continue }
            guard let blob = sqliteBlob(statement, column: 1) else { continue }
            results.append((clusterId, blob))
            counts[clusterId] = used + 1
        }
        return results
    }

    func fetchUnnamedClusterFaceCountsUnsafe(maxClusters: Int = 600) -> [Int: Int] {
        let sql = """
        SELECT c.clusterId, c.faceCount
        FROM person_clusters c
        WHERE COALESCE(c.ignored, 0) = 0
          AND c.personId IS NULL
          AND c.faceCount > 0
        ORDER BY c.faceCount DESC, c.updatedAt DESC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        var counts: [Int: Int] = [:]
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(maxClusters))
        while sqlite3_step(statement) == SQLITE_ROW {
            counts[Int(sqlite3_column_int(statement, 0))] = Int(sqlite3_column_int(statement, 1))
        }
        return counts
    }

    func fetchUnnamedClusterIdsUnsafe() -> [Int] {
        let sql = """
        SELECT clusterId
        FROM person_clusters
        WHERE COALESCE(ignored, 0) = 0
          AND personId IS NULL
          AND faceCount > 0
        ORDER BY clusterId ASC;
        """
        var statement: OpaquePointer?
        var ids: [Int] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.append(Int(sqlite3_column_int(statement, 0)))
        }
        return ids
    }

    /// Move all faces from `sourceClusterId` into `destinationClusterId`, then mark source ignored.
    func mergeClusterIntoClusterUnsafe(
        sourceClusterId: Int,
        destinationClusterId: Int,
        updatedAt: String
    ) {
        guard sourceClusterId != destinationClusterId else { return }

        let moveSQL = """
        UPDATE face_instances
        SET clusterId = ?
        WHERE clusterId = ?;
        """
        var moveStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, moveSQL, -1, &moveStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(moveStatement, 1, Int32(destinationClusterId))
            sqlite3_bind_int(moveStatement, 2, Int32(sourceClusterId))
            sqlite3_step(moveStatement)
        }
        sqlite3_finalize(moveStatement)

        refreshClusterStatsUnsafe(clusterId: destinationClusterId, updatedAt: updatedAt)

        let clearSQL = """
        UPDATE person_clusters
        SET faceCount = 0,
            representativeFaceInstanceId = NULL,
            ignored = 1,
            updatedAt = ?
        WHERE clusterId = ?;
        """
        var clearStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, clearSQL, -1, &clearStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(clearStatement, 1, (updatedAt as NSString).utf8String, -1, nil)
            sqlite3_bind_int(clearStatement, 2, Int32(sourceClusterId))
            sqlite3_step(clearStatement)
        }
        sqlite3_finalize(clearStatement)
    }

    // MARK: - Clusters

    func createClusterUnsafe(
        representativeFaceInstanceId: Int?,
        createdAt: String
    ) -> Int {
        let sql = """
        INSERT INTO person_clusters (
            representativeFaceInstanceId, faceCount, personId, ignored, createdAt, updatedAt
        ) VALUES (?, 0, NULL, 0, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        if let representativeFaceInstanceId {
            sqlite3_bind_int(statement, 1, Int32(representativeFaceInstanceId))
        } else {
            sqlite3_bind_null(statement, 1)
        }
        sqlite3_bind_text(statement, 2, (createdAt as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (createdAt as NSString).utf8String, -1, nil)
        guard sqlite3_step(statement) == SQLITE_DONE else { return -1 }
        return Int(sqlite3_last_insert_rowid(db))
    }

    func refreshClusterStatsUnsafe(clusterId: Int, updatedAt: String) {
        let sql = """
        UPDATE person_clusters
        SET faceCount = (
                SELECT COUNT(*) FROM face_instances WHERE clusterId = ?
            ),
            representativeFaceInstanceId = (
                SELECT faceInstanceId
                FROM face_instances
                WHERE clusterId = ?
                ORDER BY COALESCE(quality, 0) DESC, faceInstanceId DESC
                LIMIT 1
            ),
            updatedAt = ?
        WHERE clusterId = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(clusterId))
        sqlite3_bind_int(statement, 2, Int32(clusterId))
        sqlite3_bind_text(statement, 3, (updatedAt as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 4, Int32(clusterId))
        sqlite3_step(statement)
    }

    func assignClusterToPersonUnsafe(clusterId: Int, personId: Int, updatedAt: String) {
        let sql = """
        UPDATE person_clusters
        SET personId = ?, ignored = 0, updatedAt = ?
        WHERE clusterId = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(personId))
        sqlite3_bind_text(statement, 2, (updatedAt as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 3, Int32(clusterId))
        sqlite3_step(statement)

        let facesSQL = """
        UPDATE face_instances
        SET personId = ?
        WHERE clusterId = ?;
        """
        var facesStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, facesSQL, -1, &facesStatement, nil) == SQLITE_OK {
            sqlite3_bind_int(facesStatement, 1, Int32(personId))
            sqlite3_bind_int(facesStatement, 2, Int32(clusterId))
            sqlite3_step(facesStatement)
        }
        sqlite3_finalize(facesStatement)
    }

    func ignoreClusterUnsafe(clusterId: Int, updatedAt: String) {
        let sql = """
        UPDATE person_clusters
        SET ignored = 1, updatedAt = ?
        WHERE clusterId = ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (updatedAt as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(clusterId))
        sqlite3_step(statement)
    }

    func fetchPhotoIdsForClusterUnsafe(clusterId: Int) -> [String] {
        let sql = """
        SELECT DISTINCT photoId
        FROM face_instances
        WHERE clusterId = ?
        ORDER BY photoId ASC;
        """
        var statement: OpaquePointer?
        var ids: [String] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(clusterId))
        while sqlite3_step(statement) == SQLITE_ROW {
            if let cString = sqlite3_column_text(statement, 0) {
                ids.append(String(cString: cString))
            }
        }
        return ids
    }

    func fetchUnnamedClustersUnsafe(limit: Int = 90, minimumPhotoCount: Int = 2) -> [PersonClusterRecord] {
        // Prefer a large, sharp face for the avatar — quality-only picks often chose tiny/blurry crops.
        // Hide 1-photo fragments so the grid shows real people with meaningful photo counts.
        let sql = """
        SELECT
            c.clusterId,
            best.faceInstanceId,
            c.faceCount,
            (
                SELECT COUNT(DISTINCT fi2.photoId)
                FROM face_instances fi2
                WHERE fi2.clusterId = c.clusterId
            ) AS photoCount,
            c.personId,
            c.ignored,
            best.photoId,
            best.bboxX,
            best.bboxY,
            best.bboxWidth,
            best.bboxHeight
        FROM person_clusters c
        JOIN (
            SELECT
                fi.clusterId,
                fi.faceInstanceId,
                fi.photoId,
                fi.bboxX,
                fi.bboxY,
                fi.bboxWidth,
                fi.bboxHeight,
                ROW_NUMBER() OVER (
                    PARTITION BY fi.clusterId
                    ORDER BY CASE
                                 WHEN (fi.bboxWidth * fi.bboxHeight) >= 0.025 THEN 0
                                 ELSE 1
                             END ASC,
                             (fi.bboxWidth * fi.bboxHeight) DESC,
                             COALESCE(fi.quality, 0) DESC,
                             fi.faceInstanceId DESC
                ) AS rn
            FROM face_instances fi
            WHERE fi.clusterId IS NOT NULL
        ) AS best ON best.clusterId = c.clusterId AND best.rn = 1
        WHERE COALESCE(c.ignored, 0) = 0
          AND c.personId IS NULL
          AND c.faceCount > 0
          AND (
                SELECT COUNT(DISTINCT fi3.photoId)
                FROM face_instances fi3
                WHERE fi3.clusterId = c.clusterId
              ) >= ?
        ORDER BY photoCount DESC, c.faceCount DESC, c.updatedAt DESC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        var records: [PersonClusterRecord] = []
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(minimumPhotoCount))
        sqlite3_bind_int(statement, 2, Int32(limit))
        while sqlite3_step(statement) == SQLITE_ROW {
            let representativeId: Int? = sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int(statement, 1))
            let personId: Int? = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil
                : Int(sqlite3_column_int(statement, 4))
            let photoId: String? = sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(statement, 6))
            let hasBox = sqlite3_column_type(statement, 7) != SQLITE_NULL
                && sqlite3_column_type(statement, 8) != SQLITE_NULL
                && sqlite3_column_type(statement, 9) != SQLITE_NULL
                && sqlite3_column_type(statement, 10) != SQLITE_NULL
            let box: CGRect? = hasBox
                ? CGRect(
                    x: sqlite3_column_double(statement, 7),
                    y: sqlite3_column_double(statement, 8),
                    width: sqlite3_column_double(statement, 9),
                    height: sqlite3_column_double(statement, 10)
                )
                : nil
            let faceCount = Int(sqlite3_column_int(statement, 2))
            let photoCount = Int(sqlite3_column_int(statement, 3))
            records.append(
                PersonClusterRecord(
                    clusterId: Int(sqlite3_column_int(statement, 0)),
                    representativeFaceInstanceId: representativeId,
                    faceCount: faceCount,
                    photoCount: max(photoCount, 0),
                    personId: personId,
                    ignored: sqlite3_column_int(statement, 5) != 0,
                    representativePhotoId: photoId,
                    faceBoundingBox: box
                )
            )
        }
        return records
    }

    private func sqliteBlob(_ statement: OpaquePointer?, column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        return Data(bytes: bytes, count: count)
    }
}
