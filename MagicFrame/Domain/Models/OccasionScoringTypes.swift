import Foundation

struct OccasionForScoring: Sendable {
    let occasionId: Int
    let occasionKey: String
    let occasionType: String
    let windowDaysBefore: Int
    let windowDaysAfter: Int
    let usesThanksgivingRelativeStart: Bool
    let windowDaysAfterThanksgiving: Int
    let weekendBoost: Double
}

struct OccasionDateForScoring: Sendable {
    let year: Int
    let dateISO: String
    let observedDateISO: String?
    let explicitStartISO: String?
    let explicitEndISO: String?

    var anchorISO: String {
        observedDateISO ?? dateISO
    }
}

struct OccasionScoringRule: Sendable {
    let signalType: String
    let signalValue: String
    let score: Double
}

struct EventOccasionScoreDraft: Sendable {
    let eventId: Int
    let occasionId: Int
    let year: Int
    let dateScore: Double
    let objectScore: Double
    let albumScore: Double
    let weekendScore: Double
    let totalScore: Double
    let confidence: String?
}

struct EventOccasionScoringTarget: Sendable {
    let eventId: Int
    let startDateISO: String
    let endDateISO: String
    /// Trip containers: include photos on child day events for dates and text/album signals.
    let includesDescendantPhotos: Bool
}

struct OccasionScoringTopMatch: Sendable {
    let rank: Int
    let occasionKey: String
    let occasionName: String
    let year: Int
    let totalScore: Double
    let dateScore: Double
    let objectScore: Double
    let albumScore: Double
    let weekendScore: Double
    let confidence: String?
    let eventId: Int
    let eventName: String
    let startDateISO: String
    let endDateISO: String

    var consoleLine: String {
        let conf = confidence ?? "—"
        let name = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? "event \(eventId)" : name
        return String(
            format: "#%d %@ %d · total %.2f (date %.2f, object %.2f, album %.2f, weekend %.2f, %@) · event %d “%@” %@–%@",
            rank,
            occasionKey,
            year,
            totalScore,
            dateScore,
            objectScore,
            albumScore,
            weekendScore,
            conf,
            eventId,
            title,
            startDateISO,
            endDateISO
        )
    }
}
