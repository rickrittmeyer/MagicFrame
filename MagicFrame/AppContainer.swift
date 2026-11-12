import Foundation

/// Composition root: wires persistence, repositories, and services for the app.
final class AppContainer {

    static let shared = AppContainer()

    let databaseManager: DatabaseManager
    let metadata: AppMetadataStore
    let photos: PhotoRepository
    let people: PeopleRepository
    let albums: AlbumRepository
    let photoTextMetadata: PhotoTextMetadataRepository
    let photoExif: PhotoExifRepository
    let albumImport: AlbumImportService
    let photoTextMetadataImport: PhotoTextMetadataImportService
    let photoExifImport: PhotoExifImportService
    let metadataEnrichment: MetadataEnrichmentService
    let events: EventRepository
    let eventTags: EventTagRepository
    let objectTags: ObjectTagRepository
    let visionJobs: VisionJobRepository
    let faceRecognition: FaceRecognitionRepository
    let pictureSearches: PictureSearchRepository
    let holidays: HolidayRepository
    private(set) lazy var faceRecognitionService: FaceRecognitionService = FaceRecognitionService(
        database: databaseManager,
        faces: faceRecognition,
        people: people
    )

    private(set) lazy var visionJobEnqueue: VisionJobEnqueueService = VisionJobEnqueueService(
        database: databaseManager,
        visionJobs: visionJobs,
        eventObjectRecognition: eventObjectRecognition,
        eventTags: eventTags,
        faceRecognition: faceRecognition
    )

    private(set) lazy var visionJobProcessor: VisionJobProcessor = VisionJobProcessor(
        database: databaseManager,
        eventObjectRecognition: eventObjectRecognition,
        faceRecognition: faceRecognitionService
    )

    private(set) lazy var visionJobCoordinator: VisionJobCoordinator = VisionJobCoordinator(
        database: databaseManager,
        visionJobs: visionJobs,
        processor: visionJobProcessor
    )

    private(set) lazy var eventObjectRecognition: EventObjectRecognitionService = EventObjectRecognitionService(
        database: databaseManager,
        events: events,
        objectTags: objectTags,
        eventTags: eventTags
    )

    let locations: LocationRepository
    let stadiums: StadiumRepository
    private(set) lazy var sportsGameLookup: SportsGameLookupService = SportsGameLookupService(
        stadiums: stadiums
    )
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
        albums = AlbumRepository(database: databaseManager)
        photoTextMetadata = PhotoTextMetadataRepository(database: databaseManager)
        photoExif = PhotoExifRepository(database: databaseManager)
        albumImport = AlbumImportService(albums: albums, photos: photos)
        photoTextMetadataImport = PhotoTextMetadataImportService(
            photos: photos,
            textMetadata: photoTextMetadata
        )
        photoExifImport = PhotoExifImportService(repository: photoExif)
        metadataEnrichment = MetadataEnrichmentService(
            albumImport: albumImport,
            photoTextImport: photoTextMetadataImport,
            database: databaseManager
        )
        events = EventRepository(database: databaseManager, photos: photos)
        eventTags = EventTagRepository(database: databaseManager)
        objectTags = ObjectTagRepository(database: databaseManager)
        visionJobs = VisionJobRepository(database: databaseManager)
        faceRecognition = FaceRecognitionRepository(database: databaseManager)
        holidays = HolidayRepository(database: databaseManager)
        pictureSearches = PictureSearchRepository(
            database: databaseManager,
            holidays: holidays
        )
        locations = LocationRepository(database: databaseManager, events: events)
        stadiums = StadiumRepository(database: databaseManager)
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
            backfillEventAttributeTagsFromColumns: { [eventTags] in
                eventTags.backfillAttributeTagsFromColumnsIfNeeded()
                eventTags.migrateMisclassifiedMilestoneEventTypesIfNeeded()
            }
        ))
    }
}
