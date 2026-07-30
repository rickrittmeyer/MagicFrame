import Foundation

struct MetadataAssignmentCounts: Sendable {
    let unassignedNoGPS: Int
    let attachedViaMetadata: Int
    let attachedNeedingReview: Int

    var summaryLine: String {
        "\(attachedViaMetadata.formatted()) no-GPS photos attached to events via metadata"
    }

    var detailLine: String {
        "\(unassignedNoGPS.formatted()) no-GPS still unassigned · \(attachedNeedingReview.formatted()) need review"
    }
}
