import Foundation
import Combine

@MainActor
final class LocationDetailViewModel: ObservableObject {

    let locationId: Int
    private let database: any MagicFrameDatabase

    @Published var location: ManagedLocation?
    @Published var userName: String = ""
    @Published var eventItems: [EventListDisplayItem] = []
    @Published var typeOptions: [String] = []
    @Published var isAddingType = false
    @Published var newTypeName = ""
    @Published var homeRole: LocationHomeRole = .none
    @Published var homeStartDate = Date()
    @Published var homeEndDate = Date()

    init(
        locationId: Int,
        database: any MagicFrameDatabase = AppDependencies.database
    ) {
        self.locationId = locationId
        self.database = database
    }

    func load() {
        location = database.getLocation(locationId: locationId)
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
        typeOptions = database.getLocationTypeOptions()
    }

    private func rebuildEventItems() {
        let events = database.getEventsForLocation(locationId: locationId)
        let slideshowIdsByEvent = database.getSlideshowPhotoIds(for: events)
        eventItems = events.map { event in
            EventListDisplayItem(
                event: event,
                slideshowPhotoIds: slideshowIdsByEvent[event.eventId] ?? []
            )
        }
    }

    func saveNickname() {
        database.updateLocationNickname(
            locationId: locationId,
            nickname: userName
        )
        location = database.getLocation(locationId: locationId)
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

        database.updateLocationHomeDesignation(
            locationId: locationId,
            role: homeRole,
            homeStartDate: startDate,
            homeEndDate: endDate
        )
        load()
    }

    func setLocationType(_ type: String?) {
        database.updateLocationType(locationId: locationId, locationType: type)
        location = database.getLocation(locationId: locationId)
    }

    func toggleFavorite() {
        guard let location else { return }

        database.setLocationFavorite(
            locationId: locationId,
            isFavorite: !location.isFavorite
        )
        self.location = database.getLocation(locationId: locationId)
    }

    func refreshEvent(eventId: Int) {
        guard let index = eventItems.firstIndex(where: { $0.event.eventId == eventId }),
              let updated = database.getEvent(eventId: eventId) else {
            return
        }

        let slideshowIds = database.getSlideshowPhotoIds(for: [updated])
        eventItems[index] = EventListDisplayItem(
            event: updated,
            slideshowPhotoIds: slideshowIds[updated.eventId] ?? []
        )
    }

    func hideEvent(eventId: Int) {
        database.setEventUserHidden(eventId: eventId, hidden: true)
        eventItems.removeAll { $0.event.eventId == eventId }
    }

    func unhideEvent(eventId: Int) {
        database.setEventUserHidden(eventId: eventId, hidden: false)
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

        database.addCustomLocationType(trimmed)
        typeOptions = database.getLocationTypeOptions()
        setLocationType(trimmed)
        newTypeName = ""
        isAddingType = false
    }
}
