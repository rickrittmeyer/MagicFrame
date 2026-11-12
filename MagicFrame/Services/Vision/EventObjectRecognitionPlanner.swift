import Foundation

/// Chooses which object detection categories apply to an event.
struct EventObjectRecognitionPlanner {

    let eventTags: EventTagRepository

    func planCategoriesUnsafe(eventId: Int) -> [ObjectDetectionCategoryPlan] {
        let holidayValues = Set(eventTags.fetchHolidayTagValuesForEventUnsafe(eventId: eventId))
        guard !holidayValues.isEmpty else { return [] }

        return ObjectDetectionCategory.allCases.compactMap { category in
            guard holidayValues.contains(category.holidayTagValue),
                  !category.objectKeys.isEmpty else {
                return nil
            }
            return ObjectDetectionCategoryPlan(
                category: category,
                objectKeys: category.objectKeys,
                qualifyingScore: 1.0
            )
        }
        .sorted { $0.category.displayName < $1.category.displayName }
    }

    /// Plans object detection for a holiday category without requiring an existing holiday tag.
    func planForcedHolidayCategoryUnsafe(occasionKey: String) -> ObjectDetectionCategoryPlan? {
        guard let category = ObjectDetectionCategory(occasionKey: occasionKey),
              !category.objectKeys.isEmpty else {
            return nil
        }

        return ObjectDetectionCategoryPlan(
            category: category,
            objectKeys: category.objectKeys,
            qualifyingScore: 1.0
        )
    }
}
