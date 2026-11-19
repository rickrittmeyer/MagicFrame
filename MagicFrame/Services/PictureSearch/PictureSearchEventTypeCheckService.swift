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

    /// Event-scoped scoring for AI Assist — uses all photos on the event (not a Picture Search run).
    @discardableResult
    func scoreEvent(
        eventId: Int,
        scoreCard: PictureSearchEventScoreCardSettings,
        floatingHoliday: FloatingHolidayDefinition? = nil
    ) -> PictureSearchEventTypeScore {
        sync {
            scoreAndApplyEventUnsafe(
                eventId: eventId,
                scoreCard: scoreCard,
                floatingHoliday: floatingHoliday,
                persistRunId: nil,
                targetFieldOverride: nil,
                scoredAt: ISO8601DateFormatter().string(from: Date())
            ).score
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

            let applied = scoreAndApplyEventUnsafe(
                eventId: eventId,
                scoreCard: scoreCard,
                floatingHoliday: floatingHoliday,
                persistRunId: runReport.pictureSearchRunId,
                targetFieldOverride: definition.targetAttributeField,
                scoredAt: now
            )
            groomTagsWritten += applied.groomWritten ? 1 : 0
            brideTagsWritten += applied.brideWritten ? 1 : 0
            scores.append(applied.score)
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

    private struct ScoreApplyResult {
        let score: PictureSearchEventTypeScore
        let groomWritten: Bool
        let brideWritten: Bool
    }

    /// `persistRunId == nil` → event-scoped vision (all event photos) and skip run score persistence.
    private func scoreAndApplyEventUnsafe(
        eventId: Int,
        scoreCard: PictureSearchEventScoreCardSettings,
        floatingHoliday: FloatingHolidayDefinition?,
        persistRunId: Int?,
        targetFieldOverride: EventAttributeField?,
        scoredAt: String
    ) -> ScoreApplyResult {
        let targetType = scoreCard.targetEventType.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedType = targetType.isEmpty ? "Wedding" : targetType
        let targetField = targetFieldOverride
            ?? EventAttributeField.fromTagCategory(scoreCard.targetTagCategory)
            ?? EventAttributeField.pictureSearchCategory(forTargetValue: normalizedType)
        let useEventPhotos = persistRunId == nil
        let runIdForVision = persistRunId ?? 0

        let isWedding = targetField == .milestoneType
            && normalizedType.compare("Wedding", options: .caseInsensitive) == .orderedSame
        let isBirthday = targetField == .milestoneType
            && MilestonePictureSearchDefaults.isPersonBirthdayTagValue(normalizedType)
        let isHoliday = targetField == .holidayType
            || scoreCard.targetTagCategory.compare(
                EventAttributeField.holidayType.tagCategory,
                options: .caseInsensitive
            ) == .orderedSame

        let holidayGate: CalendarDateGate? = isHoliday
            ? holidayDateGateUnsafe(
                eventId: eventId,
                scoreCard: scoreCard,
                floatingHoliday: floatingHoliday
            )
            : nil

        let birthdayMatch: BirthdayPersonMatch? = isBirthday
            ? resolveBirthdayPersonMatchUnsafe(eventId: eventId, scoreCard: scoreCard)
            : nil

        // Holiday / Birthday date is a gate, not points: skip outside the window entirely.
        if holidayGate == .outsideWindow
            || (isBirthday && (birthdayMatch == nil || birthdayMatch?.gate == .outsideWindow)) {
            let skipped = PictureSearchEventTypeScore(
                eventId: eventId,
                targetEventType: normalizedType,
                visionScore: 0,
                dateScore: 0,
                locationScore: 0,
                peopleScore: 0,
                totalScore: 0,
                likelyGroom: nil,
                likelyBride: nil
            )
            if let persistRunId {
                persistEventScoreUnsafe(runId: persistRunId, score: skipped, scoredAt: scoredAt)
            }
            return ScoreApplyResult(score: skipped, groomWritten: false, brideWritten: false)
        }

        let score: PictureSearchEventTypeScore
        switch normalizedType.lowercased() {
        case "wedding":
            score = scoreWeddingUnsafe(
                eventId: eventId,
                runId: runIdForVision,
                scoreCard: scoreCard,
                floatingHoliday: floatingHoliday,
                useAllEventPhotos: useEventPhotos
            )
        default:
            score = scoreGenericUnsafe(
                eventId: eventId,
                targetEventType: normalizedType,
                runId: runIdForVision,
                scoreCard: scoreCard,
                floatingHoliday: floatingHoliday,
                useAllEventPhotos: useEventPhotos
            )
        }

        if let persistRunId {
            persistEventScoreUnsafe(
                runId: persistRunId,
                score: score,
                scoredAt: scoredAt
            )
        }

        let tagRejected = eventTags.isAIAttributeTagValueRejectedUnsafe(
            eventId: eventId,
            category: targetField.tagCategory,
            tagValue: normalizedType
        )

        let exactCalendarDate = holidayGate == .exactHolidayDate
            || birthdayMatch?.gate == .exactHolidayDate

        var groomWritten = false
        var brideWritten = false
        // Exact holiday/birthday date → auto-include. Otherwise require the AI score threshold.
        let shouldApply = !tagRejected && (
            exactCalendarDate || scoreCard.meetsAIThreshold(totalScore: score.totalScore)
        )
        if shouldApply {
            eventTags.upsertAIAttributeTagUnsafe(
                eventId: eventId,
                field: targetField,
                tagValue: normalizedType,
                totalScore: score.totalScore
            )
            if isBirthday, let birthdayMatch {
                _ = eventTags.applyAIBirthdayMainPersonUnsafe(
                    eventId: eventId,
                    personName: birthdayMatch.displayName,
                    totalScore: score.totalScore
                )
            }
            if isWedding {
                eventTags.deleteMisclassifiedEventTypeForMilestoneUnsafe(
                    eventId: eventId,
                    tagValue: "Wedding"
                )
                let couple = WeddingCoupleResolutionService(
                    database: database,
                    eventTags: eventTags
                ).resolveAndApply(eventId: eventId)
                groomWritten = couple.groomTagWritten
                brideWritten = couple.brideTagWritten
                // Refresh likely names from the new resolver for score persistence.
                let refreshed = PictureSearchEventTypeScore(
                    eventId: score.eventId,
                    targetEventType: score.targetEventType,
                    visionScore: score.visionScore,
                    dateScore: score.dateScore,
                    locationScore: score.locationScore,
                    peopleScore: score.peopleScore,
                    totalScore: score.totalScore,
                    likelyGroom: couple.groom?.displayName,
                    likelyBride: couple.bride?.displayName
                )
                if let persistRunId {
                    persistEventScoreUnsafe(
                        runId: persistRunId,
                        score: refreshed,
                        scoredAt: scoredAt
                    )
                }
                return ScoreApplyResult(
                    score: refreshed,
                    groomWritten: groomWritten,
                    brideWritten: brideWritten
                )
            }
        }

        return ScoreApplyResult(score: score, groomWritten: groomWritten, brideWritten: brideWritten)
    }

    // MARK: - Wedding / generic

    private func scoreWeddingUnsafe(
        eventId: Int,
        runId: Int,
        scoreCard: PictureSearchEventScoreCardSettings,
        floatingHoliday: FloatingHolidayDefinition?,
        useAllEventPhotos: Bool = false
    ) -> PictureSearchEventTypeScore {
        let visionScore = visionEvidenceScoreUnsafe(
            eventId: eventId,
            runId: runId,
            tags: scoreCard.visionTags,
            useAllEventPhotos: useAllEventPhotos
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
        // Likely bride/groom names are filled by WeddingCoupleResolutionService after threshold.
        return PictureSearchEventTypeScore(
            eventId: eventId,
            targetEventType: "Wedding",
            visionScore: visionScore,
            dateScore: dateScore,
            locationScore: locationScore,
            peopleScore: peopleScore,
            totalScore: visionScore + dateScore + locationScore + peopleScore,
            likelyGroom: nil,
            likelyBride: nil
        )
    }

    private func scoreGenericUnsafe(
        eventId: Int,
        targetEventType: String,
        runId: Int,
        scoreCard: PictureSearchEventScoreCardSettings,
        floatingHoliday: FloatingHolidayDefinition?,
        useAllEventPhotos: Bool = false
    ) -> PictureSearchEventTypeScore {
        let isHoliday = scoreCard.targetTagCategory.compare(
            EventAttributeField.holidayType.tagCategory,
            options: .caseInsensitive
        ) == .orderedSame
        let isBirthday = scoreCard.targetTagCategory.compare(
            EventAttributeField.milestoneType.tagCategory,
            options: .caseInsensitive
        ) == .orderedSame
            && MilestonePictureSearchDefaults.isPersonBirthdayTagValue(scoreCard.targetEventType)

        let visionScore = visionEvidenceScoreUnsafe(
            eventId: eventId,
            runId: runId,
            tags: scoreCard.visionTags,
            useAllEventPhotos: useAllEventPhotos
        )
        // Holiday / Birthday: date is a gate only (no date points).
        let dateScore = (isHoliday || isBirthday)
            ? 0
            : dateEvidenceScoreUnsafe(
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

    private enum CalendarDateGate: Equatable {
        case outsideWindow
        case exactHolidayDate
        case inWindow
    }

    private struct BirthdayPersonMatch: Equatable {
        let personId: Int
        let displayName: String
        let gate: CalendarDateGate
    }

    /// Holiday scorecards: date filters candidates; it does not add points.
    private func holidayDateGateUnsafe(
        eventId: Int,
        scoreCard: PictureSearchEventScoreCardSettings,
        floatingHoliday: FloatingHolidayDefinition?
    ) -> CalendarDateGate {
        let dateSearch = scoreCard.dateSearch
        if dateSearch.dateSearchType == .allDates {
            return .inWindow
        }
        guard let range = eventDateRangeUnsafe(eventId: eventId) else {
            return .outsideWindow
        }

        let calendar = Calendar.current
        let midpoint = Date(
            timeIntervalSince1970: (range.start.timeIntervalSince1970 + range.end.timeIntervalSince1970) / 2
        )
        let midDay = calendar.startOfDay(for: midpoint)
        let year = calendar.component(.year, from: midpoint)

        switch dateSearch.dateSearchType {
        case .allDates:
            return .inWindow
        case .sameDateEveryYear, .movingHoliday:
            guard let anchor = scoringAnchorDate(
                year: year,
                dateSearch: dateSearch,
                floatingHoliday: floatingHoliday,
                calendar: calendar
            ) else {
                return .outsideWindow
            }
            let allowed = PictureSearchDateMatcher.allowedDates(
                around: anchor,
                dateSearch: dateSearch,
                calendar: calendar
            )
            guard allowed.contains(midDay) else { return .outsideWindow }
            if calendar.isDate(midDay, inSameDayAs: anchor) {
                return .exactHolidayDate
            }
            return .inWindow
        case .sameDateRangeEveryYear:
            guard let start = dateSearch.rangeStartMonthDay,
                  let end = dateSearch.rangeEndMonthDay else {
                return .outsideWindow
            }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "MM-dd"
            let monthDay = formatter.string(from: midDay)
            let inRange: Bool
            if start <= end {
                inRange = monthDay >= start && monthDay <= end
            } else {
                inRange = monthDay >= start || monthDay <= end
            }
            return inRange ? .inWindow : .outsideWindow
        case .absoluteRange:
            guard let startISO = dateSearch.absoluteStartDate,
                  let endISO = dateSearch.absoluteEndDate,
                  let start = EventDateParser.parseDate(String(startISO.prefix(10))),
                  let end = EventDateParser.parseDate(String(endISO.prefix(10))) else {
                return .outsideWindow
            }
            let startDay = calendar.startOfDay(for: start)
            let endDay = calendar.startOfDay(for: end)
            guard midDay >= startDay && midDay <= endDay else { return .outsideWindow }
            return .inWindow
        }
    }

    /// Birthday: 7 days before … 3 days after birth month/day. Prefer scorecard people, else people on the event.
    private func resolveBirthdayPersonMatchUnsafe(
        eventId: Int,
        scoreCard: PictureSearchEventScoreCardSettings
    ) -> BirthdayPersonMatch? {
        guard let range = eventDateRangeUnsafe(eventId: eventId) else { return nil }
        let calendar = Calendar.current
        let midpoint = Date(
            timeIntervalSince1970: (range.start.timeIntervalSince1970 + range.end.timeIntervalSince1970) / 2
        )
        let midDay = calendar.startOfDay(for: midpoint)

        var candidates = birthdayPeopleFromScoreCardUnsafe(scoreCard: scoreCard)
        if candidates.isEmpty {
            candidates = birthdayPeopleInEventUnsafe(eventId: eventId)
        }
        guard !candidates.isEmpty else { return nil }

        var best: BirthdayPersonMatch?
        for person in candidates {
            let gate = birthdayDateGateUnsafe(
                midDay: midDay,
                birthDateISO: person.birthDateISO,
                calendar: calendar
            )
            guard gate != .outsideWindow else { continue }
            let match = BirthdayPersonMatch(
                personId: person.personId,
                displayName: person.displayName,
                gate: gate
            )
            if best == nil {
                best = match
            } else if gate == .exactHolidayDate, best?.gate != .exactHolidayDate {
                best = match
            }
        }
        return best
    }

    private struct BirthdayPersonRow {
        let personId: Int
        let displayName: String
        let birthDateISO: String
    }

    private func birthdayPeopleFromScoreCardUnsafe(
        scoreCard: PictureSearchEventScoreCardSettings
    ) -> [BirthdayPersonRow] {
        let ids = scoreCard.people.map(\.personId).filter { $0 > 0 }
        guard !ids.isEmpty else { return [] }
        return fetchBirthdayPeopleUnsafe(personIds: ids)
    }

    private func birthdayPeopleInEventUnsafe(eventId: Int) -> [BirthdayPersonRow] {
        let ids = Array(personIdsInEventUnsafe(eventId: eventId))
        guard !ids.isEmpty else { return [] }
        return fetchBirthdayPeopleUnsafe(personIds: ids)
    }

    private func fetchBirthdayPeopleUnsafe(personIds: [Int]) -> [BirthdayPersonRow] {
        guard !personIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: personIds.count).joined(separator: ", ")
        let sql = """
        SELECT personId, displayName, birthDate
        FROM people
        WHERE personId IN (\(placeholders))
          AND birthDate IS NOT NULL
          AND TRIM(birthDate) != ''
          AND length(birthDate) >= 10;
        """
        var statement: OpaquePointer?
        var rows: [BirthdayPersonRow] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (index, id) in personIds.enumerated() {
                sqlite3_bind_int(statement, Int32(index + 1), Int32(id))
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let personId = Int(sqlite3_column_int(statement, 0))
                guard let nameC = sqlite3_column_text(statement, 1),
                      let birthC = sqlite3_column_text(statement, 2) else {
                    continue
                }
                let name = String(cString: nameC).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                rows.append(
                    BirthdayPersonRow(
                        personId: personId,
                        displayName: name,
                        birthDateISO: String(cString: birthC)
                    )
                )
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    /// Exact birth month/day, or within 7 days before … 3 days after (checks adjacent years).
    private func birthdayDateGateUnsafe(
        midDay: Date,
        birthDateISO: String,
        calendar: Calendar
    ) -> CalendarDateGate {
        guard let birthDate = EventDateParser.parseDate(birthDateISO) else {
            return .outsideWindow
        }
        let birthMonth = calendar.component(.month, from: birthDate)
        let birthDay = calendar.component(.day, from: birthDate)
        let midYear = calendar.component(.year, from: midDay)
        let daysBefore = MilestonePictureSearchDefaults.birthdayDaysBefore
        let daysAfter = MilestonePictureSearchDefaults.birthdayDaysAfter

        var best: CalendarDateGate = .outsideWindow
        for year in [midYear - 1, midYear, midYear + 1] {
            guard let anchor = calendar.date(
                from: DateComponents(year: year, month: birthMonth, day: birthDay)
            ) else {
                continue
            }
            let anchorDay = calendar.startOfDay(for: anchor)
            if calendar.isDate(midDay, inSameDayAs: anchorDay) {
                return .exactHolidayDate
            }
            guard let windowStart = calendar.date(byAdding: .day, value: -daysBefore, to: anchorDay),
                  let windowEnd = calendar.date(byAdding: .day, value: daysAfter, to: anchorDay) else {
                continue
            }
            if midDay >= windowStart && midDay <= windowEnd {
                best = .inWindow
            }
        }
        return best
    }

    /// For each query-matched photo in the event, add `points * confidence` for every score-card tag present at/above threshold.
    private func visionEvidenceScoreUnsafe(
        eventId: Int,
        runId: Int,
        tags: [PictureSearchEventScoreCardSettings.VisionTagRule],
        useAllEventPhotos: Bool = false
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

        let photoIds = useAllEventPhotos
            ? photoIdsForEventUnsafe(eventId: eventId)
            : photoIdsForEventInRunUnsafe(runId: runId, eventId: eventId)
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

    private func photoIdsForEventUnsafe(eventId: Int) -> [String] {
        let sql = """
        SELECT pe.photoId
        FROM photo_events pe
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
        var ids: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(eventId))
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
