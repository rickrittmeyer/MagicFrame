import Foundation

/// Scores events against calendar occasions (holidays first; birthdays later).
final class OccasionScoringService {

    static let minTotalScoreToPersist = 0.2

    private let database: DatabaseManager
    private let occasions: OccasionRepository
    private let events: EventRepository
    private let holidayTags: OccasionHolidayTagService
    private let tuning: () -> EventTuningSettings

    init(
        database: DatabaseManager,
        occasions: OccasionRepository,
        events: EventRepository,
        holidayTags: OccasionHolidayTagService,
        tuning: @escaping () -> EventTuningSettings = { .defaults }
    ) {
        self.database = database
        self.occasions = occasions
        self.events = events
        self.holidayTags = holidayTags
        self.tuning = tuning
    }

    func occasionScoringCounts() -> OccasionScoringCounts {
        database.sync {
            occasions.ensureDefaultScoringRulesSeedDataUnsafe()
            return occasions.occasionScoringCountsUnsafe()
        }
    }

    func topHolidayMatches(limit: Int = 25) -> [OccasionScoringTopMatch] {
        database.sync {
            occasions.fetchTopHolidayScoresUnsafe(limit: limit)
        }
    }

    /// Recomputes holiday scores for all events with photos (day events and trip parents).
    func scoreAllHolidayEvents() -> (scoring: OccasionScoringRunResult, tags: HolidayTagApplyResult) {
        database.sync {
            occasions.ensureDefaultSeedDataUnsafe()
            occasions.ensureDefaultScoringRulesSeedDataUnsafe()
            let scoring = scoreAllHolidayEventsUnsafe()
            let tags = holidayTags.syncHolidayTagsFromScoresUnsafe()
            return (scoring, tags)
        }
    }

    /// Recomputes holiday scores and syncs the AI holiday tag for one event.
    func scoreHolidayEvent(eventId: Int) {
        database.sync {
            scoreHolidayEventOnDatabaseQueueUnsafe(eventId: eventId)
        }
    }

    /// Caller must already be on `database` queue (no nested `sync`).
    func scoreHolidayEventOnDatabaseQueueUnsafe(eventId: Int) {
        occasions.ensureDefaultScoringRulesSeedDataUnsafe()
        _ = scoreHolidayEventUnsafe(eventId: eventId)
        holidayTags.syncHolidayTagForEventUnsafe(eventId: eventId)
    }

    /// Re-scores only the listed holiday occasions (cheaper during incremental object scans).
    /// Caller must already be on `database` queue.
    func scoreHolidayOccasionsOnDatabaseQueueUnsafe(
        eventId: Int,
        occasionKeys: [String]
    ) {
        guard !occasionKeys.isEmpty else { return }

        occasions.ensureDefaultScoringRulesSeedDataUnsafe()
        _ = scoreHolidayOccasionsUnsafe(eventId: eventId, occasionKeys: occasionKeys)
        holidayTags.syncHolidayTagForEventUnsafe(eventId: eventId)
    }

    /// True when current object evidence would qualify for a post-object AI holiday tag.
    /// Caller must already be on `database` queue.
    func qualifiesForPostObjectHolidayTagOnDatabaseQueueUnsafe(
        eventId: Int,
        occasionKeys: [String]
    ) -> Bool {
        let settings = tuning()
        let keySet = Set(occasionKeys.map { $0.lowercased() })
        guard !keySet.isEmpty else { return false }

        let context = holidayScoringContextUnsafe()
        guard let target = events.fetchEventOccasionScoringTargetUnsafe(eventId: eventId),
              let eventRange = resolveEventDateRangeUnsafe(target: target) else {
            return false
        }

        for occasion in context.occasions where keySet.contains(occasion.occasionKey.lowercased()) {
            let rules = context.rulesByOccasion[occasion.occasionId] ?? []
            let textSignalScore = textScoreFromRules(
                eventId: target.eventId,
                rules: rules,
                includesDescendantPhotos: target.includesDescendantPhotos
            )
            let objectSignalScore = objectScoreFromRules(
                eventId: target.eventId,
                rules: rules,
                includesDescendantPhotos: target.includesDescendantPhotos,
                minObjectConfidence: settings.holidayObjectMinConfidence
            )
            guard objectSignalScore > 0 else { continue }

            for year in OccasionDateScoring.yearsSpanning(
                eventStart: eventRange.start,
                eventEnd: eventRange.end
            ) {
                guard let occasionDate = occasions.fetchOccasionDateUnsafe(
                    occasionId: occasion.occasionId,
                    year: year
                ),
                let window = OccasionDateScoring.resolveScoringWindow(
                    OccasionDateScoring.WindowResolutionInput(
                        year: year,
                        occasionKey: occasion.occasionKey,
                        anchorISO: occasionDate.anchorISO,
                        explicitStartISO: occasionDate.explicitStartISO,
                        explicitEndISO: occasionDate.explicitEndISO,
                        daysBefore: occasion.windowDaysBefore,
                        daysAfter: occasion.windowDaysAfter,
                        usesThanksgivingRelativeStart: occasion.usesThanksgivingRelativeStart,
                        daysAfterThanksgiving: occasion.windowDaysAfterThanksgiving
                    )
                ) else {
                    continue
                }

                let dateScore = OccasionDateScoring.dateScore(
                    eventStart: eventRange.start,
                    eventEnd: eventRange.end,
                    window: window
                )
                let weekendScore = OccasionWeekendScoring.score(
                    eventStart: eventRange.start,
                    eventEnd: eventRange.end,
                    boost: occasion.weekendBoost
                )
                let weighted = OccasionHolidayScoringWeights.weightedBreakdown(
                    dateScore: dateScore,
                    textScore: textSignalScore,
                    objectScore: objectSignalScore,
                    weekendScore: weekendScore,
                    objectRecognitionCompleted: true
                )
                let confidence = confidence(for: weighted.totalScore)

                if OccasionScoringThresholds.meetsHolidayTag(
                    confidence: confidence,
                    totalScore: weighted.totalScore,
                    objectRecognitionCompleted: true,
                    objectScore: weighted.cappedObjectScore,
                    settings: settings
                ) {
                    return true
                }
            }
        }

        return false
    }

    /// Re-scores holiday occasions for events touched during event sync (caller on database queue).
    func rescoreHolidayEventsAfterEventSyncUnsafe(eventIds: Set<Int>, scoreAllEvents: Bool) {
        occasions.ensureDefaultSeedDataUnsafe()
        occasions.ensureDefaultScoringRulesSeedDataUnsafe()

        let eventIdsToScore: [Int]
        if scoreAllEvents {
            eventIdsToScore = events.fetchEventOccasionScoringTargetsUnsafe().map(\.eventId)
        } else {
            eventIdsToScore = eventIds.sorted()
        }

        guard !eventIdsToScore.isEmpty else { return }

        for eventId in eventIdsToScore {
            _ = scoreHolidayEventUnsafe(eventId: eventId)
            holidayTags.syncHolidayTagForEventUnsafe(eventId: eventId)
        }

        print("Post-sync holiday scoring: \(eventIdsToScore.count) event(s)")
    }

    private func scoreAllHolidayEventsUnsafe() -> OccasionScoringRunResult {
        let context = holidayScoringContextUnsafe()
        let targets = events.fetchEventOccasionScoringTargetsUnsafe()
        occasions.deleteAllHolidayScoresUnsafe()
        let scoredAt = ISO8601DateFormatter().string(from: Date())
        var rowsWritten = 0
        var rowsSkippedBelowThreshold = 0

        for target in targets {
            let result = scoreTargetUnsafe(
                target: target,
                holidayOccasions: context.occasions,
                rulesByOccasion: context.rulesByOccasion,
                scoredAt: scoredAt
            )
            rowsWritten += result.rowsWritten
            rowsSkippedBelowThreshold += result.rowsSkippedBelowThreshold
        }

        return OccasionScoringRunResult(
            eventsConsidered: targets.count,
            rowsWritten: rowsWritten,
            rowsSkippedBelowThreshold: rowsSkippedBelowThreshold
        )
    }

    @discardableResult
    private func scoreHolidayEventUnsafe(eventId: Int) -> OccasionScoringRunResult {
        let context = holidayScoringContextUnsafe()
        guard let target = events.fetchEventOccasionScoringTargetUnsafe(eventId: eventId) else {
            return OccasionScoringRunResult(
                eventsConsidered: 0,
                rowsWritten: 0,
                rowsSkippedBelowThreshold: 0
            )
        }

        occasions.deleteHolidayScoresForEventUnsafe(eventId: eventId)

        let scoredAt = ISO8601DateFormatter().string(from: Date())
        let result = scoreTargetUnsafe(
            target: target,
            holidayOccasions: context.occasions,
            rulesByOccasion: context.rulesByOccasion,
            scoredAt: scoredAt
        )

        return OccasionScoringRunResult(
            eventsConsidered: 1,
            rowsWritten: result.rowsWritten,
            rowsSkippedBelowThreshold: result.rowsSkippedBelowThreshold
        )
    }

    @discardableResult
    private func scoreHolidayOccasionsUnsafe(
        eventId: Int,
        occasionKeys: [String]
    ) -> OccasionScoringRunResult {
        let keySet = Set(occasionKeys.map { $0.lowercased() })
        let context = holidayScoringContextUnsafe()
        guard let target = events.fetchEventOccasionScoringTargetUnsafe(eventId: eventId) else {
            return OccasionScoringRunResult(
                eventsConsidered: 0,
                rowsWritten: 0,
                rowsSkippedBelowThreshold: 0
            )
        }

        let scopedOccasions = context.occasions.filter {
            keySet.contains($0.occasionKey.lowercased())
        }
        guard !scopedOccasions.isEmpty else {
            return OccasionScoringRunResult(
                eventsConsidered: 0,
                rowsWritten: 0,
                rowsSkippedBelowThreshold: 0
            )
        }

        occasions.deleteHolidayScoresForEventOccasionKeysUnsafe(
            eventId: eventId,
            occasionKeys: scopedOccasions.map(\.occasionKey)
        )

        let scoredAt = ISO8601DateFormatter().string(from: Date())
        let result = scoreTargetUnsafe(
            target: target,
            holidayOccasions: scopedOccasions,
            rulesByOccasion: context.rulesByOccasion,
            scoredAt: scoredAt
        )

        return OccasionScoringRunResult(
            eventsConsidered: 1,
            rowsWritten: result.rowsWritten,
            rowsSkippedBelowThreshold: result.rowsSkippedBelowThreshold
        )
    }

    private func holidayScoringContextUnsafe() -> (
        occasions: [OccasionForScoring],
        rulesByOccasion: [Int: [OccasionScoringRule]]
    ) {
        let holidayOccasions = occasions.fetchEnabledOccasionsUnsafe(occasionType: "holiday")
        let rulesByOccasion = Dictionary(
            uniqueKeysWithValues: holidayOccasions.map { occasion in
                (occasion.occasionId, occasions.fetchScoringRulesUnsafe(occasionId: occasion.occasionId))
            }
        )
        return (holidayOccasions, rulesByOccasion)
    }

    private func scoreTargetUnsafe(
        target: EventOccasionScoringTarget,
        holidayOccasions: [OccasionForScoring],
        rulesByOccasion: [Int: [OccasionScoringRule]],
        scoredAt: String
    ) -> (rowsWritten: Int, rowsSkippedBelowThreshold: Int) {
        guard let eventRange = resolveEventDateRangeUnsafe(target: target) else {
            return (0, 0)
        }

        var rowsWritten = 0
        var rowsSkippedBelowThreshold = 0
        let settings = tuning()
        let objectRecognitionCompleted = events.isObjectRecognitionCompletedUnsafe(
            eventId: target.eventId
        )

        for occasion in holidayOccasions {
            let rules = rulesByOccasion[occasion.occasionId] ?? []
            let textSignalScore = textScoreFromRules(
                eventId: target.eventId,
                rules: rules,
                includesDescendantPhotos: target.includesDescendantPhotos
            )
            let objectSignalScore = objectScoreFromRules(
                eventId: target.eventId,
                rules: rules,
                includesDescendantPhotos: target.includesDescendantPhotos,
                minObjectConfidence: settings.holidayObjectMinConfidence
            )

            for year in OccasionDateScoring.yearsSpanning(
                eventStart: eventRange.start,
                eventEnd: eventRange.end
            ) {
                guard let occasionDate = occasions.fetchOccasionDateUnsafe(
                    occasionId: occasion.occasionId,
                    year: year
                ),
                let window = OccasionDateScoring.resolveScoringWindow(
                    OccasionDateScoring.WindowResolutionInput(
                        year: year,
                        occasionKey: occasion.occasionKey,
                        anchorISO: occasionDate.anchorISO,
                        explicitStartISO: occasionDate.explicitStartISO,
                        explicitEndISO: occasionDate.explicitEndISO,
                        daysBefore: occasion.windowDaysBefore,
                        daysAfter: occasion.windowDaysAfter,
                        usesThanksgivingRelativeStart: occasion.usesThanksgivingRelativeStart,
                        daysAfterThanksgiving: occasion.windowDaysAfterThanksgiving
                    )
                ) else {
                    continue
                }

                let dateScore = OccasionDateScoring.dateScore(
                    eventStart: eventRange.start,
                    eventEnd: eventRange.end,
                    window: window
                )
                let weekendScore = OccasionWeekendScoring.score(
                    eventStart: eventRange.start,
                    eventEnd: eventRange.end,
                    boost: occasion.weekendBoost
                )
                let weighted = OccasionHolidayScoringWeights.weightedBreakdown(
                    dateScore: dateScore,
                    textScore: textSignalScore,
                    objectScore: objectSignalScore,
                    weekendScore: weekendScore,
                    objectRecognitionCompleted: objectRecognitionCompleted
                )
                let cappedTextScore = weighted.cappedTextScore
                let cappedObjectScore = weighted.cappedObjectScore
                let totalScore = weighted.totalScore

                guard totalScore >= Self.minTotalScoreToPersist else {
                    rowsSkippedBelowThreshold += 1
                    continue
                }

                let draft = EventOccasionScoreDraft(
                    eventId: target.eventId,
                    occasionId: occasion.occasionId,
                    year: year,
                    dateScore: dateScore,
                    objectScore: cappedObjectScore,
                    albumScore: cappedTextScore,
                    weekendScore: weekendScore,
                    totalScore: totalScore,
                    confidence: confidence(for: totalScore)
                )
                occasions.upsertEventOccasionScoreUnsafe(draft, scoredAt: scoredAt)
                rowsWritten += 1
            }
        }

        return (rowsWritten, rowsSkippedBelowThreshold)
    }

    private func resolveEventDateRangeUnsafe(
        target: EventOccasionScoringTarget
    ) -> (start: Date, end: Date)? {
        var startISO = target.startDateISO
        var endISO = target.endDateISO

        if EventDateParser.parseDate(startISO) == nil || EventDateParser.parseDate(endISO) == nil,
           let photoRange = events.photoDateRangeISOForEventUnsafe(
            eventId: target.eventId,
            includesDescendantPhotos: target.includesDescendantPhotos
           ) {
            startISO = photoRange.start
            endISO = photoRange.end
        }

        guard let start = EventDateParser.parseDate(startISO),
              let end = EventDateParser.parseDate(endISO) else {
            return nil
        }

        return (start, end)
    }

    private func textScoreFromRules(
        eventId: Int,
        rules: [OccasionScoringRule],
        includesDescendantPhotos: Bool
    ) -> Double {
        scoreFromRules(
            eventId: eventId,
            rules: rules,
            includesDescendantPhotos: includesDescendantPhotos,
            signalTypes: ["keyword", "album"],
            minObjectConfidence: tuning().holidayObjectMinConfidence
        )
    }

    private func objectScoreFromRules(
        eventId: Int,
        rules: [OccasionScoringRule],
        includesDescendantPhotos: Bool,
        minObjectConfidence: Double
    ) -> Double {
        var total = 0.0
        var matchedKeys = Set<String>()

        for rule in rules {
            guard rule.signalType.lowercased() == "object" else { continue }

            let key = "\(rule.signalType)|\(rule.signalValue)"
            guard !matchedKeys.contains(key) else { continue }

            let photoCount = occasions.eventObjectPhotoCountUnsafe(
                eventId: eventId,
                objectKey: rule.signalValue,
                includesDescendantPhotos: includesDescendantPhotos,
                minConfidence: minObjectConfidence
            )
            guard photoCount > 0 else { continue }

            total += rule.score * Double(photoCount)
            matchedKeys.insert(key)
        }

        return total
    }

    private func scoreFromRules(
        eventId: Int,
        rules: [OccasionScoringRule],
        includesDescendantPhotos: Bool,
        signalTypes: [String],
        minObjectConfidence: Double
    ) -> Double {
        let allowedTypes = Set(signalTypes.map { $0.lowercased() })
        var total = 0.0
        var matchedKeys = Set<String>()

        for rule in rules {
            guard allowedTypes.contains(rule.signalType.lowercased()) else { continue }

            let key = "\(rule.signalType)|\(rule.signalValue)"
            guard !matchedKeys.contains(key) else { continue }

            if occasions.eventMatchesScoringSignalUnsafe(
                eventId: eventId,
                signalType: rule.signalType,
                signalValue: rule.signalValue,
                includesDescendantPhotos: includesDescendantPhotos,
                minObjectConfidence: minObjectConfidence
            ) {
                total += rule.score
                matchedKeys.insert(key)
            }
        }

        return total
    }

    private func confidence(for totalScore: Double) -> String? {
        if totalScore >= 0.75 { return "high" }
        if totalScore >= 0.45 { return "medium" }
        if totalScore >= Self.minTotalScoreToPersist { return "low" }
        return nil
    }
}
