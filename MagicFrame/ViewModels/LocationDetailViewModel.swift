import Foundation
import Combine

@MainActor
final class LocationDetailViewModel: ObservableObject {

    let locationId: Int

    @Published var location: ManagedLocation?
    @Published var userName: String = ""
    @Published var eventItems: [EventListDisplayItem] = []
    @Published var typeOptions: [String] = []
    @Published var isAddingType = false
    @Published var newTypeName = ""
    @Published var homeRole: LocationHomeRole = .none
    @Published var homeStartDate = Date()
    @Published var homeEndDate = Date()

    init(locationId: Int) {
        self.locationId = locationId
    }

    func load() {
        location = PhotoDatabase.shared.getLocation(locationId: locationId)
        userName = location?.nickname ?? ""
        homeRole = location?.homeRole ?? .none

        if let start = location?.homeStartDate.flatMap({ EventDateParser.parseDate($0) }) {
            homeStartDate = start
        }

        if let end = location?.homeEndDate.flatMap({ EventDateParser.parseDate($0) }) {
            homeEndDate = end
        } else {
            homeEndDate = Date()
        }

        rebuildEventItems()
        typeOptions = PhotoDatabase.shared.getLocationTypeOptions()
    }

    private func rebuildEventItems() {
        let events = PhotoDatabase.shared.getEventsForLocation(locationId: locationId)
        let slideshowIdsByEvent = PhotoDatabase.shared.getSlideshowPhotoIds(for: events)
        eventItems = events.map { event in
            EventListDisplayItem(
                event: event,
                slideshowPhotoIds: slideshowIdsByEvent[event.eventId] ?? []
            )
        }
    }

    func saveNickname() {
        PhotoDatabase.shared.updateLocationNickname(
            locationId: locationId,
            nickname: userName
        )
        location = PhotoDatabase.shared.getLocation(locationId: locationId)
    }

    func saveHomeDesignation() {
        let startDate: Date?
        let endDate: Date?

        switch homeRole {
        case .none:
            startDate = nil
            endDate = nil
        case .current:
            startDate = homeStartDate
            endDate = nil
        case .former:
            startDate = homeStartDate
            endDate = homeEndDate
        }

        PhotoDatabase.shared.updateLocationHomeDesignation(
            locationId: locationId,
            role: homeRole,
            homeStartDate: startDate,
            homeEndDate: endDate
        )
        load()
    }

    func setLocationType(_ type: String?) {
        PhotoDatabase.shared.updateLocationType(locationId: locationId, locationType: type)
        location = PhotoDatabase.shared.getLocation(locationId: locationId)
    }

    func toggleFavorite() {
        guard let location else { return }

        PhotoDatabase.shared.setLocationFavorite(
            locationId: locationId,
            isFavorite: !location.isFavorite
        )
        self.location = PhotoDatabase.shared.getLocation(locationId: locationId)
    }

    func refreshEvent(eventId: Int) {
        guard let index = eventItems.firstIndex(where: { $0.event.eventId == eventId }),
              let updated = PhotoDatabase.shared.getEvent(eventId: eventId) else {
            return
        }

        let slideshowIds = PhotoDatabase.shared.getSlideshowPhotoIds(for: [updated])
        eventItems[index] = EventListDisplayItem(
            event: updated,
            slideshowPhotoIds: slideshowIds[updated.eventId] ?? []
        )
    }

    func hideEvent(eventId: Int) {
        PhotoDatabase.shared.setEventUserHidden(eventId: eventId, hidden: true)
        eventItems.removeAll { $0.event.eventId == eventId }
    }

    func unhideEvent(eventId: Int) {
        PhotoDatabase.shared.setEventUserHidden(eventId: eventId, hidden: false)
        refreshEvent(eventId: eventId)
    }

    func beginAddingType() {
        newTypeName = ""
        isAddingType = true
    }

    func saveNewType() {
        let trimmed = newTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isAddingType = false
            return
        }

        PhotoDatabase.shared.addCustomLocationType(trimmed)
        typeOptions = PhotoDatabase.shared.getLocationTypeOptions()
        setLocationType(trimmed)
        newTypeName = ""
        isAddingType = false
    }
}
