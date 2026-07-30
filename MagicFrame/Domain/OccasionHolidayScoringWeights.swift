import Foundation

enum OccasionHolidayScoringWeights: Sendable {
    nonisolated static let preObjectDate = 0.65
    nonisolated static let preObjectText = 0.35

    nonisolated static let postObjectDate = 0.50
    nonisolated static let postObjectText = 0.25
    nonisolated static let postObjectObject = 0.25

    enum SelectedBaseFormula: String, Sendable, Equatable {
        case preObject
        case postObject
    }

    struct WeightedBreakdown: Sendable, Equatable {
        let dateScore: Double
        let cappedTextScore: Double
        let cappedObjectScore: Double
        let preObjectBase: Double
        let postObjectBase: Double?
        let baseScore: Double
        let selectedFormula: SelectedBaseFormula
        let dateWeight: Double
        let textWeight: Double
        let objectWeight: Double
        let weightedDateContribution: Double
        let weightedTextContribution: Double
        let weightedObjectContribution: Double
        let weekendScore: Double
        let totalScore: Double

        var formulaSummary: String {
            var parts: [String] = []

            let preLine = String(
                format: "pre-object %.2f×%.2f + %.2f×%.2f = %.2f",
                dateScore,
                OccasionHolidayScoringWeights.preObjectDate,
                cappedTextScore,
                OccasionHolidayScoringWeights.preObjectText,
                preObjectBase
            )
            parts.append(preLine)

            if let postObjectBase {
                let postLine = String(
                    format: "post-object %.2f×%.2f + %.2f×%.2f + %.2f×%.2f = %.2f",
                    dateScore,
                    OccasionHolidayScoringWeights.postObjectDate,
                    cappedTextScore,
                    OccasionHolidayScoringWeights.postObjectText,
                    cappedObjectScore,
                    OccasionHolidayScoringWeights.postObjectObject,
                    postObjectBase
                )
                parts.append(postLine)
                if selectedFormula == .postObject {
                    parts.append(String(format: "base %.2f (post-object wins)", baseScore))
                } else {
                    parts.append(String(format: "base %.2f (pre-object wins)", baseScore))
                }
            } else {
                parts.append(String(format: "base %.2f", baseScore))
            }

            if weekendScore > 0 {
                parts.append(
                    String(format: "total min(1.00, %.2f + %.2f weekend) = %.2f", baseScore, weekendScore, totalScore)
                )
            } else {
                parts.append(String(format: "total %.2f", totalScore))
            }

            return parts.joined(separator: " · ")
        }
    }

    nonisolated static func usesPostObjectWeights(
        objectRecognitionCompleted: Bool,
        objectScore: Double
    ) -> Bool {
        objectRecognitionCompleted && objectScore > 0
    }

    nonisolated static func weightedBreakdown(
        dateScore: Double,
        textScore: Double,
        objectScore: Double,
        weekendScore: Double,
        objectRecognitionCompleted: Bool
    ) -> WeightedBreakdown {
        let cappedTextScore = min(1.0, textScore)
        let cappedObjectScore = min(1.0, objectScore)

        let preObjectBase = dateScore * preObjectDate + cappedTextScore * preObjectText

        var postObjectBase: Double?
        var baseScore = preObjectBase
        var selectedFormula = SelectedBaseFormula.preObject
        var dateWeight = preObjectDate
        var textWeight = preObjectText
        var objectWeight = 0.0
        var weightedDateContribution = dateScore * preObjectDate
        var weightedTextContribution = cappedTextScore * preObjectText
        var weightedObjectContribution = 0.0

        if usesPostObjectWeights(
            objectRecognitionCompleted: objectRecognitionCompleted,
            objectScore: cappedObjectScore
        ) {
            let postBase = dateScore * postObjectDate
                + cappedTextScore * postObjectText
                + cappedObjectScore * postObjectObject
            postObjectBase = postBase
            if postBase >= preObjectBase {
                baseScore = postBase
                selectedFormula = .postObject
                dateWeight = postObjectDate
                textWeight = postObjectText
                objectWeight = postObjectObject
                weightedDateContribution = dateScore * postObjectDate
                weightedTextContribution = cappedTextScore * postObjectText
                weightedObjectContribution = cappedObjectScore * postObjectObject
            }
        }

        let totalScore = min(1.0, baseScore + weekendScore)

        return WeightedBreakdown(
            dateScore: dateScore,
            cappedTextScore: cappedTextScore,
            cappedObjectScore: cappedObjectScore,
            preObjectBase: preObjectBase,
            postObjectBase: postObjectBase,
            baseScore: baseScore,
            selectedFormula: selectedFormula,
            dateWeight: dateWeight,
            textWeight: textWeight,
            objectWeight: objectWeight,
            weightedDateContribution: weightedDateContribution,
            weightedTextContribution: weightedTextContribution,
            weightedObjectContribution: weightedObjectContribution,
            weekendScore: weekendScore,
            totalScore: totalScore
        )
    }

    nonisolated static func baseScore(
        dateScore: Double,
        textScore: Double,
        objectScore: Double,
        objectRecognitionCompleted: Bool
    ) -> Double {
        weightedBreakdown(
            dateScore: dateScore,
            textScore: textScore,
            objectScore: objectScore,
            weekendScore: 0,
            objectRecognitionCompleted: objectRecognitionCompleted
        ).baseScore
    }

    nonisolated static func weights(
        for breakdown: WeightedBreakdown
    ) -> (date: Double, text: Double, object: Double) {
        (breakdown.dateWeight, breakdown.textWeight, breakdown.objectWeight)
    }

    nonisolated static func weights(
        objectRecognitionCompleted: Bool,
        objectScore: Double = 0
    ) -> (date: Double, text: Double, object: Double) {
        if usesPostObjectWeights(
            objectRecognitionCompleted: objectRecognitionCompleted,
            objectScore: objectScore
        ) {
            return (postObjectDate, postObjectText, postObjectObject)
        }
        return (preObjectDate, preObjectText, 0)
    }
}
