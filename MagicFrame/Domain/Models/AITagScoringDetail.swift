import Foundation

struct AITagScoringRuleDetail: Identifiable, Sendable, Equatable {
    let signalType: String
    let signalValue: String
    let score: Double
    let matched: Bool
    /// Distinct photos with this object above min confidence. Object rules only.
    let matchedPhotoCount: Int?

    var id: String { "\(signalType)|\(signalValue)" }

    var effectiveContribution: Double {
        guard matched else { return 0 }
        if signalType.lowercased() == "object",
           let matchedPhotoCount,
           matchedPhotoCount > 0 {
            return score * Double(matchedPhotoCount)
        }
        return score
    }

    var contributionLabel: String {
        if signalType.lowercased() == "object",
           let matchedPhotoCount,
           matchedPhotoCount > 0,
           matchedPhotoCount > 1 {
            return String(
                format: "+%.2f × %d photos = +%.2f",
                score,
                matchedPhotoCount,
                effectiveContribution
            )
        }
        return String(format: "+%.2f", effectiveContribution)
    }

    var displayLabel: String {
        let needle = Self.needle(from: signalValue) ?? signalValue

        switch signalType.lowercased() {
        case "keyword" where signalValue.hasPrefix("filename_contains:"):
            return "Filename contains “\(needle)”"
        case "keyword" where signalValue.hasPrefix("title_contains:"):
            return "Photo title contains “\(needle)”"
        case "album" where signalValue.hasPrefix("title_contains:"):
            return "Album title contains “\(needle)”"
        case "object":
            return "Object: \(OccasionObjectKeyFormatter.displayName(from: signalValue))"
        default:
            return "\(signalType): \(signalValue)"
        }
    }

    private static func needle(from signalValue: String) -> String? {
        for prefix in ["filename_contains:", "title_contains:", "keyword:"] {
            guard signalValue.hasPrefix(prefix) else { continue }
            let value = String(signalValue.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

struct AITagTunableSetting: Identifiable, Sendable, Equatable {
    let label: String
    let value: String

    var id: String { label }
}

struct AITagScoringDetail: Identifiable, Sendable, Equatable {
    let tagLabel: String
    let tagCategory: String
    let occasionId: Int?
    let occasionKey: String?
    let occasionName: String?
    let scoringYear: Int?

    let dateScoringBreakdown: OccasionDateScoring.Breakdown?
    let anchorDateISO: String?

    let dateScore: Double?
    let objectScore: Double?
    let albumScore: Double?
    let weekendScore: Double?
    let objectRecognitionCompleted: Bool
    let dateWeight: Double
    let textWeight: Double
    let objectWeight: Double
    let baseScore: Double?
    let totalScore: Double?
    let weightedBreakdown: OccasionHolidayScoringWeights.WeightedBreakdown?
    let confidence: String?
    let appliedPhase: EventTagAppliedPhase?

    let windowDaysBefore: Int?
    let windowDaysAfter: Int?
    let usesThanksgivingRelativeStart: Bool
    let windowDaysAfterThanksgiving: Int?
    let thanksgivingDateISO: String?
    let weekendBoost: Double?

    let scoringRules: [AITagScoringRuleDetail]
    let tunableSettings: [AITagTunableSetting]

    let unavailableReason: String?
    let statusNote: String?

    var id: String {
        if let occasionId, let scoringYear {
            return "\(occasionId)-\(scoringYear)"
        }
        return "holiday-scorecard-placeholder"
    }

    var hasScoreBreakdown: Bool {
        dateScore != nil || objectScore != nil || albumScore != nil || weekendScore != nil || totalScore != nil
    }

    var supportsDateScoringEdits: Bool {
        occasionId != nil && scoringYear != nil && anchorDateISO != nil
    }

    var textScoringRules: [AITagScoringRuleDetail] {
        scoringRules.filter {
            let type = $0.signalType.lowercased()
            return type == "keyword" || type == "album"
        }
    }

    var objectScoringRules: [AITagScoringRuleDetail] {
        scoringRules.filter { $0.signalType.lowercased() == "object" }
    }

    var matchedTextSignalRules: [AITagScoringRuleDetail] {
        textScoringRules.filter(\.matched)
    }

    var matchedObjectRules: [AITagScoringRuleDetail] {
        objectScoringRules.filter(\.matched)
    }

    var textSignalRawTotal: Double {
        matchedTextSignalRules.reduce(0) { $0 + $1.score }
    }

    var objectSignalRawTotal: Double {
        matchedObjectRules.reduce(0) { $0 + $1.effectiveContribution }
    }

    var textSignalWasCapped: Bool {
        textSignalRawTotal > 1.0
    }

    var objectSignalWasCapped: Bool {
        objectSignalRawTotal > 1.0
    }

    var supportsObjectScoringEdits: Bool {
        occasionId != nil && occasionKey != nil
    }
}
