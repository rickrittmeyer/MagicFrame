import Foundation

/// Scoped object groups for vision detection. Each category maps to a holiday occasion.
enum ObjectDetectionCategory: String, CaseIterable, Sendable {
    case christmas
    case halloween
    case mothersDay = "mothers_day"
    case fathersDay = "fathers_day"

    var occasionKey: String { rawValue }

    var displayName: String {
        switch self {
        case .christmas: return "Christmas"
        case .halloween: return "Halloween"
        case .mothersDay: return "Mother's Day"
        case .fathersDay: return "Father's Day"
        }
    }

    init?(occasionKey: String) {
        self.init(rawValue: occasionKey)
    }
}

struct ObjectDetectionCategoryPlan: Sendable, Equatable {
    let category: ObjectDetectionCategory
    let occasionId: Int
    let objectKeys: [String]
    let qualifyingScore: Double
}
