import Foundation

struct EventSyncProgress {
    let processed: Int
    let total: Int
    let remainingUnassigned: Int
    var statusMessage: String?
    var isRebuild: Bool = false
    var forcePublish: Bool = false

    var displayStatus: String {
        if let statusMessage {
            return statusMessage
        }

        if isRebuild {
            return "Rebuilding events… \(remainingUnassigned.formatted()) photos left"
        }

        return "Building events… \(remainingUnassigned.formatted()) photos left"
    }
}
