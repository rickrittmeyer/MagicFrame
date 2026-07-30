import Foundation

struct EditableOccasion: Identifiable, Equatable, Sendable {
    let occasionId: Int
    let occasionKey: String
    var name: String
    let occasionType: String
    var windowDaysBefore: Int
    var windowDaysAfter: Int
    var usesThanksgivingRelativeStart: Bool
    var windowDaysAfterThanksgiving: Int
    var weekendBoost: Double
    var isEnabled: Bool

    var id: Int { occasionId }

    var windowSummary: String {
        if occasionKey == "christmas", usesThanksgivingRelativeStart {
            return "Thanksgiving +\(windowDaysAfterThanksgiving) / Christmas +\(windowDaysAfter) days"
        }
        return "−\(windowDaysBefore) / +\(windowDaysAfter) days"
    }
}
