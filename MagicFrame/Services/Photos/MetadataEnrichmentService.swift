import Foundation

/// Post-index metadata phase (albums + cheap text) before event assignment.
final class MetadataEnrichmentService {

    private let albumImport: AlbumImportService
    private let photoTextImport: PhotoTextMetadataImportService
    private let database: DatabaseManager

    init(
        albumImport: AlbumImportService,
        photoTextImport: PhotoTextMetadataImportService,
        database: DatabaseManager
    ) {
        self.albumImport = albumImport
        self.photoTextImport = photoTextImport
        self.database = database
    }

    func runPostIndexPhase() {
        print("Metadata enrichment: starting post-index phase")
        albumImport.importAllVisibleAlbums()
        photoTextImport.importCheapTextMetadata()
        DevDatabaseTools.debugMetadataCounts(database: database)
        print("Metadata enrichment: post-index phase complete")
    }
}
