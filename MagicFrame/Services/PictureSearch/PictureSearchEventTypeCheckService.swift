import Foundation
import SQLite3

/// Scores candidate events for a picture search's target event type, then applies AI people tags.
final class PictureSearchEventTypeCheckService {

    private let database: DatabaseManager
    private let eventTags: EventTagRepository

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

    func checkEventTypes(
        runReport: PictureSearchRunReport,
        definition: PictureSearchDefinition,
        scoreCard: PictureSearchEventScoreCardSettings,
        floatingHoliday: FloatingHolidayDefinition? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> PictureSearchEventTypeCheckReport {
        sync {
            checkEventTypesUnsafe(
                runReport: runReport,
                definition: definition,
                scoreCard: scoreCard,
                floatingHoliday: floatingHoliday,
                progress: progress
            )
        }
    }

    private func checkEventTypesUnsafe(
        runReport: PictureSearchRunReport,
        definition: PictureSearchDefinition,
        scoreCard: PictureSearchEventScoreCardSettings,
        floatingHoliday: FloatingHolidayDefinition?,
        progress: (@Sendable (Int, Int) -> Void)?
    ) -> PictureSearchEventTypeCheckReport {
        let eventIds = runReport.candidateEventIds
        let targetType = definition.targetEventType.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedType = targetType.isEmpty ? "Wedding" : targetType

        var scores: [PictureSearchEventTypeScore] = []
        var groomTagsWritten = 0
        var brideTagsWritten = 0
        let now = ISO8601DateFormatter().string(from: Date())

        for (index, eventId) in eventIds.enumerated() {
            progress?(index + 1, eventIds.count)

            let score: PictureSearchEventTypeScore
            switch normalizedType.lowercased() {
            case "wedding":
                score = scoreWeddingUnsafe(
                    eventId: eventId,
                    runId: runReport.pictureSearchRunId,
                    scoreCard: scoreCard,
                    floatingHoliday: floatingHoliday
                )
            default:
                score = scoreGenericUnsafe(
                    eventId: eventId,
                    targetEventType: normalizedType,
                    runId: runReport.pictureSearchRunId,
                    scoreCard: scoreCard,
                    floatingHoliday: floatingHoliday
                )
            }

            persistEventScoreUnsafe(
                runId: runReport.pictureSearchRunId,
                score: score,
                scoredAt: now
            )

            let targetField = definition.targetAttributeField
            let isWedding = targetField == .milestoneType
                && normalizedType.compare("Wedding", options: .caseInsensitive) == .orderedSame

            let tagRejected = eventTags.isAIAttributeTagValueRejectedUnsafe(
                eventId: eventId,
                category: targetField.tagCategory,
                tagValue: normalizedType
            )

            // User rejected this AI tag — keep scores for the run, but do not re-apply tags.
            if !tagRejected, scoreCard.meetsAIThreshold(totalScore: score.totalScore) {
                if isWedding {
                    let written = eventTags.upsertAIEventMainPeopleUnsafe(
                        eventId: eventId,
                        primaryName: score.likelyGroom,
                        secondaryName: score.likelyBride,
                        totalScore: score.totalScore
                    )
                    groomTagsWritten += written.primaryWritten ? 1 : 0
                    brideTagsWritten += written.secondaryWritten ? 1 : 0
                }

                eventTags.upsertAIAttributeTagUnsafe(
                    eventId: eventId,
                    field: targetField,
                    tagValue: normalizedType,
                    totalScore: score.totalScore
                )
                if isWedding {
                    // Older scoring wrote Wedding under eventType; keep a single Milestone chip.
                    eventTags.deleteMisclassifiedEventTypeForMilestoneUnsafe(
                        eventId: eventId,
                        tagValue: "Wedding"
                    )
                }
            }

            scores.append(score)
        }

        scores.sort { $0.totalScore > $1.totalScore }

        return PictureSearchEventTypeCheckReport(
            pictureSearchRunId: runReport.pictureSearchRunId,
            targetEventType: normalizedType,
            eventScores: scores,
            groomTagsWritten: groomTagsWritten,
            brideTagsWritten: brideTagsWritten
        )
    }

    // MARK: - Wedding / generic

    private func scoreWeddingUnsafe(
        eventId: Int,
        runId: Int,
        scoreCard: PictureSearchEventScoreCardSettings,
        floatingHoliday: FloatingHolidayDefinition?
    ) -> PictureSearchEventTypeScore {
        let visionScore = visionEvidenceScoreUnsafe(
            eventId: eventId,
            runId: runId,
            tags: scoreCard.visionTags
        )
        let dateScore = dateEvidenceScoreUnsafe(
            eventId: eventId,
            scoreCard: scoreCard,
            floatingHoliday: floatingHoliday
        )
        let locationScore = locationEvidenceScoreUnsafe(
            eventId: eventId,
            locations: scoreCard.locations
        )
        let peopleScore = peopleEvidenceScoreUnsafe(
            eventId: eventId,
            people: scoreCard.people
        )
        let likelyGroom = mostFrequentPersonForVisionTagUnsafe(
            eventId: eventId,
            objectKey: "Groom"
        )
        let likelyBride = mostFrequentPersonForVisionTagUnsafe(
            eventId: eventId,
            objectKey: "Bride"
        )

        return PictureSearchEventTypeScore(
            eventId: eventId,
            targetEventType: "Wedding",
            visionScore: visionScore,
            dateScore: dateScore,
            locationScore: locationScore,
            peopleScore: peopleScore,
            totalScore: visionScore + dateScore + locationScore + peopleScore,
            likelyGroom: likelyGroom,
            likelyBride: likelyBride
        )
    }

    private func scoreGenericUnsafe(
        eventId: Int,
        targetEventType: String,
        runId: Int,
        scoreCard: PictureSearchEventScoreCardSettings,
        floatingHoliday: FloatingHolidayDefinition?
    ) -> PictureSearchEventTypeScore {
        let visionScore = visionEvidenceScoreUnsafe(
            eventId: eventId,
            runId: runId,
            tags: scoreCard.visionTags
        )
        let dateScore = dateEvidenceScoreUnsafe(
            eventId: eventId,
            scoreCard: scoreCard,
            floatingHoliday: floatingHoliday
        )
        let locationScore = locationEvidenceScoreUnsafe(
            eventId: eventId,
            locations: scoreCard.locations
        )
        let peopleScore = peopleEvidenceScoreUnsafe(
            eventId: eventId,
            people: scoreCard.people
        )
        return PictureSearchEventTypeScore(
            eventId: eventId,
            targetEventType: targetEventType,
            visionScore: visionScore,
            dateScore: dateScore,
            locationScore: locationScore,
            peopleScore: peopleScore,
            totalScore: visionScore + dateScore + locationScore + peopleScore,
            likelyGroom: nil,
            likelyBride: nil
        )
    }

    /// For each query-matched photo in the event, add `points * confidence` for every score-card tag present at/above threshold.
    private func visionEvidenceScoreUnsafe(
        eventId: Int,
        runId: Int,
        tags: [PictureSearchEventScoreCardSettings.VisionTagRule]
    ) -> Double {
        let usableTags = tags
            .map {
                PictureSearchEventScoreCardSettings.VisionTagRule(
                    objectKey: $0.objectKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    minConfidence: max(0, min(1, $0.minConfidence)),
                    points: $0.points
                )
            }
            .filter { !$0.objectKey.isEmpty }
        guard !usableTags.isEmpty else { return 0 }

        let photoIds = photoIdsForEventInRunUnsafe(runId: runId, eventId: eventId)
        guard !photoIds.isEmpty else { return 0 }

        var total = 0.0
        for photoId in photoIds {
            for tag in usableTags {
                if let confidence = photoTagConfidenceUnsafe(
                    photoId: photoId,
                    objectKey: tag.objectKey
                ), confidence >= tag.minConfidence {
                    total += tag.points * confidence
                }
            }
        }
        return total
    }

    private func dateEvidenceScoreUnsafe(
        eventId: Int,
        scoreCard: PictureSearchEventScoreCardSettings,
        floatingHoliday: FloatingHolidayDefinition?
    ) -> Double {
        let dateSearch = scoreCard.dateSearch
        guard dateSearch.dateSearchType != .allDates else { return 0 }
        guard let range = eventDateRangeUnsafe(eventId: eventId) else { return 0 }

        let calendar = Calendar.current
        let midpoint = Date(
            timeIntervalSince1970: (range.start.timeIntervalSince1970 + range.end.timeIntervalSince1970) / 2
        )
        let year = calendar.component(.year, from: midpoint)

        guard let anchor = scoringAnchorDate(
            year: year,
            dateSearch: dateSearch,
            floatingHoliday: floatingHoliday,
            calendar: calendar
        ) else {
            return 0
        }

        let midDay = calendar.startOfDay(for: midpoint)
        let anchorDay = calendar.startOfDay(for: anchor)
        let daysAway = abs(calendar.dateComponents([.day], from: anchorDay, to: midDay).day ?? 0)
        if daysAway == 0 {
            return scoreCard.onDatePoints
        }
        return scoreCard.onDatePoints + (Double(daysAway) * scoreCard.pointsPerDayFromAnchor)
    }

    private func scoringAnchorDate(
        year: Int,
        dateSearch: DateSearchDefinition,
        floatingHoliday: FloatingHolidayDefinition?,
        calendar: Calendar
    ) -> Date? {
        switch dateSearch.dateSearchType {
        case .allDates:
            return nil
        case .sameDateEveryYear, .movingHoliday:
            return PictureSearchDateMatcher.anchorDate(
                year: year,
                dateSearch: dateSearch,
                floatingHoliday: floatingHoliday,
                calendar: calendar
            )
        case .sameDateRangeEveryYear:
            guard let mmdd = dateSearch.rangeStartMonthDay else { return nil }
            let parts = mmdd.split(separator: "-")
            guard parts.count == 2,
                  let month = Int(parts[0]),
                  let day = Int(parts[1]) else {
                return nil
            }
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        case .absoluteRange:
            guard let startISO = dateSearch.absoluteStartDate,
                  startISO.count >= 10 else {
                return nil
            }
            return EventDateParser.parseDate(String(startISO.prefix(10)))
        }
    }

    private func locationEvidenceScoreUnsafe(
        eventId: Int,
        locations: [PictureSearchEventScoreCardSettings.LocationRule]
    ) -> Double {
        let usable = locations
            .map {
                PictureSearchEventScoreCardSettings.LocationRule(
                    searchTerm: $0.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines),
                    points: $0.points
                )
            }
            .filter { !$0.searchTerm.isEmpty }
        guard !usable.isEmpty else { return 0 }
        guard let haystack = eventLocationHaystackUnsafe(eventId: eventId) else { return 0 }

        var total = 0.0
        for rule in usable {
            if haystack.localizedCaseInsensitiveContains(rule.searchTerm) {
                total += rule.points
            }
        }
        return total
    }

    private func peopleEvidenceScoreUnsafe(
        eventId: Int,
        people: [PictureSearchEventScoreCardSettings.PersonRule]
    ) -> Double {
        guard !people.isEmpty else { return 0 }
        let presentIds = personIdsInEventUnsafe(eventId: eventId)
        guard !presentIds.isEmpty else { return 0 }

        var total = 0.0
        for rule in people {
            if presentIds.contains(rule.personId) {
                total += rule.points
            }
        }
        return total
    }

    private func eventDateRangeUnsafe(eventId: Int) -> (start: Date, end: Date)? {
        let sql = """
        SELECT startDate, endDate
        FROM events
        WHERE eventId = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        var range: (Date, Date)?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if sqlite3_step(statement) == SQLITE_ROW,
               let startC = sqlite3_column_text(statement, 0),
               let endC = sqlite3_column_text(statement, 1),
               let start = EventDateParser.parseDate(String(cString: startC)),
               let end = EventDateParser.parseDate(String(cString: endC)) {
                range = (start, end)
            }
        }
        sqlite3_finalize(statement)
        return range.map { ($0.0, $0.1) }
    }

    private func eventLocationHaystackUnsafe(eventId: Int) -> String? {
        let sql = """
        SELECT
            IFNULL(e.city, ''),
            IFNULL(e.state, ''),
            IFNULL(e.placeName, ''),
            IFNULL(l.city, ''),
            IFNULL(l.state, ''),
            IFNULL(l.placeName, ''),
            IFNULL(l.nickname, '')
        FROM events e
        LEFT JOIN locations l ON l.locationId = e.locationId
        WHERE e.eventId = ?
        LIMIT 1;
        """
        var statement: OpaquePointer?
        var haystack: String?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            if sqlite3_step(statement) == SQLITE_ROW {
                var parts: [String] = []
                for column in 0..<7 {
                    if let cString = sqlite3_column_text(statement, Int32(column)) {
                        let text = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { parts.append(text) }
                    }
                }
                haystack = parts.joined(separator: " ")
            }
        }
        sqlite3_finalize(statement)
        return haystack
    }

    private func personIdsInEventUnsafe(eventId: Int) -> Set<Int> {
        let sql = """
        SELECT DISTINCT pp.personId
        FROM photo_events pe
        JOIN photo_people pp ON pp.photoId = pe.photoId
        JOIN photos p ON p.id = pe.photoId AND p.isDeleted = 0
        WHERE pe.eventId = ?
           OR pe.eventId IN (
               SELECT child.eventId
               FROM events child
               WHERE child.parentEventId = ?
                 AND child.isDeleted = 0
           );
        """
        var statement: OpaquePointer?
        var ids = Set<Int>()
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_int(statement, 2, Int32(eventId))
            while sqlite3_step(statement) == SQLITE_ROW {
                ids.insert(Int(sqlite3_column_int(statement, 0)))
            }
        }
        sqlite3_finalize(statement)
        return ids
    }

    private func photoIdsForEventInRunUnsafe(runId: Int, eventId: Int) -> [String] {
        let sql = """
        SELECT photoId
        FROM picture_search_photo_matches
        WHERE pictureSearchRunId = ?
          AND eventId = ?;
        """
        var statement: OpaquePointer?
        var ids: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(runId))
            sqlite3_bind_int(statement, 2, Int32(eventId))
            while sqlite3_step(statement) == SQLITE_ROW {
                if let cString = sqlite3_column_text(statement, 0) {
                    ids.append(String(cString: cString))
                }
            }
        }
        sqlite3_finalize(statement)
        return ids
    }

    private func photoTagConfidenceUnsafe(photoId: String, objectKey: String) -> Double? {
        let sql = """
        SELECT confidence
        FROM photo_object_tags
        WHERE photoId = ?
          AND LOWER(objectKey) = LOWER(?)
        LIMIT 1;
        """
        var statement: OpaquePointer?
        var confidence: Double?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (photoId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (objectKey as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                confidence = sqlite3_column_double(statement, 0)
            }
        }
        sqlite3_finalize(statement)
        return confidence
    }

    /// Among photos in the event that carry this Vision tag, return the person name that appears most.
    private func mostFrequentPersonForVisionTagUnsafe(
        eventId: Int,
        objectKey: String
    ) -> String? {
        let sql = """
        SELECT pe.name, COUNT(*) AS hits
        FROM photo_events pev
        JOIN photos p ON p.id = pev.photoId AND p.isDeleted = 0
        JOIN photo_object_tags pot ON pot.photoId = p.id
        JOIN photo_people pp ON pp.photoId = p.id
        JOIN people pe ON pe.personId = pp.personId
        WHERE pev.eventId = ?
          AND LOWER(pot.objectKey) = LOWER(?)
          AND TRIM(pe.name) != ''
        GROUP BY pe.personId
        ORDER BY hits DESC, pe.name COLLATE NOCASE ASC
        LIMIT 1;
        """

        var statement: OpaquePointer?
        var name: String?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
            sqlite3_bind_text(statement, 2, (objectKey as NSString).utf8String, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW,
               let cString = sqlite3_column_text(statement, 0) {
                name = String(cString: cString)
            }
        }
        sqlite3_finalize(statement)
        return name
    }

    private func persistEventScoreUnsafe(
        runId: Int,
        score: PictureSearchEventTypeScore,
        scoredAt: String
    ) {
        let sql = """
        INSERT INTO picture_search_event_scores (
            pictureSearchRunId, eventId, targetEventType,
            visionScore, dateScore, locationScore, peopleScore, totalScore,
            likelyGroom, likelyBride, scoredAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(pictureSearchRunId, eventId) DO UPDATE SET
            targetEventType = excluded.targetEventType,
            visionScore = excluded.visionScore,
            dateScore = excluded.dateScore,
            locationScore = excluded.locationScore,
            peopleScore = excluded.peopleScore,
            totalScore = excluded.totalScore,
            likelyGroom = excluded.likelyGroom,
            likelyBride = excluded.likelyBride,
            scoredAt = excluded.scoredAt;
        """

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(runId))
            sqlite3_bind_int(statement, 2, Int32(score.eventId))
            sqlite3_bind_text(statement, 3, (score.targetEventType as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 4, score.visionScore)
            sqlite3_bind_double(statement, 5, score.dateScore)
            sqlite3_bind_double(statement, 6, score.locationScore)
            sqlite3_bind_double(statement, 7, score.peopleScore)
            sqlite3_bind_double(statement, 8, score.totalScore)
            if let groom = score.likelyGroom {
                sqlite3_bind_text(statement, 9, (groom as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 9)
            }
            if let bride = score.likelyBride {
                sqlite3_bind_text(statement, 10, (bride as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(statement, 10)
            }
            sqlite3_bind_text(statement, 11, (scoredAt as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
}
