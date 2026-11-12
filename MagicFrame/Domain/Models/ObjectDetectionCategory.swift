import Foundation

/// Scoped object groups for vision detection. Each category maps to a holiday tag.
enum ObjectDetectionCategory: String, CaseIterable, Sendable {
    case christmas
    case halloween
    case mothersDay = "mothers_day"
    case fathersDay = "fathers_day"

    /// Stable slug used by Vision job payloads (formerly occasion keys).
    var occasionKey: String { rawValue }

    var displayName: String {
        switch self {
        case .christmas: return "Christmas"
        case .halloween: return "Halloween"
        case .mothersDay: return "Mother's Day"
        case .fathersDay: return "Father's Day"
        }
    }

    /// Holiday `event_tags.tagValue` for this category.
    var holidayTagValue: String { displayName }

    /// Hardcoded Vision object keys (formerly occasion_scoring_rules object signals).
    var objectKeys: [String] {
        switch self {
        case .christmas:
            return ["christmas_tree", "ornament", "santa"]
        case .halloween:
            return ["pumpkin", "jack_o_lantern", "costume"]
        case .mothersDay:
            return ["flower", "bouquet"]
        case .fathersDay:
            return ["gift"]
        }
    }

    init?(occasionKey: String) {
        self.init(rawValue: occasionKey)
    }

    init?(holidayTagValue: String) {
        let trimmed = holidayTagValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = Self.allCases.first(where: { $0.holidayTagValue == trimmed }) else {
            return nil
        }
        self = match
    }
}

struct ObjectDetectionCategoryPlan: Sendable, Equatable {
    let category: ObjectDetectionCategory
    let objectKeys: [String]
    let qualifyingScore: Double
}
