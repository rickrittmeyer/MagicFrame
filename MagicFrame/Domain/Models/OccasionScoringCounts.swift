import Foundation

struct OccasionScoringCounts: Sendable {
    let holidayOccasions: Int
    let scoringRules: Int
    let scoredRows: Int
    let highConfidence: Int
    let mediumConfidence: Int
    let lowConfidence: Int

    var summaryLine: String {
        "\(scoredRows.formatted()) event–occasion scores"
        + " (\(highConfidence.formatted()) high · \(mediumConfidence.formatted()) med · \(lowConfidence.formatted()) low)"
    }

    var detailLine: String {
        "\(holidayOccasions.formatted()) holiday occasions · \(scoringRules.formatted()) rules"
    }
}

struct OccasionScoringRunResult: Sendable {
    let eventsConsidered: Int
    let rowsWritten: Int
    let rowsSkippedBelowThreshold: Int

    var summaryLine: String {
        "Holiday scoring: \(rowsWritten.formatted()) scores written for \(eventsConsidered.formatted()) events"
    }

    var detailLine: String {
        "\(rowsSkippedBelowThreshold.formatted()) candidate pairs below threshold"
    }
}
