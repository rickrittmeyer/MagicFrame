import Foundation

struct PhotoTextRecognitionScanReport: Sendable {
    let photoCount: Int
    let photosScanned: Int
    let photosSkippedAnalyzed: Int
    let photosFailed: Int
    let observationsWritten: Int
    let photosWithText: Int
    let stoppedEarly: Bool

    var summaryLine: String {
        let cancelled = stoppedEarly ? " · cancelled" : ""
        return "OCR: \(photosScanned) scanned · \(photosWithText) with text · "
            + "\(observationsWritten) lines · \(photosSkippedAnalyzed) already done · "
            + "\(photosFailed) failed"
            + cancelled
    }
}

/// Runs Apple Vision text recognition on photo IDs and stores results in `photo_ocr_text`.
final class PhotoTextRecognitionScanService {

    private let database: DatabaseManager
    private let photos: PhotoRepository
    private let ocrText: PhotoOCRTextRepository

    init(
        database: DatabaseManager,
        photos: PhotoRepository,
        ocrText: PhotoOCRTextRepository
    ) {
        self.database = database
        self.photos = photos
        self.ocrText = ocrText
    }

    func scan(
        photoIds: [String],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> PhotoTextRecognitionScanReport {
        let algorithmVersion = PhotoTextRecognitionAnalyzer.algorithmVersion
        var photosScanned = 0
        var photosSkippedAnalyzed = 0
        var photosFailed = 0
        var observationsWritten = 0
        var photosWithText = 0
        var stoppedEarly = false

        for (index, photoId) in photoIds.enumerated() {
            if Task.isCancelled {
                stoppedEarly = true
                break
            }

            progress?(index + 1, photoIds.count)

            let alreadyDone = sync {
                photos.textRecognitionVersionUnsafe(photoId: photoId) >= algorithmVersion
            }
            if alreadyDone {
                photosSkippedAnalyzed += 1
                continue
            }

            guard let observations = await PhotoTextRecognitionAnalyzer.recognizeText(
                assetIdentifier: photoId
            ) else {
                // Image load failed — leave version unset so a later pass retries.
                photosFailed += 1
                continue
            }

            let fullText = PhotoTextRecognitionAnalyzer.joinedFullText(from: observations)
            let indexedAt = ISO8601DateFormatter().string(from: Date())

            sync {
                ocrText.upsertUnsafe(
                    photoId: photoId,
                    fullText: fullText,
                    observationCount: observations.count,
                    algorithmVersion: algorithmVersion,
                    indexedAt: indexedAt
                )
                photos.markPhotoTextRecognizedUnsafe(
                    photoId: photoId,
                    version: algorithmVersion
                )
            }

            photosScanned += 1
            observationsWritten += observations.count
            if !observations.isEmpty {
                photosWithText += 1
            }
            await Task.yield()
        }

        return PhotoTextRecognitionScanReport(
            photoCount: photoIds.count,
            photosScanned: photosScanned,
            photosSkippedAnalyzed: photosSkippedAnalyzed,
            photosFailed: photosFailed,
            observationsWritten: observationsWritten,
            photosWithText: photosWithText,
            stoppedEarly: stoppedEarly
        )
    }

    private func sync<T>(_ work: () -> T) -> T {
        if database.isOnQueue {
            return work()
        }
        return database.sync(work)
    }
}
