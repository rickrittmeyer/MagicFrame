import Foundation

/// Chooses which object detection categories apply to an event.
struct EventObjectRecognitionPlanner {

    let occasions: OccasionRepository
    let tuning: () -> EventTuningSettings

    func planCategoriesUnsafe(eventId: Int) -> [ObjectDetectionCategoryPlan] {
        let threshold = tuning().holidayTagPreObjectMinTotalScore
        let qualifyingRows = occasions.fetchQualifyingHolidayScoresUnsafe(
            eventId: eventId,
            minimumTotalScore: threshold
        )

        var plans: [ObjectDetectionCategoryPlan] = []

        for row in qualifyingRows {
            guard let category = ObjectDetectionCategory(occasionKey: row.occasionKey) else {
                continue
            }

            let objectKeys = occasions.fetchObjectScoringRulesUnsafe(occasionId: row.occasionId)
                .map(\.objectKey)
            guard !objectKeys.isEmpty else { continue }

            plans.append(
                ObjectDetectionCategoryPlan(
                    category: category,
                    occasionId: row.occasionId,
                    objectKeys: objectKeys,
                    qualifyingScore: row.totalScore
                )
            )
        }

        return plans.sorted {
            $0.qualifyingScore == $1.qualifyingScore
                ? $0.category.displayName < $1.category.displayName
                : $0.qualifyingScore > $1.qualifyingScore
        }
    }

    /// Plans object detection for a holiday occasion without requiring a qualifying metadata score.
    func planForcedHolidayCategoryUnsafe(occasionKey: String) -> ObjectDetectionCategoryPlan? {
        guard let category = ObjectDetectionCategory(occasionKey: occasionKey),
              let occasionId = occasions.fetchOccasionIdForKeyUnsafe(occasionKey: occasionKey),
              let occasion = occasions.fetchOccasionByIdUnsafe(occasionId: occasionId),
              occasion.scoring.occasionType == "holiday" else {
            return nil
        }

        let objectKeys = occasions.fetchObjectScoringRulesUnsafe(occasionId: occasionId)
            .map(\.objectKey)
        guard !objectKeys.isEmpty else { return nil }

        return ObjectDetectionCategoryPlan(
            category: category,
            occasionId: occasionId,
            objectKeys: objectKeys,
            qualifyingScore: 1.0
        )
    }
}
