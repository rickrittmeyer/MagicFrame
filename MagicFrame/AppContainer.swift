import Foundation

/// Composition root: wires persistence, repositories, and services for the app.
final class AppContainer {

    static let shared = AppContainer()

    let databaseManager: DatabaseManager
    let metadata: AppMetadataStore
    let photos: PhotoRepository
    let people: PeopleRepository
    let peopleImport: PeopleImportService
    let events: EventRepository
    let locations: LocationRepository
    let geocodePendingQueue: LocationGeocodePendingQueue

    private(set) lazy var photoDatabase: PhotoDatabase = PhotoDatabase(container: self)

    lazy var eventLocations: EventLocationCoordinator = {
        EventLocationCoordinator(
            database: databaseManager,
            locations: locations,
            events: events,
            geocodeQueue: geocodePendingQueue,
            eventTuning: { [weak photoDatabase] in
                photoDatabase?.eventTuningUnsafe() ?? .defaults
            }
        )
    }()

    lazy var eventClustering: EventClusteringService = {
        EventClusteringService(
            host: photoDatabase,
            database: databaseManager,
            events: events
        )
    }()

    private init(databaseManager: DatabaseManager = .shared) {
        self.databaseManager = databaseManager
        metadata = AppMetadataStore(database: databaseManager)
        photos = PhotoRepository(database: databaseManager, metadata: metadata)
        people = PeopleRepository(database: databaseManager)
        peopleImport = PeopleImportService(people: people)
        events = EventRepository(database: databaseManager, photos: photos)
        locations = LocationRepository(database: databaseManager, events: events)
        photos.bindLocations(locations)
        geocodePendingQueue = LocationGeocodePendingQueue(
            database: databaseManager,
            locations: locations
        )

        databaseManager.bootstrapSchema(legacyHooks: LegacyDataMigrationHooks(
            migrateLegacyTripEventType: events.migrateLegacyTripEventTypeAttribute,
            migrateLegacyHomeLocations: locations.migrateLegacyHomeLocations,
            migrateTripSubEventChildNames: events.migrateTripSubEventChildNamesIfNeeded,
            repairStaleGeocodeStatuses: locations.repairStaleGeocodeStatuses
        ))
    }
}
