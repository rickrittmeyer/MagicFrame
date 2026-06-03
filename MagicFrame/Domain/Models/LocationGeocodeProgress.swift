import Foundation

struct LocationGeocodeProgress {
    let queueCount: Int
    let isProcessing: Bool
    let pendingInDatabase: Int

    var displayRemaining: Int {
        max(queueCount + (isProcessing ? 1 : 0), pendingInDatabase)
    }

    var isActive: Bool {
        isProcessing || displayRemaining > 0
    }
}
