import Foundation

protocol EventRepositoryProtocol: AnyObject {
    func updateCoverPhotoForEvent(eventId: Int)
    func updateAllEventCoverPhotos()
    func backfillEventAssignedAt()
    func rebuildEventPeople()
    func setEventShowOnFrame(eventId: Int, show: Bool)
    func setEventUserHidden(eventId: Int, hidden: Bool)
    func getEventAttributeOptions(for field: EventAttributeField) -> [String]
    func addCustomEventAttributeOption(_ value: String, for field: EventAttributeField)
    func updateEventAttribute(eventId: Int, field: EventAttributeField, value: String?)
    func getEventsForLocation(locationId: Int) -> [IndexedEvent]
    @discardableResult
    func updateEventName(eventId: Int, name: String, userEdited: Bool) -> Bool
    @discardableResult
    func updateChildEventName(eventId: Int, name: String, userEdited: Bool) -> Bool
    func syncDefaultChildEventName(forSubEventId eventId: Int)
    func getEvents(includeHidden: Bool) -> [IndexedEvent]
    func getEvent(eventId: Int) -> IndexedEvent?
    func getSlideshowPhotoIds(for events: [IndexedEvent]) -> [Int: [String]]
    func setPhotoShowOnFrame(photoId: String, eventId: Int, show: Bool)
    func removePhotoFromEvent(photoId: String, eventId: Int)
    func getPhotosForEvent(eventId: Int, includeHidden: Bool) -> [IndexedPhoto]
    func setSimilarGroupPicks(groupPhotoIds: [String], pickedPhotoIds: Set<String>)
    func setPhotosShowOnFrame(photoIds: [String], show: Bool)
    func setPhotosShowOnFrame(updates: [String: Bool])
    func setPhotosHiddenInEvent(photoIds: [String], hidden: Bool)
    func getEventIdForPhoto(photoId: String) -> Int?
    func getSubEvents(parentEventId: Int) -> [IndexedEvent]
    func getTripSections(for parentEventId: Int, includeHidden: Bool) -> [TripEventSection]
    func updateEventsFromLocation(locationId: Int)
    func restoreDeletedTripContainers()
}

extension EventRepository: EventRepositoryProtocol {}
