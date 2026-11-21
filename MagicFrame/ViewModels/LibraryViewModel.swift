import Foundation
import Combine
import Photos

struct EventListDisplayItem: Identifiable {
    let event: IndexedEvent
    let slideshowPhotoIds: [String]
    /// True when any still/video in this event (or a trip child day) has includeInSlideshow.
    let hasOnFramePhotos: Bool
    /// Best on-frame video for muted inline cover playback (nil if none).
    let onFrameVideoId: String?
    /// Score bar on cover photos: away over home, scores right-aligned.
    let gameCoverScoreBoard: GameCoverScoreBoard?
    /// Suggested list title when the user has not edited the name: "Home vs Away".
    let gameSuggestedName: String?
    /// League for Sport sort (sporting events with a linked game result).
    let gameLeague: SportsLeague?
    /// Stable team sort key: alphabetically ordered home/away display names.
    let gameTeamSortKey: String?

    var id: Int { event.eventId }

    init(
        event: IndexedEvent,
        slideshowPhotoIds: [String] = [],
        hasOnFramePhotos: Bool = false,
        onFrameVideoId: String? = nil,
        gameCoverScoreBoard: GameCoverScoreBoard? = nil,
        gameSuggestedName: String? = nil,
        gameLeague: SportsLeague? = nil,
        gameTeamSortKey: String? = nil
    ) {
        self.event = event
        self.slideshowPhotoIds = slideshowPhotoIds
        self.hasOnFramePhotos = hasOnFramePhotos
        self.onFrameVideoId = onFrameVideoId
        self.gameCoverScoreBoard = gameCoverScoreBoard
        self.gameSuggestedName = gameSuggestedName
        self.gameLeague = gameLeague
        self.gameTeamSortKey = gameTeamSortKey
    }

    func withSlideshowPhotoIds(_ ids: [String]) -> EventListDisplayItem {
        EventListDisplayItem(
            event: event,
            slideshowPhotoIds: ids,
            hasOnFramePhotos: hasOnFramePhotos,
            onFrameVideoId: onFrameVideoId,
            gameCoverScoreBoard: gameCoverScoreBoard,
            gameSuggestedName: gameSuggestedName,
            gameLeague: gameLeague,
            gameTeamSortKey: gameTeamSortKey
        )
    }

    func withOnFrameVideoId(_ onFrameVideoId: String?) -> EventListDisplayItem {
        EventListDisplayItem(
            event: event,
            slideshowPhotoIds: slideshowPhotoIds,
            hasOnFramePhotos: hasOnFramePhotos,
            onFrameVideoId: onFrameVideoId,
            gameCoverScoreBoard: gameCoverScoreBoard,
            gameSuggestedName: gameSuggestedName,
            gameLeague: gameLeague,
            gameTeamSortKey: gameTeamSortKey
        )
    }

    func withEvent(_ event: IndexedEvent) -> EventListDisplayItem {
        EventListDisplayItem(
            event: event,
            slideshowPhotoIds: slideshowPhotoIds,
            hasOnFramePhotos: hasOnFramePhotos,
            onFrameVideoId: onFrameVideoId,
            gameCoverScoreBoard: gameCoverScoreBoard,
            gameSuggestedName: gameSuggestedName,
            gameLeague: gameLeague,
            gameTeamSortKey: gameTeamSortKey
        )
    }

    func withHasOnFramePhotos(_ hasOnFramePhotos: Bool) -> EventListDisplayItem {
        EventListDisplayItem(
            event: event,
            slideshowPhotoIds: slideshowPhotoIds,
            hasOnFramePhotos: hasOnFramePhotos,
            onFrameVideoId: onFrameVideoId,
            gameCoverScoreBoard: gameCoverScoreBoard,
            gameSuggestedName: gameSuggestedName,
            gameLeague: gameLeague,
            gameTeamSortKey: gameTeamSortKey
        )
    }
}

enum EventListSectionPresentation: Equatable, Sendable {
    /// Collapsible year banner (Collections / Holidays).
    case yearAccordion
    /// Always-visible rows; optional `headerTitle` divider (Weddings).
    case flatAlwaysVisible
}

struct EventYearSection: Identifiable {
    /// Year for accordion sections, or a stable sentinel id for flat sections.
    let year: Int
    let items: [EventListDisplayItem]
    var presentation: EventListSectionPresentation = .yearAccordion
    /// Shown above flat sections (e.g. "Possible Weddings"). Nil = no header.
    var headerTitle: String? = nil

    var id: Int { year }

    var eventCount: Int { items.count }

    var photoCount: Int {
        items.reduce(0) { $0 + $1.event.photoCount + $1.event.videoCount }
    }

    static let confirmedMilestoneSectionId = -1_000_001
    static let possibleMilestoneSectionId = -1_000_002
    static let confirmedHolidaySectionId = -1_000_003
    static let possibleHolidaySectionId = -1_000_004
    static let confirmedOutingSectionId = -1_000_005
    static let possibleOutingSectionId = -1_000_006
}

struct EventListScrollTarget: Equatable {
    let eventId: Int
    let requestID: UUID
}

struct WeddingCoupleConfirmRequest: Identifiable {
    let displayEventId: Int
    let event: IndexedEvent
    let people: [MilestonePersonPickerItem]

    var id: Int { displayEventId }
}

struct SimilarEventPeoplePickRequest: Identifiable {
    let displayEventId: Int
    let event: IndexedEvent
    let alternative: SimilarEventTagAlternative
    let people: [MilestonePersonPickerItem]

    var id: Int { displayEventId }

    var needsCouple: Bool { alternative.possibleNumberOfEventMainPeople >= 2 }
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
    @Published var homeAllPhotosCount: Int = 0
    @Published var homePeopleCount: Int = 0
    @Published var homeLocationsCount: Int = 0
    /// When set (e.g. while browsing Christmas photos), the Events tab opens that holiday’s events.
    @Published var eventsTabFilter: EventListFilter = .allEvents
    /// Media-stack bottom chrome: landing hubs vs full Media|Events|Developer|Search.
    @Published var mainTabChromeMode: MainTabChromeMode = .landing
    /// Cross-tab deep link into the Media stack (consumed by `MainTabView`).
    @Published var mediaNavigationRequest: MediaNavigationRequest?
    /// Bumped when the Search tab should open Pictures search on the current All Media browser.
    @Published var mediaPhotoSearchRequestID: UUID?
    /// Last visible month per Photos↔Events pair (in-memory; survives tab remounts).
    private var browseMonthAnchorByScope: [BrowseMonthScope: BrowseMonthAnchor] = [:]
    @Published var holidayLandingItems: [HolidayLandingItem] = []
    @Published var isLoadingHolidayLanding = false
    @Published var hasLoadedHolidayLanding = false
    @Published var milestoneLandingItems: [TagCategoryLandingItem] = []
    @Published var outingLandingItems: [TagCategoryLandingItem] = []
    @Published var activityLandingItems: [TagCategoryLandingItem] = []
    @Published var peopleLandingItems: [PeopleRepository.PeopleLandingItem] = []
    @Published var isLoadingPeopleLanding = false
    @Published var eventListScrollTarget: EventListScrollTarget?
    @Published var pendingWeddingCoupleConfirm: WeddingCoupleConfirmRequest?
    @Published var pendingSimilarEventAlternatives: SimilarEventAlternativesRequest?
    /// After choosing a similar-event alternative that needs main people.
    @Published var pendingSimilarEventPeoplePick: SimilarEventPeoplePickRequest?
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
    private var eventListEnrichmentTask: Task<Void, Never>?
    /// Populated only when the Events on Frame filter needs it (or after an explicit refresh).
    private var onFrameEventIdsCache: Set<Int>?
    private var eventDateRepairTask: Task<Void, Never>?
    private var holidayLandingVisionTask: Task<Void, Never>?
    private var visionTagScanTask: Task<Void, Never>?
    private var holidayYearExpandTask: Task<Void, Never>?
    private var activeHolidayVisionYear: Int?
    private var activeHolidayVisionScopeKey: String?
    private var holidayLandingRefreshTask: Task<Void, Never>?
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
                self?.handleEventSyncProgress(notification)
            }
            .store(in: &cancellables)
    }

    private func handleEventSyncProgress(_ notification: Notification) {
        guard !isShowingGeocodeProgress else { return }
        let info = notification.userInfo

        if let statusMessage = info?["statusMessage"] as? String {
            publishStatusThrottled(
                statusMessage,
                force: Self.notificationBool(info?["forcePublish"])
            )
            return
        }

        if let progress = notification.object as? EventSyncProgress {
            if let statusMessage = progress.statusMessage {
                publishStatusThrottled(statusMessage, force: progress.forcePublish)
            } else {
                publishStatusThrottled(progress.displayStatus)
            }
            return
        }

        let progress = EventSyncProgress(
            processed: Self.notificationInt(info?["processed"]),
            total: Self.notificationInt(info?["total"]),
            remainingUnassigned: Self.notificationInt(info?["remainingUnassigned"]),
            isRebuild: Self.notificationBool(info?["isRebuild"])
        )
        publishStatusThrottled(progress.displayStatus)
    }

    private static func notificationInt(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        return 0
    }

    private static func notificationBool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let bool = value as? Bool { return bool }
        return false
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

    func focusEventsTabOnChristmas() {
        focusEventsTabOnHoliday(tagValue: "Christmas")
    }

    func focusEventsTabOnHoliday(tagValue: String) {
        eventsTabFilter = .holidayTag(value: tagValue)
    }

    func focusEventsTabOnMilestone(_ filter: EventListFilter) {
        eventsTabFilter = filter
    }

    func focusEventsTabOnOuting(_ filter: EventListFilter) {
        eventsTabFilter = filter
    }

    func clearEventsTabFocus() {
        eventsTabFilter = .allEvents
    }

    func setMainTabChromeMode(_ mode: MainTabChromeMode) {
        guard mainTabChromeMode != mode else { return }
        mainTabChromeMode = mode
    }

    /// All Events back → Media Home (Figma events.all).
    func requestReturnToHome() {
        clearEventsTabFocus()
        mediaNavigationRequest = .home
    }

    /// Events holiday back → Media Holidays hub (Figma).
    func requestReturnToHolidaysHub() {
        clearEventsTabFocus()
        mediaNavigationRequest = .holidaysHub
    }

    /// All Events → All Media Photos (Media tab while on the All Events root).
    func requestNavigateToAllMediaPhotos() {
        clearEventsTabFocus()
        mediaNavigationRequest = .allMediaPhotos
    }

    func requestOpenMediaPhotoSearch() {
        mediaPhotoSearchRequestID = UUID()
    }

    func consumeMediaPhotoSearchRequest() {
        mediaPhotoSearchRequestID = nil
    }

    func consumeMediaNavigationRequest() {
        mediaNavigationRequest = nil
    }

    func rememberBrowseMonth(_ anchor: BrowseMonthAnchor, scope: BrowseMonthScope) {
        browseMonthAnchorByScope[scope] = anchor
    }

    func browseMonthAnchor(for scope: BrowseMonthScope) -> BrowseMonthAnchor? {
        browseMonthAnchorByScope[scope]
    }

    func rememberBrowseMonth(yyyymm: Int, scope: BrowseMonthScope) {
        guard let anchor = BrowseMonthAnchor.from(yyyymm: yyyymm) else { return }
        rememberBrowseMonth(anchor, scope: scope)
    }

    func rememberBrowseMonth(photoSectionId: String, scope: BrowseMonthScope) {
        guard let anchor = BrowseMonthAnchor.from(photoSectionId: photoSectionId) else { return }
        rememberBrowseMonth(anchor, scope: scope)
    }

    func cancelHolidayLandingRefresh() {
        holidayLandingRefreshTask?.cancel()
        holidayLandingRefreshTask = nil
    }

    /// Fire-and-forget refresh for Holidays landing (cancellable when navigating away).
    func scheduleHolidayLandingRefresh() {
        holidayLandingRefreshTask?.cancel()
        holidayLandingRefreshTask = Task(priority: .utility) { [weak self] in
            await self?.refreshHolidayLandingItemsAsync()
        }
    }

    func refreshHolidayLandingItems() async {
        holidayLandingRefreshTask?.cancel()
        await refreshHolidayLandingItemsAsync()
    }

    private func refreshHolidayLandingItemsAsync() async {
        isLoadingHolidayLanding = true
        defer { isLoadingHolidayLanding = false }

        let catalog = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.fetchHolidayLandingCatalogItems()
        }.value

        guard !Task.isCancelled else { return }

        holidayLandingItems = catalog
        hasLoadedHolidayLanding = true
    }

    func refreshHomeCategoryCounts() async {
        let counts = await Task.detached(priority: .utility) { [backgroundDatabase] in
            (
                photos: backgroundDatabase.countActivePhotos(),
                people: backgroundDatabase.fetchAllPeople().count,
                locations: backgroundDatabase.countLocations()
            )
        }.value

        homeAllPhotosCount = counts.photos
        homePeopleCount = counts.people
        homeLocationsCount = counts.locations
    }

    func refreshMilestoneLandingItems() async {
        milestoneLandingItems = TagCategoryLandingCatalog.milestones()
    }

    func refreshOutingLandingItems() async {
        outingLandingItems = TagCategoryLandingCatalog.outings()
    }

    func refreshActivityLandingItems() async {
        activityLandingItems = TagCategoryLandingCatalog.activities()
    }

    @Published var unnamedFaceClusters: [PersonClusterRecord] = []
    @Published var isLoadingFaceClusters = false
    @Published var faceRecognitionScannedCount: Int = 0
    @Published var faceRecognitionRemainingCount: Int = 0
    @Published var faceRecognitionTotalCount: Int = 0
    @Published var faceRecognitionFacesDetectedCount: Int = 0
    @Published var faceRecognitionClustersIdentifiedCount: Int = 0
    @Published var isFaceRecognitionScanning: Bool = false

    private var faceRecognitionProgressTask: Task<Void, Never>?

    func refreshPeopleLandingItems() async {
        isLoadingPeopleLanding = true
        defer { isLoadingPeopleLanding = false }

        peopleLandingItems = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.fetchPeopleLandingItems()
        }.value
    }

    func refreshUnnamedFaceClusters() async {
        isLoadingFaceClusters = true
        defer { isLoadingFaceClusters = false }
        unnamedFaceClusters = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.fetchUnnamedFaceClusters()
        }.value
    }

    func enqueueFaceRecognitionScanTapped(forceRescan: Bool = false) {
        FaceCircleAvatar.clearCache()
        unnamedFaceClusters = []
        let summary = backgroundDatabase.enqueueFaceRecognitionScan(forceRescan: forceRescan)
        refreshFaceRecognitionProgressCounts()
        if let skipped = summary.skippedReason, summary.enqueuedCount == 0 {
            publishStatusThrottled(skipped, force: true)
            isFaceRecognitionScanning = false
        } else {
            publishStatusThrottled(
                "Queued \(summary.enqueuedCount.formatted()) face scans · "
                    + "\(faceRecognitionScannedCount.formatted()) of \(faceRecognitionTotalCount.formatted()) photos done"
                    + " · leave People while scanning",
                force: true
            )
            startFaceRecognitionProgressMonitoring()
        }
    }

    func cancelFaceRecognitionScanTapped() {
        faceRecognitionProgressTask?.cancel()
        faceRecognitionProgressTask = nil
        isFaceRecognitionScanning = false
        FaceCircleAvatar.clearCache()
        let restored = backgroundDatabase.cancelFaceRecognitionScan(restoreScannedVersions: true)
        refreshFaceRecognitionProgressCounts()
        publishStatusThrottled(
            restored > 0
                ? "Canceled face scan · restored \(restored.formatted()) already-scanned photos"
                : "Canceled face scan queue",
            force: true
        )
        Task { await refreshUnnamedFaceClusters() }
    }

    func resetAllFaceRecognitionDataTapped() async {
        faceRecognitionProgressTask?.cancel()
        faceRecognitionProgressTask = nil
        isFaceRecognitionScanning = false
        FaceCircleAvatar.clearCache()
        publishStatusThrottled("Resetting face recognition…", force: true)
        await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.resetAllFaceRecognitionData()
        }.value
        unnamedFaceClusters = []
        peopleLandingItems = []
        refreshFaceRecognitionProgressCounts()
        publishStatusThrottled(
            "Face recognition reset · run Picture Searches / open events to detect faces, then rebuild clusters before naming",
            force: true
        )
        await refreshPeopleLandingItems()
        await refreshUnnamedFaceClusters()
    }

    func refreshFaceRecognitionProgressCounts() {
        applyFaceRecognitionProgress(backgroundDatabase.faceRecognitionProgress())
    }

    /// Repairs “0 photos scanned” after an accidental force-rescan cleared version stamps.
    func repairFaceRecognitionProgressIfNeeded() {
        let before = backgroundDatabase.faceRecognitionProgress()
        guard before.photosScanned == 0, before.facesDetected > 0 else {
            applyFaceRecognitionProgress(before)
            return
        }
        _ = backgroundDatabase.restoreFaceRecognitionVersionsForScannedPhotos()
        applyFaceRecognitionProgress(backgroundDatabase.faceRecognitionProgress())
    }

    func resumeFaceRecognitionProgressMonitoringIfNeeded() {
        guard !isFaceRecognitionScanning else { return }
        let pendingJobs = backgroundDatabase.pendingFaceRecognitionJobCount()
        guard pendingJobs > 0 else { return }
        startFaceRecognitionProgressMonitoring()
    }

    private func applyFaceRecognitionProgress(_ progress: FaceRecognitionProgress) {
        faceRecognitionScannedCount = progress.photosScanned
        faceRecognitionRemainingCount = progress.photosRemaining
        faceRecognitionTotalCount = progress.photosTotal
        faceRecognitionFacesDetectedCount = progress.facesDetected
        faceRecognitionClustersIdentifiedCount = progress.clustersIdentified
    }

    private func startFaceRecognitionProgressMonitoring() {
        faceRecognitionProgressTask?.cancel()
        isFaceRecognitionScanning = true
        FaceCircleAvatar.clearCache()
        faceRecognitionProgressTask = Task { [weak self] in
            guard let self else { return }
            var ticks = 0
            while !Task.isCancelled {
                let progress = await Task.detached(priority: .utility) { [backgroundDatabase] in
                    backgroundDatabase.faceRecognitionProgress()
                }.value
                let pendingJobs = backgroundDatabase.pendingFaceRecognitionJobCount()

                applyFaceRecognitionProgress(progress)

                let line =
                    "Face recognition \(progress.photosScanned.formatted()) of \(progress.photosTotal.formatted()) photos"
                    + " · \(progress.facesDetected.formatted()) faces"
                    + " · \(progress.clustersIdentified.formatted()) clusters"
                    + (pendingJobs > 0 ? " · \(pendingJobs.formatted()) queued" : "")
                publishStatusThrottled(line)

                ticks += 1
                if ticks % 8 == 0 {
                    FaceCircleAvatar.clearCache()
                }

                if pendingJobs == 0 {
                    isFaceRecognitionScanning = false
                    FaceCircleAvatar.clearCache()
                    // Do NOT auto-consolidate here — pairwise merge jetsams after large batches.
                    // User should tap Rebuild clusters when idle.
                    publishStatusThrottled(
                        "Face recognition idle · \(progress.photosScanned.formatted()) of \(progress.photosTotal.formatted()) photos"
                            + " · \(progress.facesDetected.formatted()) faces"
                            + " · \(progress.clustersIdentified.formatted()) clusters"
                            + " · tap Rebuild clusters when ready",
                        force: true
                    )
                    // Keep the People grid empty of heavy avatars until the user asks.
                    unnamedFaceClusters = []
                    break
                }

                try? await Task.sleep(for: .milliseconds(1_000))
            }
            if !Task.isCancelled {
                isFaceRecognitionScanning = false
            }
        }
    }

    func nameFaceCluster(
        clusterId: Int,
        displayName: String,
        firstName: String?,
        lastName: String?,
        maidenName: String?
    ) {
        let personId = backgroundDatabase.nameFaceCluster(
            clusterId: clusterId,
            displayName: displayName,
            firstName: firstName,
            lastName: lastName,
            maidenName: maidenName
        )
        if personId > 0 {
            publishStatusThrottled("Named \(displayName)", force: true)
        }
        Task {
            await refreshPeopleLandingItems()
            await refreshUnnamedFaceClusters()
            refreshLibraryCounts()
        }
    }

    func mergeFaceCluster(clusterId: Int, intoPersonId personId: Int) {
        backgroundDatabase.mergeFaceCluster(clusterId: clusterId, intoPersonId: personId)
        Task {
            await refreshPeopleLandingItems()
            await refreshUnnamedFaceClusters()
            refreshLibraryCounts()
        }
    }

    func ignoreFaceCluster(clusterId: Int) {
        backgroundDatabase.ignoreFaceCluster(clusterId: clusterId)
        Task { await refreshUnnamedFaceClusters() }
    }

    func consolidateFaceClustersTapped() async {
        let merged = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.consolidateUnnamedFaceClusters()
        }.value
        if merged > 0 {
            publishStatusThrottled(
                "Combined \(merged.formatted()) duplicate face cluster\(merged == 1 ? "" : "s")",
                force: true
            )
        } else {
            publishStatusThrottled("No similar face clusters to combine", force: true)
        }
        await refreshUnnamedFaceClusters()
    }

    func rebuildFaceClustersTapped() async {
        publishStatusThrottled("Rebuilding face clusters…", force: true)
        FaceCircleAvatar.clearCache()
        unnamedFaceClusters = []
        let clusterCount = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.rebuildUnnamedFaceClusters()
        }.value
        FaceCircleAvatar.clearCache()
        // Separate pass after rebuild frees its working set — never combine in one go.
        try? await Task.sleep(for: .milliseconds(300))
        let merged = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.consolidateUnnamedFaceClusters()
        }.value
        FaceCircleAvatar.clearCache()
        var message = "Rebuilt \(clusterCount.formatted()) face cluster\(clusterCount == 1 ? "" : "s")"
        if merged > 0 {
            message += " · combined \(merged.formatted()) near-duplicates"
        }
        publishStatusThrottled(message, force: true)
        await refreshUnnamedFaceClusters()
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
        eventListEnrichmentTask?.cancel()
        if filter != activeEventListFilter {
            events = []
            eventSections = []
            expandedListYear = nil
            onFrameEventIdsCache = nil
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
        eventListEnrichmentTask?.cancel()
        onFrameEventIdsCache = nil

        let loadStart = CFAbsoluteTimeGetCurrent()
        // Paint first: event rows + covers only. Game scores, on-frame flags, and slideshow picks follow.
        let payload = await Task.detached(priority: .utility) { [backgroundDatabase, includeHidden, listFilter] in
            let loaded = backgroundDatabase.getEventsForList(
                includeHidden: includeHidden,
                limit: nil,
                filter: listFilter
            )
            let sections = LibraryViewModel.buildEventSections(
                from: loaded,
                slideshowIdsByEvent: [:],
                onFrameEventIds: [],
                gameResultsByEventId: [:],
                listFilter: listFilter
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

        let enrichmentEventIds = events.map(\.eventId)
        eventListEnrichmentTask = Task(priority: .utility) { [weak self] in
            await self?.enrichEventListAfterPaint(
                eventIds: enrichmentEventIds,
                loadSlideshowIds: loadSlideshowIds
            )
        }
    }

    /// Loads saved game scoreboards after the list is visible, then slideshow preview picks.
    private func enrichEventListAfterPaint(
        eventIds: [Int],
        loadSlideshowIds: Bool
    ) async {
        guard !eventIds.isEmpty else { return }

        let gameResults = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.fetchEventGameResults(eventIds: eventIds)
        }.value
        guard !Task.isCancelled else { return }

        if !gameResults.isEmpty {
            await MainActor.run {
                mergeGameResults(gameResults)
            }
        }

        guard !Task.isCancelled else { return }

        if loadSlideshowIds {
            await loadSlideshowPhotosChunked()
        } else {
            await MainActor.run {
                reloadSlideshowPhotosForExpandedYearIfNeeded()
            }
        }
    }

    /// Scans which list events have on-frame photos. Used when the Events on Frame filter is selected.
    func ensureOnFrameEventFlagsLoaded() async {
        if onFrameEventIdsCache != nil { return }
        let eventIds = events.map(\.eventId)
        guard !eventIds.isEmpty else {
            onFrameEventIdsCache = []
            return
        }

        let ids = await Task.detached(priority: .utility) { [backgroundDatabase] in
            backgroundDatabase.listEventIdsWithOnFramePhotos(among: eventIds)
        }.value
        guard !Task.isCancelled else { return }

        onFrameEventIdsCache = ids
        mergeOnFrameFlags(ids)
    }

    private func mergeGameResults(_ gameResultsByEventId: [Int: EventGameResult]) {
        guard !gameResultsByEventId.isEmpty else { return }
        eventSections = eventSections.map { section in
            EventYearSection(
                year: section.year,
                items: section.items.map { item in
                    guard let game = gameResultsByEventId[item.event.eventId] else { return item }
                    return EventListDisplayItem(
                        event: item.event,
                        slideshowPhotoIds: item.slideshowPhotoIds,
                        hasOnFramePhotos: item.hasOnFramePhotos,
                        onFrameVideoId: item.onFrameVideoId,
                        gameCoverScoreBoard: game.coverScoreBoard,
                        gameSuggestedName: game.suggestedEventName,
                        gameLeague: game.league,
                        gameTeamSortKey: game.teamSortKey
                    )
                },
                presentation: section.presentation,
                headerTitle: section.headerTitle
            )
        }
    }

    private func mergeOnFrameFlags(_ onFrameEventIds: Set<Int>) {
        eventSections = eventSections.map { section in
            EventYearSection(
                year: section.year,
                items: section.items.map { item in
                    let flag = onFrameEventIds.contains(item.event.eventId)
                    guard item.hasOnFramePhotos != flag else { return item }
                    return item.withHasOnFramePhotos(flag)
                },
                presentation: section.presentation,
                headerTitle: section.headerTitle
            )
        }
    }

    /// Re-fetches slideshow picks for the expanded year after a list reload.
    /// Always reloads when a year is expanded — cover seeds alone must not skip framed picks.
    func reloadSlideshowPhotosForExpandedYearIfNeeded() {
        guard let year = expandedListYear else { return }
        guard activeHolidayVisionConfig == nil else { return }
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

                let (partial, onFrameVideos) = await Task.detached(priority: .utility) { [backgroundDatabase] in
                    (
                        backgroundDatabase.getSlideshowPhotoIds(for: chunk),
                        backgroundDatabase.getOnFrameVideoIds(for: chunk)
                    )
                }.value

                guard !Task.isCancelled else { continue }
                guard !partial.isEmpty || !onFrameVideos.isEmpty else { continue }

                await MainActor.run {
                    if !partial.isEmpty {
                        self.mergeSlideshowPhotoIds(partial)
                    }
                    if !onFrameVideos.isEmpty {
                        self.mergeOnFrameVideoIds(onFrameVideos)
                    }
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

            let (partial, onFrameVideos) = await Task.detached(priority: .utility) { [backgroundDatabase] in
                (
                    backgroundDatabase.getSlideshowPhotoIds(for: chunk),
                    backgroundDatabase.getOnFrameVideoIds(for: chunk)
                )
            }.value

            guard !Task.isCancelled else { continue }
            guard !partial.isEmpty || !onFrameVideos.isEmpty else { continue }

            await MainActor.run {
                if !partial.isEmpty {
                    mergeSlideshowPhotoIds(partial)
                }
                if !onFrameVideos.isEmpty {
                    mergeOnFrameVideoIds(onFrameVideos)
                }
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

    private func mergeOnFrameVideoIds(_ videoIdsByEvent: [Int: String]) {
        var anyChange = false
        let updated = eventSections.map { section in
            var sectionChanged = false
            let items = section.items.map { item -> EventListDisplayItem in
                guard let videoId = videoIdsByEvent[item.event.eventId] else { return item }
                if item.onFrameVideoId == videoId {
                    return item
                }
                sectionChanged = true
                return item.withOnFrameVideoId(videoId)
            }
            guard sectionChanged else { return section }
            anyChange = true
            return EventYearSection(
                year: section.year,
                items: items,
                presentation: section.presentation,
                headerTitle: section.headerTitle
            )
        }
        if anyChange {
            eventSections = updated
        }
    }

    private func mergeSlideshowPhotoIds(_ slideshowIdsByEvent: [Int: [String]]) {
        guard !slideshowIdsByEvent.isEmpty else { return }

        var anyChange = false
        let updated = eventSections.map { section in
            var sectionChanged = false
            let items = section.items.map { item -> EventListDisplayItem in
                guard let ids = slideshowIdsByEvent[item.event.eventId], !ids.isEmpty else {
                    return item
                }
                if item.slideshowPhotoIds == ids {
                    return item
                }
                sectionChanged = true
                return item.withSlideshowPhotoIds(ids)
            }
            guard sectionChanged else { return section }
            anyChange = true
            return EventYearSection(
                year: section.year,
                items: items,
                presentation: section.presentation,
                headerTitle: section.headerTitle
            )
        }
        if anyChange {
            eventSections = updated
        }
    }

    nonisolated private static func buildEventSections(
        from events: [IndexedEvent],
        slideshowIdsByEvent: [Int: [String]],
        onFrameEventIds: Set<Int> = [],
        gameResultsByEventId: [Int: EventGameResult] = [:],
        listFilter: EventListFilter = .allEvents
    ) -> [EventYearSection] {
        let items = events.map { event in
            let game = gameResultsByEventId[event.eventId]
            let ids = slideshowIdsByEvent[event.eventId] ?? []
            let slideshowIds: [String] = {
                if !ids.isEmpty { return ids }
                if let coverPhotoId = event.coverPhotoId, !coverPhotoId.isEmpty {
                    return [coverPhotoId]
                }
                return []
            }()
            return EventListDisplayItem(
                event: event,
                slideshowPhotoIds: slideshowIds,
                hasOnFramePhotos: onFrameEventIds.contains(event.eventId),
                gameCoverScoreBoard: game?.coverScoreBoard,
                gameSuggestedName: game?.suggestedEventName,
                gameLeague: game?.league,
                gameTeamSortKey: game?.teamSortKey
            )
        }

        if case .milestoneTag(let tagValue) = listFilter {
            return buildMilestoneFlatSections(from: items, tagValue: tagValue)
        }
        if case .eventTypeTag(let tagValue) = listFilter {
            return buildOutingFlatSections(from: items, tagValue: tagValue)
        }
        if case .holidayTag(let tagValue) = listFilter {
            return buildHolidayFlatSections(from: items, tagValue: tagValue)
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

    /// User milestones first (by date), then AI under “Possible …” (by score). No year dividers.
    nonisolated private static func buildMilestoneFlatSections(
        from items: [EventListDisplayItem],
        tagValue: String
    ) -> [EventYearSection] {
        buildConfirmedPossibleFlatSections(
            from: items,
            confirmedSectionId: EventYearSection.confirmedMilestoneSectionId,
            possibleSectionId: EventYearSection.possibleMilestoneSectionId,
            possibleHeader: tagValue == "Wedding" ? "Possible Weddings" : "Possible \(tagValue)",
            isUserConfirmed: { $0.event.milestoneTag(matching: tagValue)?.source == .user },
            sort: {
                IndexedEvent.compareMilestoneTaggedListOrder($0.event, $1.event, tagValue: tagValue)
            }
        )
    }

    /// Confirmed holiday tags first, then AI under “Possible {Holiday} Events”.
    nonisolated private static func buildHolidayFlatSections(
        from items: [EventListDisplayItem],
        tagValue: String
    ) -> [EventYearSection] {
        buildConfirmedPossibleFlatSections(
            from: items,
            confirmedSectionId: EventYearSection.confirmedHolidaySectionId,
            possibleSectionId: EventYearSection.possibleHolidaySectionId,
            possibleHeader: "Possible \(tagValue) Events",
            isUserConfirmed: { $0.event.holidayTag(matching: tagValue)?.source == .user },
            sort: {
                IndexedEvent.compareHolidayTaggedListOrder($0.event, $1.event, tagValue: tagValue)
            }
        )
    }

    /// Confirmed outing event types first, then AI under “Possible …”.
    nonisolated private static func buildOutingFlatSections(
        from items: [EventListDisplayItem],
        tagValue: String
    ) -> [EventYearSection] {
        let possibleHeader: String = {
            switch tagValue {
            case "Concert": return "Possible Concerts"
            case "Play": return "Possible Plays"
            case "Sporting event": return "Possible Sporting Events"
            default: return "Possible \(tagValue)"
            }
        }()
        return buildConfirmedPossibleFlatSections(
            from: items,
            confirmedSectionId: EventYearSection.confirmedOutingSectionId,
            possibleSectionId: EventYearSection.possibleOutingSectionId,
            possibleHeader: possibleHeader,
            isUserConfirmed: { $0.event.eventTypeTag(matching: tagValue)?.source == .user },
            sort: {
                IndexedEvent.compareEventTypeTaggedListOrder(
                    $0.event,
                    $1.event,
                    tagValue: tagValue
                )
            }
        )
    }

    nonisolated private static func buildConfirmedPossibleFlatSections(
        from items: [EventListDisplayItem],
        confirmedSectionId: Int,
        possibleSectionId: Int,
        possibleHeader: String,
        isUserConfirmed: (EventListDisplayItem) -> Bool,
        sort: (EventListDisplayItem, EventListDisplayItem) -> Bool
    ) -> [EventYearSection] {
        let userItems = items.filter(isUserConfirmed).sorted(by: sort)
        let aiItems = items.filter { !isUserConfirmed($0) }.sorted(by: sort)

        var sections: [EventYearSection] = []
        if !userItems.isEmpty {
            sections.append(
                EventYearSection(
                    year: confirmedSectionId,
                    items: userItems,
                    presentation: .flatAlwaysVisible,
                    headerTitle: nil
                )
            )
        }
        if !aiItems.isEmpty {
            sections.append(
                EventYearSection(
                    year: possibleSectionId,
                    items: aiItems,
                    presentation: .flatAlwaysVisible,
                    headerTitle: possibleHeader
                )
            )
        }
        return sections
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
        visionTagScanTask?.cancel()
        visionTagScanTask = nil
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
                    self?.publishStatusThrottled("Indexed \(count.formatted()) items…")
                }
            }
        }.value

        await Task.detached(priority: .utility) {
            db.runPostIndexMetadataEnrichment()
        }.value

        await db.importMissingPhotoExif { [weak self] message in
            Task { @MainActor in
                self?.publishStatusThrottled(message, force: true)
            }
        }

        setBaseStatus("Indexed \(indexedCount.formatted()) items — building events…")
        await performEventSync(forceMaintenance: true)
        await reloadEventsAsync()
        setBaseStatus("Indexed \(indexedCount.formatted()) items — \(events.count.formatted()) events")
    }

    private nonisolated static func enumeratePhotoLibrary(
        database: PhotoDatabase,
        onProgress: @escaping @Sendable (Int) -> Void
    ) -> Int {
        let startDate = Calendar.current.date(byAdding: .year, value: -100, to: Date())
            ?? Date.distantPast
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND (mediaType == %d OR mediaType == %d)",
            startDate as NSDate,
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
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
                qualityScore: qualityScore,
                duration: asset.mediaType == .video ? asset.duration : nil
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
            publishStatusThrottled("Syncing events…", force: true)
            let unassignedBefore = await Task.detached(priority: .background) { [backgroundDatabase] in
                backgroundDatabase.countUnassignedPhotosForEvents()
            }.value
            await performEventSync(forceMaintenance: false)
            if unassignedBefore >= Self.fullMaintenanceUnassignedThreshold {
                await runEventMaintenance()
            } else {
                isSyncingEvents = true
                publishStatusThrottled("Joining no-GPS events…", force: true)
                await Task.detached(priority: .background) { [backgroundDatabase] in
                    backgroundDatabase.joinTimeOnlyEventsToSameDayLocatedEvents()
                }.value
            }
            isSyncingEvents = false
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

    /// Consistent SQLite snapshot for Share Sheet / AirDrop (does not write to Mac Desktop).
    func exportDatabaseForSharing() async -> URL? {
        publishStatusThrottled("Preparing database export…", force: true)
        do {
            let url = try await Task.detached(priority: .utility) {
                try DatabaseManager.shared.exportConsistentSnapshot()
            }.value
            publishStatusThrottled("Database ready to share — AirDrop to your Mac", force: true)
            return url
        } catch {
            publishStatusThrottled(
                "Database export failed: \(error.localizedDescription)",
                force: true
            )
            return nil
        }
    }

    func geocodeNextLocationsBatch() {
        database.startGeocodingEventLocations(limit: 40)
        publishStatusThrottled("Geocoding 40 recent locations…", force: true)
    }

    func relinkEventLocationsTapped() {
        guard !isMaintainingEvents, !isSyncingEvents else { return }

        Task {
            isMaintainingEvents = true
            publishStatusThrottled("Linking event locations from photo GPS…", force: true)

            let db = backgroundDatabase
            await Task.detached(priority: .background) {
                db.relinkEventLocationsFromPhotos()
            }.value

            isMaintainingEvents = false
            await reloadEventsAsync()
            refreshLibraryCounts()
            publishStatusThrottled("Event locations relinked. Run Geocode if names are empty.", force: true)
        }
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

    func tagPhotosWithVisionTagTapped(startMonthDay: String, endMonthDay: String) {
        guard let range = PhotoVisionTagQuery.normalizedRange(
            start: startMonthDay,
            end: endMonthDay
        ) else {
            publishStatusThrottled("Use a range like 12/1 – 12/31", force: true)
            return
        }

        visionTagScanTask?.cancel()
        visionTagScanTask = Task {
            isMaintainingEvents = true
            defer {
                isMaintainingEvents = false
                visionTagScanTask = nil
            }

            publishStatusThrottled(
                "Finding photos for \(range.displayText) (all years)…",
                force: true
            )

            let selection = await Task.detached(priority: .utility) { [backgroundDatabase] in
                backgroundDatabase.fetchUnanalyzedPhotoIdsMatchingMonthDayRange(
                    start: range.start,
                    end: range.end
                )
            }.value

            guard !Task.isCancelled else { return }

            let selectionLine = "\(range.displayText): \(selection.summaryLine)"
            print(selectionLine)
            if !selection.photoCountByYear.isEmpty {
                let yearBreakdown = selection.photoCountByYear.keys.sorted().map { year in
                    "\(year)=\(selection.photoCountByYear[year] ?? 0)"
                }.joined(separator: ", ")
                print("Vision tag years: \(yearBreakdown)")
            }

            guard !selection.photoIds.isEmpty else {
                if selection.totalInRange == 0 {
                    publishStatusThrottled(
                        "No photos for \(range.displayText) in any year.",
                        force: true
                    )
                } else {
                    publishStatusThrottled(
                        "All \(selection.totalInRange.formatted()) photos for \(range.displayText) "
                            + "(\(selection.yearSpanText)) already tagged.",
                        force: true
                    )
                }
                return
            }

            publishStatusThrottled(
                "Tagging \(selection.unanalyzedCount.formatted()) photos for \(range.displayText) "
                    + "· \(selection.yearSpanText) (newest first)…",
                force: true
            )

            let report = await backgroundDatabase.scanPhotosWithVisionTags(
                photoIds: selection.photoIds
            ) { current, total in
                Task { @MainActor in
                    self.publishStatusThrottled(
                        "Vision tags \(current.formatted()) of \(total.formatted())…"
                    )
                }
            }

            let message = "\(report.summaryLine) · \(range.displayText) · \(selection.yearSpanText)"
            print(message)
            publishStatusThrottled(message, force: true)
        }
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
            await refreshHolidayLandingItems()
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
        setEventsOnFrame(eventIds: [eventId], show: !events[index].showOnFrame)
    }

    func setEventsOnFrame(eventIds: Set<Int>, show: Bool) {
        guard !eventIds.isEmpty else { return }
        for eventId in eventIds {
            database.setEventShowOnFrame(eventId: eventId, show: show)
            if let index = events.firstIndex(where: { $0.eventId == eventId }),
               let updated = database.getEvent(eventId: eventId) {
                events[index] = updated
            }
        }
        rebuildEventSections()
    }

    func setEventsHidden(eventIds: Set<Int>, hidden: Bool) {
        guard !eventIds.isEmpty else { return }
        for eventId in eventIds {
            database.setEventUserHidden(eventId: eventId, hidden: hidden)
        }
        // Leave the current list mode; drop rows that no longer belong here.
        events.removeAll { eventIds.contains($0.eventId) }
        rebuildEventSections()
        setBaseStatus(
            showHiddenEvents
                ? "Showing \(events.count) hidden events"
                : "Showing \(events.count) events"
        )
    }

    func setEventsFavorite(eventIds: Set<Int>, isFavorite: Bool) {
        guard !eventIds.isEmpty else { return }
        for eventId in eventIds {
            database.setEventFavorite(eventId: eventId, isFavorite: isFavorite)
            if let index = events.firstIndex(where: { $0.eventId == eventId }),
               let updated = database.getEvent(eventId: eventId) {
                events[index] = updated
            }
        }
        eventSections = eventSections.map { section in
            EventYearSection(
                year: section.year,
                items: section.items.map { item in
                    guard eventIds.contains(item.event.eventId),
                          let updated = events.first(where: { $0.eventId == item.event.eventId }) else {
                        return item
                    }
                    return item.withEvent(updated)
                },
                presentation: section.presentation,
                headerTitle: section.headerTitle
            )
        }
    }

    /// Photo IDs among `photoIds` that are marked favorite (for Favorites event-list filter).
    func favoritePhotoIds(among photoIds: [String]) -> Set<String> {
        guard !photoIds.isEmpty else { return [] }
        let unique = Array(Set(photoIds))
        return Set(
            database.fetchPhotosForBrowser(photoIds: unique)
                .compactMap { $0.photo.isFavorite ? $0.photo.id : nil }
        )
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
        if tag.category == .milestoneType,
           tag.tagValue.compare("Wedding", options: .caseInsensitive) == .orderedSame {
            beginConfirmWedding(displayEventId: displayEventId, tag: tag)
            return
        }

        for eventId in tag.actionEventIds(displayEventId: displayEventId) {
            database.confirmAIAttributeTag(eventId: eventId, field: tag.category)
        }
        refreshEvent(eventId: displayEventId)
        Task {
            await refreshHomeCategoryCounts()
            await refreshHolidayLandingItems()
        }
    }

    /// Flips Wedding milestone AI → user, then presents Bride/Groom picker.
    func beginConfirmWedding(displayEventId: Int, tag: EventAttributeTag) {
        for eventId in tag.actionEventIds(displayEventId: displayEventId) {
            database.confirmAIAttributeTag(eventId: eventId, field: tag.category)
        }
        refreshEvent(eventId: displayEventId)

        guard let event = database.getEvent(eventId: displayEventId)
            ?? events.first(where: { $0.eventId == displayEventId }) else {
            return
        }

        let people = EventMilestonePersonPickerOrdering.items(
            eventPeople: database.fetchEventPeople(
                eventId: event.eventId,
                includeChildEvents: true
            ),
            allPeople: database.fetchAllPeople()
        )
        pendingWeddingCoupleConfirm = WeddingCoupleConfirmRequest(
            displayEventId: displayEventId,
            event: event,
            people: people
        )

        Task {
            await refreshHomeCategoryCounts()
            await refreshHolidayLandingItems()
        }
    }

    func completeWeddingCoupleConfirm(
        displayEventId: Int,
        bride: MilestonePersonPickerItem,
        groom: MilestonePersonPickerItem,
        weddingDate: Date
    ) {
        pendingWeddingCoupleConfirm = nil

        database.replaceUserEventMainPeople(
            eventId: displayEventId,
            names: [bride.name, groom.name]
        )

        let weddingDateISO = EventDateParser.dateOnlyISO(from: weddingDate)
        database.updateWeddingDate(eventId: displayEventId, weddingDate: weddingDateISO)
        _ = database.upsertMarriedCoupleRelationship(
            bridePersonId: bride.personId,
            groomPersonId: groom.personId,
            weddingDateISO: weddingDateISO,
            sourceEventId: displayEventId
        )
        _ = database.propagateAnniversaryTagsFromWedding(
            sourceEventId: displayEventId,
            person1: bride.name,
            person2: groom.name,
            weddingDateISO: weddingDateISO
        )
        database.updateWeddingCoverPhotoForEvent(eventId: displayEventId)

        if let event = database.getEvent(eventId: displayEventId), !event.userEditedName {
            let template = database.fetchEventNameTemplate(
                tagCategory: EventAttributeField.milestoneType.tagCategory,
                tagValue: "Wedding"
            )
            if let suggested = MilestoneEventNaming.suggestCoupleEventName(
                person1: bride.name,
                person2: groom.name,
                milestoneType: "Wedding",
                weddingDateISO: weddingDateISO,
                eventStartDate: event.startDate,
                nameTemplate: template
            ) {
                _ = database.updateEventName(
                    eventId: displayEventId,
                    name: suggested,
                    userEdited: false
                )
            }
        }

        refreshEvent(eventId: displayEventId)
        Task {
            await refreshHomeCategoryCounts()
            await reloadEventsAsync(
                filter: activeEventListFilter,
                loadSlideshowIds: false,
                preserveListWhileLoading: true
            )
        }
    }

    func rejectAIAttributeTag(displayEventId: Int, tag: EventAttributeTag) {
        removeAttributeTag(displayEventId: displayEventId, tag: tag)
    }

    /// Removes any event tag (AI or user). If `similar_event_tags` has rows for that
    /// category/value, offers alternatives; otherwise removal is done.
    func removeAttributeTag(displayEventId: Int, tag: EventAttributeTag) {
        for eventId in tag.actionEventIds(displayEventId: displayEventId) {
            database.removeEventAttributeTag(eventId: eventId, tag: tag)
        }
        refreshEvent(eventId: displayEventId)
        presentSimilarEventAlternativesIfNeeded(displayEventId: displayEventId, removedTag: tag)

        Task {
            await refreshHomeCategoryCounts()
            await refreshHolidayLandingItems()
        }
    }

    private func presentSimilarEventAlternativesIfNeeded(
        displayEventId: Int,
        removedTag: EventAttributeTag
    ) {
        let alternatives = database.fetchSimilarEventAlternatives(
            tagCategory: removedTag.category.tagCategory,
            tagValue: removedTag.tagValue
        )
        guard !alternatives.isEmpty else { return }
        guard let event = database.getEvent(eventId: displayEventId)
            ?? events.first(where: { $0.eventId == displayEventId }) else {
            return
        }
        pendingSimilarEventAlternatives = SimilarEventAlternativesRequest(
            displayEventId: displayEventId,
            event: event,
            rejectedTag: removedTag,
            alternatives: alternatives
        )
    }

    func applySimilarEventAlternative(
        displayEventId: Int,
        alternative: SimilarEventTagAlternative
    ) {
        pendingSimilarEventAlternatives = nil

        // Write exactly possibleTagCategory + possibleTagValue from similar_event_tags.
        database.applySimilarEventUserTag(
            eventId: displayEventId,
            tagCategory: alternative.possibleTagCategory,
            tagValue: alternative.possibleTagValue
        )

        let peopleNeeded = max(0, alternative.possibleNumberOfEventMainPeople)
        guard peopleNeeded > 0,
              let event = database.getEvent(eventId: displayEventId)
                ?? events.first(where: { $0.eventId == displayEventId }) else {
            refreshEvent(eventId: displayEventId)
            return
        }

        // 1 → Senior/Junior Prom, Christening, Confirmation; 2 → Engagement Party.
        let people = EventMilestonePersonPickerOrdering.items(
            eventPeople: database.fetchEventPeople(
                eventId: event.eventId,
                includeChildEvents: true
            ),
            allPeople: database.fetchAllPeople()
        )
        pendingSimilarEventPeoplePick = SimilarEventPeoplePickRequest(
            displayEventId: displayEventId,
            event: event,
            alternative: alternative,
            people: people
        )
        refreshEvent(eventId: displayEventId)
    }

    func completeSimilarEventPeoplePick(
        displayEventId: Int,
        person1: MilestonePersonPickerItem,
        person2: MilestonePersonPickerItem?
    ) {
        let tagValue = pendingSimilarEventPeoplePick?.alternative.possibleTagValue
        pendingSimilarEventPeoplePick = nil
        var names = [person1.name]
        if let person2 {
            names.append(person2.name)
        }
        database.replaceUserEventMainPeople(eventId: displayEventId, names: names)

        if let tagValue,
           let event = database.getEvent(eventId: displayEventId),
           !event.userEditedName,
           let template = database.fetchEventNameTemplate(
               tagCategory: EventAttributeField.milestoneType.tagCategory,
               tagValue: tagValue
           ),
           let suggested = MilestoneEventNaming.suggestTemplatedEventName(
               nameTemplate: template,
               person1: person1.name,
               person2: person2?.name
           ) {
            _ = database.updateEventName(
                eventId: displayEventId,
                name: suggested,
                userEdited: false
            )
        }

        refreshEvent(eventId: displayEventId)
        Task {
            await reloadEventsAsync(
                filter: activeEventListFilter,
                loadSlideshowIds: false,
                preserveListWhileLoading: true
            )
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
        onFrameEventIdsCache?.remove(eventId)
        // Filter in memory — avoid getSlideshowPhotoIds / game-result re-query on MainActor.
        eventSections = eventSections.compactMap { section in
            let items = section.items.filter { $0.event.eventId != eventId }
            guard !items.isEmpty else { return nil }
            return EventYearSection(
                year: section.year,
                items: items,
                presentation: section.presentation,
                headerTitle: section.headerTitle
            )
        }
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
        let eventIds = events.map(\.eventId)
        let onFrameEventIds = onFrameEventIdsCache ?? onFrameIdsFromCurrentSections()
        let gameResults = database.fetchEventGameResults(eventIds: eventIds)
        eventSections = Self.buildEventSections(
            from: events,
            slideshowIdsByEvent: mergedSlideshowIds(
                preserved: preservedSlideshowIds,
                fromDatabase: fromDatabase
            ),
            onFrameEventIds: onFrameEventIds,
            gameResultsByEventId: gameResults,
            listFilter: activeEventListFilter
        )
    }

    private func onFrameIdsFromCurrentSections() -> Set<Int> {
        var ids = Set<Int>()
        for section in eventSections {
            for item in section.items where item.hasOnFramePhotos {
                ids.insert(item.event.eventId)
            }
        }
        return ids
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
                    return item.withSlideshowPhotoIds(ids)
                },
                presentation: section.presentation,
                headerTitle: section.headerTitle
            )
        }
    }

}
