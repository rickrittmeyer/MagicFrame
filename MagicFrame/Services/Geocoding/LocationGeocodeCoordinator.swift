import CoreLocation
import Foundation
import MapKit

/// Database callbacks used by the sequential reverse-geocoding queue.
protocol LocationGeocodeStore: AnyObject {
    func fetchPendingGeocodeLocations(limit: Int?) -> [PendingLocation]
    func fetchEventLocationsNeedingGeocode(limit: Int?) -> [PendingLocation]
    func tryCopyNearbyGeocode(locationId: Int, latitude: Double, longitude: Double) -> Bool
    func completeLocationGeocode(
        locationId: Int,
        city: String?,
        state: String?,
        placeName: String?
    )
    func markLocationGeocodeFailed(locationId: Int)
    func countPendingGeocodeLocations() -> Int
}

/// Throttled, sequential reverse-geocoding queue for location rows.
final class LocationGeocodeCoordinator {

    static let shared = LocationGeocodeCoordinator()

    private let store: LocationGeocodeStore
    private let interRequestDelay: TimeInterval = 1.25
    private let maxRetries = 5
    private let baseRetryDelay: TimeInterval = 3.0
    private let geocodeTimeout: TimeInterval = 45
    private let progressLogInterval = 25

    private var queue: [PendingLocation] = []
    private var queuedIds = Set<Int>()
    private var isProcessing = false
    private var retryCounts: [Int: Int] = [:]
    private var inFlightLocation: PendingLocation?
    private var processedSinceLog = 0
    private var geocodeTimeoutWorkItem: DispatchWorkItem?
    private var lastProgressPost = Date.distantPast
    private var inFlightRequest: MKReverseGeocodingRequest?

    init(store: LocationGeocodeStore? = nil) {
        self.store = store ?? AppDependencies.container.photoDatabase
    }

    /// Halts the in-memory queue — use when geocoding is starving the UI.
    func stopAll() {
        geocodeTimeoutWorkItem?.cancel()
        geocodeTimeoutWorkItem = nil
        inFlightRequest?.cancel()
        inFlightRequest = nil
        queue.removeAll()
        queuedIds.removeAll()
        retryCounts.removeAll()
        inFlightLocation = nil
        processedSinceLog = 0
        isProcessing = false
        lastProgressPost = .distantPast
        print("Geocode queue: stopped")
        postProgress(isProcessing: false)
    }

    func enqueueAllPendingFromDatabase() {
        enqueue(store.fetchPendingGeocodeLocations(limit: nil))
    }

    func enqueueEventLocationsMissingDetails(limit: Int?) {
        enqueue(store.fetchEventLocationsNeedingGeocode(limit: limit))
    }

    /// Restarts processing when the queue stalled (e.g. after backgrounding or XPC drop).
    func resumeIfNeeded() {
        if isProcessing, let location = inFlightLocation {
            print("Geocode queue: resuming interrupted request for location \(location.locationId)")
            inFlightRequest?.cancel()
            clearInFlight()
            queue.insert(location, at: 0)
            isProcessing = false
        } else if isProcessing, inFlightLocation == nil, queue.isEmpty {
            isProcessing = false
        }

        guard !queue.isEmpty || inFlightLocation != nil else {
            if isProcessing {
                finishProcessing()
            }
            return
        }

        startProcessingIfNeeded()
    }

    func enqueue(_ locations: [PendingLocation]) {
        guard !locations.isEmpty else { return }

        var added = 0
        for location in locations {
            guard !queuedIds.contains(location.locationId) else { continue }
            queuedIds.insert(location.locationId)
            queue.append(location)
            added += 1
        }

        guard added > 0 else {
            startProcessingIfNeeded()
            return
        }

        print("Geocode queue: added \(added), total queued \(queue.count)")
        startProcessingIfNeeded()
    }

    private func startProcessingIfNeeded() {
        guard !isProcessing else {
            postProgress(isProcessing: true)
            return
        }

        isProcessing = true
        processNext()
    }

    private func processNext() {
        if queue.isEmpty {
            refillQueueFromDatabase()
        }

        guard !queue.isEmpty else {
            finishProcessing()
            return
        }

        postProgress(isProcessing: true)

        let location = queue.removeFirst()

        if store.tryCopyNearbyGeocode(
            locationId: location.locationId,
            latitude: location.latitude,
            longitude: location.longitude
        ) {
            queuedIds.remove(location.locationId)
            retryCounts.removeValue(forKey: location.locationId)
            print("Copied nearby geocode for location \(location.locationId)")
            noteProcessedLocation()
            scheduleNext(after: 0.05)
            return
        }

        inFlightLocation = location
        scheduleGeocodeTimeout()

        let clLocation = CLLocation(latitude: location.latitude, longitude: location.longitude)
        guard let request = MKReverseGeocodingRequest(location: clLocation) else {
            handleGeocodeResponse(location: location, mapItems: nil, error: nil)
            return
        }

        inFlightRequest = request
        Task { [weak self] in
            do {
                let mapItems = try await request.mapItems
                self?.handleGeocodeResponse(location: location, mapItems: mapItems, error: nil)
            } catch {
                self?.handleGeocodeResponse(location: location, mapItems: nil, error: error)
            }
        }
    }

    private func scheduleGeocodeTimeout() {
        geocodeTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleGeocodeTimeout()
        }
        geocodeTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + geocodeTimeout, execute: workItem)
    }

    private func clearInFlight() {
        geocodeTimeoutWorkItem?.cancel()
        geocodeTimeoutWorkItem = nil
        inFlightRequest?.cancel()
        inFlightRequest = nil
        inFlightLocation = nil
    }

    private func handleGeocodeTimeout() {
        guard let location = inFlightLocation else { return }

        print("Geocode timeout for location \(location.locationId)")
        inFlightRequest?.cancel()
        clearInFlight()

        let attempt = retryCounts[location.locationId, default: 0]
        if attempt < maxRetries {
            retryCounts[location.locationId] = attempt + 1
            queue.insert(location, at: 0)
            scheduleNext(after: baseRetryDelay)
            return
        }

        store.markLocationGeocodeFailed(locationId: location.locationId)
        queuedIds.remove(location.locationId)
        retryCounts.removeValue(forKey: location.locationId)
        noteProcessedLocation()
        scheduleNext(after: interRequestDelay)
    }

    private func refillQueueFromDatabase() {
        let pending = store.fetchPendingGeocodeLocations(limit: 100)
        for location in pending where !queuedIds.contains(location.locationId) {
            queuedIds.insert(location.locationId)
            queue.append(location)
        }
    }

    private func handleGeocodeResponse(
        location: PendingLocation,
        mapItems: [MKMapItem]?,
        error: Error?
    ) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            let nextDelay: TimeInterval = await self.processGeocodeResult(
                location: location,
                mapItems: mapItems,
                error: error
            )

            await MainActor.run {
                self.scheduleNext(after: nextDelay)
            }
        }
    }

    private func processGeocodeResult(
        location: PendingLocation,
        mapItems: [MKMapItem]?,
        error: Error?
    ) async -> TimeInterval {
        let stillCurrent = await MainActor.run {
            guard inFlightLocation?.locationId == location.locationId else { return false }
            clearInFlight()
            return true
        }

        guard stillCurrent else { return interRequestDelay }

        if let mapItem = mapItems?.first {
            let city = ReverseGeocodeParser.geocodedCity(from: mapItem)
            let state = ReverseGeocodeParser.administrativeArea(from: mapItem)
            store.completeLocationGeocode(
                locationId: location.locationId,
                city: city,
                state: state,
                placeName: ReverseGeocodeParser.placeLabel(from: mapItem)
            )
            await MainActor.run {
                queuedIds.remove(location.locationId)
                retryCounts.removeValue(forKey: location.locationId)
            }
            print(
                "Geocoded location \(location.locationId): \(city ?? "nil"), \(state ?? "nil")"
            )
            await MainActor.run {
                noteProcessedLocation()
            }
            return interRequestDelay
        }

        if let error, isRetryableGeocodeError(error) {
            let attempt = await MainActor.run {
                retryCounts[location.locationId, default: 0]
            }
            if attempt < maxRetries {
                await MainActor.run {
                    retryCounts[location.locationId] = attempt + 1
                    queue.insert(location, at: 0)
                }
                let delay = baseRetryDelay * pow(2.0, Double(attempt))
                print(
                    "Geocode retry \(attempt + 1)/\(maxRetries) for location \(location.locationId) in \(Int(delay))s: \(error.localizedDescription)"
                )
                return delay
            }
        }

        let message = error?.localizedDescription ?? "no map item returned"
        print("Geocode failed for location \(location.locationId): \(message)")
        store.markLocationGeocodeFailed(locationId: location.locationId)
        await MainActor.run {
            queuedIds.remove(location.locationId)
            retryCounts.removeValue(forKey: location.locationId)
            noteProcessedLocation()
        }
        return interRequestDelay
    }

    private func noteProcessedLocation() {
        processedSinceLog += 1
        guard processedSinceLog % progressLogInterval == 0 else { return }

        let pending = store.countPendingGeocodeLocations()
        print(
            "Geocode progress: \(pending.formatted()) pending in database,"
            + " \(queue.count.formatted()) in queue"
        )
    }

    private func scheduleNext(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.processNext()
        }
    }

    private func finishProcessing() {
        clearInFlight()
        isProcessing = false
        processedSinceLog = 0
        postProgress(isProcessing: false)
        print("Geocode queue finished")
    }

    private func postProgress(isProcessing: Bool) {
        let now = Date()
        guard isProcessing == false
            || now.timeIntervalSince(lastProgressPost) >= 2.0 else {
            return
        }
        lastProgressPost = now

        let pending = store.countPendingGeocodeLocations()
        let progress = LocationGeocodeProgress(
            queueCount: queue.count,
            isProcessing: isProcessing,
            pendingInDatabase: pending
        )

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .locationGeocodeProgressChanged,
                object: progress
            )
        }
    }

    private func isRetryableGeocodeError(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == kCLErrorDomain {
            switch CLError.Code(rawValue: nsError.code) {
            case .network, .locationUnknown:
                return true
            case .geocodeFoundNoResult, .geocodeFoundPartialResult:
                return false
            default:
                return true
            }
        }

        if nsError.domain == "GEOErrorDomain" {
            return true
        }

        return true
    }
}

extension PhotoDatabase: LocationGeocodeStore {}
