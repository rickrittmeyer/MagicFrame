import Foundation

/// Persisted Pictures search used for browsing and topic pipelines (holidays, milestones, …).
struct MediaSavedSearch: Identifiable, Equatable, Sendable, Codable {
    var mediaSavedSearchId: Int?
    var name: String
    /// `event_tags.tagCategory` (e.g. holiday / milestone).
    var targetTagCategory: String
    /// Tag value / event type (e.g. Christmas).
    var targetTagValue: String
    var query: MediaSearchQuery
    var isEnabled: Bool
    var performFaceDetect: Bool
    /// Linked `picture_searches` row for run/score-card compatibility during cutover.
    var legacyPictureSearchId: Int?
    var createdAt: String?
    var updatedAt: String?

    var id: Int { mediaSavedSearchId ?? -1 }

    init(
        mediaSavedSearchId: Int? = nil,
        name: String,
        targetTagCategory: String = "",
        targetTagValue: String = "",
        query: MediaSearchQuery,
        isEnabled: Bool = true,
        performFaceDetect: Bool = false,
        legacyPictureSearchId: Int? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.mediaSavedSearchId = mediaSavedSearchId
        self.name = name
        self.targetTagCategory = targetTagCategory
        self.targetTagValue = targetTagValue
        self.query = query
        self.isEnabled = isEnabled
        self.performFaceDetect = performFaceDetect
        self.legacyPictureSearchId = legacyPictureSearchId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func encodingQueryJSON() throws -> String {
        let data = try JSONEncoder().encode(query)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MediaSavedSearchError.encodingFailed
        }
        return json
    }

    static func decodingQueryJSON(_ json: String) throws -> MediaSearchQuery {
        guard let data = json.data(using: .utf8) else {
            throw MediaSavedSearchError.decodingFailed
        }
        return try JSONDecoder().decode(MediaSearchQuery.self, from: data)
    }
}

enum MediaSavedSearchError: Error {
    case encodingFailed
    case decodingFailed
}
