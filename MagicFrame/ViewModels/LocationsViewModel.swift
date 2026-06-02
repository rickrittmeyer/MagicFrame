import Foundation
import Combine

@MainActor
final class LocationsViewModel: ObservableObject {

    @Published var locations: [ManagedLocation] = []
    @Published var typeOptions: [String] = []
    @Published var statusText: String = "Ready"

    @Published var isAddingType = false
    @Published var newTypeName: String = ""

    @Published var isRenamingLocation = false
    @Published var renameText: String = ""
    @Published var searchText: String = ""
    private var renamingLocationId: Int?

    var filteredLocations: [ManagedLocation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return locations }

        return locations.filter { $0.matchesSearch(query) }
    }

    var listStatusText: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return statusText }

        return "\(filteredLocations.count) of \(locations.count)"
    }

    private var baseStatusText = "Ready"
    private var isShowingGeocodeProgress = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .locationGeocodeProgressChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let progress = notification.object as? LocationGeocodeProgress else {
                    return
                }
                self.handleGeocodeProgress(progress)
            }
            .store(in: &cancellables)
    }

    func onAppear() {
        loadLocations()
        scheduleBackgroundGeocodeIfNeeded()
    }

    func loadLocations() {
        locations = PhotoDatabase.shared.getLocationsRankedByEventCount()
        typeOptions = PhotoDatabase.shared.getLocationTypeOptions()
        setBaseStatus("\(locations.count) locations")
    }

    private func handleGeocodeProgress(_ progress: LocationGeocodeProgress) {
        if progress.isActive {
            isShowingGeocodeProgress = true
            statusText = "Geocoding \(progress.displayRemaining) remaining…"
        } else if isShowingGeocodeProgress {
            isShowingGeocodeProgress = false
            locations = PhotoDatabase.shared.getLocationsRankedByEventCount()
            setBaseStatus("\(locations.count) locations")
        }
    }

    private func setBaseStatus(_ text: String) {
        baseStatusText = text
        if !isShowingGeocodeProgress {
            statusText = text
        }
    }

    private func scheduleBackgroundGeocodeIfNeeded() {
        let pendingCount = PhotoDatabase.shared.locationsNeedingGeocodeCount()
        guard pendingCount > 0 else { return }

        // Geocode in small batches on demand — avoids locking up the app after import.
        PhotoDatabase.shared.startGeocodingEventLocations(limit: 40)
    }

    func setLocationType(locationId: Int, type: String?) {
        PhotoDatabase.shared.updateLocationType(locationId: locationId, locationType: type)

        guard let index = locations.firstIndex(where: { $0.locationId == locationId }) else {
            return
        }

        let location = locations[index]
        locations[index] = ManagedLocation(
            locationId: location.locationId,
            nickname: location.nickname,
            placeName: location.placeName,
            city: location.city,
            state: location.state,
            locationType: type,
            isFavorite: location.isFavorite,
            eventCount: location.eventCount,
            latitude: location.latitude,
            longitude: location.longitude,
            isCurrentHome: location.isCurrentHome,
            homeStartDate: location.homeStartDate,
            homeEndDate: location.homeEndDate
        )
    }

    func toggleLocationFavorite(locationId: Int) {
        guard let index = locations.firstIndex(where: { $0.locationId == locationId }) else {
            return
        }

        let location = locations[index]
        let newValue = !location.isFavorite

        PhotoDatabase.shared.setLocationFavorite(locationId: locationId, isFavorite: newValue)

        locations[index] = ManagedLocation(
            locationId: location.locationId,
            nickname: location.nickname,
            placeName: location.placeName,
            city: location.city,
            state: location.state,
            locationType: location.locationType,
            isFavorite: newValue,
            eventCount: location.eventCount,
            latitude: location.latitude,
            longitude: location.longitude,
            isCurrentHome: location.isCurrentHome,
            homeStartDate: location.homeStartDate,
            homeEndDate: location.homeEndDate
        )
    }

    func beginRenaming(location: ManagedLocation) {
        renamingLocationId = location.locationId
        renameText = location.nickname ?? ""
        isRenamingLocation = true
    }

    func saveRenamedLocation() {
        guard let locationId = renamingLocationId else {
            isRenamingLocation = false
            return
        }

        PhotoDatabase.shared.updateLocationNickname(
            locationId: locationId,
            nickname: renameText
        )

        if let index = locations.firstIndex(where: { $0.locationId == locationId }) {
            let location = locations[index]
            let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            let nickname = trimmed.isEmpty ? nil : trimmed

            locations[index] = ManagedLocation(
                locationId: location.locationId,
                nickname: nickname,
                placeName: location.placeName,
                city: location.city,
                state: location.state,
                locationType: location.locationType,
                isFavorite: location.isFavorite,
                eventCount: location.eventCount,
                latitude: location.latitude,
                longitude: location.longitude,
                isCurrentHome: location.isCurrentHome,
                homeStartDate: location.homeStartDate,
                homeEndDate: location.homeEndDate
            )
        }

        renamingLocationId = nil
        renameText = ""
        isRenamingLocation = false
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
        newTypeName = ""
        isAddingType = false
    }
}

private extension ManagedLocation {

    func matchesSearch(_ query: String) -> Bool {
        let needle = query.lowercased()
        let fields = [
            nickname,
            placeName,
            city,
            state,
            locationType,
            displayTitle,
            detailSubtitle,
            cityStateLine,
            homeOccupancySummary,
            isCurrentHome ? "current home" : nil,
            isFormerHome ? "former home" : nil
        ]

        return fields.contains { field in
            field?.lowercased().contains(needle) == true
        }
    }
}
