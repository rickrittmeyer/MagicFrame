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
    /// Concrete facade for `Task.detached` (avoids Swift concurrency traps with `any` existential).
    private let backgroundDatabase: PhotoDatabase

    @Published var statusText: String = "Ready"
    @Published var events: [IndexedEvent] = []
    @Published var eventSections: [EventYearSection] = []
    /// Expanded year accordion in the events library (survives list row updates).
    @Published var expandedListYear: Int?
    @Published var activeEventListFilter: EventListFilter = .allEvents
    @Published var homeCollectionsCount: Int = 0
    @Published var homeChristmasCount: Int = 0
    @Published var occasionLandingItems: [OccasionLandingItem] = []
    @Published var isLoadingOccasionLanding = false
    @Published var hasLoadedOccasionLanding = false
    @Published var isLoadingOccasionLandingCounts = false
    @Published var occasionFrameSnapshot: OccasionFrameLandingSnapshot?
    @Published var isLoadingOccasionFrame = false
    @Published var homeLocationsCount: Int = 0
    @Published var eventListScrollTarget: EventListScrollTarget?
    @Published var recentPhotos: [IndexedPhoto] = []

    @Published var isSyncingEvents: Bool = false
    @Published var isBuildingCovers: Bool = false
    @Published var isLoadingEvents: Bool = false
    @Published var isLoadingRecentPhotos: Bool = false
    @Published var isIndexingPhotos: Bool = false
    @Published var isMaintainingEvents: Bool = false
    @Published var isRefreshingMetadata: Bool = false
    @Published var isLoadingSlideshowPhotos: Bool = false
    @Published var indexedPhotoCount: Int = 0
    @Published var showHomeOnboarding = false
    @Published var showHiddenEvents = false
    @Published private(set) var isStartupComplete = false
    /// True while a holiday year Vision pass is running (list rows use lighter thumbnails).
    @Published private(set) var isHolidayVisionScanActive = false
    @Published private(set) var activeHolidayVisionConfig: HolidayVisionLandingConfig?

    var isLibraryBusy: Bool {
        isIndexingPhotos || isSyncingEvents || isRefreshingMetadata
    }

    /// Photo import replaces the events list; sync/rebuild keeps it visible and refreshes in place.
    var hidesEventsList: Bool {
        isIndexingPhotos
    }

    var showsEventsLoadingPlaceholder: Bool {
        hidesEventsList
            || (isLoadingEvents && eventSections.isEmpty)
            || (isSyncingEvents && eventSections.isEmpty)
    }

    var showsBackgroundWorkBanner: Bool {
        isLibraryBusy || isMaintainingEvents || isShowingGeocodeProgress || isLoadingSlideshowPhotos
    }

    var backgroundWorkBannerText: String {
        if let geocodeBannerMessage, isShowingGeocodeProgress {
            return geocodeBannerMessage
        }
        if isLoadingSlideshowPhotos {
            return "Loading frame preview photos for events…"
        }
        return "Working in background — events update as grouping finishes."
    }

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
    private var geocodeBannerMessage: String?
    private var slideshowLoadTask: Task<Void, Never>?
    private var eventDateRepairTask: Task<Void, Never>?
    private var holidayLandingVisionTask: Task<Void, Never>?
    private var holidayYearExpandTask: Task<Void, Never>?
    private var activeHolidayVisionYear: Int?
    private var activeHolidayVisionScopeKey: String?
    private var occasionLandingRefreshTask: Task<Void, Never>?
    private var lastStatusPublish = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private var pipelineTask: Task<Void, Never>?
    private var hasLoadedEventsForUI = false

    init(database: any MagicFrameDatabase = AppDependencies.database) {
        self.database = database
        self.backgroundDatabase = PhotoDatabase.shared
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

        backgroundDatabase.stopGeocoding()
        pipelineTask = Task(priority: .utility) {
            await self.runStartupPipeline()
        }
    }

    /// Refreshes home tile counts after startup (list loads when a category opens).
    func loadEventsForUIIfNeeded() async {
        guard isStartupComplete, !hasLoadedEventsForUI else { return }
        guard !showHomeOnboarding else { return }

        hasLoadedEventsForUI = true
        await refreshHomeCategoryCounts()

        Task.detached(priority: .background) { [backgroundDatabase] in
            backgroundDatabase.ensureCropAlgorithmVersionCurrent()
        }
    }

    func cancelOccasionLandingRefresh() {
        occasionLandingRefreshTask?.cancel()
        occasionLandingRefreshTask = nil
        isLoadingOccasionLandingCounts = false
    }

    /// Fire-and-forget refresh for Holidays landing (cancellable when navigating away).
    func scheduleOccasionLandingRefresh() {
        occasionLandingRefreshTask?.cancel()
        occasionLandingRefreshTask = Task(priority: .utility) { [weak self] in
            await self?.refreshOccasionLandingItemsAsync()
        }
    }

    func refreshOccasionLandingItems() async {
        occasionLandingRefreshTask?.cancel()
        await refreshOccasionLandingItemsAsync()
    }

    private func refreshOccasionLandingItemsAsync() async {
        isLoadingOccasionLanding = true
        defer { isLoadingOccasionLanding = false }

        let catalog = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.fetchOccasionLandingCatalogItems()
        }.value

        guard !Task.isCancelled else { return }

        let cached = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.applyCachedOccasionLandingMetrics(to: catalog)
        }.value

        guard !Task.isCancelled else { return }

        occasionLandingItems = cached.items
        hasLoadedOccasionLanding = true

        guard !cached.staleTagValues.isEmpty else { return }

        isLoadingOccasionLandingCounts = true
        defer { isLoadingOccasionLandingCounts = false }

        let staleItems = cached.staleTagValues.compactMap { tagValue in
            occasionLandingItems.first(where: { $0.tagValue == tagValue })
        }
        guard !staleItems.isEmpty else { return }

        let requests = staleItems.map {
            OccasionLandingMetricsRequest(
                occasionKey: $0.occasionKey,
                tagValue: $0.tagValue,
                occasionType: $0.occasionType,
                displayName: $0.name
            )
        }

        let metricsByTagValue = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.countOccasionLandingMetricsBatch(requests: requests)
        }.value

        guard !Task.isCancelled else { return }

        for item in staleItems {
            guard let metrics = metricsByTagValue[item.tagValue],
                  let index = occasionLandingItems.firstIndex(where: { $0.tagValue == item.tagValue }) else {
                continue
            }

            occasionLandingItems[index] = item.withCounts(
                collection: metrics.collections,
                onFrame: metrics.onFramePhotos
            )
        }
    }

    func refreshHomeCategoryCounts() async {
        let counts = await Task.detached(priority: .utility) { [backgroundDatabase] in
            (
                collections: backgroundDatabase.countListEvents(includeHidden: false, filter: .allEvents),
                christmas: backgroundDatabase.countListEvents(
                    includeHidden: false,
                    filter: .christmas
                ),
                locations: backgroundDatabase.countLocations()
            )
        }.value

        homeCollectionsCount = counts.collections
        homeChristmasCount = counts.christmas
        homeLocationsCount = counts.locations
    }

    private func runStartupPipeline() async {
        refreshLibraryCounts()
        isSyncingEvents = false
        isMaintainingEvents = false
        isIndexingPhotos = false
        isShowingGeocodeProgress = false

        let hasHome = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.hasCurrentHome()
        }.value

        defer {
            isStartupComplete = true
            pipelineTask = nil
        }

        guard hasHome else {
            showHomeOnboarding = true
            return
        }

        if indexedPhotoCount > 0 {
            let eventCount = await Task.detached(priority: .utility) { [backgroundDatabase] in
                backgroundDatabase.countListEvents(includeHidden: false, filter: .allEvents)
            }.value

            if eventCount > 0 {
                setBaseStatus("\(eventCount.formatted()) events — loading list…")
                return
            }
        }

        await continueLibraryBootstrap()
    }

    func homeOnboardingCompleted() {
        showHomeOnboarding = false
        pipelineTask?.cancel()
        pipelineTask = Task(priority: .utility) {
            await self.continueLibraryBootstrap(reindexAfterHomeSetup: true)
            self.isStartupComplete = true
            self.pipelineTask = nil
        }
    }

    private func continueLibraryBootstrap(reindexAfterHomeSetup: Bool = false) async {
        await MainActor.run {
            refreshLibraryCounts()
        }

        let needsIndex = await MainActor.run { indexedPhotoCount == 0 }
        if needsIndex {
            await indexPhotosFromLibrary()
        } else {
            let db = backgroundDatabase
            await Task.detached(priority: .utility) {
                db.runPostIndexMetadataEnrichmentIfNeeded()
            }.value

            if reindexAfterHomeSetup {
                await performEventRebuild()
            }
            // Event assignment is user-triggered (Sync Events) so launch stays lightweight.
        }

        if needsIndex {
            await performEventSync(forceMaintenance: true)
        }

        await refreshHomeCategoryCounts()
        hasLoadedEventsForUI = true

        let db = backgroundDatabase
        Task(priority: .background) { [weak self] in
            db.restoreDeletedTripContainersOnQueue()
            db.repairHomeLocations()
            db.ensureCropAlgorithmVersionCurrent()
            await MainActor.run {
                self?.refreshLibraryCounts()
            }
        }
    }

    /// Call when a collection screen appears so the list shows a loading state immediately.
    func beginEventListLoad(for filter: EventListFilter) {
        slideshowLoadTask?.cancel()
        if filter != activeEventListFilter {
            events = []
            eventSections = []
            expandedListYear = nil
        }
        activeEventListFilter = filter
        if case .holidayTag(let tagValue) = filter {
            activeHolidayVisionConfig = backgroundDatabase.holidayVisionLandingConfig(tagValue: tagValue)
        } else {
            activeHolidayVisionConfig = nil
        }
        isLoadingEvents = true
    }

    func reloadEventsAsync(
        filter: EventListFilter? = nil,
        loadSlideshowIds: Bool = true,
        preserveListWhileLoading: Bool = false
    ) async {
        let listFilter = filter ?? activeEventListFilter
        if !preserveListWhileLoading,
           listFilter != activeEventListFilter || !isLoadingEvents {
            beginEventListLoad(for: listFilter)
        }
        let includeHidden = showHiddenEvents

        let loadStart = CFAbsoluteTimeGetCurrent()
        let payload = await Task.detached(priority: .utility) { [backgroundDatabase, includeHidden, listFilter] in
            let loaded = backgroundDatabase.getEventsForList(
                includeHidden: includeHidden,
                limit: nil,
                filter: listFilter
            )
            let sections = LibraryViewModel.buildEventSections(
                from: loaded,
                slideshowIdsByEvent: [:]
            )
            return (loaded, sections)
        }.value

        let loadSeconds = CFAbsoluteTimeGetCurrent() - loadStart
        if loadSeconds > 0.5 {
            print(
                String(
                    format: "Loaded %d %@ events in %.1fs",
                    payload.0.count,
                    listFilter.navigationTitle,
                    loadSeconds
                )
            )
        }

        let preservedSlideshowIds = slideshowIdsFromCurrentSections()
        events = payload.0
        if loadSlideshowIds {
            eventSections = payload.1
        } else {
            eventSections = applyPreservedSlideshowIds(
                to: payload.1,
                preserved: preservedSlideshowIds
            )
        }
        isLoadingEvents = false
        let title = listFilter.navigationTitle
        setBaseStatus("\(events.count.formatted()) \(title.lowercased())")

        if loadSlideshowIds, !events.isEmpty {
            scheduleSlideshowLoad()
        } else {
            reloadSlideshowPhotosForExpandedYearIfNeeded()
        }
    }

    /// Re-fetches slideshow picks for the expanded year when a background reload cleared them.
    func reloadSlideshowPhotosForExpandedYearIfNeeded() {
        guard let year = expandedListYear else { return }
        guard activeHolidayVisionConfig == nil else { return }
        let items = eventSections.first(where: { $0.year == year })?.items ?? []
        guard items.contains(where: { $0.slideshowPhotoIds.isEmpty }) else { return }
        loadSlideshowPhotosForYear(year)
    }

    /// Loads slideshow photo picks for one expanded year section (avoids loading the whole library).
    func loadSlideshowPhotosForYear(_ year: Int) {
        slideshowLoadTask?.cancel()
        slideshowLoadTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            let events = await MainActor.run {
                self.eventSections
                    .first(where: { $0.year == year })?
                    .items
                    .map(\.event) ?? []
            }
            guard !events.isEmpty else { return }

            let chunkSize = 6
            for chunkStart in stride(from: 0, to: events.count, by: chunkSize) {
                if Task.isCancelled { return }

                let chunkEnd = min(chunkStart + chunkSize, events.count)
                let chunk = Array(events[chunkStart..<chunkEnd])

                let partial = await Task.detached(priority: .utility) { [backgroundDatabase] in
                    backgroundDatabase.getSlideshowPhotoIds(for: chunk)
                }.value

                guard !Task.isCancelled, !partial.isEmpty else { continue }

                await MainActor.run {
                    self.mergeSlideshowPhotoIds(partial)
                }

                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// Loads `includeInSlideshow` photo picks in chunks so large libraries stay responsive.
    private func scheduleSlideshowLoad() {
        slideshowLoadTask?.cancel()
        slideshowLoadTask = Task(priority: .utility) { [weak self] in
            await self?.loadSlideshowPhotosChunked()
        }
    }

    private func loadSlideshowPhotosChunked() async {
        let snapshot = await MainActor.run { events }
        guard !snapshot.isEmpty else { return }

        await MainActor.run { isLoadingSlideshowPhotos = true }
        defer {
            Task { @MainActor in
                isLoadingSlideshowPhotos = false
            }
        }

        let chunkSize = Self.slideshowLoadChunkSize
        var processedChunks = 0

        for chunkStart in stride(from: 0, to: snapshot.count, by: chunkSize) {
            if Task.isCancelled { return }

            let chunkEnd = min(chunkStart + chunkSize, snapshot.count)
            let chunk = Array(snapshot[chunkStart..<chunkEnd])

            let partial = await Task.detached(priority: .utility) { [backgroundDatabase] in
                backgroundDatabase.getSlideshowPhotoIds(for: chunk)
            }.value

            guard !Task.isCancelled, !partial.isEmpty else { continue }

            await MainActor.run {
                mergeSlideshowPhotoIds(partial)
            }

            processedChunks += 1
            if processedChunks == 1 || processedChunks % 2 == 0 {
                publishStatusThrottled(
                    "Loaded preview photos for \(min(chunkEnd, snapshot.count).formatted()) of \(snapshot.count.formatted()) events…"
                )
            }
        }

        guard !Task.isCancelled else { return }

        await MainActor.run {
            publishStatusThrottled("\(events.count) events", force: true)
        }
    }

    private func mergeSlideshowPhotoIds(_ slideshowIdsByEvent: [Int: [String]]) {
        guard !slideshowIdsByEvent.isEmpty else { return }

        eventSections = eventSections.map { section in
            EventYearSection(
                year: section.year,
                items: section.items.map { item in
                    guard let ids = slideshowIdsByEvent[item.event.eventId], !ids.isEmpty else {
                        return item
                    }
                    return EventListDisplayItem(event: item.event, slideshowPhotoIds: ids)
                }
            )
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
        slideshowLoadTask?.cancel()
        slideshowLoadTask = nil
        eventDateRepairTask?.cancel()
        eventDateRepairTask = nil
        database.stopGeocoding()
        isSyncingEvents = false
        isMaintainingEvents = false
        isIndexingPhotos = false
        isLoadingSlideshowPhotos = false
        isShowingGeocodeProgress = false
        geocodeBannerMessage = nil
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

        let db = backgroundDatabase
        let indexedCount = await Task.detached(priority: .utility) { [weak self] in
            Self.enumeratePhotoLibrary(database: db) { count in
                guard count == 1 || count % 1000 == 0 else { return }
                Task { @MainActor in
                    self?.publishStatusThrottled("Indexed \(count.formatted()) photos…")
                }
            }
        }.value

        await Task.detached(priority: .utility) {
            db.runPostIndexMetadataEnrichment()
            db.importPeopleFromAlbums()
            db.rebuildEventPeople()
        }.value

        setBaseStatus("Indexed \(indexedCount.formatted()) photos — building events…")
        await performEventSync(forceMaintenance: true)
        await reloadEventsAsync()
        setBaseStatus("Indexed \(indexedCount.formatted()) photos — \(events.count.formatted()) events")
    }

    private nonisolated static func enumeratePhotoLibrary(
        database: PhotoDatabase,
        onProgress: @escaping @Sendable (Int) -> Void
    ) -> Int {
        let startDate = Calendar.current.date(byAdding: .year, value: -100, to: Date())
            ?? Date.distantPast
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND mediaType == %d",
            startDate as NSDate,
            PHAssetMediaType.image.rawValue
        )

        let assets = PHAsset.fetchAssets(with: options)
        var count = 0
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

            database.upsertPhoto(
                id: asset.localIdentifier,
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
        return count
    }

    func cancelEventSync() {
        stopAllBackgroundWork()
    }

    private func performEventSyncIfNeeded() async {
        let db = backgroundDatabase
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
            geocodeBannerMessage =
                "Geocoding \(progress.displayRemaining) remaining — open Locations to prioritize"
        } else if isShowingGeocodeProgress {
            isShowingGeocodeProgress = false
            geocodeBannerMessage = nil
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

        let db = backgroundDatabase

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

            if !hasMore {
                break
            }

            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        guard !Task.isCancelled else {
            await MainActor.run { isSyncingEvents = false }
            return
        }

        await runMetadataPhotoAssignmentPass()

        await MainActor.run {
            isSyncingEvents = false
        }

        // Full trip/location maintenance is expensive on large libraries.
        // Callers that need it pass forceMaintenance: true (index/rebuild) or run it from syncEventsTapped when unassigned is high.
        if forceMaintenance {
            await runEventMaintenance()
        }
    }

    private func runMetadataPhotoAssignmentPass() async {
        let unassignedNoGPS = await Task.detached(priority: .background) { [backgroundDatabase] in
            backgroundDatabase.countUnassignedMetadataPhotosForEvents()
        }.value

        guard unassignedNoGPS > 0 else { return }

        await MainActor.run {
            publishStatusThrottled(
                "Assigning \(unassignedNoGPS.formatted()) no-GPS photos"
                    + " (metadata match, then date/time events)…",
                force: true
            )
        }

        await Task.detached(priority: .background) { [backgroundDatabase] in
            backgroundDatabase.syncMetadataAssignmentUntilComplete()
        }.value

        let counts = await Task.detached(priority: .background) { [backgroundDatabase] in
            backgroundDatabase.metadataAssignmentCounts()
        }.value

        await MainActor.run {
            publishStatusThrottled("\(counts.summaryLine). \(counts.detailLine)", force: true)
        }
    }

    private func runEventMaintenance() async {
        await MainActor.run {
            isMaintainingEvents = true
            publishStatusThrottled("Finishing event grouping…", force: true)
        }

        let db = backgroundDatabase
        await Task.detached(priority: .background) {
            db.finishEventSyncMaintenance()
        }.value

        await MainActor.run {
            isMaintainingEvents = false
        }
    }

    /// Full trip/location maintenance is expensive; skip it for small catch-up syncs.
    nonisolated private static let fullMaintenanceUnassignedThreshold = 100
    /// Chunk size for background slideshow SQL (`IN` list + memory).
    nonisolated private static let slideshowLoadChunkSize = 400

    func syncEventsTapped() {
        Task {
            let unassignedBefore = database.countUnassignedPhotosForEvents()
            await performEventSync(forceMaintenance: false)
            if unassignedBefore >= Self.fullMaintenanceUnassignedThreshold {
                await runEventMaintenance()
            }
            await reloadEventsAsync(loadSlideshowIds: true)
        }
    }

    func rebuildEventsTapped() {
        pipelineTask?.cancel()
        pipelineTask = Task(priority: .utility) { [weak self] in
            await self?.performEventRebuild()
            await self?.reloadEventsAsync()
            self?.pipelineTask = nil
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

        let db = backgroundDatabase
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

        await runMetadataPhotoAssignmentPass()

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

            let db = backgroundDatabase
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

    /// Re-imports PhotoKit albums + filename metadata for indexed photos (no full re-index).
    func refreshMetadataEnrichmentTapped() {
        guard !isRefreshingMetadata, !isIndexingPhotos else { return }

        Task {
            isRefreshingMetadata = true
            defer { isRefreshingMetadata = false }

            publishStatusThrottled("Refreshing album & filename metadata…", force: true)

            let db = backgroundDatabase
            await Task.detached(priority: .utility) {
                db.runPostIndexMetadataEnrichment()
            }.value

            applyMetadataCountsStatus()
        }
    }

    /// Prints metadata table counts to the Xcode console and updates status.
    func showMetadataCountsTapped() {
        backgroundDatabase.debugMetadataCounts()
        applyMetadataCountsStatus()
    }

    private func applyMetadataCountsStatus() {
        let counts = backgroundDatabase.metadataEnrichmentCounts()
        publishStatusThrottled("\(counts.summaryLine). \(counts.detailLine)", force: true)
    }

    func showEventDateDiagnosticsTapped() {
        let counts = backgroundDatabase.eventDateDiagnosticCounts()
        publishStatusThrottled("\(counts.summaryLine). \(counts.detailLine)", force: true)
    }

    func showMetadataAssignmentCountsTapped() {
        let counts = backgroundDatabase.metadataAssignmentCounts()
        publishStatusThrottled("\(counts.summaryLine). \(counts.detailLine)", force: true)
    }

    func showOccasionScoringCountsTapped() {
        let counts = backgroundDatabase.occasionScoringCounts()
        publishStatusThrottled("\(counts.summaryLine). \(counts.detailLine)", force: true)
    }

    func scoreHolidayOccasionsTapped() {
        Task {
            isMaintainingEvents = true
            defer { isMaintainingEvents = false }

            publishStatusThrottled("Scoring holiday occasions for events…", force: true)

            let result = await Task.detached(priority: .utility) { [backgroundDatabase] in
                backgroundDatabase.scoreAllHolidayOccasions()
            }.value

            publishStatusThrottled(
                "\(result.scoring.summaryLine). \(result.tags.summaryLine). \(result.tags.detailLine)",
                force: true
            )

            await reloadEventsAsync(
                filter: activeEventListFilter,
                loadSlideshowIds: false
            )
            await refreshHomeCategoryCounts()
            await refreshOccasionLandingItems()
        }
    }

    func christmasObjectKeysForVisionDebug() -> [String] {
        backgroundDatabase.christmasObjectKeysForVisionDebug()
    }

    func analyzeVisionLabels(
        assetIdentifier: String,
        objectKeys: [String]
    ) async -> VisionLabelAnalysisResult {
        await VisionLabelDebugService.analyze(
            assetIdentifier: assetIdentifier,
            objectKeys: objectKeys
        )
    }

    func cancelHolidayLandingVisionScans(reason: String = "left holiday collection") {
        holidayYearExpandTask?.cancel()
        holidayYearExpandTask = nil
        let label = activeHolidayVisionConfig?.logLabel ?? "Holiday"
        if holidayLandingVisionTask != nil || activeHolidayVisionScopeKey != nil {
            print("\(label) vision scan cancelled: \(reason)")
        }
        holidayLandingVisionTask?.cancel()
        holidayLandingVisionTask = nil
        if let scopeKey = activeHolidayVisionScopeKey {
            AppDependencies.container.visionJobCoordinator.cancelScope(scopeKey)
        }
        activeHolidayVisionScopeKey = nil
        activeHolidayVisionYear = nil
        isHolidayVisionScanActive = false
    }

    func cancelChristmasLandingVisionScans(reason: String = "left Christmas collection") {
        cancelHolidayLandingVisionScans(reason: reason)
    }

    /// Waits for the year section to render, then either loads slideshows or starts Vision if needed.
    func handleHolidayYearExpanded(_ year: Int) {
        guard let config = activeHolidayVisionConfig else { return }

        holidayYearExpandTask?.cancel()
        let includeHidden = showHiddenEvents
        let database = backgroundDatabase

        holidayYearExpandTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }

            let eventIds = await MainActor.run { [weak self] () -> [Int] in
                guard let self else { return [] }
                return self.eventSections
                    .first(where: { $0.year == year })?
                    .items
                    .map(\.event.eventId) ?? []
            }
            guard !eventIds.isEmpty else { return }

            let needsVision = await Task.detached(priority: .utility) {
                database.holidayYearNeedsVisionScan(
                    config: config,
                    eventIds: eventIds,
                    includeHiddenPhotos: includeHidden
                )
            }.value
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                if needsVision {
                    self.scheduleHolidayVisionScansForYear(year)
                } else {
                    self.loadSlideshowPhotosForYear(year)
                }
            }
        }
    }

    func handleChristmasYearExpanded(_ year: Int) {
        handleHolidayYearExpanded(year)
    }

    /// Enqueues a background Vision pass for AI-tagged holiday events in one expanded year section.
    private func scheduleHolidayVisionScansForYear(_ year: Int) {
        guard let config = activeHolidayVisionConfig else { return }
        if isHolidayVisionScanActive, activeHolidayVisionYear == year {
            return
        }

        slideshowLoadTask?.cancel()
        holidayLandingVisionTask?.cancel()

        let includeHidden = showHiddenEvents
        let database = backgroundDatabase
        let scopeKey = "holiday:\(config.tagValue):\(year)"
        let eventIds = eventSections
            .first(where: { $0.year == year })?
            .items
            .map(\.event.eventId) ?? []
        guard !eventIds.isEmpty else { return }

        activeHolidayVisionYear = year
        activeHolidayVisionScopeKey = scopeKey
        isHolidayVisionScanActive = true

        let summary = database.enqueueHolidayYearObjectRecognitionJobs(
            config: config,
            year: year,
            eventIds: eventIds,
            includeHiddenPhotos: includeHidden,
            priority: 50
        )

        if summary.enqueuedCount == 0 {
            Task { @MainActor [weak self] in
                await self?.finishHolidayVisionScanAndReload(for: year)
            }
            return
        }

        publishStatusThrottled(
            "\(config.logLabel) vision scan (\(year)) queued · \(summary.enqueuedCount) job(s)",
            force: true
        )

        holidayLandingVisionTask = Task { [weak self] in
            guard let self else { return }

            await self.waitForVisionJobs(scopeKey: scopeKey)

            guard !Task.isCancelled else { return }

            await self.finishHolidayVisionScanAndReload(for: year)

            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }

            await self.refreshHomeCategoryCounts()
        }
    }

    private func finishHolidayVisionScanAndReload(for year: Int) async {
        if activeHolidayVisionYear == year {
            activeHolidayVisionYear = nil
            activeHolidayVisionScopeKey = nil
        }
        isHolidayVisionScanActive = false
        await reloadEventsAsync(loadSlideshowIds: false, preserveListWhileLoading: true)
        loadSlideshowPhotosForYear(year)
    }

    func resolveEventForDetail(eventId: Int) -> IndexedEvent? {
        database.getEvent(eventId: eventId)
            ?? events.first(where: { $0.eventId == eventId })
    }

    func onEventDetailDismissed(eventId: Int) {
        if database.eventMatchesListFilter(eventId: eventId, filter: activeEventListFilter) {
            refreshEvent(eventId: eventId)
        } else {
            removeEventFromList(eventId: eventId)
        }
    }

    func resetHolidayObjectRecognitionTapped(tagValue: String) {
        guard let config = backgroundDatabase.holidayVisionLandingConfig(tagValue: tagValue) else {
            publishStatusThrottled("No Vision landing config for \(tagValue). Add object scoring rules.", force: true)
            return
        }
        let report = backgroundDatabase.resetHolidayObjectRecognitionState(
            config: config,
            includeHiddenPhotos: true
        )
        let message =
            "Reset \(config.displayName) Vision state: \(report.taggedEventCount) tagged event(s)"
            + " · \(report.candidatesNeedingScan) AI-tagged need scanning."
            + " Expand a year in \(config.displayName) to test landing scans."
        print(message)
        publishStatusThrottled(message, force: true)
    }

    func holidayVisionLandingConfigs() -> [HolidayVisionLandingConfig] {
        backgroundDatabase.fetchAllHolidayVisionLandingConfigs()
    }

    func resetChristmasObjectRecognitionTapped() {
        resetHolidayObjectRecognitionTapped(tagValue: "Christmas")
    }

    func rescanHolidayObjectRecognitionTapped(tagValue: String) {
        Task {
            isMaintainingEvents = true
            defer { isMaintainingEvents = false }

            let holidayName = backgroundDatabase.holidayVisionLandingConfig(tagValue: tagValue)?
                .displayName ?? tagValue
            publishStatusThrottled(
                "Clearing \(holidayName) object scans and queuing Vision rescan…",
                force: true
            )

            let result = backgroundDatabase.enqueueHolidayTaggedObjectRescan(
                tagValue: tagValue,
                includeHiddenPhotos: true,
                priority: 10
            )

            guard result.enqueuedCount > 0 else {
                let message = "No \(holidayName) tagged events to rescan."
                print(message)
                publishStatusThrottled(message, force: true)
                return
            }

            publishStatusThrottled(
                "\(holidayName) rescan queued · \(result.enqueuedCount) job(s) for \(result.taggedEventCount) event(s)…",
                force: true
            )

            await waitForVisionJobs(scopeKey: result.scopeKey)

            let message =
                "\(holidayName) rescan complete · \(result.taggedEventCount) tagged event(s) · \(result.enqueuedCount) job(s) processed."
            print(message)
            publishStatusThrottled(message, force: true)

            await reloadEventsAsync(
                filter: activeEventListFilter,
                loadSlideshowIds: false
            )
            await refreshHomeCategoryCounts()
            await refreshOccasionLandingItems()
        }
    }

    func rescanChristmasObjectRecognitionTapped() {
        rescanHolidayObjectRecognitionTapped(tagValue: "Christmas")
    }

    private func waitForVisionJobs(scopeKey: String) async {
        let database = backgroundDatabase
        while !Task.isCancelled {
            let pending = database.visionJobPendingCount(scopeKey: scopeKey, eventId: nil)
            if pending == 0 { break }

            let status = AppDependencies.container.visionJobCoordinator.snapshot.statusText
            if let status {
                publishStatusThrottled(status)
            }

            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    func showTopHolidayOccasionScoresTapped(limit: Int = 25) {
        let matches = backgroundDatabase.debugPrintTopHolidayOccasionScores(limit: limit)
        if let top = matches.first {
            publishStatusThrottled(
                "Top holiday: \(top.occasionKey) \(top.year) · \(String(format: "%.2f", top.totalScore)) (\(top.confidence ?? "—")) on event \(top.eventId). See console for top \(limit).",
                force: true
            )
        } else {
            publishStatusThrottled(
                "No holiday occasion scores yet — run Score Holiday Occasions first.",
                force: true
            )
        }
    }

    func runMetadataAssignmentTapped() {
        Task {
            isMaintainingEvents = true
            defer { isMaintainingEvents = false }
            await runMetadataPhotoAssignmentPass()
            await reloadEventsAsync(loadSlideshowIds: false)
        }
    }

    /// Repairs missing event dates off the critical path so the list can paint first.
    func scheduleEventDateRepairIfNeeded() {
        eventDateRepairTask?.cancel()
        eventDateRepairTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let db = backgroundDatabase
            guard !Task.isCancelled else { return }
            guard db.eventDateDiagnosticCounts().needsRepair else { return }

            await MainActor.run {
                publishStatusThrottled("Repairing event year grouping in background…", force: true)
            }

            let repair = await Task.detached(priority: .utility) {
                db.repairEventDateSummaries()
            }.value

            guard !Task.isCancelled else { return }

            await reloadEventsAsync(loadSlideshowIds: false)
            publishStatusThrottled(repair.summaryLine, force: true)
        }
    }

    func repairEventDatesTapped() {
        eventDateRepairTask?.cancel()
        eventDateRepairTask = Task {
            isMaintainingEvents = true
            defer {
                isMaintainingEvents = false
                eventDateRepairTask = nil
            }

            publishStatusThrottled("Repairing event dates…", force: true)

            let repair = await Task.detached(priority: .utility) { [backgroundDatabase] in
                backgroundDatabase.repairEventDateSummaries()
            }.value

            await reloadEventsAsync(loadSlideshowIds: false)
            publishStatusThrottled(repair.summaryLine, force: true)
        }
    }

    func deduplicateLocationsTapped() {
        Task {
            isMaintainingEvents = true
            defer { isMaintainingEvents = false }

            let db = backgroundDatabase
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

            let db = backgroundDatabase
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
            attributeTags: event.attributeTags,
            eventMainPerson: event.eventMainPerson,
            eventMainPerson2: event.eventMainPerson2,
            weddingDate: event.weddingDate,
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

    func confirmAIAttributeTag(displayEventId: Int, tag: EventAttributeTag) {
        for eventId in tag.actionEventIds(displayEventId: displayEventId) {
            database.confirmAIAttributeTag(eventId: eventId, field: tag.category)
        }
        refreshEvent(eventId: displayEventId)
        Task {
            await refreshHomeCategoryCounts()
            await refreshOccasionLandingItems()
        }
    }

    func rejectAIAttributeTag(displayEventId: Int, tag: EventAttributeTag) {
        for eventId in tag.actionEventIds(displayEventId: displayEventId) {
            database.rejectAIAttributeTag(eventId: eventId, field: tag.category)
        }
        refreshEvent(eventId: displayEventId)
        Task {
            await refreshHomeCategoryCounts()
            await refreshOccasionLandingItems()
        }
    }

    func confirmAIHolidayTag(displayEventId: Int, tag: EventHolidayTag) {
        confirmAIAttributeTag(
            displayEventId: displayEventId,
            tag: EventAttributeTag(holidayTag: tag)
        )
    }

    func rejectAIHolidayTag(displayEventId: Int, tag: EventHolidayTag) {
        rejectAIAttributeTag(
            displayEventId: displayEventId,
            tag: EventAttributeTag(holidayTag: tag)
        )
    }

    func refreshEvent(eventId: Int) {
        guard let updated = database.getEvent(eventId: eventId) else {
            removeEventFromList(eventId: eventId)
            return
        }

        // Update the row in place so Event Detail navigation stays stable while open.
        // Filter membership (e.g. post-Vision tag removal) is reconciled on reloadEventsAsync.
        if let index = events.firstIndex(where: { $0.eventId == eventId }) {
            events[index] = updated
            rebuildEventSections()
        }
    }

    private func removeEventFromList(eventId: Int) {
        events.removeAll { $0.eventId == eventId }
        rebuildEventSections()
        let title = activeEventListFilter.navigationTitle
        setBaseStatus("\(events.count.formatted()) \(title.lowercased())")
    }

    func reloadEvents() {
        Task {
            await reloadEventsAsync()
        }
    }

    private func rebuildEventSections() {
        let preservedSlideshowIds = slideshowIdsFromCurrentSections()
        let fromDatabase = database.getSlideshowPhotoIds(for: events)
        eventSections = Self.buildEventSections(
            from: events,
            slideshowIdsByEvent: mergedSlideshowIds(
                preserved: preservedSlideshowIds,
                fromDatabase: fromDatabase
            )
        )
    }

    private func slideshowIdsFromCurrentSections() -> [Int: [String]] {
        var result: [Int: [String]] = [:]
        for section in eventSections {
            for item in section.items where !item.slideshowPhotoIds.isEmpty {
                result[item.event.eventId] = item.slideshowPhotoIds
            }
        }
        return result
    }

    private func mergedSlideshowIds(
        preserved: [Int: [String]],
        fromDatabase: [Int: [String]]
    ) -> [Int: [String]] {
        var merged = preserved
        for (eventId, ids) in fromDatabase where !ids.isEmpty {
            merged[eventId] = ids
        }
        return merged
    }

    private func applyPreservedSlideshowIds(
        to sections: [EventYearSection],
        preserved: [Int: [String]]
    ) -> [EventYearSection] {
        guard !preserved.isEmpty else { return sections }
        return sections.map { section in
            EventYearSection(
                year: section.year,
                items: section.items.map { item in
                    if !item.slideshowPhotoIds.isEmpty {
                        return item
                    }
                    guard let ids = preserved[item.event.eventId], !ids.isEmpty else {
                        return item
                    }
                    return EventListDisplayItem(event: item.event, slideshowPhotoIds: ids)
                }
            )
        }
    }

    // MARK: - Occasion frame landing (Mother's / Father's Day)

    func refreshOccasionFrameLanding(for item: OccasionLandingItem) async {
        isLoadingOccasionFrame = true
        defer { isLoadingOccasionFrame = false }

        let snapshot = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.fetchOccasionFrameLandingSnapshot(
                occasionKey: item.occasionKey,
                tagValue: item.tagValue,
                name: item.name,
                nextOccurrence: item.nextOccurrence,
                occasionType: item.occasionType
            )
        }.value

        occasionFrameSnapshot = snapshot
        updateOccasionLandingCounts(for: item, snapshot: snapshot)
    }

    func removePhotoFromOccasionFrame(photoId: String, occasionKey: String) {
        database.setPhotoOccasionOnFrame(
            photoId: photoId,
            occasionKey: occasionKey,
            isOnFrame: false
        )

        if var snapshot = occasionFrameSnapshot, snapshot.occasionKey == occasionKey {
            snapshot = OccasionFrameLandingSnapshot(
                occasionKey: snapshot.occasionKey,
                name: snapshot.name,
                tagValue: snapshot.tagValue,
                nextOccurrence: snapshot.nextOccurrence,
                collectionCount: snapshot.collectionCount,
                onFramePhotoIds: snapshot.onFramePhotoIds.filter { $0 != photoId }
            )
            occasionFrameSnapshot = snapshot
            if let item = occasionLandingItems.first(where: { $0.occasionKey == occasionKey }) {
                updateOccasionLandingCounts(for: item, snapshot: snapshot)
            }
        }
    }

    func addPhotosToOccasionFrame(
        photoIds: [String],
        occasionKey: String,
        source: PhotoOccasionSource
    ) {
        guard !photoIds.isEmpty else { return }

        for photoId in photoIds {
            database.linkPhotoToOccasion(
                photoId: photoId,
                occasionKey: occasionKey,
                source: source,
                personId: nil,
                isOnFrame: true
            )
        }

        if let item = occasionLandingItems.first(where: { $0.occasionKey == occasionKey }) {
            Task {
                await refreshOccasionFrameLanding(for: item)
                await refreshOccasionLandingItems()
            }
        }
    }

    func saveOccasionPeopleSubjects(
        occasionKey: String,
        parentPersonId: Int,
        childPersonIds: [Int],
        parentRole: OccasionSubjectRole
    ) {
        let subjects: [(personId: Int, role: OccasionSubjectRole)] =
            [(parentPersonId, parentRole)]
            + childPersonIds.map { ($0, .child) }

        database.saveOccasionSubjects(
            occasionKey: occasionKey,
            subjects: subjects
        )
    }

    func searchOccasionPeoplePhotos(
        parentPersonId: Int,
        childPersonIds: [Int],
        exactPeopleOnly: Bool
    ) -> [String] {
        database.searchPhotosWithPeople(
            requiredPersonId: parentPersonId,
            includingAnyOfPersonIds: childPersonIds,
            exactPeopleOnly: exactPeopleOnly
        )
    }

    func searchOccasionPersonPhotos(personId: Int, exactPeopleOnly: Bool) -> [String] {
        database.searchPhotosWithPerson(personId: personId, exactPeopleOnly: exactPeopleOnly)
    }

    func fetchOccasionPersonId(occasionKey: String) -> Int? {
        database.fetchOccasionPersonId(occasionKey: occasionKey)
    }

    func fetchAllPeople() -> [PeopleRepository.PersonRecord] {
        database.fetchAllPeople()
    }

    func fetchOccasionSubjects(occasionKey: String) -> [OccasionSubject] {
        database.fetchOccasionSubjects(occasionKey: occasionKey)
    }

    private func updateOccasionLandingCounts(
        for item: OccasionLandingItem,
        snapshot: OccasionFrameLandingSnapshot
    ) {
        guard let index = occasionLandingItems.firstIndex(where: { $0.occasionKey == item.occasionKey }) else {
            return
        }

        occasionLandingItems[index] = item.withCounts(
            collection: snapshot.collectionCount,
            onFrame: snapshot.onFramePhotoIds.count
        )
    }
}
