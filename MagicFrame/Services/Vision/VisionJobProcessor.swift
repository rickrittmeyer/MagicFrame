import Foundation

struct VisionJobProcessResult: Sendable {
    let completed: Bool
    let stoppedEarly: Bool
    let statusText: String?
    let error: String?
}

/// Executes a single claimed Vision job (Vision API + DB writes).
final class VisionJobProcessor {

    private let database: DatabaseManager
    private let eventObjectRecognition: EventObjectRecognitionService
    private let faceRecognition: FaceRecognitionService

    init(
        database: DatabaseManager,
        eventObjectRecognition: EventObjectRecognitionService,
        faceRecognition: FaceRecognitionService
    ) {
        self.database = database
        self.eventObjectRecognition = eventObjectRecognition
        self.faceRecognition = faceRecognition
    }

    func process(_ job: VisionJob) async -> VisionJobProcessResult {
        switch job.jobType {
        case .objectPhotoScan:
            return await processObjectPhotoScan(job)
        case .objectEventFinalize:
            return await processObjectEventFinalize(job)
        case .faceRecognitionScan:
            return await processFaceRecognitionScan(job)
        case .faceMetricsScan, .faceCropScan:
            return VisionJobProcessResult(
                completed: true,
                stoppedEarly: false,
                statusText: nil,
                error: "Job type not implemented yet: \(job.jobType.rawValue)"
            )
        }
    }

    private func processFaceRecognitionScan(_ job: VisionJob) async -> VisionJobProcessResult {
        guard let photoId = job.photoId else {
            return VisionJobProcessResult(
                completed: true,
                stoppedEarly: false,
                statusText: nil,
                error: "Missing photoId"
            )
        }

        // Keep Vision/CGImage intermediates off the long-lived job stack.
        let detections = await FaceRecognitionAnalyzer.analyze(assetIdentifier: photoId)
        autoreleasepool {
            faceRecognition.applyScanResult(
                photoId: photoId,
                detections: detections,
                algorithmVersion: FaceRecognitionAnalyzer.algorithmVersion
            )
        }

        return VisionJobProcessResult(
            completed: true,
            stoppedEarly: false,
            statusText: "Face recognition for photo",
            error: nil
        )
    }

    private func processObjectPhotoScan(_ job: VisionJob) async -> VisionJobProcessResult {
        guard let photoId = job.photoId, let eventId = job.eventId else {
            return VisionJobProcessResult(
                completed: true,
                stoppedEarly: false,
                statusText: nil,
                error: "Missing photoId or eventId"
            )
        }

        let detections = await PhotoObjectVisionAnalyzer.analyze(
            assetIdentifier: photoId,
            targetObjectKeys: Set(job.payload.targetObjectKeys)
        )

        let createdAt = ISO8601DateFormatter().string(from: Date())
        let outcome = database.sync { () -> (stoppedEarly: Bool, detectionCount: Int) in
            eventObjectRecognition.applyPhotoScanResultUnsafe(
                eventId: eventId,
                photoId: photoId,
                detections: detections,
                occasionKeys: job.payload.occasionKeys,
                scannedAt: createdAt
            )
        }

        let statusText = "Scanning objects for event \(eventId)"
        return VisionJobProcessResult(
            completed: true,
            stoppedEarly: outcome.stoppedEarly,
            statusText: statusText,
            error: nil
        )
    }

    private func processObjectEventFinalize(_ job: VisionJob) async -> VisionJobProcessResult {
        guard let eventId = job.eventId else {
            return VisionJobProcessResult(
                completed: true,
                stoppedEarly: false,
                statusText: nil,
                error: "Missing eventId"
            )
        }

        let createdAt = ISO8601DateFormatter().string(from: Date())
        database.sync {
            eventObjectRecognition.finalizeEventObjectRecognitionUnsafe(
                eventId: eventId,
                occasionKeys: job.payload.occasionKeys,
                completedAt: createdAt,
                stoppedEarly: false
            )
        }

        return VisionJobProcessResult(
            completed: true,
            stoppedEarly: false,
            statusText: "Finalized object recognition for event \(eventId)",
            error: nil
        )
    }
}
