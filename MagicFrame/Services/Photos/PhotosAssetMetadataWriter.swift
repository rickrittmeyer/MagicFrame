import CoreLocation
import Foundation
import Photos

/// Writes capture date / location into the Apple Photos library via `PHAssetChangeRequest`.
enum PhotosAssetMetadataWriter {

    /// Updates `creationDate` on the matching assets. Returns an error message, or `nil` on success.
    static func updateCreationDates(
        _ updates: [(photoId: String, date: Date)]
    ) async -> String? {
        guard !updates.isEmpty else { return nil }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return "Photos access is required to change dates."
        }

        let dateById = Dictionary(uniqueKeysWithValues: updates.map { ($0.photoId, $0.date) })
        return await performChanges {
            let result = PHAsset.fetchAssets(
                withLocalIdentifiers: Array(dateById.keys),
                options: nil
            )
            result.enumerateObjects { asset, _, _ in
                guard let date = dateById[asset.localIdentifier] else { return }
                let request = PHAssetChangeRequest(for: asset)
                request.creationDate = date
            }
        } failureMessage: {
            "Could not update photo dates in Photos."
        }
    }

    /// Updates `location` on the matching assets (`nil` clears location). Returns an error message, or `nil` on success.
    static func updateLocations(
        _ updates: [(photoId: String, location: CLLocation?)]
    ) async -> String? {
        guard !updates.isEmpty else { return nil }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return "Photos access is required to change locations."
        }

        let locationById = Dictionary(uniqueKeysWithValues: updates.map { ($0.photoId, $0.location) })
        return await performChanges {
            let result = PHAsset.fetchAssets(
                withLocalIdentifiers: Array(locationById.keys),
                options: nil
            )
            result.enumerateObjects { asset, _, _ in
                guard locationById.keys.contains(asset.localIdentifier) else { return }
                let request = PHAssetChangeRequest(for: asset)
                request.location = locationById[asset.localIdentifier] ?? nil
            }
        } failureMessage: {
            "Could not update photo locations in Photos."
        }
    }

    private static func performChanges(
        _ changes: @escaping () -> Void,
        failureMessage: @escaping () -> String
    ) async -> String? {
        await withCheckedContinuation { continuation in
            var resumed = false
            let resumeOnce: (String?) -> Void = { message in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: message)
            }

            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error {
                    resumeOnce(error.localizedDescription)
                } else if !success {
                    resumeOnce(failureMessage())
                } else {
                    resumeOnce(nil)
                }
            }
        }
    }
}
