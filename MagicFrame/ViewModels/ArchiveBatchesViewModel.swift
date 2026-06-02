import Foundation
import Combine

@MainActor
final class ArchiveBatchesViewModel: ObservableObject {

    @Published var batches: [PhotoUploadBatch] = []
    @Published var locations: [ManagedLocation] = []
    @Published var statusText: String = ""

    private let libraryViewModel: LibraryViewModel

    init(libraryViewModel: LibraryViewModel) {
        self.libraryViewModel = libraryViewModel
    }

    func load() {
        batches = PhotoDatabase.shared.getLikelyUploadBatches()
        locations = PhotoDatabase.shared.getLocationsRankedByEventCount()
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

        PhotoDatabase.shared.applyArchiveBatchMetadata(
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
