import Foundation
import Combine
import Photos

struct EventListDisplayItem: Identifiable {
    let event: IndexedEvent
    let slideshowPhotoIds: [String]

    var id: Int { event.eventId }

    init(event: IndexedEvent, slideshowPhotoIds: [String] = []) {
        self.event = event
        self.slideshowPhotoIds = slideshowPhotoIds
    }
}

struct EventYearSection: Identifiable {
    let year: Int
    let items: [EventListDisplayItem]

    var id: Int { year }

    var eventCount: Int { items.count }

    var photoCount: Int {
        items.reduce(0) { $0 + $1.event.photoCount }
    }
}

struct EventListScrollTarget: Equatable {
    let eventId: Int
    let requestID: UUID
}

@MainActor
final class LibraryViewModel: ObservableObject {

    let database: any MagicFrameDatabase

    @Published var statusText: String = "Ready"
    @Published var events: [IndexedEvent] = []
    @Published var eventSections: [EventYearSection] = []
    @Published var eventListScrollTarget: EventListScrollTarget?
    @Published var recentPhotos: [IndexedPhoto] = []

    @Published var isSyncingEvents: Bool = false
    @Published var isBuildingCovers: Bool = false
    @Published var isLoadingEvents: Bool = false
    @Published var isLoadingRecentPhotos: Bool = false
    @Published var isIndexingPhotos: Bool = false
    @Published var isMaintainingEvents: Bool = false
    @Published var isReconcilingPhotos: Bool = false
    @Published var indexedPhotoCount: Int = 0
    @Published var showHomeOnboarding = false
    @Published var showHiddenEvents = false

    var isLibraryBusy: Bool {
        isIndexingPhotos || isSyncingEvents || isReconcilingPhotos
    }

    /// Photo import replaces the events list; sync/rebuild keeps it visible and refreshes in place.
    var hidesEventsList: Bool {
        isIndexingPhotos
    }

    var showsEventsLoadingPlaceholder: Bool {
        hidesEventsList || (isSyncingEvents && eventSections.isEmpty)
    }

    var showsBackgroundWorkBanner: Bool {
        isLibraryBusy || isMaintainingEvents || isShowingGeocodeProgress
    }

    private static let lastPhotoReconcileDefaultsKey = "lastPhotoLibraryReconcileAt"
    private static let photoReconcileThrottleInterval: TimeInterval = 6 * 60 * 60

    var eventsEmptyHint: String {
        if showHomeOnboarding {
            return "Set your home first so events group correctly."
        }
        if showHiddenEvents {
            return "No hidden events."
        }
        if isIndexingPhotos {
            return "Importing photos from your library…"
        }
        if isSyncingEvents || isMaintainingEvents {
            return statusText
        }
        if indexedPhotoCount == 0 {
            return "No photos indexed yet. Use Developer → Index Photos, or allow photo access when prompted."
        }
        return "No events yet. Try Developer → Sync Events if sync did not start automatically."
    }

    private var baseStatusText = "Ready"
    private var isShowingGeocodeProgress = false
    private var lastStatusPublish = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private var pipelineTask: Task<Void, Never>?

    init(database: any MagicFrameDatabase = AppDependencies.database) {
        self.database = database
        NotificationCenter.default.publisher(for: .locationGeocodeProgressChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let progress = notification.object as? LocationGeocodeProgress else {
                    return
                }
                self.handleGeocodeProgress(progress)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .eventSyncProgressChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let progress = notification.object as? EventSyncProgress else {
                    return
                }
                self.handleEventSyncProgress(progress)
            }
            .store(in: &cancellables)
    }

    private func handleEventSyncProgress(_ progress: EventSyncProgress) {
        guard !isShowingGeocodeProgress else { return }

        if let statusMessage = progress.statusMessage {
            publishStatusThrottled(statusMessage)
            return
        }

        publishStatusThrottled(progress.displayStatus)
    }

    private func publishStatusThrottled(_ text: String, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastStatusPublish) >= 0.75 else { return }
        lastStatusPublish = now
        statusText = text
    }

    @Published var archivePhotoCount: Int = 0

    func onAppear() {
        guard pipelineTask == nil else { return }

        let db = database
        pipelineTask = Task.detached(priority: .utility) { [weak self] in
            db.stopGeocoding()
            await self?.runStartupPipeline()
        }
    }

    private func runStartupPipeline() async {
        await MainActor.run {
            refreshLibraryCounts()
            isSyncingEvents = false
            isMaintainingEvents = false
            isIndexingPhotos = false
            isReconcilingPhotos = false
            isShowingGeocodeProgress = false
        }

        let db = database
        let hasHome = await Task.detached(priority: .utility) {
            db.hasCurrentHome()
        }.value

        guard hasHome else {
            await MainActor.run {
                showHomeOnboarding = true
                pipelineTask = nil
            }
            return
        }

        let photoCount = await MainActor.run { indexedPhotoCount }

        if photoCount > 0 {
            let eventCount = await Task.detached(priority: .utility) {
                db.getEvents(includeHidden: false).count
            }.value

            if eventCount > 0 {
                await reloadEventsAsync()
                await reconcileDeletedPhotosIfNeeded(force: false)
                await MainActor.run {
                    pipelineTask = nil
                }
                return
            }
        }

        await continueLibraryBootstrap()
        await reconcileDeletedPhotosIfNeeded(force: false)
        await MainActor.run {
            pipelineTask = nil
        }
    }

    func handleScenePhaseActive() {
        guard pipelineTask == nil else { return }
        guard !isLibraryBusy else { return }

        pipelineTask = Task.detached(priority: .utility) { [weak self] in
            await self?.reconcileDeletedPhotosIfNeeded(force: false)
            await MainActor.run {
                self?.pipelineTask = nil
            }
        }
    }

    func homeOnboardingCompleted() {
        showHomeOnboarding = false
        pipelineTask?.cancel()
        pipelineTask = Task.detached(priority: .utility) { [weak self] in
            await self?.continueLibraryBootstrap(reindexAfterHomeSetup: true)
            await self?.reconcileDeletedPhotosIfNeeded(force: false)
            await MainActor.run {
                self?.pipelineTask = nil
            }
        }
    }

    private func continueLibraryBootstrap(reindexAfterHomeSetup: Bool = false) async {
        await MainActor.run {
            refreshLibraryCounts()
        }

        let needsIndex = await MainActor.run { indexedPhotoCount == 0 }
        if needsIndex {
            await indexPhotosFromLibrary()
        } else if reindexAfterHomeSetup {
            await performEventRebuild()
        } else {
            await performEventSyncIfNeeded()
        }

        if needsIndex {
            await performEventSync(forceMaintenance: true)
        }

        await reloadEventsAsync()

        let db = database
        Task.detached(priority: .utility) { [weak self] in
            db.restoreDeletedTripContainersOnQueue()
            db.repairHomeLocations()
            await self?.reloadEventsAsync()
            await MainActor.run {
                self?.refreshLibraryCounts()
            }
        }
    }

    func reloadEventsAsync() async {
        await MainActor.run {
            isLoadingEvents = true
        }

        let includeHidden = await MainActor.run { showHiddenEvents }

        let db = database
        let loaded = await Task.detached(priority: .utility) {
            db.getEvents(includeHidden: includeHidden)
        }.value

        let slideshowIdsByEvent = await Task.detached(priority: .utility) {
            db.getSlideshowPhotoIds(for: loaded)
        }.value
        let sections = Self.buildEventSections(from: loaded, slideshowIdsByEvent: slideshowIdsByEvent)

        await MainActor.run {
            events = loaded
            eventSections = sections
            isLoadingEvents = false
            setBaseStatus("\(events.count) events")
        }
    }

    nonisolated private static func buildEventSections(
        from events: [IndexedEvent],
        slideshowIdsByEvent: [Int: [String]]
    ) -> [EventYearSection] {
        let items = events.map { event in
            EventListDisplayItem(
                event: event,
                slideshowPhotoIds: slideshowIdsByEvent[event.eventId] ?? []
            )
        }
        let grouped = Dictionary(grouping: items) { item in
            item.event.eventYear ?? 0
        }

        return grouped.keys
            .sorted(by: >)
            .map { year in
                EventYearSection(
                    year: year,
                    items: grouped[year, default: []]
                        .sorted { $0.event.startDate > $1.event.startDate }
                )
            }
    }

    func resumeBackgroundWork() async {
        // Intentionally idle — geocoding is user-triggered from Locations/Developer.
    }

    func stopAllBackgroundWork() {
        pipelineTask?.cancel()
        pipelineTask = nil
        database.stopGeocoding()
        isSyncingEvents = false
        isMaintainingEvents = false
        isIndexingPhotos = false
        isReconcilingPhotos = false
        isShowingGeocodeProgress = false
        publishStatusThrottled("Background work stopped", force: true)
    }

    func refreshArchivePhotoCount() {
        archivePhotoCount = database.countPhotosMissingLocation()
    }

    func refreshLibraryCounts() {
        indexedPhotoCount = database.countActivePhotos()
        refreshArchivePhotoCount()
    }

    func indexPhotosFromLibrary() async {
        guard !isIndexingPhotos else { return }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized, .limited:
            break
        case .denied:
            setBaseStatus("Photo access denied — enable in Settings")
            return
        case .restricted:
            setBaseStatus("Photo access restricted")
            return
        default:
            setBaseStatus("Photo access unavailable")
            return
        }

        isIndexingPhotos = true
        defer {
            isIndexingPhotos = false
            refreshLibraryCounts()
        }

        events = []
        eventSections = []
        recentPhotos = []
        statusText = "Indexing photos…"

        let db = database
        let indexResult = await Task.detached(priority: .utility) { [weak self] in
            Self.enumeratePhotoLibrary(database: db) { count in
                guard count == 1 || count % 1000 == 0 else { return }
                Task { @MainActor in
                    self?.publishStatusThrottled("Indexed \(count.formatted()) photos…")
                }
            }
        }.value

        var deletedCount = 0
        if status == .authorized {
            publishStatusThrottled("Removing deleted photos…", force: true)
            deletedCount = await Task.detached(priority: .utility) {
                db.reconcileDeletedLibraryPhotos(currentIds: indexResult.ids)
            }.value
            Self.markPhotoReconcileCompleted()
        }

        await Task.detached(priority: .utility) {
            db.importPeopleFromAlbums()
            db.rebuildEventPeople()
        }.value

        if deletedCount > 0 {
            setBaseStatus(
                "Indexed \(indexResult.count.formatted()) photos, removed \(deletedCount.formatted()) deleted — building events…"
            )
        } else {
            setBaseStatus("Indexed \(indexResult.count.formatted()) photos — building events…")
        }
    }

    /// Soft-deletes SQLite photos that no longer exist in the Photos library, then refreshes covers/events.
    /// Skips Limited Library access (unseen assets would look "deleted"). Throttled unless `force`.
    func reconcileDeletedPhotosIfNeeded(force: Bool = false) async {
        guard !isIndexingPhotos, !isSyncingEvents, !isReconcilingPhotos else { return }
        if !force, !Self.shouldReconcilePhotosNow() { return }

        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authStatus == .authorized else { return }
        guard indexedPhotoCount > 0 else { return }

        isReconcilingPhotos = true
        publishStatusThrottled("Checking for deleted photos…", force: true)
        defer { isReconcilingPhotos = false }

        if Task.isCancelled { return }

        let db = database
        let deletedCount = await Task.detached(priority: .utility) {
            let currentIds = Self.fetchCurrentPhotoLibraryIds()
            return db.reconcileDeletedLibraryPhotos(currentIds: currentIds)
        }.value

        Self.markPhotoReconcileCompleted()

        if Task.isCancelled { return }

        if deletedCount > 0 {
            await reloadEventsAsync()
            refreshLibraryCounts()
            setBaseStatus("Removed \(deletedCount.formatted()) deleted photo(s)")
        } else if !isShowingGeocodeProgress {
            statusText = baseStatusText
        }
    }

    private nonisolated static func shouldReconcilePhotosNow() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: lastPhotoReconcileDefaultsKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(last) >= photoReconcileThrottleInterval
    }

    private nonisolated static func markPhotoReconcileCompleted() {
        UserDefaults.standard.set(Date(), forKey: lastPhotoReconcileDefaultsKey)
    }

    private nonisolated static func photoLibraryFetchOptions() -> PHFetchOptions {
        let startDate = Calendar.current.date(byAdding: .year, value: -100, to: Date())
            ?? Date.distantPast
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND mediaType == %d",
            startDate as NSDate,
            PHAssetMediaType.image.rawValue
        )
        return options
    }

    private nonisolated static func fetchCurrentPhotoLibraryIds() -> Set<String> {
        let assets = PHAsset.fetchAssets(with: photoLibraryFetchOptions())
        var ids = Set<String>()
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            ids.insert(asset.localIdentifier)
        }
        return ids
    }

    private nonisolated static func enumeratePhotoLibrary(
        database: any MagicFrameDatabase,
        onProgress: @escaping @Sendable (Int) -> Void
    ) -> (count: Int, ids: Set<String>) {
        let assets = PHAsset.fetchAssets(with: photoLibraryFetchOptions())
        var count = 0
        var ids = Set<String>()
        ids.reserveCapacity(assets.count)
        let dateFormatter = ISO8601DateFormatter()

        assets.enumerateObjects { asset, _, _ in
            let width = asset.pixelWidth
            let height = asset.pixelHeight
            let aspectRatio = height == 0 ? 0.0 : Double(width) / Double(height)

            let orientation: String
            if width > height {
                orientation = "landscape"
            } else if height > width {
                orientation = "portrait"
            } else {
                orientation = "square"
            }

            let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
            var qualityScore = 50
            if width >= 3000 && height >= 2000 {
                qualityScore += 20
            }
            if orientation == "landscape" {
                qualityScore += 15
            }
            if asset.isFavorite {
                qualityScore += 10
            }
            if isScreenshot {
                qualityScore -= 30
            }
            qualityScore = max(0, min(100, qualityScore))

            let id = asset.localIdentifier
            ids.insert(id)

            database.upsertPhoto(
                id: id,
                creationDate: dateFormatter.string(from: asset.creationDate ?? Date()),
                modificationDate: dateFormatter.string(from: asset.modificationDate ?? Date()),
                mediaType: asset.mediaType.rawValue,
                mediaSubtype: Int(asset.mediaSubtypes.rawValue),
                width: width,
                height: height,
                isFavorite: asset.isFavorite,
                isHidden: asset.isHidden,
                latitude: asset.location?.coordinate.latitude,
                longitude: asset.location?.coordinate.longitude,
                isScreenshot: isScreenshot,
                aspectRatio: aspectRatio,
                orientation: orientation,
                qualityScore: qualityScore
            )

            count += 1
            if count == 1 || count % 250 == 0 {
                onProgress(count)
            }
        }

        onProgress(count)
        return (count, ids)
    }

    func cancelEventSync() {
        stopAllBackgroundWork()
    }

    private func performEventSyncIfNeeded() async {
        let db = database
        let remaining = await Task.detached(priority: .utility) {
            db.countUnassignedPhotosForEvents()
        }.value

        guard remaining > 0 else { return }
        await performEventSync(forceMaintenance: false)
    }

    func scheduleEventSyncIfNeeded() {
        Task {
            await performEventSyncIfNeeded()
            await reloadEventsAsync()
        }
    }

    func scheduleEventSync(forceMaintenance: Bool = false) {
        Task {
            await performEventSync(forceMaintenance: forceMaintenance)
            await reloadEventsAsync()
        }
    }

    private func handleGeocodeProgress(_ progress: LocationGeocodeProgress) {
        if progress.isActive {
            isShowingGeocodeProgress = true
            publishStatusThrottled(
                "Geocoding \(progress.displayRemaining) remaining — open Locations to prioritize"
            )
        } else if isShowingGeocodeProgress {
            isShowingGeocodeProgress = false
            publishStatusThrottled(baseStatusText, force: true)
        }
    }

    private func setBaseStatus(_ text: String) {
        baseStatusText = text
        if !isShowingGeocodeProgress {
            statusText = text
        }
    }

    private func performEventSync(forceMaintenance: Bool = false) async {
        guard !isSyncingEvents else { return }

        await MainActor.run {
            isSyncingEvents = true
        }

        let db = database
        var didAssignPhotos = false
        var batchCount = 0
        var lastEventsReload = Date.distantPast

        while !Task.isCancelled {
            let remaining = await Task.detached(priority: .background) {
                db.countUnassignedPhotosForEvents()
            }.value

            guard remaining > 0 else { break }

            await MainActor.run {
                publishStatusThrottled(
                    EventSyncProgress(
                        processed: 0,
                        total: 0,
                        remainingUnassigned: remaining
                    ).displayStatus
                )
            }

            let hasMore = await Task.detached(priority: .background) {
                db.syncEventsAssignmentBatch()
            }.value

            didAssignPhotos = true
            batchCount += 1
            let now = Date()
            if batchCount == 1 || batchCount % 3 == 0 || now.timeIntervalSince(lastEventsReload) >= 2.0 {
                lastEventsReload = now
                await reloadEventsAsync()
            }

            if !hasMore {
                break
            }

            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        guard !Task.isCancelled else {
            await MainActor.run { isSyncingEvents = false }
            return
        }

        await MainActor.run {
            isSyncingEvents = false
        }

        if didAssignPhotos || forceMaintenance {
            await runEventMaintenance()
        }
    }

    private func runEventMaintenance() async {
        await MainActor.run {
            isMaintainingEvents = true
            publishStatusThrottled("Finishing event grouping…", force: true)
        }

        let db = database
        await Task.detached(priority: .background) {
            db.finishEventSyncMaintenance()
        }.value

        await MainActor.run {
            isMaintainingEvents = false
        }
    }

    func syncEventsTapped() {
        Task {
            await performEventSync(forceMaintenance: true)
            await reloadEventsAsync()
        }
    }

    func rebuildEventsTapped() {
        pipelineTask?.cancel()
        pipelineTask = Task.detached(priority: .utility) { [weak self] in
            await self?.performEventRebuild()
            await self?.reloadEventsAsync()
            await MainActor.run {
                self?.pipelineTask = nil
            }
        }
    }

    func scheduleEventRebuild() {
        rebuildEventsTapped()
    }

    private func performEventRebuild() async {
        guard !isSyncingEvents else { return }

        await MainActor.run {
            isSyncingEvents = true
        }

        let db = database
        let total = await Task.detached(priority: .background) {
            db.prepareEventRebuild()
        }.value

        await reloadEventsAsync()

        guard total > 0 else {
            await Task.detached(priority: .background) {
                db.finishEventRebuild()
            }.value
            await MainActor.run { isSyncingEvents = false }
            return
        }

        var batchCount = 0
        var lastEventsReload = Date.distantPast

        while !Task.isCancelled {
            let remaining = await Task.detached(priority: .background) {
                db.countUnassignedPhotosForEvents()
            }.value

            guard remaining > 0 else { break }

            await MainActor.run {
                publishStatusThrottled(
                    EventSyncProgress(
                        processed: 0,
                        total: total,
                        remainingUnassigned: remaining,
                        isRebuild: true
                    ).displayStatus
                )
            }

            await Task.detached(priority: .background) {
                db.syncEventsAssignmentBatch()
            }.value

            batchCount += 1
            let now = Date()
            if batchCount == 1 || batchCount % 3 == 0 || now.timeIntervalSince(lastEventsReload) >= 2.0 {
                lastEventsReload = now
                await reloadEventsAsync()
            }

            let stillRemaining = await Task.detached(priority: .background) {
                db.countUnassignedPhotosForEvents()
            }.value

            if stillRemaining == 0 {
                break
            }

            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        guard !Task.isCancelled else {
            await MainActor.run { isSyncingEvents = false }
            return
        }

        await MainActor.run {
            isSyncingEvents = false
            publishStatusThrottled("Finishing rebuild…", force: true)
        }

        await Task.detached(priority: .background) {
            db.finishEventRebuild()
        }.value
    }

    func buildCoversTapped() {
        Task {
            isBuildingCovers = true
            defer { isBuildingCovers = false }

            let db = database
            await Task.detached(priority: .utility) {
                db.updateAllEventCoverPhotos()
            }.value

            await reloadEventsAsync()
            setBaseStatus("Cover photos updated")
        }
    }

    func geocodeNextLocationsBatch() {
        database.startGeocodingEventLocations(limit: 40)
        publishStatusThrottled("Geocoding 40 recent locations…", force: true)
    }

    func deduplicateLocationsTapped() {
        Task {
            isMaintainingEvents = true
            defer { isMaintainingEvents = false }

            let db = database
            let merged = await Task.detached(priority: .utility) {
                db.deduplicateLocationsByAddress(maxDistanceMiles: nil)
            }.value

            publishStatusThrottled(
                merged > 0
                    ? "Merged \(merged) duplicate locations"
                    : "No duplicate locations found",
                force: true
            )
        }
    }

    func showEventsTapped() {
        Task {
            isLoadingEvents = true
            defer { isLoadingEvents = false }

            recentPhotos = []
            events = []
            eventSections = []

            let db = database
            await Task.detached(priority: .utility) {
                db.debugEventPipeline()
                db.debugLocationCounts()
                db.debugSchema()
            }.value

            await reloadEventsAsync()
        }
    }

    func showRecentPhotosTapped(limit: Int = 100) {
        isLoadingRecentPhotos = true
        defer { isLoadingRecentPhotos = false }

        recentPhotos = database.getRecentPhotos(limit: limit)
        setBaseStatus("Showing \(recentPhotos.count) photos")
    }

    func toggleEventOnFrame(eventId: Int) {
        guard let index = events.firstIndex(where: { $0.eventId == eventId }) else {
            return
        }

        let event = events[index]
        let newValue = !event.showOnFrame

        database.setEventShowOnFrame(eventId: eventId, show: newValue)

        events[index] = IndexedEvent(
            eventId: event.eventId,
            name: event.name,
            startDate: event.startDate,
            endDate: event.endDate,
            photoCount: event.photoCount,
            latitude: event.latitude,
            longitude: event.longitude,
            city: event.city,
            state: event.state,
            placeName: event.placeName,
            people: event.people,
            coverPhotoId: event.coverPhotoId,
            showOnFrame: newValue,
            userEditedName: event.userEditedName,
            locationNickname: event.locationNickname,
            locationId: event.locationId,
            parentEventId: event.parentEventId,
            isTripEvent: event.isTripEvent,
            eventType: event.eventType,
            activityType: event.activityType,
            milestoneType: event.milestoneType,
            holidayType: event.holidayType,
            eventMainPerson: event.eventMainPerson,
            tripType: event.tripType,
            childEventName: event.childEventName,
            userEditedChildEventName: event.userEditedChildEventName,
            isUserHidden: event.isUserHidden
        )
        rebuildEventSections()
    }

    func hideEvent(eventId: Int) {
        database.setEventUserHidden(eventId: eventId, hidden: true)
        events.removeAll { $0.eventId == eventId }
        rebuildEventSections()
        setBaseStatus(showHiddenEvents ? "Showing \(events.count) hidden events" : "Showing \(events.count) events")
    }

    func unhideEvent(eventId: Int) {
        database.setEventUserHidden(eventId: eventId, hidden: false)
        eventListScrollTarget = EventListScrollTarget(eventId: eventId, requestID: UUID())

        if showHiddenEvents {
            showHiddenEvents = false
            Task {
                await reloadEventsAsync()
            }
            return
        }

        refreshEvent(eventId: eventId)
        setBaseStatus("Showing \(events.count) events")
    }

    func acknowledgeEventListScroll() {
        eventListScrollTarget = nil
    }

    func toggleShowHiddenEvents() {
        showHiddenEvents.toggle()
        Task {
            await reloadEventsAsync()
        }
    }

    func refreshEvent(eventId: Int) {
        guard let updated = database.getEvent(eventId: eventId) else {
            return
        }

        if let index = events.firstIndex(where: { $0.eventId == eventId }) {
            events[index] = updated
        }

        rebuildEventSections()
    }

    func reloadEvents() {
        Task {
            await reloadEventsAsync()
        }
    }

    private func rebuildEventSections() {
        let slideshowIdsByEvent = database.getSlideshowPhotoIds(for: events)
        let items = events.map { event in
            EventListDisplayItem(
                event: event,
                slideshowPhotoIds: slideshowIdsByEvent[event.eventId] ?? []
            )
        }

        let grouped = Dictionary(grouping: items) { item in
            item.event.eventYear ?? 0
        }

        eventSections = grouped.keys
            .sorted(by: >)
            .map { year in
                EventYearSection(
                    year: year,
                    items: grouped[year, default: []]
                        .sorted { $0.event.startDate > $1.event.startDate }
                )
            }
    }
}
