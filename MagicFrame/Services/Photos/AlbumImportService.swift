import Foundation
import Photos

/// Imports PhotoKit albums and links memberships for photos already in `photos`.
final class AlbumImportService {

    static let membershipBatchSize = 500

    private static let highCardinalitySmartSubtypes: Set<PHAssetCollectionSubtype> = [
        .smartAlbumUserLibrary,
        .smartAlbumRecentlyAdded,
        .smartAlbumFavorites,
        .smartAlbumAllHidden,
        .smartAlbumDepthEffect,
        .smartAlbumLivePhotos,
        .smartAlbumPanoramas,
        .smartAlbumScreenshots,
        .smartAlbumSelfPortraits,
        .smartAlbumBursts,
        .smartAlbumAnimated,
        .smartAlbumRAW,
        .smartAlbumCinematic,
        .smartAlbumSpatial
    ]

    private let albums: AlbumRepository
    private let photos: PhotoRepository

    init(albums: AlbumRepository, photos: PhotoRepository) {
        self.albums = albums
        self.photos = photos
    }

    /// Rebuilds album rows and indexed-photo memberships from visible PhotoKit collections.
    func importAllVisibleAlbums() {
        let indexedPhotoIds = photos.fetchActivePhotoIdSet()
        guard !indexedPhotoIds.isEmpty else {
            print("Album import: no indexed photos — skipping")
            return
        }

        let now = ISO8601DateFormatter().string(from: Date())
        albums.clearPhotoAlbumMemberships()

        var totalAlbums = 0
        var totalLinks = 0
        var pendingLinks: [(photoId: String, albumId: String, source: String)] = []

        for collectionType in [PHAssetCollectionType.album, PHAssetCollectionType.smartAlbum] {
            let collections = PHAssetCollection.fetchAssetCollections(
                with: collectionType,
                subtype: .any,
                options: nil
            )

            collections.enumerateObjects { [self] collection, _, _ in
                let albumId = collection.localIdentifier
                guard let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else {
                    return
                }

                let isHighCardinality = collectionType == .smartAlbum
                    && Self.highCardinalitySmartSubtypes.contains(collection.assetCollectionSubtype)

                let assets = PHAsset.fetchAssets(in: collection, options: nil)
                let assetCount = assets.count

                self.albums.upsertAlbum(
                    albumId: albumId,
                    title: title,
                    collectionType: Self.collectionTypeLabel(collectionType),
                    collectionSubtype: String(describing: collection.assetCollectionSubtype),
                    isPersonAlbum: false,
                    personId: nil,
                    isHighCardinality: isHighCardinality,
                    assetCount: assetCount,
                    indexedAt: now
                )
                totalAlbums += 1

                assets.enumerateObjects { asset, _, _ in
                    let photoId = asset.localIdentifier
                    guard indexedPhotoIds.contains(photoId) else { return }

                    pendingLinks.append((photoId: photoId, albumId: albumId, source: "index"))
                    if pendingLinks.count >= Self.membershipBatchSize {
                        self.albums.insertPhotoAlbumLinks(pendingLinks)
                        totalLinks += pendingLinks.count
                        pendingLinks.removeAll(keepingCapacity: true)
                    }
                }
            }
        }

        if !pendingLinks.isEmpty {
            albums.insertPhotoAlbumLinks(pendingLinks)
            totalLinks += pendingLinks.count
        }

        print(
            "Album import complete: \(totalAlbums) albums,"
            + " \(totalLinks) indexed photo memberships"
        )
    }

    private static func collectionTypeLabel(_ type: PHAssetCollectionType) -> String {
        switch type {
        case .album:
            return "album"
        case .smartAlbum:
            return "smartAlbum"
        default:
            return String(describing: type)
        }
    }
}
