import Foundation

enum PhotoEventAssignmentMethod: String, Sendable {
    case gpsMatch = "gps_match"
    case timeMatch = "time_match"
    case albumTime = "album_time"
    case peopleTime = "people_time"
    case albumPeopleTime = "album_people_time"
    case manualDateAdjust = "manual_date_adjust"
}

enum PhotoEventAssignmentScorer {

    struct Input: Equatable {
        let sharedAlbums: Int
        let sharedPeople: Int
        let timeGapSeconds: TimeInterval
        let maxGapSeconds: TimeInterval
    }

    struct Output: Equatable {
        let confidence: Double
        let method: PhotoEventAssignmentMethod
        let needsReview: Bool
    }

    static func score(
        input: Input,
        tuning: EventTuningSettings
    ) -> Output? {
        guard input.maxGapSeconds > 0 else { return nil }

        let hasAlbumSignal = input.sharedAlbums >= tuning.metadataAttachMinSharedAlbums
        let hasPeopleSignal = input.sharedPeople >= tuning.metadataAttachMinSharedPeople

        guard hasAlbumSignal || hasPeopleSignal else { return nil }
        guard input.timeGapSeconds <= input.maxGapSeconds else { return nil }

        let timeScore = 1.0 - min(1.0, input.timeGapSeconds / input.maxGapSeconds)

        let albumComponent = min(1.0, Double(input.sharedAlbums) / 3.0)
        let peopleComponent = min(1.0, Double(input.sharedPeople) / 3.0)

        var confidence =
            tuning.metadataAttachAlbumWeight * albumComponent
            + tuning.metadataAttachPeopleWeight * peopleComponent
            + tuning.metadataAttachTimeWeight * timeScore

        if hasAlbumSignal && hasPeopleSignal {
            confidence = min(1.0, confidence + 0.1)
        }

        confidence = min(1.0, max(0.0, confidence))
        guard confidence >= tuning.metadataAttachMinConfidence else { return nil }

        let method: PhotoEventAssignmentMethod
        if hasAlbumSignal && hasPeopleSignal {
            method = .albumPeopleTime
        } else if hasPeopleSignal {
            method = .peopleTime
        } else {
            method = .albumTime
        }

        let needsReview = confidence < tuning.metadataAttachReviewConfidence

        return Output(confidence: confidence, method: method, needsReview: needsReview)
    }
}
