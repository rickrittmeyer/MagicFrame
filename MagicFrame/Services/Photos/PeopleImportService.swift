import Foundation
import Photos

/// Imports person tags from Photos albums whose names start with `P-`.
final class PeopleImportService {

    private let people: PeopleRepository

    init(people: PeopleRepository) {
        self.people = people
    }

    func importPeopleFromAlbums() {
        importPeopleFromCollectionType(.album)
        importPeopleFromCollectionType(.smartAlbum)
    }

    private func importPeopleFromCollectionType(_ type: PHAssetCollectionType) {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: type,
            subtype: .any,
            options: nil
        )

        collections.enumerateObjects { collection, _, _ in
            guard let albumName = collection.localizedTitle else { return }
            guard albumName.hasPrefix("P-") else { return }

            let personName = String(albumName.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !personName.isEmpty else { return }

            let personId = self.people.upsertPerson(name: personName)
            let assets = PHAsset.fetchAssets(in: collection, options: nil)

            assets.enumerateObjects { asset, _, _ in
                self.people.linkPhotoToPerson(
                    photoId: asset.localIdentifier,
                    personId: personId,
                    source: "album"
                )
            }

            print("Imported \(assets.count) photos for person: \(personName)")
        }
    }
}
