import Foundation

struct PhotoOccasionBackfillResult: Sendable {
    let didRun: Bool
    let rowsUpserted: Int

    static let skipped = PhotoOccasionBackfillResult(didRun: false, rowsUpserted: 0)
}
