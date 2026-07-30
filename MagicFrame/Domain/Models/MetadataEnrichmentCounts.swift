import Foundation

struct MetadataEnrichmentCounts: Equatable {
    let albumRows: Int
    let photoAlbumLinkRows: Int
    let textMetadataRows: Int
    let activePhotoRows: Int
    let photosWithAlbumMembership: Int
    let photosWithTextMetadata: Int

    var summaryLine: String {
        "\(albumRows.formatted()) albums · \(photoAlbumLinkRows.formatted()) links · " +
            "\(textMetadataRows.formatted()) text rows · \(activePhotoRows.formatted()) photos indexed"
    }

    var detailLine: String {
        "\(photosWithAlbumMembership.formatted()) photos in albums · " +
            "\(photosWithTextMetadata.formatted()) with filename metadata"
    }
}
