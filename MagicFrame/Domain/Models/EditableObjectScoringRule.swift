import Foundation

struct EditableObjectScoringRule: Identifiable, Equatable, Sendable {
    let occasionId: Int
    var objectKey: String
    var score: Double

    var id: String { "\(occasionId)|\(objectKey)" }

    var displayName: String {
        OccasionObjectKeyFormatter.displayName(from: objectKey)
    }
}
