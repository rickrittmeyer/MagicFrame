import Foundation

struct PhotoVisionTagScanReport: Sendable {
    let photoCount: Int
    let photosScanned: Int
    let photosSkippedAnalyzed: Int
    let photosFailed: Int
    let tagsWritten: Int
    let stoppedEarly: Bool

    var summaryLine: String {
        let cancelled = stoppedEarly ? " · cancelled" : ""
        return "Vision tags: \(photosScanned) scanned · \(tagsWritten) labels · "
            + "\(photosSkippedAnalyzed) already tagged · \(photosFailed) failed"
            + cancelled
    }
}

/// Month-day range selection across **all years** (e.g. 08-01…08-31 → every August).
struct PhotoVisionTagMonthDaySelection: Sendable {
    let photoIds: [String]
    let totalInRange: Int
    let alreadyAnalyzed: Int
    /// Counts of photos in range by calendar year (analyzed + unanalyzed).
    let photoCountByYear: [Int: Int]

    var yearCount: Int { photoCountByYear.count }

    var unanalyzedCount: Int { photoIds.count }

    var yearSpanText: String {
        let years = photoCountByYear.keys.sorted()
        guard let first = years.first, let last = years.last else { return "no years" }
        if first == last { return "\(first)" }
        return "\(first)–\(last) (\(years.count) years)"
    }

    var summaryLine: String {
        "\(totalInRange.formatted()) photos in range · \(yearSpanText) · "
            + "\(alreadyAnalyzed.formatted()) already tagged · "
            + "\(unanalyzedCount.formatted()) to scan"
    }
}

enum PhotoVisionTagQuery {
    struct MonthDayRange: Sendable, Equatable {
        let start: String
        let end: String

        var wrapsYear: Bool { start > end }

        var displayText: String {
            "\(Self.displayMonthDay(start))–\(Self.displayMonthDay(end))"
        }

        private static func displayMonthDay(_ value: String) -> String {
            let parts = value.split(separator: "-")
            guard parts.count == 2,
                  let month = Int(parts[0]),
                  let day = Int(parts[1]) else {
                return value
            }
            return "\(month)/\(day)"
        }
    }

    /// Accepts `12-24` or `12/24`.
    static func normalizedMonthDay(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split { $0 == "-" || $0 == "/" }
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        return String(format: "%02d-%02d", month, day)
    }

    static func normalizedRange(start: String, end: String) -> MonthDayRange? {
        guard let startDay = normalizedMonthDay(start),
              let endDay = normalizedMonthDay(end) else {
            return nil
        }
        return MonthDayRange(start: startDay, end: endDay)
    }
}

/// Runs Apple Vision scene classification on a list of photo IDs (no face detection).
final class PhotoVisionTagScanService {

    static let tagSource = "vision_classify"

    private let database: DatabaseManager
    private let photos: PhotoRepository
    private let objectTags: ObjectTagRepository

    init(
        database: DatabaseManager,
        photos: PhotoRepository,
        objectTags: ObjectTagRepository
    ) {
        self.database = database
        self.photos = photos
        self.objectTags = objectTags
    }

    func scan(
        photoIds: [String],
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> PhotoVisionTagScanReport {
        var photosScanned = 0
        var photosSkippedAnalyzed = 0
        var photosFailed = 0
        var tagsWritten = 0
        var stoppedEarly = false

        for (index, photoId) in photoIds.enumerated() {
            if Task.isCancelled {
                stoppedEarly = true
                break
            }

            progress?(index + 1, photoIds.count)

            let alreadyAnalyzed = sync {
                photos.isVisionAnalyzedUnsafe(photoId: photoId)
            }
            if alreadyAnalyzed {
                photosSkippedAnalyzed += 1
                continue
            }

            guard let classifications = await PhotoObjectVisionAnalyzer.allClassifications(
                assetIdentifier: photoId
            ) else {
                // Image load failed — leave visionAnalyzed unset so a later pass retries.
                photosFailed += 1
                continue
            }

            // Empty Vision results are still a successful analysis (no labels to store).
            let detections = classifications.map {
                PhotoObjectDetection(objectKey: $0.identifier, confidence: $0.confidence)
            }
            let createdAt = ISO8601DateFormatter().string(from: Date())

            sync {
                if !detections.isEmpty {
                    objectTags.upsertPhotoObjectTagsUnsafe(
                        photoId: photoId,
                        detections: detections,
                        source: Self.tagSource,
                        createdAt: createdAt
                    )
                }
                photos.markPhotoVisionAnalyzedUnsafe(photoId: photoId)
            }

            photosScanned += 1
            tagsWritten += detections.count
            await Task.yield()
        }

        return PhotoVisionTagScanReport(
            photoCount: photoIds.count,
            photosScanned: photosScanned,
            photosSkippedAnalyzed: photosSkippedAnalyzed,
            photosFailed: photosFailed,
            tagsWritten: tagsWritten,
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
