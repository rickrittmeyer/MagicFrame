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

    static let defaults = EventTuningSettings()

    var eventMatchMaxGapSeconds: TimeInterval { eventMatchMaxGapHours * 3600 }
    var tripMergeMaxGapSeconds: TimeInterval { tripMergeMaxGapHours * 3600 }
    var tripSubEventMaxGapSeconds: TimeInterval { tripSubEventMaxGapHours * 3600 }
}
