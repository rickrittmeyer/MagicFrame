import Foundation

/// Persistent SQLite-backed Vision worker. Processes small batches off the main thread.
@MainActor
final class VisionJobCoordinator {

    struct Snapshot: Sendable {
        let isProcessing: Bool
        let statusText: String?
        let pendingJobCount: Int
        let activeScopeKey: String?
        let activeEventId: Int?
    }

    private let database: DatabaseManager
    private let visionJobs: VisionJobRepository
    private let processor: VisionJobProcessor
    private let batchSize: Int
    private let idleSleepNanoseconds: UInt64

    private var workerTask: Task<Void, Never>?
    private(set) var snapshot = Snapshot(
        isProcessing: false,
        statusText: nil,
        pendingJobCount: 0,
        activeScopeKey: nil,
        activeEventId: nil
    )

    var onSnapshotChanged: (@MainActor (Snapshot) -> Void)?

    init(
        database: DatabaseManager,
        visionJobs: VisionJobRepository,
        processor: VisionJobProcessor,
        // Face scans are memory-heavy; claim one job at a time so CGImages drain between photos.
        batchSize: Int = 1,
        idleSleepMilliseconds: Int = 250
    ) {
        self.database = database
        self.visionJobs = visionJobs
        self.processor = processor
        self.batchSize = batchSize
        self.idleSleepNanoseconds = UInt64(idleSleepMilliseconds) * 1_000_000
    }

    func startIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.runWorkerLoop()
        }
    }

    func stop() {
        workerTask?.cancel()
        workerTask = nil
        publishSnapshot(
            isProcessing: false,
            statusText: nil,
            activeScopeKey: nil,
            activeEventId: nil
        )
    }

    func cancelScope(_ scopeKey: String) {
        database.sync {
            visionJobs.cancelScopeUnsafe(scopeKey: scopeKey)
        }
        refreshPendingCount()
    }

    func pendingCount(scopeKey: String? = nil, eventId: Int? = nil) -> Int {
        database.sync {
            visionJobs.countPendingUnsafe(
                scopeKey: scopeKey,
                eventId: eventId,
                algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
            )
        }
    }

    private func runWorkerLoop() async {
        publishSnapshot(isProcessing: true, statusText: nil, activeScopeKey: nil, activeEventId: nil)

        while !Task.isCancelled {
            let claimed = database.sync {
                visionJobs.claimPendingJobsUnsafe(
                    limit: batchSize,
                    algorithmVersion: PhotoObjectVisionAnalyzer.algorithmVersion
                )
            }

            refreshPendingCount()

            guard !claimed.isEmpty else {
                publishSnapshot(
                    isProcessing: false,
                    statusText: nil,
                    activeScopeKey: nil,
                    activeEventId: nil
                )
                try? await Task.sleep(nanoseconds: idleSleepNanoseconds)
                continue
            }

            publishSnapshot(isProcessing: true, statusText: "Running Vision jobs…", activeScopeKey: nil, activeEventId: nil)

            for job in claimed {
                if Task.isCancelled { break }

                publishSnapshot(
                    isProcessing: true,
                    statusText: statusText(for: job),
                    activeScopeKey: job.payload.scopeKey,
                    activeEventId: job.eventId
                )

                let result = await processor.process(job)
                let finishedAt = ISO8601DateFormatter().string(from: Date())

                database.sync {
                    if let error = result.error {
                        visionJobs.markFailedUnsafe(jobId: job.id, error: error, finishedAt: finishedAt)
                    } else {
                        visionJobs.markCompletedUnsafe(jobId: job.id, finishedAt: finishedAt)
                    }

                    if result.stoppedEarly, let eventId = job.eventId {
                        let version = PhotoObjectVisionAnalyzer.algorithmVersion
                        visionJobs.cancelPendingPhotoScansForEventUnsafe(
                            eventId: eventId,
                            algorithmVersion: version
                        )
                        visionJobs.completePendingFinalizeJobsForEventUnsafe(
                            eventId: eventId,
                            algorithmVersion: version
                        )
                    }
                }

                refreshPendingCount()
                // Longer pause lets Photos/Vision release cached decode buffers.
                if job.jobType == .faceRecognitionScan {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                await Task.yield()
            }
        }

        publishSnapshot(isProcessing: false, statusText: nil, activeScopeKey: nil, activeEventId: nil)
    }

    private func statusText(for job: VisionJob) -> String {
        switch job.jobType {
        case .objectPhotoScan:
            if let eventId = job.eventId {
                return "Scanning objects for event \(eventId)"
            }
            return "Scanning photo objects"
        case .objectEventFinalize:
            if let eventId = job.eventId {
                return "Finalizing object recognition for event \(eventId)"
            }
            return "Finalizing object recognition"
        case .faceMetricsScan:
            return "Analyzing face metrics"
        case .faceCropScan:
            return "Analyzing face crop"
        case .faceRecognitionScan:
            return "Recognizing faces"
        }
    }

    private func refreshPendingCount() {
        let pending = pendingCount()
        snapshot = Snapshot(
            isProcessing: snapshot.isProcessing,
            statusText: snapshot.statusText,
            pendingJobCount: pending,
            activeScopeKey: snapshot.activeScopeKey,
            activeEventId: snapshot.activeEventId
        )
        onSnapshotChanged?(snapshot)
    }

    private func publishSnapshot(
        isProcessing: Bool,
        statusText: String?,
        activeScopeKey: String?,
        activeEventId: Int?
    ) {
        let pending = pendingCount()
        snapshot = Snapshot(
            isProcessing: isProcessing,
            statusText: statusText,
            pendingJobCount: pending,
            activeScopeKey: activeScopeKey,
            activeEventId: activeEventId
        )
        onSnapshotChanged?(snapshot)
    }
}
