import Foundation
import SQLite3

/// Applies/removes AI holiday tags from `event_occasion_scores` using pre/post object thresholds.
final class OccasionHolidayTagService {

    struct BestHolidayScore: Sendable {
        let eventId: Int
        let occasionId: Int
        let occasionKey: String
        let displayName: String
        let scoringYear: Int
        let totalScore: Double
        let objectScore: Double
        let confidence: String?
        let objectRecognitionCompleted: Bool
    }

    private let database: DatabaseManager
    private let eventTags: EventTagRepository
    private let tuning: () -> EventTuningSettings

    init(
        database: DatabaseManager,
        eventTags: EventTagRepository,
        tuning: @escaping () -> EventTuningSettings
    ) {
        self.database = database
        self.eventTags = eventTags
        self.tuning = tuning
    }

    func syncHolidayTagsFromScores() -> HolidayTagApplyResult {
        database.sync {
            syncHolidayTagsFromScoresUnsafe()
        }
    }

    func syncHolidayTagForEventUnsafe(eventId: Int) {
        let best = fetchBestHolidayScoreForEventUnsafe(eventId: eventId)
        syncHolidayTagUnsafe(eventId: eventId, best: best)
    }

    func syncHolidayTagsFromScoresUnsafe() -> HolidayTagApplyResult {
        let bestByEvent = fetchBestHolidayScoresPerEventUnsafe()
        var candidateEventIds = Set(bestByEvent.keys)
        for eventId in eventTags.fetchEventIdsWithAIHolidayTagsUnsafe() {
            candidateEventIds.insert(eventId)
        }

        var applied = 0
        var updated = 0
        var removed = 0
        var skippedUserOwned = 0

        for eventId in candidateEventIds {
            let outcome = syncHolidayTagUnsafe(eventId: eventId, best: bestByEvent[eventId])
            switch outcome {
            case .applied:
                applied += 1
            case .updated:
                updated += 1
            case .removed:
                removed += 1
            case .skippedUserOwned:
                skippedUserOwned += 1
            case .unchanged:
                break
            }
        }

        return HolidayTagApplyResult(
            applied: applied,
            updated: updated,
            removed: removed,
            skippedUserOwned: skippedUserOwned
        )
    }

    private enum HolidayTagSyncOutcome {
        case applied
        case updated
        case removed
        case skippedUserOwned
        case unchanged
    }

    @discardableResult
    private func syncHolidayTagUnsafe(
        eventId: Int,
        best: BestHolidayScore?
    ) -> HolidayTagSyncOutcome {
        if eventTags.isAIHolidayTagRejectedUnsafe(eventId: eventId) {
            return .unchanged
        }

        if let existing = eventTags.fetchHolidayTagRowUnsafe(eventId: eventId),
           existing.source == .user {
            return .skippedUserOwned
        }

        guard let best else {
            if eventTags.fetchHolidayTagRowUnsafe(eventId: eventId)?.source == .ai {
                eventTags.deleteAIHolidayTagUnsafe(eventId: eventId)
                return .removed
            }
            return .unchanged
        }

        let phase = OccasionScoringThresholds.appliedPhase(
            objectRecognitionCompleted: best.objectRecognitionCompleted,
            objectScore: best.objectScore
        )
        let qualifies = OccasionScoringThresholds.meetsHolidayTag(
            confidence: best.confidence,
            totalScore: best.totalScore,
            objectRecognitionCompleted: best.objectRecognitionCompleted,
            objectScore: best.objectScore,
            settings: tuning()
        )

        let tagValue = Self.holidayTagValue(
            occasionKey: best.occasionKey,
            displayName: best.displayName
        )

        if qualifies {
            let hadAI = eventTags.fetchHolidayTagRowUnsafe(eventId: eventId)?.source == .ai
            eventTags.upsertAIHolidayTagUnsafe(
                eventId: eventId,
                tagValue: tagValue,
                appliedPhase: phase,
                occasionId: best.occasionId,
                scoringYear: best.scoringYear,
                confidence: best.confidence,
                totalScore: best.totalScore
            )
            mirrorAITagToTripParentIfNeeded(
                childEventId: eventId,
                tagValue: tagValue,
                appliedPhase: phase,
                occasionId: best.occasionId,
                scoringYear: best.scoringYear,
                confidence: best.confidence,
                totalScore: best.totalScore
            )
            return hadAI ? .updated : .applied
        }

        if eventTags.fetchHolidayTagRowUnsafe(eventId: eventId)?.source == .ai {
            eventTags.deleteAIHolidayTagUnsafe(eventId: eventId)
            return .removed
        }

        return .unchanged
    }

    static func holidayTagValue(occasionKey: String, displayName: String) -> String {
        switch occasionKey {
        case "christmas": return "Christmas"
        case "halloween": return "Halloween"
        case "easter": return "Easter"
        case "thanksgiving": return "Thanksgiving"
        case "mothers_day": return "Mother's Day"
        case "fathers_day": return "Father's Day"
        default:
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? occasionKey : trimmed
        }
    }

    private func mirrorAITagToTripParentIfNeeded(
        childEventId: Int,
        tagValue: String,
        appliedPhase: EventTagAppliedPhase,
        occasionId: Int,
        scoringYear: Int,
        confidence: String?,
        totalScore: Double
    ) {
        guard let parentEventId = fetchParentEventIdUnsafe(eventId: childEventId) else {
            return
        }
        if let existing = eventTags.fetchHolidayTagRowUnsafe(eventId: parentEventId),
           existing.source == .user {
            return
        }
        eventTags.upsertAIHolidayTagUnsafe(
            eventId: parentEventId,
            tagValue: tagValue,
            appliedPhase: appliedPhase,
            occasionId: occasionId,
            scoringYear: scoringYear,
            confidence: confidence,
            totalScore: totalScore
        )
    }

    private func fetchParentEventIdUnsafe(eventId: Int) -> Int? {
        let sql = """
        SELECT parentEventId
        FROM events
        WHERE eventId = ?
          AND parentEventId IS NOT NULL
          AND isDeleted = 0
        LIMIT 1;
        """

        var statement: OpaquePointer?

        if sqlite3_prepare_v2(database.connection, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if sqlite3_step(statement) == SQLITE_ROW {
                let parentId = Int(sqlite3_column_int(statement, 0))
                sqlite3_finalize(statement)
                return parentId
            }
        }

        sqlite3_finalize(statement)
        return nil
    }

    private func fetchBestHolidayScoresPerEventUnsafe() -> [Int: BestHolidayScore] {
        var bestByEvent: [Int: BestHolidayScore] = [:]

        for candidate in fetchHolidayScoreCandidatesUnsafe(eventId: nil) {
            if let existing = bestByEvent[candidate.eventId] {
                bestByEvent[candidate.eventId] = preferredHolidayScore(existing, candidate)
            } else {
                bestByEvent[candidate.eventId] = candidate
            }
        }

        return bestByEvent
    }

    private func fetchBestHolidayScoreForEventUnsafe(eventId: Int) -> BestHolidayScore? {
        var best: BestHolidayScore?
        for candidate in fetchHolidayScoreCandidatesUnsafe(eventId: eventId) {
            if let existing = best {
                best = preferredHolidayScore(existing, candidate)
            } else {
                best = candidate
            }
        }
        return best
    }

    private func preferredHolidayScore(
        _ existing: BestHolidayScore,
        _ candidate: BestHolidayScore
    ) -> BestHolidayScore {
        if candidate.totalScore > existing.totalScore {
            return candidate
        }
        if candidate.totalScore == existing.totalScore,
           OccasionScoringThresholds.confidenceRank(candidate.confidence)
               > OccasionScoringThresholds.confidenceRank(existing.confidence) {
            return candidate
        }
        return existing
    }

    private func fetchHolidayScoreCandidatesUnsafe(eventId: Int?) -> [BestHolidayScore] {
        var sql = """
        SELECT
            s.eventId,
            s.occasionId,
            s.year,
            s.totalScore,
            s.objectScore,
            s.confidence,
            o.occasionKey,
            o.name,
            COALESCE(e.objectRecognitionCompleted, 0)
        FROM event_occasion_scores s
        JOIN occasions o ON o.occasionId = s.occasionId
        JOIN events e ON e.eventId = s.eventId
        WHERE o.occasionType = 'holiday'
          AND COALESCE(s.isRejected, 0) = 0
          AND COALESCE(o.isEnabled, 1) = 1
          AND e.isDeleted = 0
        """

        if eventId != nil {
            sql += " AND s.eventId = ?"
        }
        sql += ";"

        var statement: OpaquePointer?
        var rows: [BestHolidayScore] = []

        if sqlite3_prepare_v2(database.connection, sql, -1, &statement, nil) == SQLITE_OK {
            if let eventId {
                sqlite3_bind_int(statement, 1, Int32(eventId))
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    BestHolidayScore(
                        eventId: Int(sqlite3_column_int(statement, 0)),
                        occasionId: Int(sqlite3_column_int(statement, 1)),
                        occasionKey: String(cString: sqlite3_column_text(statement, 6)),
                        displayName: String(cString: sqlite3_column_text(statement, 7)),
                        scoringYear: Int(sqlite3_column_int(statement, 2)),
                        totalScore: sqlite3_column_double(statement, 3),
                        objectScore: sqlite3_column_double(statement, 4),
                        confidence: sqliteOptionalText(statement, column: 5),
                        objectRecognitionCompleted: sqlite3_column_int(statement, 8) != 0
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
