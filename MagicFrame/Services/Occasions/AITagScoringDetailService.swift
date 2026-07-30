import Foundation

struct AITagScoringDetailService {

    let events: EventRepository
    let occasions: OccasionRepository
    let eventTags: EventTagRepository
    let tuning: () -> EventTuningSettings

    func buildHolidayScorecardsForEventUnsafe(
        eventId: Int,
        includesDescendantPhotos: Bool
    ) -> [AITagScoringDetail] {
        let settings = tuning()
        let matches = occasions.fetchEventHolidayScoreMatchesUnsafe(eventId: eventId)
        let aiHolidayTag = eventTags.fetchHolidayTagRowUnsafe(eventId: eventId)
        let objectRecognitionCompleted = events.isObjectRecognitionCompletedUnsafe(eventId: eventId)

        guard !matches.isEmpty else {
            return [
                emptyHolidayScorecard(
                    objectRecognitionCompleted: objectRecognitionCompleted,
                    settings: settings
                ),
            ]
        }

        return matches.enumerated().map { index, match in
            buildHolidayDetailUnsafe(
                eventId: eventId,
                occasionId: match.occasionId,
                year: match.year,
                tagLabel: match.occasionName,
                tagCategory: "Holiday scoring",
                scoreRow: match.scoreRow,
                includesDescendantPhotos: includesDescendantPhotos,
                appliedPhase: nil,
                aiHolidayTag: aiHolidayTag,
                isBestMatch: index == 0
            )
        }
    }

    func buildDetailUnsafe(
        eventId: Int,
        field: EventAttributeField,
        includesDescendantPhotos: Bool
    ) -> AITagScoringDetail? {
        guard let metadata = eventTags.fetchAttributeTagScoringMetadataUnsafe(
            eventId: eventId,
            field: field
        ),
        metadata.source == .ai else {
            return nil
        }

        let settings = tuning()
        let tunableSettings = tunableSettings(
            appliedPhase: metadata.appliedPhase,
            settings: settings
        )

        guard let occasionId = metadata.occasionId,
              let scoringYear = metadata.scoringYear,
              occasions.fetchOccasionByIdUnsafe(occasionId: occasionId) != nil else {
            let weights = OccasionHolidayScoringWeights.weights(objectRecognitionCompleted: false)
            return AITagScoringDetail(
                tagLabel: metadata.tagValue,
                tagCategory: field.menuTitle,
                occasionId: metadata.occasionId,
                occasionKey: nil,
                occasionName: nil,
                scoringYear: metadata.scoringYear,
                dateScoringBreakdown: nil,
                anchorDateISO: nil,
                dateScore: nil,
                objectScore: nil,
                albumScore: nil,
                weekendScore: nil,
                objectRecognitionCompleted: false,
                dateWeight: weights.date,
                textWeight: weights.text,
                objectWeight: weights.object,
                baseScore: nil,
                totalScore: metadata.totalScore,
                weightedBreakdown: nil,
                confidence: metadata.confidence,
                appliedPhase: metadata.appliedPhase,
                windowDaysBefore: nil,
                windowDaysAfter: nil,
                usesThanksgivingRelativeStart: false,
                windowDaysAfterThanksgiving: nil,
                thanksgivingDateISO: nil,
                weekendBoost: nil,
                scoringRules: [],
                tunableSettings: tunableSettings,
                unavailableReason: "This AI tag was not linked to occasion scoring.",
                statusNote: nil
            )
        }

        let scoreRow = occasions.fetchEventOccasionScoreUnsafe(
            eventId: eventId,
            occasionId: occasionId,
            year: scoringYear
        )

        return buildHolidayDetailUnsafe(
            eventId: eventId,
            occasionId: occasionId,
            year: scoringYear,
            tagLabel: metadata.tagValue,
            tagCategory: field.menuTitle,
            scoreRow: scoreRow,
            includesDescendantPhotos: includesDescendantPhotos,
            appliedPhase: metadata.appliedPhase,
            aiHolidayTag: eventTags.fetchHolidayTagRowUnsafe(eventId: eventId),
            isBestMatch: true
        )
    }

    private func buildHolidayDetailUnsafe(
        eventId: Int,
        occasionId: Int,
        year: Int,
        tagLabel: String,
        tagCategory: String,
        scoreRow: OccasionRepository.EventOccasionScoreRow?,
        includesDescendantPhotos: Bool,
        appliedPhase overridePhase: EventTagAppliedPhase?,
        aiHolidayTag: (source: EventTagSource, tagValue: String)?,
        isBestMatch: Bool
    ) -> AITagScoringDetail {
        let settings = tuning()
        guard let occasion = occasions.fetchOccasionByIdUnsafe(occasionId: occasionId) else {
            let weights = OccasionHolidayScoringWeights.weights(objectRecognitionCompleted: false)
            return AITagScoringDetail(
                tagLabel: tagLabel,
                tagCategory: tagCategory,
                occasionId: occasionId,
                occasionKey: nil,
                occasionName: nil,
                scoringYear: year,
                dateScoringBreakdown: nil,
                anchorDateISO: nil,
                dateScore: scoreRow?.dateScore,
                objectScore: scoreRow?.objectScore,
                albumScore: scoreRow?.albumScore,
                weekendScore: scoreRow?.weekendScore,
                objectRecognitionCompleted: false,
                dateWeight: weights.date,
                textWeight: weights.text,
                objectWeight: weights.object,
                baseScore: nil,
                totalScore: scoreRow?.totalScore,
                weightedBreakdown: nil,
                confidence: scoreRow?.confidence,
                appliedPhase: overridePhase,
                windowDaysBefore: nil,
                windowDaysAfter: nil,
                usesThanksgivingRelativeStart: false,
                windowDaysAfterThanksgiving: nil,
                thanksgivingDateISO: nil,
                weekendBoost: nil,
                scoringRules: [],
                tunableSettings: tunableSettings(appliedPhase: overridePhase, settings: settings),
                unavailableReason: "Holiday occasion not found.",
                statusNote: nil
            )
        }

        let objectRecognitionCompleted = events.isObjectRecognitionCompletedUnsafe(eventId: eventId)

        let rules = occasions.fetchScoringRulesUnsafe(occasionId: occasionId)
        let ruleDetails = rules.map { rule in
            let isObjectRule = rule.signalType.lowercased() == "object"
            let matchedPhotoCount = isObjectRule
                ? occasions.eventObjectPhotoCountUnsafe(
                    eventId: eventId,
                    objectKey: rule.signalValue,
                    includesDescendantPhotos: includesDescendantPhotos,
                    minConfidence: settings.holidayObjectMinConfidence
                )
                : nil
            let matched = isObjectRule
                ? (matchedPhotoCount ?? 0) > 0
                : occasions.eventMatchesScoringSignalUnsafe(
                    eventId: eventId,
                    signalType: rule.signalType,
                    signalValue: rule.signalValue,
                    includesDescendantPhotos: includesDescendantPhotos,
                    minObjectConfidence: settings.holidayObjectMinConfidence
                )

            return AITagScoringRuleDetail(
                signalType: rule.signalType,
                signalValue: rule.signalValue,
                score: rule.score,
                matched: matched,
                matchedPhotoCount: matchedPhotoCount
            )
        }

        let dateScore = scoreRow?.dateScore
        let objectScore = scoreRow?.objectScore
        let albumScore = scoreRow?.albumScore
        let weekendScore = scoreRow?.weekendScore ?? 0
        let weightedBreakdown: OccasionHolidayScoringWeights.WeightedBreakdown?
        if let dateScore, let albumScore {
            weightedBreakdown = OccasionHolidayScoringWeights.weightedBreakdown(
                dateScore: dateScore,
                textScore: albumScore,
                objectScore: objectScore ?? 0,
                weekendScore: weekendScore,
                objectRecognitionCompleted: objectRecognitionCompleted
            )
        } else {
            weightedBreakdown = nil
        }
        let baseScore = weightedBreakdown?.baseScore
        let resolvedTotalScore = weightedBreakdown?.totalScore ?? scoreRow?.totalScore
        let activeWeights = weightedBreakdown.map(OccasionHolidayScoringWeights.weights(for:))
            ?? OccasionHolidayScoringWeights.weights(
                objectRecognitionCompleted: objectRecognitionCompleted,
                objectScore: objectScore ?? 0
            )

        let occasionDate = occasions.fetchOccasionDateUnsafe(
            occasionId: occasionId,
            year: year
        )
        let anchorDateISO = occasionDate?.anchorISO
        let dateScoringBreakdown = buildDateScoringBreakdownUnsafe(
            eventId: eventId,
            includesDescendantPhotos: includesDescendantPhotos,
            occasion: occasion.scoring,
            occasionDate: occasionDate,
            year: year
        )
        let thanksgivingDateISO = occasion.scoring.occasionKey == "christmas"
            && occasion.scoring.usesThanksgivingRelativeStart
            ? USThanksgivingDate.dateISO(forYear: year)
            : nil

        let resolvedPhase = overridePhase
            ?? OccasionScoringThresholds.appliedPhase(
                objectRecognitionCompleted: objectRecognitionCompleted,
                objectScore: objectScore ?? 0
            )

        let occasionTunables: [AITagTunableSetting] = [
            AITagTunableSetting(
                label: "Weekend boost",
                value: String(format: "%.2f", occasion.scoring.weekendBoost)
            ),
            AITagTunableSetting(
                label: "Object min confidence",
                value: String(format: "%.2f", settings.holidayObjectMinConfidence)
            ),
        ]

        return AITagScoringDetail(
            tagLabel: tagLabel,
            tagCategory: tagCategory,
            occasionId: occasionId,
            occasionKey: occasion.scoring.occasionKey,
            occasionName: occasion.name,
            scoringYear: year,
            dateScoringBreakdown: dateScoringBreakdown,
            anchorDateISO: anchorDateISO,
            dateScore: dateScore,
            objectScore: objectScore,
            albumScore: albumScore,
            weekendScore: weekendScore,
            objectRecognitionCompleted: objectRecognitionCompleted,
            dateWeight: activeWeights.date,
            textWeight: activeWeights.text,
            objectWeight: activeWeights.object,
            baseScore: baseScore,
            totalScore: resolvedTotalScore,
            weightedBreakdown: weightedBreakdown,
            confidence: scoreRow?.confidence,
            appliedPhase: resolvedPhase,
            windowDaysBefore: occasion.scoring.windowDaysBefore,
            windowDaysAfter: occasion.scoring.windowDaysAfter,
            usesThanksgivingRelativeStart: occasion.scoring.usesThanksgivingRelativeStart,
            windowDaysAfterThanksgiving: occasion.scoring.usesThanksgivingRelativeStart
                ? occasion.scoring.windowDaysAfterThanksgiving
                : nil,
            thanksgivingDateISO: thanksgivingDateISO,
            weekendBoost: occasion.scoring.weekendBoost,
            scoringRules: ruleDetails,
            tunableSettings: tunableSettings(appliedPhase: resolvedPhase, settings: settings)
                + occasionTunables,
            unavailableReason: scoreRow == nil
                ? "No persisted occasion score row for this event/year."
                : nil,
            statusNote: holidayTagStatusNote(
                occasionKey: occasion.scoring.occasionKey,
                displayName: occasion.name,
                scoreRow: scoreRow,
                objectRecognitionCompleted: objectRecognitionCompleted,
                aiHolidayTag: aiHolidayTag,
                isBestMatch: isBestMatch,
                settings: settings
            )
        )
    }

    private func emptyHolidayScorecard(
        objectRecognitionCompleted: Bool,
        settings: EventTuningSettings
    ) -> AITagScoringDetail {
        let weights = OccasionHolidayScoringWeights.weights(
            objectRecognitionCompleted: objectRecognitionCompleted,
            objectScore: 0
        )
        return AITagScoringDetail(
            tagLabel: "No persisted scores",
            tagCategory: "Holiday scoring",
            occasionId: nil,
            occasionKey: nil,
            occasionName: nil,
            scoringYear: nil,
            dateScoringBreakdown: nil,
            anchorDateISO: nil,
            dateScore: nil,
            objectScore: nil,
            albumScore: nil,
            weekendScore: nil,
            objectRecognitionCompleted: objectRecognitionCompleted,
            dateWeight: weights.date,
            textWeight: weights.text,
            objectWeight: weights.object,
            baseScore: nil,
            totalScore: nil,
            weightedBreakdown: nil,
            confidence: nil,
            appliedPhase: objectRecognitionCompleted ? .postObject : .preObject,
            windowDaysBefore: nil,
            windowDaysAfter: nil,
            usesThanksgivingRelativeStart: false,
            windowDaysAfterThanksgiving: nil,
            thanksgivingDateISO: nil,
            weekendBoost: nil,
            scoringRules: [],
            tunableSettings: tunableSettings(appliedPhase: nil, settings: settings),
            unavailableReason:
                "No holiday score rows are stored for this event "
                + "(scores below 0.20 are not persisted). "
                + "Scores refresh when you open this screen.",
            statusNote: nil
        )
    }

    private func holidayTagStatusNote(
        occasionKey: String,
        displayName: String,
        scoreRow: OccasionRepository.EventOccasionScoreRow?,
        objectRecognitionCompleted: Bool,
        aiHolidayTag: (source: EventTagSource, tagValue: String)?,
        isBestMatch: Bool,
        settings: EventTuningSettings
    ) -> String? {
        guard let scoreRow else { return nil }

        let phase = OccasionScoringThresholds.appliedPhase(
            objectRecognitionCompleted: objectRecognitionCompleted,
            objectScore: scoreRow.objectScore
        )
        let qualifies = OccasionScoringThresholds.meetsHolidayTag(
            confidence: scoreRow.confidence,
            totalScore: scoreRow.totalScore,
            objectRecognitionCompleted: objectRecognitionCompleted,
            objectScore: scoreRow.objectScore,
            settings: settings
        )
        let tagValue = OccasionHolidayTagService.holidayTagValue(
            occasionKey: occasionKey,
            displayName: displayName
        )

        var parts: [String] = []
        if objectRecognitionCompleted, scoreRow.objectScore <= 0 {
            parts.append(
                "Object scan completed with no qualifying detections — metadata-only scores cannot keep an AI tag"
            )
        } else {
            parts.append(
                qualifies
                    ? "Meets \(phase == .preObject ? "pre-object" : "post-object") tag thresholds"
                    : "Below \(phase == .preObject ? "pre-object" : "post-object") tag thresholds"
            )
        }

        if isBestMatch {
            parts.append("Highest holiday score for this event")
        }

        if let aiHolidayTag {
            switch aiHolidayTag.source {
            case .ai:
                if aiHolidayTag.tagValue == tagValue {
                    parts.append("AI holiday tag applied")
                } else if isBestMatch {
                    parts.append("AI tag is “\(aiHolidayTag.tagValue)”")
                }
            case .user:
                parts.append("User holiday tag: \(aiHolidayTag.tagValue)")
            }
        } else if qualifies && isBestMatch {
            parts.append("Would receive AI holiday tag on sync")
        } else if isBestMatch {
            parts.append("No AI holiday tag on this event")
        }

        return parts.joined(separator: " · ")
    }

    private func buildDateScoringBreakdownUnsafe(
        eventId: Int,
        includesDescendantPhotos: Bool,
        occasion: OccasionForScoring,
        occasionDate: OccasionDateForScoring?,
        year: Int
    ) -> OccasionDateScoring.Breakdown? {
        guard let target = events.fetchEventOccasionScoringTargetUnsafe(eventId: eventId),
              let eventRange = resolveEventDateRangeUnsafe(
                target: target,
                includesDescendantPhotos: includesDescendantPhotos
              ),
              let occasionDate,
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
            return nil
        }

        return OccasionDateScoring.breakdown(
            eventStart: eventRange.start,
            eventEnd: eventRange.end,
            window: window
        )
    }

    private func resolveEventDateRangeUnsafe(
        target: EventOccasionScoringTarget,
        includesDescendantPhotos: Bool
    ) -> (start: Date, end: Date)? {
        var startISO = target.startDateISO
        var endISO = target.endDateISO

        if EventDateParser.parseDate(startISO) == nil || EventDateParser.parseDate(endISO) == nil,
           let photoRange = events.photoDateRangeISOForEventUnsafe(
            eventId: target.eventId,
            includesDescendantPhotos: includesDescendantPhotos
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

    private func tunableSettings(
        appliedPhase: EventTagAppliedPhase?,
        settings: EventTuningSettings
    ) -> [AITagTunableSetting] {
        switch appliedPhase {
        case .preObject:
            return [
                AITagTunableSetting(
                    label: "Pre-object min confidence",
                    value: settings.holidayTagPreObjectMinConfidence
                ),
                AITagTunableSetting(
                    label: "Pre-object min total score",
                    value: String(format: "%.2f", settings.holidayTagPreObjectMinTotalScore)
                ),
            ]
        case .postObject:
            return [
                AITagTunableSetting(
                    label: "Post-object min confidence",
                    value: settings.holidayTagPostObjectMinConfidence
                ),
                AITagTunableSetting(
                    label: "Post-object min total score",
                    value: String(format: "%.2f", settings.holidayTagPostObjectMinTotalScore)
                ),
            ]
        case nil:
            return [
                AITagTunableSetting(
                    label: "Pre-object min confidence",
                    value: settings.holidayTagPreObjectMinConfidence
                ),
                AITagTunableSetting(
                    label: "Pre-object min total score",
                    value: String(format: "%.2f", settings.holidayTagPreObjectMinTotalScore)
                ),
                AITagTunableSetting(
                    label: "Post-object min confidence",
                    value: settings.holidayTagPostObjectMinConfidence
                ),
                AITagTunableSetting(
                    label: "Post-object min total score",
                    value: String(format: "%.2f", settings.holidayTagPostObjectMinTotalScore)
                ),
            ]
        }
    }
}
