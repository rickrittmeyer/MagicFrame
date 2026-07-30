import Foundation

struct OccasionDateScoringEdit: Sendable, Equatable {
    let anchorDate: Date
    let windowDaysBefore: Int
    let windowDaysAfter: Int
    let usesThanksgivingRelativeStart: Bool
    let windowDaysAfterThanksgiving: Int
}
