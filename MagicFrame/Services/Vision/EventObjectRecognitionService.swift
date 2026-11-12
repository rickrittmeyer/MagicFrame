import Foundation

struct EventObjectRecognitionProgress: Sendable {
    let categories: [ObjectDetectionCategoryPlan]
    let photoIndex: Int
    let photoCount: Int
    let currentCategoryName: String?

    var statusText: String? {
        guard photoCount > 0 else { return nil }
        let categorySuffix = currentCategoryName.map { " · \($0) objects" } ?? ""
        return "Scanning photo \(photoIndex) of \(photoCount)\(categorySuffix)"
    }
}

struct EventObjectRecognitionResult: Sendable {
    let categoriesScanned: [ObjectDetectionCategory]
    let photosScanned: Int
    let detectionsWritten: Int
    let skippedReason: String?
    let stoppedEarly: Bool
    let scanCompleted: Bool
}

struct ChristmasObjectRescanReport: Sendable {
    let taggedEventCount: Int
    let eventsScanned: Int
    let eventsSkipped: Int
    let photosScanned: Int
    let detectionsWritten: Int
    let elapsedSeconds: Double
    let skipReasonCounts: [String: Int]

    var summaryLine: String {
        let skippedSuffix = eventsSkipped > 0 ? " · \(eventsSkipped) skipped" : ""
        return String(
            format: "Christmas rescan: %d tagged · %d scanned%@ · %d photos · %d detections · %.1fs",
            taggedEventCount,
            eventsScanned,
            skippedSuffix,
            photosScanned,
            detectionsWritten,
            elapsedSeconds
        )
    }

    var detailLine: String {
        guard !skipReasonCounts.isEmpty else { return "" }
        let parts = skipReasonCounts
            .sorted { $0.value > $1.value }
            .map { "\($0.key): \($0.value)" }
        return "Skips: " + parts.joined(separator: "; ")
    }
}

struct ChristmasLandingVisionScanReport: Sendable {
    let candidateEventCount: Int
    let eventsScanned: Int
    let eventsSkipped: Int
    let photosScanned: Int
    let detectionsWritten: Int
    let earlyExits: Int
    let elapsedSeconds: Double
}

struct EventObjectRecognitionPlan: Sendable {
    let shouldRun: Bool
    let skippedReason: String?
    let plans: [ObjectDetectionCategoryPlan]
    let photos: [IndexedPhoto]
    let targetObjectKeys: Set<String>
    let finalizedPartialScan: Bool
}

final class EventObjectRecognitionService {

    private typealias PreparedRun = EventObjectRecognitionPlan

    private let database: DatabaseManager
    private let events: EventRepository
    private let objectTags: ObjectTagRepository
    private let eventTags: EventTagRepository
    private let planner: EventObjectRecognitionPlanner

    init(
        database: DatabaseManager,
        events: EventRepository,
        objectTags: ObjectTagRepository,
        eventTags: EventTagRepository
    ) {
        self.database = database
        self.events = events
        self.objectTags = objectTags
        self.eventTags = eventTags
        self.planner = EventObjectRecognitionPlanner(eventTags: eventTags)
    }

    func runIfNeeded(
        eventId: Int,
        includeHiddenPhotos: Bool = false,
        forceRescan: Bool = false,
        forcedOccasionKey: String? = nil,
        progress: (@Sendable (EventObjectRecognitionProgress) -> Void)? = nil
    ) async -> EventObjectRecognitionResult {
        if Task.isCancelled {
            return EventObjectRecognitionResult(
                categoriesScanned: [],
                photosScanned: 0,
                detectionsWritten: 0,
                skippedReason: "Cancelled",
                stoppedEarly: false,
                scanCompleted: false
            )
        }

        let prepared = database.sync {
            prepareRunUnsafe(
                eventId: eventId,
                includeHiddenPhotos: includeHiddenPhotos,
                forceRescan: forceRescan,
                forcedOccasionKey: forcedOccasionKey
            )
        }

        if prepared.finalizedPartialScan {
            return EventObjectRecognitionResult(
                categoriesScanned: prepared.plans.map(\.category),
                photosScanned: 0,
                detectionsWritten: 0,
                skippedReason: nil,
                stoppedEarly: false,
                scanCompleted: true
            )
        }

        guard prepared.shouldRun else {
            return EventObjectRecognitionResult(
                categoriesScanned: [],
                photosScanned: 0,
                detectionsWritten: 0,
                skippedReason: prepared.skippedReason,
                stoppedEarly: false,
                scanCompleted: false
            )
        }

        let createdAt = ISO8601DateFormatter().string(from: Date())
        var detectionsWritten = 0
        var photosScanned = 0
        let categoryLabel = prepared.plans.map(\.category.displayName).joined(separator: ", ")
        let occasionKeys = prepared.plans.map(\.category.occasionKey)

        for (index, photo) in prepared.photos.enumerated() {
            if Task.isCancelled {
                return EventObjectRecognitionResult(
                    categoriesScanned: prepared.plans.map(\.category),
                    photosScanned: photosScanned,
                    detectionsWritten: detectionsWritten,
                    skippedReason: "Cancelled",
                    stoppedEarly: false,
                    scanCompleted: false
                )
            }

            progress?(
                EventObjectRecognitionProgress(
                    categories: prepared.plans,
                    photoIndex: index + 1,
                    photoCount: prepared.photos.count,
                    currentCategoryName: categoryLabel
                )
            )

            let detections = await PhotoObjectVisionAnalyzer.analyze(
                assetIdentifier: photo.id,
                targetObjectKeys: prepared.targetObjectKeys
            )

            photosScanned += 1

            let written = database.sync { () -> Int in
                let result = applyPhotoScanResultUnsafe(
                    eventId: eventId,
                    photoId: photo.id,
                    detections: detections,
                    occasionKeys: occasionKeys,
                    scannedAt: createdAt
                )
                return result.detectionCount
            }
            detectionsWritten += written

            await Task.yield()
        }

        database.sync {
            finalizeEventObjectRecognitionUnsafe(
                eventId: eventId,
                occasionKeys: occasionKeys,
                completedAt: createdAt,
                stoppedEarly: false
            )
        }

        return EventObjectRecognitionResult(
            categoriesScanned: prepared.plans.map(\.category),
            photosScanned: photosScanned,
            detectionsWritten: detectionsWritten,
            skippedReason: nil,
            stoppedEarly: false,
            scanCompleted: true
        )
    }

    func planRunUnsafe(
        eventId: Int,
        includeHiddenPhotos: Bool,
        forceRescan: Bool,
        forcedOccasionKey: String?
    ) -> EventObjectRecognitionPlan {
        prepareRunUnsafe(
            eventId: eventId,
            includeHiddenPhotos: includeHiddenPhotos,
            forceRescan: forceRescan,
            forcedOccasionKey: forcedOccasionKey
        )
    }

    func applyPhotoScanResultUnsafe(
        eventId: Int,
        photoId: String,
        detections: [PhotoObjectDetection],
        occasionKeys: [String],
        scannedAt: String
    ) -> (stoppedEarly: Bool, detectionCount: Int) {
        objectTags.markPhotoVisionScannedUnsafe(
            photoId: photoId,
            algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion,
            scannedAt: scannedAt
        )

        var newDetections = 0
        if !detections.isEmpty {
            newDetections = detections.count
            objectTags.upsertPhotoObjectTagsUnsafe(
                photoId: photoId,
                detections: detections,
                source: "vision_v\(PhotoObjectVisionAnalyzer.algorithmVersion)",
                createdAt: scannedAt
            )
        }

        objectTags.rebuildEventObjectTagsUnsafe(eventId: eventId, updatedAt: scannedAt)
        _ = occasionKeys
        return (false, newDetections)
    }

    func finalizeEventObjectRecognitionUnsafe(
        eventId: Int,
        occasionKeys: [String],
        completedAt: String,
        stoppedEarly: Bool
    ) {
        eventTags.markObjectRecognitionCompletedUnsafe(
            eventId: eventId,
            completedAt: completedAt,
            algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
        )
        _ = stoppedEarly
        _ = occasionKeys
    }

    private func prepareRunUnsafe(
        eventId: Int,
        includeHiddenPhotos: Bool,
        forceRescan: Bool,
        forcedOccasionKey: String?
    ) -> PreparedRun {
        if !forceRescan,
           objectTags.isObjectRecognitionCompletedUnsafe(eventId: eventId),
           objectTags.objectRecognitionAlgorithmVersionUnsafe(eventId: eventId)
               >= PhotoObjectVisionAnalyzer.algorithmVersion {
            return PreparedRun(
                shouldRun: false,
                skippedReason: "Object recognition already completed for this event.",
                plans: [],
                photos: [],
                targetObjectKeys: [],
                finalizedPartialScan: false
            )
        }

        var plans = planner.planCategoriesUnsafe(eventId: eventId)
        if plans.isEmpty,
           let forcedOccasionKey,
           let forcedPlan = planner.planForcedHolidayCategoryUnsafe(occasionKey: forcedOccasionKey) {
            plans = [forcedPlan]
        }
        guard !plans.isEmpty else {
            return PreparedRun(
                shouldRun: false,
                skippedReason: "No holiday tag or forced category for object detection.",
                plans: [],
                photos: [],
                targetObjectKeys: [],
                finalizedPartialScan: false
            )
        }

        let allPhotos = events.getPhotosForEvent(
            eventId: eventId,
            includeHidden: includeHiddenPhotos
        )
        guard !allPhotos.isEmpty else {
            return PreparedRun(
                shouldRun: false,
                skippedReason: "No photos in event.",
                plans: plans,
                photos: [],
                targetObjectKeys: [],
                finalizedPartialScan: false
            )
        }

        let unscannedPhotoIds = objectTags.filterUnscannedPhotoIdsUnsafe(
            photoIds: allPhotos.map(\.id),
            algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
        )
        let photos = allPhotos.filter { unscannedPhotoIds.contains($0.id) }

        if photos.isEmpty {
            let completedAt = ISO8601DateFormatter().string(from: Date())
            objectTags.rebuildEventObjectTagsUnsafe(eventId: eventId, updatedAt: completedAt)
            eventTags.markObjectRecognitionCompletedUnsafe(
                eventId: eventId,
                completedAt: completedAt,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )
            return PreparedRun(
                shouldRun: false,
                skippedReason: nil,
                plans: plans,
                photos: [],
                targetObjectKeys: Set(plans.flatMap(\.objectKeys)),
                finalizedPartialScan: true
            )
        }

        return PreparedRun(
            shouldRun: true,
            skippedReason: nil,
            plans: plans,
            photos: photos,
            targetObjectKeys: Set(plans.flatMap(\.objectKeys)),
            finalizedPartialScan: false
        )
    }
}
