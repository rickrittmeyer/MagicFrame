import Foundation

/// Drives incremental Vision scans when a holiday collection year section expands.
struct HolidayVisionLandingConfig: Equatable, Sendable {
    /// Category slug (`ObjectDetectionCategory.rawValue`); kept as `occasionKey` for Vision job payloads.
    let occasionKey: String
    let tagValue: String
    let displayName: String

    var logLabel: String { displayName }

    static func from(_ category: ObjectDetectionCategory) -> HolidayVisionLandingConfig? {
        guard !category.objectKeys.isEmpty else { return nil }
        return HolidayVisionLandingConfig(
            occasionKey: category.occasionKey,
            tagValue: category.holidayTagValue,
            displayName: category.displayName
        )
    }

    static var allWithObjectKeys: [HolidayVisionLandingConfig] {
        ObjectDetectionCategory.allCases.compactMap(from)
    }

    static func matching(tagValue: String) -> HolidayVisionLandingConfig? {
        guard let category = ObjectDetectionCategory(holidayTagValue: tagValue) else {
            return nil
        }
        return from(category)
    }
}
