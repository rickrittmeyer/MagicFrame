import Foundation

enum MilestonePersonPickerKind: String, Identifiable, Sendable {
    case birthday
    case graduation
    case baptism
    case wedding
    case anniversary

    var id: String { rawValue }

    var isCoupleMilestone: Bool {
        self == .wedding || self == .anniversary
    }

    var navigationTitle: String {
        switch self {
        case .birthday: return "Who's Birthday?"
        case .graduation: return "Who's Graduation?"
        case .baptism: return "Who's Baptism?"
        case .wedding: return "Who's Wedding?"
        case .anniversary: return "Whose Anniversary?"
        }
    }

    var firstPersonStepTitle: String {
        switch self {
        case .wedding: return "Who is the Bride?"
        case .anniversary: return "Who is the first person?"
        default: return navigationTitle
        }
    }

    var secondPersonStepTitle: String {
        switch self {
        case .wedding: return "Who is the Groom?"
        case .anniversary: return "Who is the second person?"
        default: return navigationTitle
        }
    }

    var weddingDateStepTitle: String {
        "Wedding Date"
    }

    var emptyDescription: String {
        switch self {
        case .birthday:
            return "Add people to your library to choose whose birthday this is."
        case .graduation:
            return "Add people to your library to choose whose graduation this is."
        case .baptism:
            return "Add people to your library to choose whose baptism this is."
        case .wedding:
            return "Add people to your library to choose who is getting married."
        case .anniversary:
            return "Add people to your library to choose whose anniversary this is."
        }
    }

    static func from(milestoneType: String?) -> MilestonePersonPickerKind? {
        guard let milestoneType else { return nil }
        let trimmed = milestoneType.trimmingCharacters(in: .whitespacesAndNewlines)
        if MilestonePictureSearchDefaults.isPersonBirthdayTagValue(trimmed) {
            return .birthday
        }
        switch trimmed.lowercased() {
        case "graduation": return .graduation
        case "baptism": return .baptism
        case "wedding": return .wedding
        case "anniversary": return .anniversary
        default: return nil
        }
    }
}
