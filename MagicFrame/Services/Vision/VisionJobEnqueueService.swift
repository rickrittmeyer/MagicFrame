import Foundation

/// Plans and enqueues Vision work units. Does not run Vision — the coordinator worker does.
final class VisionJobEnqueueService {

    private let database: DatabaseManager
    private let visionJobs: VisionJobRepository
    private let eventObjectRecognition: EventObjectRecognitionService
    private let eventTags: EventTagRepository

    private let faceRecognition: FaceRecognitionRepository

    init(
        database: DatabaseManager,
        visionJobs: VisionJobRepository,
        eventObjectRecognition: EventObjectRecognitionService,
        eventTags: EventTagRepository,
        faceRecognition: FaceRecognitionRepository
    ) {
        self.database = database
        self.visionJobs = visionJobs
        self.eventObjectRecognition = eventObjectRecognition
        self.eventTags = eventTags
        self.faceRecognition = faceRecognition
    }

    /// Enqueues face detect/embed jobs for photos not yet at the current algorithm version.
    func enqueueFaceRecognitionScan(
        forceRescan: Bool = false,
        limit: Int = 2_000,
        priority: Int = 40
    ) -> VisionJobEnqueueSummary {
        database.sync {
            enqueueFaceRecognitionScanUnsafe(
                forceRescan: forceRescan,
                limit: limit,
                priority: priority
            )
        }
    }

    private func enqueueFaceRecognitionScanUnsafe(
        forceRescan: Bool,
        limit: Int,
        priority: Int
    ) -> VisionJobEnqueueSummary {
        let algorithmVersion = FaceRecognitionAnalyzer.algorithmVersion
        let scopeKey = "faceRecognition:library"
        let createdAt = ISO8601DateFormatter().string(from: Date())

        if forceRescan {
            faceRecognition.clearFaceRecognitionVersionsUnsafe()
        } else {
            // Accidental force-rescan clears versions; put stamps back for photos
            // that already have face rows so progress/queue stay coherent.
            _ = faceRecognition.restoreFaceRecognitionVersionsForPhotosWithFacesUnsafe(
                algorithmVersion: algorithmVersion
            )
        }

        let photoIds = faceRecognition.fetchPhotoIdsNeedingFaceRecognitionUnsafe(
            algorithmVersion: algorithmVersion,
            limit: limit
        )

        var enqueued = 0
        for photoId in photoIds {
            let dedupeKey = "faceRecognitionScan|\(photoId)|v\(algorithmVersion)"
            if visionJobs.enqueueUnsafe(
                jobType: .faceRecognitionScan,
                priority: priority,
                photoId: photoId,
                eventId: nil,
                occasionKey: nil,
                algorithmVersion: algorithmVersion,
                payload: VisionJobPayload(scopeKey: scopeKey),
                dedupeKey: dedupeKey,
                createdAt: createdAt
            ) {
                enqueued += 1
            }
        }

        let remaining = faceRecognition.countPhotosNeedingFaceRecognitionUnsafe(
            algorithmVersion: algorithmVersion
        )
        let skipped: String?
        if photoIds.isEmpty {
            skipped = remaining == 0
                ? "All photos already face-scanned"
                : "No eligible photos in this batch"
        } else if enqueued == 0 {
            skipped = "Could not queue face scans (jobs already active)"
        } else {
            skipped = nil
        }

        return VisionJobEnqueueSummary(
            enqueuedCount: enqueued,
            skippedReason: skipped
        )
    }

    /// Enqueues face detect/embed for specific photos that still need the current algorithm version.
    /// Used by Picture Search results and event-open seeding (not library bulk scan).
    func enqueueFaceRecognitionForPhotoIds(
        _ photoIds: [String],
        priority: Int = 70
    ) -> VisionJobEnqueueSummary {
        database.sync {
            enqueueFaceRecognitionForPhotoIdsUnsafe(photoIds, priority: priority)
        }
    }

    private func enqueueFaceRecognitionForPhotoIdsUnsafe(
        _ photoIds: [String],
        priority: Int
    ) -> VisionJobEnqueueSummary {
        let uniqueIds = Array(Set(photoIds.filter { !$0.isEmpty }))
        guard !uniqueIds.isEmpty else {
            return VisionJobEnqueueSummary(enqueuedCount: 0, skippedReason: "No photos to face-scan")
        }

        let algorithmVersion = FaceRecognitionAnalyzer.algorithmVersion
        let needing = faceRecognition.filterPhotoIdsNeedingFaceRecognitionUnsafe(
            photoIds: uniqueIds,
            algorithmVersion: algorithmVersion
        )
        guard !needing.isEmpty else {
            return VisionJobEnqueueSummary(
                enqueuedCount: 0,
                skippedReason: "All selected photos already face-scanned"
            )
        }

        let scopeKey = "faceRecognition:library"
        let createdAt = ISO8601DateFormatter().string(from: Date())
        var enqueued = 0
        for photoId in needing {
            let dedupeKey = "faceRecognitionScan|\(photoId)|v\(algorithmVersion)"
            if visionJobs.enqueueUnsafe(
                jobType: .faceRecognitionScan,
                priority: priority,
                photoId: photoId,
                eventId: nil,
                occasionKey: nil,
                algorithmVersion: algorithmVersion,
                payload: VisionJobPayload(scopeKey: scopeKey),
                dedupeKey: dedupeKey,
                createdAt: createdAt
            ) {
                enqueued += 1
            }
        }

        let skipped: String?
        if enqueued == 0 {
            skipped = "Could not queue face scans (jobs already active)"
        } else {
            skipped = nil
        }
        return VisionJobEnqueueSummary(enqueuedCount: enqueued, skippedReason: skipped)
    }

    func enqueueEventObjectRecognition(
        eventId: Int,
        includeHiddenPhotos: Bool = false,
        forceRescan: Bool = false,
        forcedOccasionKey: String? = nil,
        priority: Int = 100,
        scopeKey: String? = nil
    ) -> VisionJobEnqueueSummary {
        database.sync {
            enqueueEventObjectRecognitionUnsafe(
                eventId: eventId,
                includeHiddenPhotos: includeHiddenPhotos,
                forceRescan: forceRescan,
                forcedOccasionKey: forcedOccasionKey,
                priority: priority,
                scopeKey: scopeKey
            )
        }
    }

    func enqueueHolidayYearObjectRecognition(
        config: HolidayVisionLandingConfig,
        year: Int,
        eventIds: [Int],
        includeHiddenPhotos: Bool = false,
        priority: Int = 50
    ) -> VisionJobEnqueueSummary {
        let scopeKey = "holiday:\(config.tagValue):\(year)"
        let candidateIds = database.sync {
            eventTags.fetchAITaggedHolidayEventIdsNeedingObjectRecognitionUnsafe(
                eventIds: eventIds,
                tagValue: config.tagValue,
                includeHidden: includeHiddenPhotos,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )
        }

        guard !candidateIds.isEmpty else {
            return VisionJobEnqueueSummary(enqueuedCount: 0, skippedReason: "No events need scanning.")
        }

        var enqueued = 0
        for eventId in candidateIds {
            let summary = enqueueEventObjectRecognition(
                eventId: eventId,
                includeHiddenPhotos: includeHiddenPhotos,
                forcedOccasionKey: config.occasionKey,
                priority: priority,
                scopeKey: scopeKey
            )
            enqueued += summary.enqueuedCount
        }

        return VisionJobEnqueueSummary(enqueuedCount: enqueued, skippedReason: nil)
    }

    func enqueueHolidayTaggedRescan(
        config: HolidayVisionLandingConfig,
        eventIds: [Int],
        includeHiddenPhotos: Bool = true,
        priority: Int = 10
    ) -> VisionJobRescanEnqueueResult {
        let scopeKey = "devRescan:\(config.tagValue)"
        var enqueued = 0
        for eventId in eventIds {
            let summary = enqueueEventObjectRecognition(
                eventId: eventId,
                includeHiddenPhotos: includeHiddenPhotos,
                forceRescan: true,
                forcedOccasionKey: config.occasionKey,
                priority: priority,
                scopeKey: scopeKey
            )
            enqueued += summary.enqueuedCount
        }
        return VisionJobRescanEnqueueResult(
            taggedEventCount: eventIds.count,
            enqueuedCount: enqueued,
            scopeKey: scopeKey
        )
    }

    private func enqueueEventObjectRecognitionUnsafe(
        eventId: Int,
        includeHiddenPhotos: Bool,
        forceRescan: Bool,
        forcedOccasionKey: String?,
        priority: Int,
        scopeKey: String?
    ) -> VisionJobEnqueueSummary {
        let plan = eventObjectRecognition.planRunUnsafe(
            eventId: eventId,
            includeHiddenPhotos: includeHiddenPhotos,
            forceRescan: forceRescan,
            forcedOccasionKey: forcedOccasionKey
        )

        if plan.finalizedPartialScan {
            return VisionJobEnqueueSummary(enqueuedCount: 0, skippedReason: nil)
        }

        guard plan.shouldRun else {
            return VisionJobEnqueueSummary(
                enqueuedCount: 0,
                skippedReason: plan.skippedReason
            )
        }

        let createdAt = ISO8601DateFormatter().string(from: Date())
        let algorithmVersion = PhotoObjectVisionAnalyzer.algorithmVersion
        let occasionKeys = plan.plans.map(\.category.occasionKey)
        let payload = VisionJobPayload(
            targetObjectKeys: Array(plan.targetObjectKeys).sorted(),
            occasionKeys: occasionKeys,
            includeHiddenPhotos: includeHiddenPhotos,
            forceRescan: forceRescan,
            scopeKey: scopeKey
        )

        var enqueued = 0
        for photo in plan.photos {
            let dedupeKey = "objectPhotoScan|\(photo.id)|v\(algorithmVersion)"
            if visionJobs.enqueueUnsafe(
                jobType: .objectPhotoScan,
                priority: priority,
                photoId: photo.id,
                eventId: eventId,
                occasionKey: forcedOccasionKey,
                algorithmVersion: algorithmVersion,
                payload: payload,
                dedupeKey: dedupeKey,
                createdAt: createdAt
            ) {
                enqueued += 1
            }
        }

        let finalizeDedupe = "objectEventFinalize|\(eventId)|v\(algorithmVersion)"
        if visionJobs.enqueueUnsafe(
            jobType: .objectEventFinalize,
            priority: priority - 1,
            photoId: nil,
            eventId: eventId,
            occasionKey: forcedOccasionKey,
            algorithmVersion: algorithmVersion,
            payload: payload,
            dedupeKey: finalizeDedupe,
            createdAt: createdAt
        ) {
            enqueued += 1
        }

        return VisionJobEnqueueSummary(enqueuedCount: enqueued, skippedReason: nil)
    }
}
