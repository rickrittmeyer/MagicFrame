import Foundation

/// Pass 2: attach no-GPS indexed photos to existing GPS-backed events (never creates events).
final class PhotoEventAssignmentService {

    private let events: EventRepository
    private let tuning: () -> EventTuningSettings

    /// Called after each batch with event IDs whose summaries were updated.
    var onBatchTouchedEvents: ((Set<Int>) -> Void)?

    init(
        events: EventRepository,
        tuning: @escaping () -> EventTuningSettings
    ) {
        self.events = events
        self.tuning = tuning
    }

    func countUnassignedMetadataPhotos() -> Int {
        events.countUnassignedMetadataPhotosForEvents()
    }

    /// Processes one batch. Returns `true` if more unassigned no-GPS photos remain.
    @discardableResult
    func syncMetadataAssignmentBatch() -> Bool {
        let settings = tuning()
        let batchLimit = settings.metadataAttachBatchSize
        let remainingBefore = events.countUnassignedMetadataPhotosForEvents()
        let photos = events.getUnassignedMetadataPhotosForEvents(limit: batchLimit)
        guard !photos.isEmpty else { return false }

        print(
            "Metadata event assignment batch: \(photos.count) photos"
            + " (\(remainingBefore.formatted()) unassigned no-GPS total)"
        )

        var touchedEventIds = Set<Int>()
        var attached = 0

        for photo in photos {
            guard let match = events.findBestMetadataAssignment(for: photo, tuning: settings) else {
                continue
            }

            events.attachPhotoToEvent(
                photoId: photo.id,
                eventId: match.eventId,
                assignmentConfidence: match.confidence,
                assignmentMethod: match.method,
                needsReview: match.needsReview
            )
            events.markPhotoEventAssigned(photoId: photo.id, needsReview: match.needsReview)
            events.expandEventDatesAfterAttach(eventId: match.eventId, photoDate: photo.date)
            touchedEventIds.insert(match.eventId)
            attached += 1
        }

        for eventId in touchedEventIds {
            events.updateEventSummary(eventId: eventId)
        }

        if !touchedEventIds.isEmpty {
            onBatchTouchedEvents?(touchedEventIds)
        }

        let remainingAfter = events.countUnassignedMetadataPhotosForEvents()
        print(
            "Metadata assignment batch done: attached \(attached),"
            + " \(remainingAfter.formatted()) no-GPS still unassigned"
        )

        return remainingAfter > 0
    }

    /// Runs metadata attach batches until none remain or a batch attaches nothing (avoids infinite rescans).
    func syncMetadataAssignmentUntilComplete() {
        var batches = 0
        var stalled = false

        while true {
            let remainingBefore = events.countUnassignedMetadataPhotosForEvents()
            guard remainingBefore > 0 else { break }

            _ = syncMetadataAssignmentBatch()
            batches += 1

            let remainingNow = events.countUnassignedMetadataPhotosForEvents()
            if remainingNow == 0 {
                break
            }
            if remainingNow >= remainingBefore {
                stalled = true
                break
            }
        }

        if batches == 0 {
            print("No unassigned no-GPS photos for metadata assignment")
        } else if stalled {
            let left = events.countUnassignedMetadataPhotosForEvents()
            print(
                "Metadata event assignment stopped after \(batches) batch(es);"
                + " \(left.formatted()) no-GPS still unassigned (no metadata match)"
            )
        } else {
            print("Metadata event assignment finished in \(batches) batch(es)")
        }
    }
}
