import Foundation

struct PhotoUploadBatch: Identifiable, Hashable {
    let id: String
    let importStart: Date
    let importEnd: Date
    let photoIds: [String]
    let samplePhotoIds: [String]
    let assignedCaptureDate: Date?
    let assignedLocationId: Int?
    let hasAssignedLocation: Bool

    var photoCount: Int { photoIds.count }

    var importDateSummary: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        let calendar = Calendar.current
        if calendar.isDate(importStart, inSameDayAs: importEnd) {
            formatter.timeStyle = .short
            let startText = formatter.string(from: importStart)
            formatter.timeStyle = .short
            let endText = DateFormatter.localizedString(
                from: importEnd,
                dateStyle: .none,
                timeStyle: .short
            )
            return "\(DateFormatter.localizedString(from: importStart, dateStyle: .medium, timeStyle: .none)) · \(startText)–\(endText)"
        }

        return "\(formatter.string(from: importStart)) – \(formatter.string(from: importEnd))"
    }

    var statusSummary: String {
        switch (assignedCaptureDate != nil, hasAssignedLocation) {
        case (true, true):
            return "Ready for events"
        case (true, false):
            return "Needs location"
        case (false, true):
            return "Needs date"
        case (false, false):
            return "Needs date and location"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PhotoUploadBatch, rhs: PhotoUploadBatch) -> Bool {
        lhs.id == rhs.id
    }
}
