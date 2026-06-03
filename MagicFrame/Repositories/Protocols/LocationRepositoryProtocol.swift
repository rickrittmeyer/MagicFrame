import Foundation

protocol LocationRepositoryProtocol: AnyObject {
    func countPendingGeocodeLocations() -> Int
    func fetchPendingGeocodeLocations(limit: Int?) -> [PendingLocation]
    func fetchEventLocationsNeedingGeocode(limit: Int?) -> [PendingLocation]
    func tryCopyNearbyGeocode(locationId: Int, latitude: Double, longitude: Double) -> Bool
    func startGeocodingAllPending()
    func startGeocodingEventLocations(limit: Int?)
    func completeLocationGeocode(
        locationId: Int,
        city: String?,
        state: String?,
        placeName: String?
    )
    func markLocationGeocodeFailed(locationId: Int)
    func getLocationTypeOptions() -> [String]
    func addCustomLocationType(_ type: String)
    func getLocationsRankedByEventCount() -> [ManagedLocation]
    func getLocation(locationId: Int) -> ManagedLocation?
    func locationsNeedingGeocodeCount() -> Int
    func updateLocationNickname(locationId: Int, nickname: String?)
    func updateLocationType(locationId: Int, locationType: String?)
    func setLocationFavorite(locationId: Int, isFavorite: Bool)
    func hasCurrentHome() -> Bool
    func createDesignatedCurrentHome(
        latitude: Double,
        longitude: Double,
        nickname: String?,
        homeStartDate: Date?
    ) -> Int
    func updateLocationHomeDesignation(
        locationId: Int,
        role: LocationHomeRole,
        homeStartDate: Date?,
        homeEndDate: Date?
    )
    func deduplicateLocationsByAddress(maxDistanceMiles: Double?) -> Int
}

extension LocationRepository: LocationRepositoryProtocol {}
