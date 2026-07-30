import Foundation

struct EventDateDiagnosticCounts: Sendable {
    let activeEvents: Int
    let missingStartDate: Int
    let tripParentsMissingStartDate: Int

    var needsRepair: Bool {
        missingStartDate > 0
    }

    var summaryLine: String {
        if missingStartDate == 0 {
            return "All \(activeEvents.formatted()) events have start dates."
        }
        return "\(missingStartDate.formatted()) of \(activeEvents.formatted()) events missing a parseable start date"
    }

    var detailLine: String {
        if tripParentsMissingStartDate == 0 {
            return "Trip containers with missing dates: 0"
        }
        return "Trip containers with missing dates: \(tripParentsMissingStartDate.formatted())"
    }
}

struct EventDateRepairResult: Sendable {
    let tripParentsUpdated: Int
    let leafEventsUpdated: Int

    var summaryLine: String {
        "Repaired dates — \(leafEventsUpdated.formatted()) events, \(tripParentsUpdated.formatted()) trip containers"
    }
}
