import Foundation
import SQLite3

/// Ground-up bride/groom finder: Vision photo labels + face prominence, plus couple-only photo.
final class WeddingCoupleResolutionService {

    private let database: DatabaseManager
    private let eventTags: EventTagRepository

    private let minimumRoleScore = 0.000_1

    init(database: DatabaseManager, eventTags: EventTagRepository) {
        self.database = database
        self.eventTags = eventTags
    }

    private var db: OpaquePointer? { database.connection }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if database.isOnQueue {
            return try work()
        }
        return try database.sync(work)
    }

    @discardableResult
    func resolveAndApply(eventId: Int) -> WeddingCoupleResolution {
        sync { resolveAndApplyUnsafe(eventId: eventId) }
    }

    func findCouplePhotoId(eventId: Int) -> String? {
        sync { findCouplePhotoIdUnsafe(eventId: eventId) }
    }

    func weddingCouplePhotoId(eventId: Int) -> String? {
        sync { fetchStoredCouplePhotoIdUnsafe(eventId: eventId) }
    }

    // MARK: - Apply

    private func resolveAndApplyUnsafe(eventId: Int) -> WeddingCoupleResolution {
        guard eventId > 0 else {
            return WeddingCoupleResolution(
                couplePhotoId: nil,
                bride: nil,
                groom: nil,
                brideTagWritten: false,
                groomTagWritten: false
            )
        }

        let couplePhotoId = findCouplePhotoIdUnsafe(eventId: eventId)
        updateStoredCouplePhotoIdUnsafe(eventId: eventId, photoId: couplePhotoId)

        let scored = scoreBrideAndGroomUnsafe(eventId: eventId, couplePhotoId: couplePhotoId)

        var bride = scored.bride
        var groom = scored.groom

        // Prefer couple-photo faces when names are missing.
        if let couplePhotoId,
           (bride?.hasDisplayName != true || groom?.hasDisplayName != true) {
            let faces = facesOnPhotoUnsafe(photoId: couplePhotoId)
            if faces.count == 2 {
                let ordered = faces.sorted {
                    ($0.bboxWidth * $0.bboxHeight) > ($1.bboxWidth * $1.bboxHeight)
                }
                if bride?.hasDisplayName != true {
                    bride = candidateFromFaceUnsafe(ordered[0], score: bride?.score ?? 0)
                }
                if groom?.hasDisplayName != true {
                    // Prefer the other face for groom when both missing.
                    let groomFace = (bride?.faceInstanceId == ordered[0].faceInstanceId)
                        ? ordered[1]
                        : ordered[0]
                    if groom?.faceInstanceId != bride?.faceInstanceId
                        || groom?.hasDisplayName != true {
                        groom = candidateFromFaceUnsafe(groomFace, score: groom?.score ?? 0)
                    }
                }
                // Ensure distinct faces when both unnamed.
                if let b = bride, let g = groom,
                   b.faceInstanceId == g.faceInstanceId,
                   faces.count == 2 {
                    let other = faces.first { $0.faceInstanceId != b.faceInstanceId }
                    if let other {
                        groom = candidateFromFaceUnsafe(other, score: g.score)
                    }
                }
            }
        }

        let written = eventTags.applyAIWeddingCouplePeopleUnsafe(
            eventId: eventId,
            brideName: bride?.hasDisplayName == true ? bride?.displayName : nil,
            groomName: groom?.hasDisplayName == true ? groom?.displayName : nil
        )

        return WeddingCoupleResolution(
            couplePhotoId: couplePhotoId,
            bride: bride,
            groom: groom,
            brideTagWritten: written.brideWritten,
            groomTagWritten: written.groomWritten
        )
    }

    // MARK: - Couple photo

    /// Photos with Vision bride+groom and exactly two faces; favorite first, then largest faces.
    private func findCouplePhotoIdUnsafe(eventId: Int) -> String? {
        let sql = """
        SELECT
            p.id,
            COALESCE(p.isFavorite, 0) AS fav,
            COALESCE(
                (SELECT SUM(fi.bboxWidth * fi.bboxHeight)
                 FROM face_instances fi
                 WHERE fi.photoId = p.id),
                0
            ) AS faceAreaSum,
            COALESCE(bride.confidence, 0) + COALESCE(groom.confidence, 0) AS tagScore,
            p.creationDate
        FROM photos p
        JOIN photo_events pe ON pe.photoId = p.id
        JOIN photo_object_tags bride
            ON bride.photoId = p.id AND LOWER(bride.objectKey) = 'bride'
        JOIN photo_object_tags groom
            ON groom.photoId = p.id AND LOWER(groom.objectKey) = 'groom'
        WHERE (
            pe.eventId = ?
            OR pe.eventId IN (
                SELECT child.eventId FROM events child
                WHERE child.parentEventId = ? AND child.isDeleted = 0
            )
        )
          AND p.isDeleted = 0
          AND COALESCE(p.mediaType, 1) != 2
          AND COALESCE(pe.manuallyExcluded, 0) = 0
          AND (
            SELECT COUNT(*) FROM face_instances fi2 WHERE fi2.photoId = p.id
          ) = 2
        ORDER BY
            fav DESC,
            faceAreaSum DESC,
            tagScore DESC,
            p.creationDate DESC
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var photoId: String?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_int(statement, 2, Int32(eventId))
            if sqlite3_step(statement) == SQLITE_ROW,
               let cString = sqlite3_column_text(statement, 0) {
                photoId = String(cString: cString)
            }
        }
        sqlite3_finalize(statement)
        return photoId
    }

    private func fetchStoredCouplePhotoIdUnsafe(eventId: Int) -> String? {
        let sql = "SELECT weddingCouplePhotoId FROM events WHERE eventId = ? LIMIT 1;"
        var statement: OpaquePointer?
        var photoId: String?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if sqlite3_step(statement) == SQLITE_ROW {
                photoId = sqliteOptionalText(statement, column: 0)
            }
        }
        sqlite3_finalize(statement)
        return photoId
    }

    private func updateStoredCouplePhotoIdUnsafe(eventId: Int, photoId: String?) {
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
        UPDATE events
        SET weddingCouplePhotoId = ?, updatedAt = ?
        WHERE eventId = ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if let photoId, !photoId.isEmpty {
                sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 1)
            }
            sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 3, Int32(eventId))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Scoring

    private struct FaceRow {
        let faceInstanceId: Int
        let photoId: String
        let bboxWidth: Double
        let bboxHeight: Double
        let quality: Double
        let clusterId: Int?
        let personId: Int?
        let displayName: String?
        let visionConfidence: Double
    }

    private struct CandidateKey: Hashable {
        let personId: Int?
        let clusterId: Int?
        let faceInstanceId: Int?

        static func from(_ face: FaceRow) -> CandidateKey {
            if let personId = face.personId, personId > 0 {
                return CandidateKey(personId: personId, clusterId: nil, faceInstanceId: nil)
            }
            if let clusterId = face.clusterId, clusterId > 0 {
                return CandidateKey(personId: nil, clusterId: clusterId, faceInstanceId: nil)
            }
            return CandidateKey(
                personId: nil,
                clusterId: nil,
                faceInstanceId: face.faceInstanceId
            )
        }
    }

    private struct Acc {
        var score: Double = 0
        var photoHits: Set<String> = []
        var bestFace: FaceRow?
        var personId: Int?
        var displayName: String?
        var clusterId: Int?
    }

    private func scoreBrideAndGroomUnsafe(
        eventId: Int,
        couplePhotoId: String?
    ) -> (bride: WeddingCoupleRoleCandidate?, groom: WeddingCoupleRoleCandidate?) {
        let brideFaces = roleFacesUnsafe(eventId: eventId, objectKey: "bride")
        let groomFaces = roleFacesUnsafe(eventId: eventId, objectKey: "groom")

        var brideRanked = rankCandidates(from: brideFaces)
        var groomRanked = rankCandidates(from: groomFaces)

        // Weak fallback: all event faces if a role has no Vision photos.
        if brideRanked.isEmpty {
            brideRanked = rankCandidates(from: allEventFacesUnsafe(eventId: eventId, confidence: 0.25))
        }
        if groomRanked.isEmpty {
            groomRanked = rankCandidates(from: allEventFacesUnsafe(eventId: eventId, confidence: 0.25))
        }

        var bride = brideRanked.first
        var groom = groomRanked.first

        if let b = bride, let g = groom, sameCandidate(b.key, g.key) {
            let brideMargin = (brideRanked.first?.score ?? 0) - (brideRanked.dropFirst().first?.score ?? 0)
            let groomMargin = (groomRanked.first?.score ?? 0) - (groomRanked.dropFirst().first?.score ?? 0)
            if brideMargin >= groomMargin {
                groom = groomRanked.dropFirst().first
            } else {
                bride = brideRanked.dropFirst().first
            }
        }

        _ = couplePhotoId
        return (
            bride: bride.map { toCandidate($0) },
            groom: groom.map { toCandidate($0) }
        )
    }

    private func rankCandidates(
        from faces: [FaceRow]
    ) -> [(key: CandidateKey, score: Double, face: FaceRow, personId: Int?, displayName: String?, clusterId: Int?)] {
        var acc: [CandidateKey: Acc] = [:]
        for face in faces {
            let key = CandidateKey.from(face)
            var entry = acc[key] ?? Acc()
            let prominence = max(face.bboxWidth * face.bboxHeight, 0.000_1)
                * max(face.quality, 0.05)
            entry.score += face.visionConfidence * prominence
            entry.photoHits.insert(face.photoId)
            if entry.bestFace == nil
                || prominence > (entry.bestFace!.bboxWidth * entry.bestFace!.bboxHeight)
                    * max(entry.bestFace!.quality, 0.05) {
                entry.bestFace = face
            }
            if let personId = face.personId, personId > 0 {
                entry.personId = personId
            }
            if let name = face.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                entry.displayName = name
            }
            if let clusterId = face.clusterId, clusterId > 0 {
                entry.clusterId = clusterId
            }
            acc[key] = entry
        }

        return acc.compactMap { key, value -> (CandidateKey, Double, FaceRow, Int?, String?, Int?)? in
            guard let best = value.bestFace else { return nil }
            let boosted = value.score + log(1.0 + Double(value.photoHits.count))
            guard boosted >= minimumRoleScore else { return nil }
            return (key, boosted, best, value.personId, value.displayName, value.clusterId)
        }
        .sorted { $0.1 > $1.1 }
        .map { ($0.0, $0.1, $0.2, $0.3, $0.4, $0.5) }
    }

    private func toCandidate(
        _ row: (key: CandidateKey, score: Double, face: FaceRow, personId: Int?, displayName: String?, clusterId: Int?)
    ) -> WeddingCoupleRoleCandidate {
        WeddingCoupleRoleCandidate(
            personId: row.personId ?? row.face.personId,
            displayName: row.displayName ?? row.face.displayName,
            faceInstanceId: row.face.faceInstanceId,
            clusterId: row.clusterId ?? row.face.clusterId,
            score: row.score
        )
    }

    private func sameCandidate(_ a: CandidateKey, _ b: CandidateKey) -> Bool {
        if let ap = a.personId, let bp = b.personId, ap > 0, bp > 0 {
            return ap == bp
        }
        if let ac = a.clusterId, let bc = b.clusterId, ac > 0, bc > 0 {
            return ac == bc
        }
        if let af = a.faceInstanceId, let bf = b.faceInstanceId {
            return af == bf
        }
        return false
    }

    private func candidateFromFaceUnsafe(_ face: FaceRow, score: Double) -> WeddingCoupleRoleCandidate {
        WeddingCoupleRoleCandidate(
            personId: face.personId,
            displayName: face.displayName,
            faceInstanceId: face.faceInstanceId,
            clusterId: face.clusterId,
            score: score
        )
    }

    private func roleFacesUnsafe(eventId: Int, objectKey: String) -> [FaceRow] {
        let sql = """
        SELECT
            fi.faceInstanceId,
            fi.photoId,
            fi.bboxWidth,
            fi.bboxHeight,
            COALESCE(fi.quality, 0),
            fi.clusterId,
            fi.personId,
            p.displayName,
            pot.confidence
        FROM photo_events pe
        JOIN photos ph ON ph.id = pe.photoId AND ph.isDeleted = 0
        JOIN photo_object_tags pot
            ON pot.photoId = ph.id AND LOWER(pot.objectKey) = LOWER(?)
        JOIN face_instances fi ON fi.photoId = ph.id
        LEFT JOIN people p ON p.personId = fi.personId
        WHERE (
            pe.eventId = ?
            OR pe.eventId IN (
                SELECT child.eventId FROM events child
                WHERE child.parentEventId = ? AND child.isDeleted = 0
            )
        )
          AND COALESCE(pe.manuallyExcluded, 0) = 0
          AND COALESCE(ph.mediaType, 1) != 2;
        """
        return fetchFaceRowsUnsafe(sql: sql, bind: { statement in
            sqlite3_bind_text(statement, 1, (objectKey as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, Int32(eventId))
            sqlite3_bind_int(statement, 3, Int32(eventId))
        })
    }

    private func allEventFacesUnsafe(eventId: Int, confidence: Double) -> [FaceRow] {
        let sql = """
        SELECT
            fi.faceInstanceId,
            fi.photoId,
            fi.bboxWidth,
            fi.bboxHeight,
            COALESCE(fi.quality, 0),
            fi.clusterId,
            fi.personId,
            p.displayName,
            ?
        FROM photo_events pe
        JOIN photos ph ON ph.id = pe.photoId AND ph.isDeleted = 0
        JOIN face_instances fi ON fi.photoId = ph.id
        LEFT JOIN people p ON p.personId = fi.personId
        WHERE (
            pe.eventId = ?
            OR pe.eventId IN (
                SELECT child.eventId FROM events child
                WHERE child.parentEventId = ? AND child.isDeleted = 0
            )
        )
          AND COALESCE(pe.manuallyExcluded, 0) = 0
          AND COALESCE(ph.mediaType, 1) != 2;
        """
        return fetchFaceRowsUnsafe(sql: sql, bind: { statement in
            sqlite3_bind_double(statement, 1, confidence)
            sqlite3_bind_int(statement, 2, Int32(eventId))
            sqlite3_bind_int(statement, 3, Int32(eventId))
        })
    }

    private func facesOnPhotoUnsafe(photoId: String) -> [FaceRow] {
        let sql = """
        SELECT
            fi.faceInstanceId,
            fi.photoId,
            fi.bboxWidth,
            fi.bboxHeight,
            COALESCE(fi.quality, 0),
            fi.clusterId,
            fi.personId,
            p.displayName,
            1.0
        FROM face_instances fi
        LEFT JOIN people p ON p.personId = fi.personId
        WHERE fi.photoId = ?;
        """
        return fetchFaceRowsUnsafe(sql: sql, bind: { statement in
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
        })
    }

    private func fetchFaceRowsUnsafe(
        sql: String,
        bind: (OpaquePointer?) -> Void
    ) -> [FaceRow] {
        var statement: OpaquePointer?
        var rows: [FaceRow] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            bind(statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                let faceInstanceId = Int(sqlite3_column_int(statement, 0))
                guard let photoC = sqlite3_column_text(statement, 1) else { continue }
                let clusterId = sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(statement, 5))
                let personId = sqlite3_column_type(statement, 6) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(statement, 6))
                let displayName = sqliteOptionalText(statement, column: 7)
                rows.append(
                    FaceRow(
                        faceInstanceId: faceInstanceId,
                        photoId: String(cString: photoC),
                        bboxWidth: sqlite3_column_double(statement, 2),
                        bboxHeight: sqlite3_column_double(statement, 3),
                        quality: sqlite3_column_double(statement, 4),
                        clusterId: clusterId,
                        personId: personId,
                        displayName: displayName,
                        visionConfidence: max(0, sqlite3_column_double(statement, 8))
                    )
                )
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    private func sqliteOptionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: cString)
    }
}
