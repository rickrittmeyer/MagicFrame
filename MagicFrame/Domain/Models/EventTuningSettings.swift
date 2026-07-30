import Foundation

struct EventTuningSettings: Codable, Equatable {
    static let storageKey = "eventTuningSettings"

    var localEventMatchMiles: Double = 1.0
    var tripEventMatchMiles: Double = 40.0
    var awayFromHomeMiles: Double = 50.0
    var eventMatchMaxGapHours: Double = 8.0
    var eventMatchDistanceWeight: Double = 600.0

    var sameDayEventMergeMiles: Double = 0.75
    var tripMergeMaxGapHours: Double = 36.0
    var tripSubEventMatchMiles: Double = 2.0
    var tripSubEventMaxGapHours: Double = 4.0

    var locationMatchMiles: Double = 0.05
    var curatedLocationMatchMiles: Double = 0.03
    var samePlaceNameMergeMiles: Double = 0.5
    var addressDeduplicationMaxMiles: Double = 1.0
    var frequentPlaceMergeMiles: Double = 0.35
    var frequentPlaceMinEvents: Int = 5
    var homeLocationMergeMiles: Double = 0.12
    var homeEventSnapMiles: Double = 0.2

    /// Pass 2: attach no-GPS photos to existing GPS-backed events (album / people / time).
    var metadataAttachMaxGapHours: Double = 24.0
    var metadataAttachMinConfidence: Double = 0.40
    var metadataAttachReviewConfidence: Double = 0.55
    var metadataAttachMinSharedAlbums: Int = 1
    var metadataAttachMinSharedPeople: Int = 1
    var metadataAttachAlbumWeight: Double = 0.45
    var metadataAttachPeopleWeight: Double = 0.40
    var metadataAttachTimeWeight: Double = 0.15
    var metadataAttachBatchSize: Int = 500

    /// AI holiday tag before object recognition (date + metadata signals).
    var holidayTagPreObjectMinConfidence: String = "medium"
    var holidayTagPreObjectMinTotalScore: Double = 0.45

    /// AI holiday tag after object scan found scorable holiday objects on the event.
    var holidayTagPostObjectMinConfidence: String = "medium"
    var holidayTagPostObjectMinTotalScore: Double = 0.60

    /// Minimum detection confidence for an object rule to match on an event.
    var holidayObjectMinConfidence: Double = 0.25

    static let defaults = EventTuningSettings()

    var metadataAttachMaxGapSeconds: TimeInterval { metadataAttachMaxGapHours * 3600 }

    var eventMatchMaxGapSeconds: TimeInterval { eventMatchMaxGapHours * 3600 }
    var tripMergeMaxGapSeconds: TimeInterval { tripMergeMaxGapHours * 3600 }
    var tripSubEventMaxGapSeconds: TimeInterval { tripSubEventMaxGapHours * 3600 }
}
