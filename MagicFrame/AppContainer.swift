import Foundation

/// Composition root: wires persistence, repositories, and services for the app.
final class AppContainer {

    static let shared = AppContainer()

    let databaseManager: DatabaseManager
    let metadata: AppMetadataStore
    let photos: PhotoRepository
    let people: PeopleRepository
    let peopleImport: PeopleImportService
    let albums: AlbumRepository
    let photoTextMetadata: PhotoTextMetadataRepository
    let albumImport: AlbumImportService
    let photoTextMetadataImport: PhotoTextMetadataImportService
    let metadataEnrichment: MetadataEnrichmentService
    let events: EventRepository
    let occasions: OccasionRepository
    let eventTags: EventTagRepository
    let objectTags: ObjectTagRepository
    let visionJobs: VisionJobRepository
    let photoOccasions: PhotoOccasionRepository
    let landingMetricsCache: OccasionLandingMetricsCache
    private(set) lazy var visionJobEnqueue: VisionJobEnqueueService = VisionJobEnqueueService(
        database: databaseManager,
        visionJobs: visionJobs,
        eventObjectRecognition: eventObjectRecognition,
        eventTags: eventTags
    )

    private(set) lazy var visionJobProcessor: VisionJobProcessor = VisionJobProcessor(
        database: databaseManager,
        eventObjectRecognition: eventObjectRecognition
    )

    private(set) lazy var visionJobCoordinator: VisionJobCoordinator = VisionJobCoordinator(
        database: databaseManager,
        visionJobs: visionJobs,
        processor: visionJobProcessor
    )

    private(set) lazy var eventObjectRecognition: EventObjectRecognitionService = EventObjectRecognitionService(
        database: databaseManager,
        events: events,
        occasions: occasions,
        objectTags: objectTags,
        eventTags: eventTags,
        occasionScoring: occasionScoring,
        tuning: { [weak self] in
            self?.photoDatabase.eventTuningUnsafe() ?? .defaults
        }
    )

    private(set) lazy var occasionScoring: OccasionScoringService = OccasionScoringService(
        database: databaseManager,
        occasions: occasions,
        events: events,
        holidayTags: OccasionHolidayTagService(
            database: databaseManager,
            eventTags: eventTags,
            tuning: { [weak self] in
                self?.photoDatabase.eventTuningUnsafe() ?? .defaults
            }
        ),
        tuning: { [weak self] in
            self?.photoDatabase.eventTuningUnsafe() ?? .defaults
        }
    )
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

    lazy var photoEventAssignment: PhotoEventAssignmentService = {
        PhotoEventAssignmentService(
            events: events,
            tuning: { [weak photoDatabase] in
                photoDatabase?.eventTuningUnsafe() ?? .defaults
            }
        )
    }()

    lazy var eventClustering: EventClusteringService = {
        EventClusteringService(
            host: photoDatabase,
            database: databaseManager,
            events: events,
            metadataAssignment: photoEventAssignment
        )
    }()

    private init(databaseManager: DatabaseManager = .shared) {
        self.databaseManager = databaseManager
        metadata = AppMetadataStore(database: databaseManager)
        photos = PhotoRepository(database: databaseManager, metadata: metadata)
        people = PeopleRepository(database: databaseManager)
        peopleImport = PeopleImportService(people: people)
        albums = AlbumRepository(database: databaseManager)
        photoTextMetadata = PhotoTextMetadataRepository(database: databaseManager)
        albumImport = AlbumImportService(albums: albums, photos: photos, people: people)
        photoTextMetadataImport = PhotoTextMetadataImportService(
            photos: photos,
            textMetadata: photoTextMetadata
        )
        metadataEnrichment = MetadataEnrichmentService(
            albumImport: albumImport,
            photoTextImport: photoTextMetadataImport,
            database: databaseManager
        )
        events = EventRepository(database: databaseManager, photos: photos)
        occasions = OccasionRepository(database: databaseManager, metadata: metadata)
        eventTags = EventTagRepository(database: databaseManager)
        objectTags = ObjectTagRepository(database: databaseManager)
        visionJobs = VisionJobRepository(database: databaseManager)
        photoOccasions = PhotoOccasionRepository(
            database: databaseManager,
            metadata: metadata
        )
        landingMetricsCache = OccasionLandingMetricsCache(
            database: databaseManager,
            metadata: metadata
        )
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
            repairStaleGeocodeStatuses: locations.repairStaleGeocodeStatuses,
            seedOccasionsIfNeeded: { [occasions] in
                occasions.ensureDefaultSeedData()
            },
            backfillPhotoOccasionFromLegacyOnFrame: { [photoOccasions] in
                _ = photoOccasions.backfillFromLegacyOnFrameIfNeeded()
            },
            backfillEventAttributeTagsFromColumns: { [eventTags] in
                eventTags.backfillAttributeTagsFromColumnsIfNeeded()
            }
        ))
    }
}
