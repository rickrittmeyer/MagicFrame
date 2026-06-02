import Foundation

struct TripEventSection: Identifiable {
    let dayNumber: Int
    let childEventName: String
    let subEventId: Int
    let photos: [IndexedPhoto]

    var id: Int { subEventId }
}
