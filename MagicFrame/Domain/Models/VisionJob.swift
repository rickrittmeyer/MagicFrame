import Foundation

enum VisionJobType: String, Codable, Sendable {
    case objectPhotoScan
    case objectEventFinalize
    case faceMetricsScan
    case faceCropScan
    case faceRecognitionScan
}

enum VisionJobStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

struct VisionJobPayload: Codable, Sendable, Equatable {
    var targetObjectKeys: [String] = []
    var occasionKeys: [String] = []
    var includeHiddenPhotos: Bool = false
    var forceRescan: Bool = false
    /// Groups jobs for UI progress (e.g. `holiday:Christmas:2024`).
    var scopeKey: String?
}

struct VisionJob: Identifiable, Sendable, Equatable {
    let id: Int
    let jobType: VisionJobType
    let status: VisionJobStatus
    let priority: Int
    let photoId: String?
    let eventId: Int?
    let occasionKey: String?
    let algorithmVersion: Int
    let payload: VisionJobPayload
    let dedupeKey: String
    let attempts: Int
    let maxAttempts: Int
    let lastError: String?
    let createdAt: String
    let startedAt: String?
    let finishedAt: String?
}

struct VisionJobEnqueueSummary: Sendable {
    let enqueuedCount: Int
    let skippedReason: String?
}

struct VisionJobRescanEnqueueResult: Sendable {
    let taggedEventCount: Int
    let enqueuedCount: Int
    let scopeKey: String
}
