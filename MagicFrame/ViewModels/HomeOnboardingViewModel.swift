import Foundation
import Combine
import CoreLocation
import MapKit

@MainActor
final class HomeOnboardingViewModel: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published var addressQuery = ""
    @Published var nickname = ""
    @Published var homeStartDate = Calendar.current.date(
        byAdding: .year,
        value: -5,
        to: Date()
    ) ?? Date()
    @Published private(set) var pinCoordinate: CLLocationCoordinate2D?
    @Published var mapSpan = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    @Published var mapFocusToken = 0
    @Published var resolvedAddress: String?
    @Published var hasConfirmedHomePin = false
    @Published var isLocating = false
    @Published var statusText = "Finding your location…"
    @Published var isSearching = false
    @Published var isSaving = false
    @Published var errorMessage: String?

    private var inFlightGeocodeRequest: MKGeocodingRequest?
    private var inFlightReverseGeocodeRequest: MKReverseGeocodingRequest?
    private let locationManager = CLLocationManager()
    private let database: any MagicFrameDatabase

    var canContinue: Bool {
        !isSaving && !isSearching && !isLocating && hasConfirmedHomePin && pinCoordinate != nil
    }

    init(database: any MagicFrameDatabase = AppDependencies.database) {
        self.database = database
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func onAppear() {
        beginLocationLookup()
    }

    func searchAddress() {
        let query = addressQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            errorMessage = "Enter a street address to search."
            return
        }

        guard let request = MKGeocodingRequest(addressString: query) else {
            errorMessage = "Could not start address lookup."
            return
        }

        inFlightGeocodeRequest?.cancel()
        inFlightGeocodeRequest = request
        isSearching = true
        errorMessage = nil
        statusText = "Looking up address…"

        Task {
            do {
                let mapItems = try await request.mapItems
                guard inFlightGeocodeRequest === request else { return }

                isSearching = false
                inFlightGeocodeRequest = nil

                if let mapItem = mapItems.first,
                   let coordinate = PhotoDatabase.coordinate(from: mapItem) {
                    movePin(to: coordinate)
                    confirmHomePin(
                        resolvedAddress: PhotoDatabase.geocodedFormattedAddress(from: mapItem),
                        status: "Confirm the pin is on your home, then continue."
                    )
                    return
                }

                errorMessage = "Address not found."
                statusText = "Try a more specific address."
            } catch {
                guard inFlightGeocodeRequest === request else { return }

                isSearching = false
                inFlightGeocodeRequest = nil
                errorMessage = error.localizedDescription
                statusText = "Try a more specific address."
            }
        }
    }

    func centerOnCurrentLocation() {
        errorMessage = nil
        beginLocationLookup(forceRefresh: true)
    }

    func updatePinFromMapRegion(_ region: MKCoordinateRegion) {
        guard hasConfirmedHomePin else { return }
        pinCoordinate = region.center
        mapSpan = region.span
    }

    func saveCurrentHome() async -> Bool {
        guard let pinCoordinate else {
            errorMessage = "Pick your home on the map first."
            return false
        }

        isSaving = true
        errorMessage = nil
        statusText = "Saving Current Home…"
        defer { isSaving = false }

        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let nicknameValue = trimmedNickname.isEmpty ? nil : trimmedNickname

        let locationId = database.createDesignatedCurrentHome(
            latitude: pinCoordinate.latitude,
            longitude: pinCoordinate.longitude,
            nickname: nicknameValue,
            homeStartDate: homeStartDate
        )

        guard locationId > 0 else {
            errorMessage = "Could not save home location."
            statusText = "Try again or pick a different spot."
            return false
        }

        statusText = "Current Home saved."
        return true
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                requestFreshLocation()
            case .denied, .restricted:
                finishLocationLookupWithoutFix(
                    message: "Location access is off. Search your home address instead."
                )
            case .notDetermined:
                break
            @unknown default:
                finishLocationLookupWithoutFix(
                    message: "Search your home address to continue."
                )
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            applyDeviceLocation(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let cached = manager.location {
                applyDeviceLocation(cached)
                return
            }

            finishLocationLookupWithoutFix(
                message: "Could not find your location. Search your home address instead."
            )
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private

    private func beginLocationLookup(forceRefresh: Bool = false) {
        if hasConfirmedHomePin, !forceRefresh { return }

        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            requestFreshLocation()
        case .notDetermined:
            isLocating = true
            statusText = "Finding your location…"
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finishLocationLookupWithoutFix(
                message: "Location access is off. Search your home address instead."
            )
        @unknown default:
            finishLocationLookupWithoutFix(
                message: "Search your home address to continue."
            )
        }
    }

    private func requestFreshLocation() {
        isLocating = true
        errorMessage = nil
        statusText = "Finding your location…"
        locationManager.requestLocation()
    }

    private func applyDeviceLocation(_ location: CLLocation) {
        isLocating = false
        movePin(to: location.coordinate)

        guard let request = MKReverseGeocodingRequest(location: location) else {
            confirmHomePin(
                resolvedAddress: nil,
                status: "Using your current location. Search by address if this is not your home."
            )
            return
        }

        inFlightReverseGeocodeRequest?.cancel()
        inFlightReverseGeocodeRequest = request

        Task {
            do {
                let mapItems = try await request.mapItems
                guard inFlightReverseGeocodeRequest === request else { return }

                inFlightReverseGeocodeRequest = nil
                let address = mapItems.first.map { PhotoDatabase.geocodedFormattedAddress(from: $0) }
                confirmHomePin(
                    resolvedAddress: address,
                    status: "Using your current location. Search by address if this is not your home."
                )
            } catch {
                guard inFlightReverseGeocodeRequest === request else { return }

                inFlightReverseGeocodeRequest = nil
                confirmHomePin(
                    resolvedAddress: nil,
                    status: "Using your current location. Search by address if this is not your home."
                )
            }
        }
    }

    private func finishLocationLookupWithoutFix(message: String) {
        isLocating = false
        statusText = message
    }

    private func confirmHomePin(resolvedAddress: String?, status: String) {
        hasConfirmedHomePin = true
        self.resolvedAddress = resolvedAddress
        statusText = status
        errorMessage = nil
    }

    private func movePin(to coordinate: CLLocationCoordinate2D) {
        pinCoordinate = coordinate
        mapSpan = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        mapFocusToken += 1
    }
}
