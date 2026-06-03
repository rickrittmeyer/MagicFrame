import Foundation
import Combine

@MainActor
final class ArchiveBatchesViewModel: ObservableObject {

    @Published var batches: [PhotoUploadBatch] = []
    @Published var locations: [ManagedLocation] = []
    @Published var statusText: String = ""

    private let libraryViewModel: LibraryViewModel
    private let database: any MagicFrameDatabase

    init(libraryViewModel: LibraryViewModel) {
        self.libraryViewModel = libraryViewModel
        self.database = libraryViewModel.database
    }

    func load() {
        batches = database.getLikelyUploadBatches(
            gapSeconds: 6 * 60 * 60,
            minPhotos: 1
        )
        locations = database.getLocationsRankedByEventCount()
            .filter { $0.latitude != nil && $0.longitude != nil }

        let photoCount = batches.reduce(0) { $0 + $1.photoCount }
        if batches.isEmpty {
            statusText = "No import batches found"
        } else {
            statusText = "\(batches.count) batches · \(photoCount) photos without location"
        }
    }

    func applyMetadata(
        to batch: PhotoUploadBatch,
        captureDate: Date,
        location: ManagedLocation
    ) {
        guard let latitude = location.latitude,
              let longitude = location.longitude else {
            return
        }

        database.applyArchiveBatchMetadata(
            photoIds: batch.photoIds,
            captureDate: captureDate,
            latitude: latitude,
            longitude: longitude
        )

        libraryViewModel.scheduleEventSyncIfNeeded()
        libraryViewModel.refreshArchivePhotoCount()
        load()
        statusText = "Updated \(batch.photoCount) photos — syncing events…"
    }
}
