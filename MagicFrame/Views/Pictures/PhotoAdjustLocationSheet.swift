import MapKit
import SwiftUI

/// Pick a known place for the selected photos. All selected photos get the same location;
/// event membership is unchanged.
struct PhotoAdjustLocationSheet: View {
    let originalLabel: String
    let originalCoordinate: CLLocationCoordinate2D?
    let selectedCount: Int
    let locations: [ManagedLocation]
    let onCancel: () -> Void
    let onAdjust: (_ location: ManagedLocation) -> Void

    @State private var searchText = ""
    @State private var selectedLocationId: Int?
    @State private var mapPosition: MapCameraPosition = .automatic

    private var filteredLocations: [ManagedLocation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return locations }
        return locations.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || ($0.city?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.state?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.placeName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var selectedLocation: ManagedLocation? {
        locations.first(where: { $0.locationId == selectedLocationId })
    }

    private var canAdjust: Bool {
        guard let selectedLocation,
              selectedLocation.latitude != nil,
              selectedLocation.longitude != nil else {
            return false
        }
        return true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summarySection
                    mapSection
                    locationsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Adjust Location")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search locations")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Adjust") {
                        guard let selectedLocation else { return }
                        onAdjust(selectedLocation)
                    }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(canAdjust ? Color.accentColor : Color.gray.opacity(0.4), in: Capsule())
                    .foregroundStyle(.white)
                    .disabled(!canAdjust)
                }
            }
            .onChange(of: selectedLocationId) { _, _ in
                syncMapToSelection()
            }
            .onAppear {
                if selectedLocationId == nil,
                   let match = locations.first(where: {
                       guard let lat = $0.latitude, let lon = $0.longitude,
                             let original = originalCoordinate else { return false }
                       return abs(lat - original.latitude) < 0.0001
                           && abs(lon - original.longitude) < 0.0001
                   }) {
                    selectedLocationId = match.locationId
                }
                syncMapToSelection()
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text("Original")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(originalLabel)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            HStack(alignment: .top) {
                Text("Adjusted")
                Spacer()
                Text(selectedLocation?.displayTitle ?? "Choose a location")
                    .foregroundStyle(selectedLocation == nil ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)
            }
            Text(
                "Choose where these photos were taken. All \(selectedCount) selected photo\(selectedCount == 1 ? "" : "s") will use this location. They will stay in their current event."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var mapSection: some View {
        Group {
            if let coordinate = selectedCoordinate ?? originalCoordinate {
                Map(position: $mapPosition) {
                    Marker("Location", coordinate: coordinate)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(height: 120)
                    .overlay {
                        Text("Select a location to preview on the map")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
            }
        }
    }

    private var locationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if locations.isEmpty {
                Text(
                    "No saved locations with GPS yet. Add locations from the Locations screen, or index geotagged photos first."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(16)
            } else if filteredLocations.isEmpty {
                Text("No locations match “\(searchText)”.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ForEach(Array(filteredLocations.enumerated()), id: \.element.locationId) { index, location in
                    Button {
                        selectedLocationId = location.locationId
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.displayTitle)
                                    .foregroundStyle(.primary)
                                if let subtitle = locationSubtitle(location) {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if location.locationId == selectedLocationId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < filteredLocations.count - 1 {
                        Divider()
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var selectedCoordinate: CLLocationCoordinate2D? {
        guard let lat = selectedLocation?.latitude,
              let lon = selectedLocation?.longitude else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func locationSubtitle(_ location: ManagedLocation) -> String? {
        if let cityState = location.cityStateLine, cityState != location.displayTitle {
            return cityState
        }
        if let place = location.placeName, place != location.displayTitle {
            return place
        }
        return nil
    }

    private func syncMapToSelection() {
        guard let coordinate = selectedCoordinate ?? originalCoordinate else { return }
        mapPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )
        )
    }
}
