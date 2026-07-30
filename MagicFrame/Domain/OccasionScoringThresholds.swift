import Foundation

enum OccasionScoringThresholds {

    static func confidenceRank(_ confidence: String?) -> Int {
        switch confidence?.lowercased() {
        case "high": return 2
        case "medium": return 1
        case "low": return 0
        default: return -1
        }
    }

    static func meets(
        confidence: String?,
        totalScore: Double,
        minimumConfidence: String,
        minimumTotalScore: Double
    ) -> Bool {
        confidenceRank(confidence) >= confidenceRank(minimumConfidence)
            && totalScore >= minimumTotalScore
    }

    static func meetsHolidayTag(
        confidence: String?,
        totalScore: Double,
        objectRecognitionCompleted: Bool,
        objectScore: Double,
        settings: EventTuningSettings
    ) -> Bool {
        if objectRecognitionCompleted {
            // After object scan, metadata-only evidence is not enough to keep an AI tag.
            guard objectScore > 0 else {
                return false
            }

            let post = thresholds(for: .postObject, settings: settings)
            return meets(
                confidence: confidence,
                totalScore: totalScore,
                minimumConfidence: post.confidence,
                minimumTotalScore: post.totalScore
            )
        }

        let pre = thresholds(for: .preObject, settings: settings)
        return meets(
            confidence: confidence,
            totalScore: totalScore,
            minimumConfidence: pre.confidence,
            minimumTotalScore: pre.totalScore
        )
    }

    /// Post-object tag thresholds apply only after a scan found scorable object evidence.
    static func appliedPhase(
        objectRecognitionCompleted: Bool,
        objectScore: Double
    ) -> EventTagAppliedPhase {
        if objectRecognitionCompleted, objectScore > 0 {
            return .postObject
        }
        return .preObject
    }

    static func thresholds(
        for phase: EventTagAppliedPhase,
        settings: EventTuningSettings
    ) -> (confidence: String, totalScore: Double) {
        switch phase {
        case .preObject:
            return (
                settings.holidayTagPreObjectMinConfidence,
                settings.holidayTagPreObjectMinTotalScore
            )
        case .postObject:
            return (
                settings.holidayTagPostObjectMinConfidence,
                settings.holidayTagPostObjectMinTotalScore
            )
        }
    }
}
