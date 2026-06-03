import Foundation

enum LocationHomeRole: String, CaseIterable, Identifiable {
    case none
    case current
    case former

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Not a home"
        case .current: return "Current Home"
        case .former: return "Former Home"
        }
    }
}
