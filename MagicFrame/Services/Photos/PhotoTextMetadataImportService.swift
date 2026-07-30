import Foundation
import Photos

/// Cheap text metadata import (no image bytes, no EXIF parsing).
final class PhotoTextMetadataImportService {

    static let assetBatchSize = 200

    private let photos: PhotoRepository
    private let textMetadata: PhotoTextMetadataRepository

    init(photos: PhotoRepository, textMetadata: PhotoTextMetadataRepository) {
        self.photos = photos
        self.textMetadata = textMetadata
    }

    /// Imports filename and any title/description available without loading image data.
    func importCheapTextMetadata() {
        let photoIds = textMetadata.fetchActivePhotoIdsMissingTextMetadata()
        guard !photoIds.isEmpty else {
            print("Photo text metadata: all indexed photos already have rows")
            return
        }

        let now = ISO8601DateFormatter().string(from: Date())
        var imported = 0

        for batchStart in stride(from: 0, to: photoIds.count, by: Self.assetBatchSize) {
            let batchEnd = min(batchStart + Self.assetBatchSize, photoIds.count)
            let batchIds = Array(photoIds[batchStart..<batchEnd])
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: batchIds, options: nil)

            assets.enumerateObjects { [self] asset, _, _ in
                let fields = Self.cheapTextFields(for: asset)
                self.textMetadata.upsert(
                    photoId: asset.localIdentifier,
                    originalFilename: fields.originalFilename,
                    assetTitle: fields.assetTitle,
                    assetDescription: fields.assetDescription,
                    metadataSource: fields.metadataSource,
                    indexedAt: now
                )
                imported += 1
            }
        }

        print("Photo text metadata import complete: \(imported) photos")
    }

    private static func cheapTextFields(for asset: PHAsset) -> (
        originalFilename: String?,
        assetTitle: String?,
        assetDescription: String?,
        metadataSource: String
    ) {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferredResource = resources.first(where: {
            $0.type == .photo || $0.type == .fullSizePhoto || $0.type == .alternatePhoto
        }) ?? resources.first

        let trimmedFilename = preferredResource?.originalFilename
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedFilename = trimmedFilename.isEmpty ? nil : trimmedFilename

        // Do not use KVC on PHAsset for title/description — unsupported keys trap at runtime.
        return (normalizedFilename, nil, nil, "resource")
    }

    private static func normalizedCheapString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
