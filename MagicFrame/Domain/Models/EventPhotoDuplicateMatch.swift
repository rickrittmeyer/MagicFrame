import Foundation

/// Metadata shown for one side of a near-identical duplicate pair.
struct EventPhotoDuplicateSideInfo: Equatable {
    let photoId: String
    let creationDate: String
    let locationLine: String
    let eventId: Int?
    let eventTitle: String?

    var dateTimeLine: String {
        PhotoPreviewLocationFormatting.dateTimeLine(from: creationDate)
    }

    var eventLine: String {
        eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Not in an event"
    }
}

/// A near-identical library copy of a photo that belongs to the current event.
struct EventPhotoDuplicateMatch: Identifiable, Equatable {
    let eventSide: EventPhotoDuplicateSideInfo
    let librarySide: EventPhotoDuplicateSideInfo
    let distance: Float

    var id: String { "\(eventSide.photoId)|\(librarySide.photoId)" }

    var eventPhotoId: String { eventSide.photoId }
    var libraryPhotoId: String { librarySide.photoId }

    /// Photo id with the later capture date, if dates are comparable and not equal.
    var photoIdWithLaterCreationDate: String? {
        guard let eventDate = EventDateParser.parseDate(eventSide.creationDate),
              let libraryDate = EventDateParser.parseDate(librarySide.creationDate) else {
            return nil
        }
        if eventDate == libraryDate { return nil }
        return eventDate > libraryDate ? eventSide.photoId : librarySide.photoId
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
