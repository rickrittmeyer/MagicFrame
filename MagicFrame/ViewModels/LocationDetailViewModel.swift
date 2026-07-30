import Foundation
import Combine

@MainActor
final class LocationDetailViewModel: ObservableObject {

    let locationId: Int
    private let database: any MagicFrameDatabase

    @Published var location: ManagedLocation?
    @Published var userName: String = ""
    @Published var typeOptions: [String] = []
    @Published var isAddingType = false
    @Published var newTypeName = ""
    @Published var homeRole: LocationHomeRole = .none
    @Published var homeStartDate = Date()
    @Published var homeEndDate = Date()

    init(
        locationId: Int,
        database: (any MagicFrameDatabase)? = nil
    ) {
        self.locationId = locationId
        self.database = database ?? AppDependencies.database
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

        typeOptions = database.getLocationTypeOptions()
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
