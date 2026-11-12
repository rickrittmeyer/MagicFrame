import Foundation
import Photos
import SwiftUI

@MainActor
final class PictureBrowserViewModel: ObservableObject {

    @Published private(set) var items: [PictureBrowserPhotoRecord] = []
    @Published var isSelecting = false
    @Published private(set) var selectedPhotoIds: Set<String> = []
    @Published var showHiddenPhotos = false
    @Published var sort: PictureBrowserSort = .dateTaken
    @Published var filter: PictureBrowserFilter = .allItems
    @Published private(set) var isLoading = false
    @Published var statusMessage: String?
    /// Bumps when the underlying photo set changes so the grid can reload without joining every id.
    @Published private(set) var contentRevision: Int = 0
    /// Year chips available for jump-to navigation.
    @Published private(set) var availableYears: [Int] = []
    /// Last year chip selected (highlight only; list still shows every year).
    @Published var focusedYear: Int?
    /// When set, the browser scrolls to the first month of this year, then clears it.
    @Published var pendingScrollYear: Int?
    /// True while the rest of the library loads after the first year is on screen.
    @Published private(set) var isLoadingFullLibrary = false
    /// Library-wide counts for the All Media header (stable while years swap).
    @Published private(set) var libraryMediaCounts: (pictures: Int, videos: Int)?

    private let photoIds: [String]
    private let confidenceByPhotoId: [String: Double]
    private let loadsAllPhotos: Bool
    private let enablesYearNavigation: Bool
    private let database: any MagicFrameDatabase
    private var indexedAtByPhotoId: [String: String] = [:]
    private var fullLibraryLoadTask: Task<Void, Never>?
    /// Cached full library after background load (so year chips swap without re-querying).
    private var allLibraryRecords: [PictureBrowserPhotoRecord]?
    private var allLibraryIndexedAt: [String: String] = [:]

    /// Landing pages: skip full-set Vision refine on open (metadata stacks only).
    var defersFullLibraryVisualRefine: Bool { enablesYearNavigation }

    var usesYearNavigation: Bool { enablesYearNavigation }

    init(
        photoIds: [String] = [],
        confidenceByPhotoId: [String: Double] = [:],
        loadsAllPhotos: Bool = false,
        enablesYearNavigation: Bool = false,
        database: any MagicFrameDatabase = AppDependencies.database
    ) {
        self.photoIds = photoIds
        self.confidenceByPhotoId = confidenceByPhotoId
        self.loadsAllPhotos = loadsAllPhotos
        self.enablesYearNavigation = enablesYearNavigation || loadsAllPhotos
        self.database = database
    }

    func indexedAt(for photoId: String) -> String {
        indexedAtByPhotoId[photoId] ?? ""
    }

    var selectedCount: Int { selectedPhotoIds.count }

    var visiblePhotos: [IndexedPhoto] {
        visibleItems.map(\.photo)
    }

    /// Pictures and videos in the list after the current filter.
    var visibleMediaCounts: (pictures: Int, videos: Int) {
        if loadsAllPhotos, let libraryMediaCounts, filter == .allItems, !showHiddenPhotos {
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

        if loadsAllPhotos, allLibraryRecords == nil {
            let hasYear = items.contains { yearValue(for: $0) == year }
            if !hasYear {
                Task {
                    await loadFocusedYearIfNeeded(year)
                    guard !Task.isCancelled else { return }
                    pendingScrollYear = year
                }
                return
            }
        }

        pendingScrollYear = year
    }

    func acknowledgePendingScrollYear() {
        pendingScrollYear = nil
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
            availableYears = fetchYears(from: items, indexedAt: indexedAtByPhotoId)
            focusedYear = availableYears.first
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

        availableYears = bootstrap.0
        focusedYear = bootstrap.2
        // Approximate until full library / media-type breakdown is known.
        libraryMediaCounts = (bootstrap.1, 0)
        applyLoadedRows(bootstrap.3, confidences: [:])
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
            availableYears = fetchYears(from: records, indexedAt: indexed)
            if focusedYear == nil {
                focusedYear = availableYears.first
            } else if let focusedYear, !availableYears.contains(focusedYear) {
                self.focusedYear = availableYears.first
            }
            libraryMediaCounts = (pictures, videos)
            applyRecords(records, indexedAt: indexed, bumpRevision: true)
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
    }

    func cancelSelection() {
        isSelecting = false
        selectedPhotoIds.removeAll()
    }

    func toggleSelection(photoId: String) {
        if selectedPhotoIds.contains(photoId) {
            selectedPhotoIds.remove(photoId)
        } else {
            selectedPhotoIds.insert(photoId)
        }
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

        database.setPhotosHiddenInEvent(photoIds: ids, hidden: hidden)
        applyLocal {
            $0.withHiddenInEvent(hidden)
        }
        cancelSelection()
        statusMessage = hidden
            ? "Hid \(ids.count) photo\(ids.count == 1 ? "" : "s")"
            : "Unhid \(ids.count) photo\(ids.count == 1 ? "" : "s")"
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
        database.setPhotosHiddenInEvent(photoIds: [photoId], hidden: hidden)
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
