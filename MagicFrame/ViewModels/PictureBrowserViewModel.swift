import CoreLocation
import Foundation
import Photos
import SwiftUI

@MainActor
final class PictureBrowserViewModel: ObservableObject {

    @Published private(set) var items: [PictureBrowserPhotoRecord] = []
    @Published var isSelecting = false
    @Published private(set) var selectedPhotoIds: Set<String> = []
    @Published private(set) var selectedPhotoIdOrder: [String] = []
    @Published private(set) var isAdjustingDates = false
    @Published private(set) var isAdjustingLocations = false
    @Published var showHiddenPhotos = false
    @Published var sort: PictureBrowserSort = .dateTaken
    @Published var filter: PictureBrowserFilter = .allItems
    @Published private(set) var isLoading = false
    @Published var statusMessage: String?
    /// Bumps when the underlying photo set changes so the grid can reload without joining every id.
    @Published private(set) var contentRevision: Int = 0
    /// Year chips available for jump-to navigation.
    /// Full library years, or only years present in the active media-search results.
    @Published private(set) var availableYears: [Int] = []
    /// Last year chip selected. Highlight follows the visible month while scrolling.
    @Published var focusedYear: Int?
    /// When set, the browser scrolls to the first month of this year, then clears it.
    @Published var pendingScrollYear: Int?
    /// When set, the browser scrolls to this exact month section id (`yyyy-MM`), then clears it.
    @Published var pendingScrollMonthSectionId: String?
    /// True while the rest of the library loads after the first year is on screen.
    @Published private(set) var isLoadingFullLibrary = false
    /// Library-wide counts for the All Media header (stable while years swap).
    @Published private(set) var libraryMediaCounts: (pictures: Int, videos: Int)?
    /// Active All Media ad-hoc search (nil = show full library).
    @Published private(set) var activeMediaSearchQuery: MediaSearchQuery?
    @Published private(set) var mediaSearchMatchedPhotoIds: Set<String> = []
    @Published private(set) var mediaSearchMatchCount: Int = 0

    private let photoIds: [String]
    private let confidenceByPhotoId: [String: Double]
    private let loadsAllPhotos: Bool
    private let enablesYearNavigation: Bool
    /// Photos↔Events pair this browser belongs to (for shared month memory).
    let browseMonthScope: BrowseMonthScope?

    var supportsMediaSearch: Bool { loadsAllPhotos }
    private let database: any MagicFrameDatabase
    private var indexedAtByPhotoId: [String: String] = [:]
    private var fullLibraryLoadTask: Task<Void, Never>?
    /// Cached full library after background load (so year chips swap without re-querying).
    private var allLibraryRecords: [PictureBrowserPhotoRecord]?
    private var allLibraryIndexedAt: [String: String] = [:]
    /// Capture years for the unfiltered library. Restored when a media search is cleared
    /// before the full library has finished loading.
    private var libraryYears: [Int] = []
    private var didApplyRestoredMonthAnchor = false

    /// Landing pages: skip full-set Vision refine on open (metadata stacks only).
    var defersFullLibraryVisualRefine: Bool { enablesYearNavigation }

    var usesYearNavigation: Bool { enablesYearNavigation }

    init(
        photoIds: [String] = [],
        confidenceByPhotoId: [String: Double] = [:],
        loadsAllPhotos: Bool = false,
        enablesYearNavigation: Bool = false,
        browseMonthScope: BrowseMonthScope? = nil,
        database: any MagicFrameDatabase = AppDependencies.database
    ) {
        self.photoIds = photoIds
        self.confidenceByPhotoId = confidenceByPhotoId
        self.loadsAllPhotos = loadsAllPhotos
        self.enablesYearNavigation = enablesYearNavigation || loadsAllPhotos
        self.browseMonthScope = browseMonthScope
        self.database = database
    }

    func indexedAt(for photoId: String) -> String {
        indexedAtByPhotoId[photoId] ?? ""
    }

    var selectedCount: Int { selectedPhotoIds.count }

    var visiblePhotos: [IndexedPhoto] {
        visibleItems.map(\.photo)
    }

    private var selectedPhotoRecords: [PictureBrowserPhotoRecord] {
        items.filter { selectedPhotoIds.contains($0.id) }
    }

    /// True when every selected photo already has the trait (filled icon / tap clears).
    var selectedAllOnFrame: Bool {
        let selected = selectedPhotoRecords
        return !selected.isEmpty && selected.allSatisfy(\.photo.showOnFrame)
    }

    var selectedAllFavorite: Bool {
        let selected = selectedPhotoRecords
        return !selected.isEmpty && selected.allSatisfy(\.photo.isFavorite)
    }

    var selectedAllHidden: Bool {
        let selected = selectedPhotoRecords
        return !selected.isEmpty && selected.allSatisfy(\.photo.isHiddenInEvent)
    }

    func toggleSelectedOnFrame() {
        setSelectedOnFrame(!selectedAllOnFrame)
    }

    func toggleSelectedFavorite() {
        setSelectedFavorite(!selectedAllFavorite)
    }

    func toggleSelectedHidden() {
        setSelectedHidden(!selectedAllHidden)
    }

    /// Pictures and videos in the list after the current filter.
    var visibleMediaCounts: (pictures: Int, videos: Int) {
        if loadsAllPhotos,
           let libraryMediaCounts,
           filter == .allItems,
           !showHiddenPhotos,
           activeMediaSearchQuery == nil {
            return libraryMediaCounts
        }
        var pictures = 0
        var videos = 0
        let source = allLibraryRecords ?? items
        for record in source where matchesVisibleList(record) {
            if record.isVideo {
                videos += 1
            } else {
                pictures += 1
            }
        }
        return (pictures, videos)
    }

    var visibleItems: [PictureBrowserPhotoRecord] {
        var result = items.filter(matchesVisibleList)

        switch sort {
        case .dateTaken:
            result.sort {
                if $0.photo.creationDate != $1.photo.creationDate {
                    return $0.photo.creationDate > $1.photo.creationDate
                }
                return $0.photo.id > $1.photo.id
            }
        case .dateImported:
            result.sort {
                let left = indexedAtByPhotoId[$0.id] ?? ""
                let right = indexedAtByPhotoId[$1.id] ?? ""
                if left != right {
                    return left > right
                }
                return $0.photo.id > $1.photo.id
            }
        case .confidence:
            result.sort {
                let left = $0.matchConfidence ?? -1
                let right = $1.matchConfidence ?? -1
                if left != right {
                    return left > right
                }
                if $0.photo.creationDate != $1.photo.creationDate {
                    return $0.photo.creationDate > $1.photo.creationDate
                }
                return $0.photo.id > $1.photo.id
            }
        }

        return result
    }

    private func yearValue(for record: PictureBrowserPhotoRecord) -> Int? {
        let raw: String
        switch sort {
        case .dateTaken, .confidence:
            raw = record.photo.creationDate
        case .dateImported:
            raw = indexedAtByPhotoId[record.id] ?? ""
        }
        guard raw.count >= 4, let year = Int(raw.prefix(4)), year >= 1000 else {
            return nil
        }
        return year
    }

    private func matchesVisibleList(_ record: PictureBrowserPhotoRecord) -> Bool {
        if !showHiddenPhotos, record.photo.isHiddenInEvent {
            return false
        }

        if activeMediaSearchQuery != nil,
           !mediaSearchMatchedPhotoIds.isEmpty,
           !mediaSearchMatchedPhotoIds.contains(record.id) {
            return false
        }

        // Active search with zero matches: show empty grid.
        if activeMediaSearchQuery != nil, mediaSearchMatchedPhotoIds.isEmpty {
            return false
        }

        switch filter {
        case .allItems:
            return true
        case .onFrame:
            return record.photo.showOnFrame
        case .offFrame:
            return !record.photo.showOnFrame
        case .favorites:
            return record.photo.isFavorite
        case .photos:
            return record.isImage
        case .video:
            return record.isVideo
        }
    }

    func applyMediaSearch(query: MediaSearchQuery, report: MediaPhotoSearchReport) {
        guard supportsMediaSearch else { return }
        activeMediaSearchQuery = query
        mediaSearchMatchedPhotoIds = Set(report.photoIds)
        mediaSearchMatchCount = report.matchCount
        refreshVisibleYears(preferNewest: true)
        contentRevision &+= 1
    }

    func clearMediaSearch() {
        guard activeMediaSearchQuery != nil || !mediaSearchMatchedPhotoIds.isEmpty else { return }
        activeMediaSearchQuery = nil
        mediaSearchMatchedPhotoIds = []
        mediaSearchMatchCount = 0
        refreshVisibleYears(preferNewest: true)
        contentRevision &+= 1
    }

    /// Year chips follow the photos currently on screen. During a media search that is the
    /// matched set already loaded, so chips for empty years are not offered.
    /// `preferNewest` selects the latest year, matching a date-sorted grid that opens at the top.
    func refreshVisibleYears(preferNewest: Bool = false) {
        guard enablesYearNavigation else { return }
        let years: [Int]
        if activeMediaSearchQuery != nil {
            years = fetchYears(
                from: items.filter(matchesVisibleList),
                indexedAt: indexedAtByPhotoId
            )
        } else if loadsAllPhotos, !libraryYears.isEmpty {
            years = libraryYears
        } else {
            years = fetchYears(from: items, indexedAt: indexedAtByPhotoId)
        }
        availableYears = years
        if !preferNewest, let focusedYear, years.contains(focusedYear) {
            return
        }
        focusedYear = years.first
    }

    func visibleItemsContain(year: Int) -> Bool {
        items.contains { yearValue(for: $0) == year && matchesVisibleList($0) }
    }

    func load() async {
        fullLibraryLoadTask?.cancel()
        if loadsAllPhotos {
            await loadAllMediaStaged()
        } else {
            await loadPhotoIdSet()
        }
    }

    /// Highlights `year` and asks the view to scroll to its first month section.
    /// If All Media has not finished loading, merges that year into the grid first.
    func jumpToYear(_ year: Int) {
        guard enablesYearNavigation else { return }
        focusedYear = year
        pendingScrollMonthSectionId = nil

        if loadsAllPhotos, allLibraryRecords == nil, !visibleItemsContain(year: year) {
            Task {
                if activeMediaSearchQuery != nil {
                    await loadMatchedYearIfNeeded(year)
                } else {
                    await loadFocusedYearIfNeeded(year)
                }
                guard !Task.isCancelled else { return }
                pendingScrollYear = year
            }
            return
        }

        pendingScrollYear = year
    }

    /// Scrolls to an exact month section (`yyyy-MM`), loading that year first when needed.
    func jumpToMonth(sectionId: String) {
        guard enablesYearNavigation else { return }
        guard let anchor = BrowseMonthAnchor.from(photoSectionId: sectionId) else {
            return
        }
        focusedYear = anchor.year
        pendingScrollYear = nil

        if loadsAllPhotos, allLibraryRecords == nil, !visibleItemsContain(year: anchor.year) {
            Task {
                if activeMediaSearchQuery != nil {
                    await loadMatchedYearIfNeeded(anchor.year)
                } else {
                    await loadFocusedYearIfNeeded(anchor.year)
                }
                guard !Task.isCancelled else { return }
                pendingScrollMonthSectionId = sectionId
            }
            return
        }

        pendingScrollMonthSectionId = sectionId
    }

    func acknowledgePendingScrollYear() {
        pendingScrollYear = nil
    }

    func acknowledgePendingScrollMonth() {
        pendingScrollMonthSectionId = nil
    }

    func rememberVisibleMonth(sectionId: String, libraryVM: LibraryViewModel) {
        guard let scope = browseMonthScope else { return }
        libraryVM.rememberBrowseMonth(photoSectionId: sectionId, scope: scope)
    }

    /// Apply remembered month once after initial load (All Media or topic browsers).
    func applyRestoredMonthAnchorIfNeeded(libraryVM: LibraryViewModel) {
        guard enablesYearNavigation, !didApplyRestoredMonthAnchor else { return }
        guard let scope = browseMonthScope,
              let anchor = libraryVM.browseMonthAnchor(for: scope) else {
            return
        }
        didApplyRestoredMonthAnchor = true
        jumpToMonth(sectionId: anchor.photoSectionId)
    }

    private func loadPhotoIdSet() async {
        isLoading = true
        defer { isLoading = false }

        let ids = photoIds
        let confidences = confidenceByPhotoId
        let loaded = await Task.detached(priority: .utility) { [database] in
            database.fetchPhotosForBrowser(photoIds: ids).map {
                (photo: $0.photo, mediaType: $0.mediaType, indexedAt: "")
            }
        }.value

        applyLoadedRows(loaded, confidences: confidences)
        if enablesYearNavigation {
            refreshVisibleYears()
            contentRevision += 1
        }
    }

    private func loadAllMediaStaged() async {
        isLoading = true
        libraryMediaCounts = nil

        let bootstrap = await Task.detached(priority: .userInitiated) { [database] in
            let years = database.fetchDistinctPhotoYearsForBrowser()
            let total = database.countActivePhotosForBrowser()
            let firstYear = years.first
            let yearRows: [(photo: IndexedPhoto, mediaType: Int, indexedAt: String)]
            if let firstYear {
                yearRows = database.fetchPhotosForBrowserYear(firstYear)
            } else {
                yearRows = []
            }
            return (years, total, firstYear, yearRows)
        }.value

        libraryYears = bootstrap.0
        focusedYear = bootstrap.2
        // Approximate until full library / media-type breakdown is known.
        libraryMediaCounts = (bootstrap.1, 0)
        applyLoadedRows(bootstrap.3, confidences: [:])
        refreshVisibleYears()
        isLoading = false

        fullLibraryLoadTask = Task(priority: .utility) { [weak self] in
            await self?.loadRemainingAllMediaLibrary()
        }
    }

    private func loadFocusedYearIfNeeded(_ year: Int) async {
        guard allLibraryRecords == nil else { return }
        isLoading = true
        let loaded = await Task.detached(priority: .userInitiated) { [database] in
            database.fetchPhotosForBrowserYear(year)
        }.value
        guard !Task.isCancelled else { return }
        // Merge into items if we already have other years loaded locally.
        let confidences = confidenceByPhotoId
        var byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var indexed = indexedAtByPhotoId
        for row in loaded {
            byId[row.photo.id] = PictureBrowserPhotoRecord(
                photo: row.photo,
                mediaType: row.mediaType,
                matchConfidence: confidences[row.photo.id]
            )
            indexed[row.photo.id] = row.indexedAt
        }
        applyRecords(Array(byId.values), indexedAt: indexed, bumpRevision: true)
        refreshVisibleYears()
        isLoading = false
    }

    /// During a media search, load only matched photos in `year` instead of the whole year.
    private func loadMatchedYearIfNeeded(_ year: Int) async {
        guard activeMediaSearchQuery != nil, allLibraryRecords == nil else { return }
        let loadedIds = Set(items.map(\.id))
        let missing = Array(mediaSearchMatchedPhotoIds.subtracting(loadedIds))
        guard !missing.isEmpty else { return }

        isLoading = true
        let useImportDate = sort == .dateImported
        let loaded = await Task.detached(priority: .userInitiated) { [database] in
            database.fetchPhotosForBrowser(
                photoIds: missing,
                year: year,
                useImportDate: useImportDate
            )
        }.value
        guard !Task.isCancelled, allLibraryRecords == nil else {
            isLoading = false
            return
        }

        let confidences = confidenceByPhotoId
        var byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var indexed = indexedAtByPhotoId
        for row in loaded {
            byId[row.photo.id] = PictureBrowserPhotoRecord(
                photo: row.photo,
                mediaType: row.mediaType,
                matchConfidence: confidences[row.photo.id]
            )
            indexed[row.photo.id] = row.indexedAt
        }
        applyRecords(Array(byId.values), indexedAt: indexed, bumpRevision: true)
        refreshVisibleYears()
        isLoading = false
    }

    private func loadRemainingAllMediaLibrary() async {
        await MainActor.run { isLoadingFullLibrary = true }
        let loaded = await Task.detached(priority: .utility) { [database] in
            database.fetchAllPhotosForBrowser()
        }.value
        guard !Task.isCancelled else { return }

        let records = loaded.map { row in
            PictureBrowserPhotoRecord(
                photo: row.photo,
                mediaType: row.mediaType,
                matchConfidence: nil
            )
        }
        let indexed = Dictionary(uniqueKeysWithValues: loaded.map { ($0.photo.id, $0.indexedAt) })
        var pictures = 0
        var videos = 0
        for record in records {
            if record.isVideo { videos += 1 } else { pictures += 1 }
        }

        await MainActor.run {
            allLibraryRecords = records
            allLibraryIndexedAt = indexed
            libraryYears = fetchYears(from: records, indexedAt: indexed)
            libraryMediaCounts = (pictures, videos)
            applyRecords(records, indexedAt: indexed, bumpRevision: true)
            refreshVisibleYears()
            isLoadingFullLibrary = false
        }
    }

    private func applyLoadedRows(
        _ loaded: [(photo: IndexedPhoto, mediaType: Int, indexedAt: String)],
        confidences: [String: Double]
    ) {
        let records = loaded.map { row in
            PictureBrowserPhotoRecord(
                photo: row.photo,
                mediaType: row.mediaType,
                matchConfidence: confidences[row.photo.id]
            )
        }
        let indexed = Dictionary(uniqueKeysWithValues: loaded.map { ($0.photo.id, $0.indexedAt) })
        applyRecords(records, indexedAt: indexed, bumpRevision: true)
    }

    private func applyRecords(
        _ records: [PictureBrowserPhotoRecord],
        indexedAt: [String: String],
        bumpRevision: Bool
    ) {
        indexedAtByPhotoId = indexedAt
        items = records
        selectedPhotoIds = selectedPhotoIds.intersection(Set(records.map(\.id)))
        selectedPhotoIdOrder = selectedPhotoIdOrder.filter { selectedPhotoIds.contains($0) }
        if bumpRevision {
            contentRevision += 1
        }
    }

    private func fetchYears(
        from records: [PictureBrowserPhotoRecord],
        indexedAt: [String: String]
    ) -> [Int] {
        var years: [Int] = []
        var seen = Set<Int>()
        for record in records {
            let raw: String
            switch sort {
            case .dateTaken, .confidence:
                raw = record.photo.creationDate
            case .dateImported:
                raw = indexedAt[record.id] ?? ""
            }
            guard raw.count >= 4, let year = Int(raw.prefix(4)), year >= 1000 else { continue }
            if seen.insert(year).inserted {
                years.append(year)
            }
        }
        return years.sorted(by: >)
    }

    func beginSelection() {
        isSelecting = true
        selectedPhotoIds.removeAll()
        selectedPhotoIdOrder.removeAll()
    }

    func cancelSelection() {
        isSelecting = false
        selectedPhotoIds.removeAll()
        selectedPhotoIdOrder.removeAll()
    }

    func toggleSelection(photoId: String) {
        if selectedPhotoIds.contains(photoId) {
            selectedPhotoIds.remove(photoId)
            selectedPhotoIdOrder.removeAll { $0 == photoId }
        } else {
            selectedPhotoIds.insert(photoId)
            selectedPhotoIdOrder.append(photoId)
        }
    }

    var adjustDateAnchorDate: Date? {
        guard let anchorId = selectedPhotoIdOrder.first,
              let record = items.first(where: { $0.id == anchorId })
                ?? selectedPhotoRecords.first,
              let date = EventDateParser.parseDate(record.photo.creationDate) else {
            return nil
        }
        return date
    }

    /// Shared source event when every selected photo maps to the same event id.
    func sharedEventIdForSelection() -> Int? {
        let ids = selectedPhotoIdOrder.isEmpty ? Array(selectedPhotoIds) : selectedPhotoIdOrder
        guard !ids.isEmpty else { return nil }
        var shared: Int?
        for photoId in ids {
            guard let eventId = database.getEventIdForPhoto(photoId: photoId) else {
                return nil
            }
            if let shared, shared != eventId {
                return nil
            }
            shared = eventId
        }
        return shared
    }

    func makeDateAdjustPreview(adjustedAnchor: Date) -> PhotoDateAdjustPreview? {
        guard let originalAnchor = adjustDateAnchorDate else { return nil }
        let delta = adjustedAnchor.timeIntervalSince(originalAnchor)
        let orderedIds = selectedPhotoIdOrder.isEmpty
            ? Array(selectedPhotoIds)
            : selectedPhotoIdOrder
        guard !orderedIds.isEmpty else { return nil }

        var updates: [(photoId: String, originalDate: Date, newDate: Date)] = []
        for photoId in orderedIds {
            guard let record = items.first(where: { $0.id == photoId }),
                  let original = EventDateParser.parseDate(record.photo.creationDate) else {
                continue
            }
            updates.append(
                (
                    photoId: photoId,
                    originalDate: original,
                    newDate: original.addingTimeInterval(delta)
                )
            )
        }
        guard !updates.isEmpty else { return nil }

        let rangeStart = updates.map(\.newDate).min() ?? adjustedAnchor
        let rangeEnd = updates.map(\.newDate).max() ?? adjustedAnchor

        var leaves = false
        if let eventId = sharedEventIdForSelection(),
           let event = database.getEvent(eventId: eventId),
           let eventStart = EventDateParser.parseDate(event.startDate),
           let eventEnd = EventDateParser.parseDate(event.endDate) {
            let start = min(eventStart, eventEnd)
            let end = max(eventStart, eventEnd)
            leaves = updates.contains { $0.newDate < start || $0.newDate > end }
        }

        return PhotoDateAdjustPreview(
            updates: updates,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            leavesCurrentEvent: leaves
        )
    }

    func candidateEventsForDateAdjust(
        preview: PhotoDateAdjustPreview,
        excludingEventId: Int?
    ) -> [IndexedEvent] {
        database.findEventsContainingDateRange(
            rangeStart: preview.rangeStart,
            rangeEnd: preview.rangeEnd,
            excludingEventId: excludingEventId
        )
    }

    @discardableResult
    func commitDateAdjust(
        preview: PhotoDateAdjustPreview,
        destination: PhotoDateAdjustDestination?
    ) async -> PhotoDateAdjustResult {
        isAdjustingDates = true
        defer { isAdjustingDates = false }
        await Task.yield()

        let photoIds = preview.photoIds
        // Update MagicFrame immediately; Photos library write can take minutes on iCloud.
        database.shiftPhotoCaptureDates(
            updates: preview.updates.map { ($0.photoId, $0.newDate) }
        )

        let iso8601 = ISO8601DateFormatter()
        applyLocal(photoIds: photoIds) { photo in
            guard let update = preview.updates.first(where: { $0.photoId == photo.id }) else {
                return photo
            }
            return photo.withCreationDate(iso8601.string(from: update.newDate))
        }

        let sourceEventId = sharedEventIdForSelection()

        guard preview.leavesCurrentEvent, let sourceEventId else {
            cancelSelection()
            statusMessage = "Updated date for \(photoIds.count) photo\(photoIds.count == 1 ? "" : "s")"
            return PhotoDateAdjustResult(
                kind: .datesOnly,
                updatedCount: photoIds.count,
                errorMessage: nil
            )
        }

        guard let destination else {
            cancelSelection()
            return PhotoDateAdjustResult(
                kind: .datesOnly,
                updatedCount: photoIds.count,
                errorMessage: "Choose where to move these photos."
            )
        }

        let selected = selectedPhotoRecords.map(\.photo)
        let locationId = selected.compactMap(\.locationId).first
        let latitude = selected.compactMap(\.latitude).first
        let longitude = selected.compactMap(\.longitude).first
        let sourceEvent = database.getEvent(eventId: sourceEventId)

        let destinationEvent: IndexedEvent?
        switch destination {
        case .createNew:
            destinationEvent = database.createEventForShiftedPhotos(
                photoIds: photoIds,
                fromEventId: sourceEventId,
                rangeStart: preview.rangeStart,
                rangeEnd: preview.rangeEnd,
                locationId: locationId ?? sourceEvent?.locationId,
                latitude: latitude ?? sourceEvent?.latitude,
                longitude: longitude ?? sourceEvent?.longitude
            )
        case let .existing(eventId):
            database.movePhotosToEvent(
                photoIds: photoIds,
                fromEventId: sourceEventId,
                toEventId: eventId,
                photoDates: preview.photoDates
            )
            destinationEvent = database.getEvent(eventId: eventId)
        }

        cancelSelection()

        guard let destinationEvent else {
            statusMessage = "Could not move photos to another event."
            return PhotoDateAdjustResult(
                kind: .datesOnly,
                updatedCount: photoIds.count,
                errorMessage: statusMessage
            )
        }

        let sourceGone = database.getEvent(eventId: sourceEventId) == nil
        statusMessage = "Moved to \(PhotoDateAdjustResult.eventSummaryLine(for: destinationEvent))"
        return PhotoDateAdjustResult(
            kind: .movedToEvent(destinationEvent, sourceEmptied: sourceGone),
            updatedCount: photoIds.count,
            errorMessage: nil
        )
    }

    /// Writes adjusted dates to Apple Photos, then promotes overrides into library `creationDate`.
    func syncAdjustedDatesToApplePhotos(
        _ updates: [(photoId: String, newDate: Date)]
    ) async -> String? {
        let error = await PhotosAssetMetadataWriter.updateCreationDates(
            updates.map { ($0.photoId, $0.newDate) }
        )
        guard error == nil else { return error }
        database.promoteCaptureDatesAfterPhotosSync(
            updates: updates.map { ($0.photoId, $0.newDate) }
        )
        return nil
    }

    private var locationAdjustAnchorPhoto: IndexedPhoto? {
        guard let anchorId = selectedPhotoIdOrder.first else {
            return selectedPhotoRecords.first?.photo
        }
        return items.first(where: { $0.id == anchorId })?.photo
            ?? selectedPhotoRecords.first?.photo
    }

    var adjustLocationAnchorCoordinate: (latitude: Double, longitude: Double)? {
        guard let photo = locationAdjustAnchorPhoto,
              let latitude = photo.latitude,
              let longitude = photo.longitude else {
            return nil
        }
        return (latitude, longitude)
    }

    var adjustLocationAnchorLabel: String {
        guard let photo = locationAdjustAnchorPhoto else {
            return PhotoPreviewLocationFormatting.noGPSData
        }
        if let locationId = photo.locationId,
           let location = database.getLocation(locationId: locationId) {
            return location.displayTitle
        }
        return PhotoPreviewLocationFormatting.line(
            nickname: nil,
            placeName: nil,
            city: nil,
            state: nil,
            latitude: photo.latitude,
            longitude: photo.longitude
        )
    }

    func locationsForAdjust() -> [ManagedLocation] {
        database.getLocationsRankedByEventCount()
            .filter { $0.latitude != nil && $0.longitude != nil }
    }

    func makeLocationAdjustPreview(location: ManagedLocation) -> PhotoLocationAdjustPreview? {
        guard let latitude = location.latitude,
              let longitude = location.longitude else {
            return nil
        }
        let orderedIds = selectedPhotoIdOrder.isEmpty
            ? Array(selectedPhotoIds)
            : selectedPhotoIdOrder
        guard !orderedIds.isEmpty else { return nil }
        return PhotoLocationAdjustPreview(
            photoIds: orderedIds,
            latitude: latitude,
            longitude: longitude,
            locationId: location.locationId,
            locationLabel: location.displayTitle
        )
    }

    @discardableResult
    func commitLocationAdjust(
        preview: PhotoLocationAdjustPreview
    ) async -> PhotoLocationAdjustResult {
        isAdjustingLocations = true
        defer { isAdjustingLocations = false }
        await Task.yield()

        let photoIds = preview.photoIds
        database.shiftPhotoLocations(
            updates: photoIds.map {
                (
                    photoId: $0,
                    latitude: preview.latitude,
                    longitude: preview.longitude,
                    locationId: preview.locationId
                )
            }
        )

        applyLocal(photoIds: photoIds) { photo in
            photo.withLocation(
                latitude: preview.latitude,
                longitude: preview.longitude,
                locationId: preview.locationId
            )
        }
        cancelSelection()
        statusMessage = "Updated location for \(photoIds.count) photo\(photoIds.count == 1 ? "" : "s")"

        return PhotoLocationAdjustResult(
            updatedCount: photoIds.count,
            errorMessage: nil
        )
    }

    /// Writes adjusted locations to Apple Photos, then promotes overrides into library GPS.
    func syncAdjustedLocationsToApplePhotos(
        _ updates: [(photoId: String, latitude: Double, longitude: Double)]
    ) async -> String? {
        let error = await PhotosAssetMetadataWriter.updateLocations(
            updates.map {
                (
                    photoId: $0.photoId,
                    location: CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                )
            }
        )
        guard error == nil else { return error }
        database.promoteLocationsAfterPhotosSync(updates: updates)
        return nil
    }

    func toggleShowHiddenPhotos() {
        showHiddenPhotos.toggle()
    }

    func setSelectedOnFrame(_ show: Bool) {
        let ids = Array(selectedPhotoIds)
        guard !ids.isEmpty else { return }

        database.setPhotosShowOnFrame(photoIds: ids, show: show)
        applyLocal {
            $0.withShowOnFrame(show)
        }
        cancelSelection()
        statusMessage = show
            ? "Added \(ids.count) to frame"
            : "Removed \(ids.count) from frame"
    }

    func setSelectedHidden(_ hidden: Bool) {
        let ids = Array(selectedPhotoIds)
        guard !ids.isEmpty else { return }

        let withoutEvents = database.setPhotosHiddenInEvent(photoIds: ids, hidden: hidden)
        let updatedIds = ids.filter { !withoutEvents.contains($0) }
        if !updatedIds.isEmpty {
            applyLocal(photoIds: updatedIds) {
                $0.withHiddenInEvent(hidden)
            }
        }
        cancelSelection()
        if updatedIds.isEmpty {
            statusMessage = "Hide only works for photos in an event"
        } else if withoutEvents.isEmpty {
            statusMessage = hidden
                ? "Hid \(updatedIds.count) photo\(updatedIds.count == 1 ? "" : "s")"
                : "Unhid \(updatedIds.count) photo\(updatedIds.count == 1 ? "" : "s")"
        } else {
            statusMessage = hidden
                ? "Hid \(updatedIds.count); \(withoutEvents.count) not in an event"
                : "Unhid \(updatedIds.count); \(withoutEvents.count) not in an event"
        }
    }

    func setSelectedFavorite(_ favorite: Bool) {
        let ids = Array(selectedPhotoIds)
        guard !ids.isEmpty else { return }

        Task {
            await setFavoriteInPhotoLibrary(photoIds: ids, isFavorite: favorite)
            database.setPhotosFavorite(photoIds: ids, isFavorite: favorite)
            applyLocal {
                $0.withFavorite(favorite)
            }
            cancelSelection()
            statusMessage = favorite
                ? "Favorited \(ids.count)"
                : "Unfavorited \(ids.count)"
        }
    }

    func togglePhotoOnFrame(photoId: String) {
        guard let item = items.first(where: { $0.id == photoId }) else { return }
        let show = !item.photo.showOnFrame
        database.setPhotosShowOnFrame(photoIds: [photoId], show: show)
        applyLocal(photoIds: [photoId]) {
            $0.withShowOnFrame(show)
        }
    }

    func togglePhotoHidden(photoId: String) {
        guard let item = items.first(where: { $0.id == photoId }) else { return }
        let hidden = !item.photo.isHiddenInEvent
        let withoutEvents = database.setPhotosHiddenInEvent(photoIds: [photoId], hidden: hidden)
        guard withoutEvents.isEmpty else {
            statusMessage = "Hide only works for photos in an event"
            return
        }
        applyLocal(photoIds: [photoId]) {
            $0.withHiddenInEvent(hidden)
        }
    }

    func togglePhotoFavorite(photoId: String) {
        guard let item = items.first(where: { $0.id == photoId }) else { return }
        let favorite = !item.photo.isFavorite
        Task {
            await setFavoriteInPhotoLibrary(photoIds: [photoId], isFavorite: favorite)
            database.setPhotosFavorite(photoIds: [photoId], isFavorite: favorite)
            applyLocal(photoIds: [photoId]) {
                $0.withFavorite(favorite)
            }
        }
    }

    private func applyLocal(
        photoIds: [String]? = nil,
        transform: (IndexedPhoto) -> IndexedPhoto
    ) {
        let targetIds = Set(photoIds ?? Array(selectedPhotoIds))
        items = items.map { item in
            guard targetIds.contains(item.id) else { return item }
            return PictureBrowserPhotoRecord(
                photo: transform(item.photo),
                mediaType: item.mediaType,
                matchConfidence: item.matchConfidence
            )
        }
        if var cached = allLibraryRecords {
            cached = cached.map { item in
                guard targetIds.contains(item.id) else { return item }
                return PictureBrowserPhotoRecord(
                    photo: transform(item.photo),
                    mediaType: item.mediaType,
                    matchConfidence: item.matchConfidence
                )
            }
            allLibraryRecords = cached
        }
        // PictureBrowserView rebuilds displayItems from contentRevision.
        contentRevision += 1
    }

    private func setFavoriteInPhotoLibrary(photoIds: [String], isFavorite: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PHPhotoLibrary.shared().performChanges({
                let result = PHAsset.fetchAssets(withLocalIdentifiers: photoIds, options: nil)
                result.enumerateObjects { asset, _, _ in
                    let request = PHAssetChangeRequest(for: asset)
                    request.isFavorite = isFavorite
                }
            }, completionHandler: { _, error in
                if let error {
                    print("PictureBrowser favorite update failed: \(error.localizedDescription)")
                }
                continuation.resume()
            })
        }
    }
}
