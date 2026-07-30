import Foundation

/// Plans and enqueues Vision work units. Does not run Vision — the coordinator worker does.
final class VisionJobEnqueueService {

    private let database: DatabaseManager
    private let visionJobs: VisionJobRepository
    private let eventObjectRecognition: EventObjectRecognitionService
    private let eventTags: EventTagRepository

    init(
        database: DatabaseManager,
        visionJobs: VisionJobRepository,
        eventObjectRecognition: EventObjectRecognitionService,
        eventTags: EventTagRepository
    ) {
        self.database = database
        self.visionJobs = visionJobs
        self.eventObjectRecognition = eventObjectRecognition
        self.eventTags = eventTags
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
