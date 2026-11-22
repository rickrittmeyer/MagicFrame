import Photos

enum PhotoLibraryDeletion {
    /// Deletes the assets from the Photos app. Returns an error message when the deletion fails.
    static func deleteAssets(localIdentifiers: [String]) async -> String? {
        let identifiers = Array(Set(localIdentifiers))
        guard !identifiers.isEmpty else { return nil }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return "Photo library access is required to delete pictures from Photos."
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var toDelete: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in
            toDelete.append(asset)
        }
        guard !toDelete.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSArray)
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(
                        returning: error?.localizedDescription
                            ?? "Could not delete the pictures from Photos."
                    )
                }
            }
        }
    }
}
