import Foundation

/// Batches geocode requests while on the database queue, then flushes to the coordinator.
final class LocationGeocodePendingQueue {

    private let database: DatabaseManager
    private let locations: LocationRepository
    private var pending: [PendingLocation] = []

    init(database: DatabaseManager, locations: LocationRepository) {
        self.database = database
        self.locations = locations
    }

    func requestFreshGeocode(locationId: Int, latitude: Double, longitude: Double) {
        locations.resetLocationGeocodeToPending(locationId: locationId)
        let item = PendingLocation(
            locationId: locationId,
            latitude: latitude,
            longitude: longitude
        )

        if database.isOnQueue {
            pending.append(item)
        } else {
            LocationGeocodeCoordinator.shared.enqueue([item])
        }
    }

    func flush() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        LocationGeocodeCoordinator.shared.enqueue(batch)
    }
}
