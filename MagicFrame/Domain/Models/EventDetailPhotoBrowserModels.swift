import Foundation

enum EventDetailPhotoSort: String, CaseIterable, Identifiable, Sendable {
    case dateCaptured
    case dateImported
    case cameraType
    case location

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dateCaptured: return "Date Captured"
        case .dateImported: return "Date Imported"
        case .cameraType: return "Camera Type"
        case .location: return "Location"
        }
    }
}

struct EventPhotoSortMetadata: Sendable {
    let indexedAt: String?
    let cameraMake: String?
    let cameraModel: String?
    let locationId: Int?

    var cameraLabel: String {
        let make = cameraMake?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = cameraModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (make.isEmpty, model.isEmpty) {
        case (false, false):
            if model.localizedCaseInsensitiveContains(make) {
                return model
            }
            return "\(make) \(model)"
        case (false, true):
            return make
        case (true, false):
            return model
        case (true, true):
            return "Unknown Camera"
        }
    }
}

struct EventDetailPhotoSortGroup: Identifiable {
    let id: String
    let title: String
    let items: [EventPhotoDisplayItem]
}

struct EventDetailPhotoBlock: Identifiable {
    let id: String
    /// Present for trip container day sections.
    let tripSection: TripPhotoDisplaySection?
    let groups: [EventDetailPhotoSortGroup]
}
