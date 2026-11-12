import SwiftUI
import MapKit

struct LocationDetailView: View {

    @EnvironmentObject private var libraryVM: LibraryViewModel
    @StateObject private var vm: LocationDetailViewModel
    @State private var showsMapSheet = false
    @State private var mapPosition: MapCameraPosition = .automatic

    private let onLocationUpdated: (() -> Void)?

    init(locationId: Int, onLocationUpdated: (() -> Void)? = nil) {
        self.onLocationUpdated = onLocationUpdated
        _vm = StateObject(wrappedValue: LocationDetailViewModel(locationId: locationId))
    }

    var body: some View {
        VStack(spacing: 0) {
            locationDetailHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Events")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                EventsLibraryListContent(
                    filter: locationFilter,
                    vm: libraryVM,
                    showsPictureStyleHeader: false
                )
            }
        }
        .navigationTitle(vm.location?.displayTitle ?? "Location")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            vm.load()
        }
        .onDisappear {
            vm.saveNickname()
            vm.saveHomeDesignation()
            onLocationUpdated?()
        }
        .sheet(isPresented: $showsMapSheet) {
            if let location = vm.location {
                LocationMapSheet(
                    location: location,
                    mapPosition: $mapPosition
                )
            }
        }
        .alert("Add Location Type", isPresented: $vm.isAddingType) {
            TextField("Type name", text: $vm.newTypeName)
            Button("Add") {
                vm.saveNewType()
            }
            Button("Cancel", role: .cancel) {
                vm.isAddingType = false
            }
        } message: {
            Text("Enter a new location type for the dropdown.")
        }
    }

    private var locationFilter: EventListFilter {
        .location(
            locationId: vm.locationId,
            displayTitle: vm.location?.displayTitle ?? "Location"
        )
    }

    @ViewBuilder
    private var locationDetailHeader: some View {
        if let location = vm.location {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Your name", text: $vm.userName)
                        .font(.body.weight(.medium))
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit {
                            vm.saveNickname()
                        }

                    if let addressLine = location.addressDisplayLine {
                        Text(addressLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 12) {
                        Button {
                            vm.toggleFavorite()
                        } label: {
                            Image(systemName: location.isFavorite ? "star.fill" : "star")
                                .foregroundStyle(location.isFavorite ? .yellow : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(location.isFavorite ? "Remove favorite" : "Add favorite")

                        locationTypeMenu(location)
                    }
                }

                if location.mapCoordinate != nil {
                    Button("Map of") {
                        updateMapPosition()
                        showsMapSheet = true
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    @ViewBuilder
    private func locationTypeMenu(_ location: ManagedLocation) -> some View {
        Menu {
            Button("Unset type") {
                vm.setLocationType(nil)
            }

            Divider()

            ForEach(vm.typeOptions, id: \.self) { type in
                Button(type) {
                    vm.setLocationType(type)
                }
            }

            Divider()

            Button("Add type...") {
                vm.beginAddingType()
            }
        } label: {
            Label(
                location.locationType ?? "Set type",
                systemImage: "tag"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func updateMapPosition() {
        guard let coordinate = vm.location?.mapCoordinate else { return }

        mapPosition = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        )
    }
}

private struct LocationMapSheet: View {

    let location: ManagedLocation
    @Binding var mapPosition: MapCameraPosition
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let coordinate = location.mapCoordinate {
                    Map(position: $mapPosition) {
                        Marker(
                            location.displayTitle,
                            coordinate: CLLocationCoordinate2D(
                                latitude: coordinate.latitude,
                                longitude: coordinate.longitude
                            )
                        )
                    }
                    .mapStyle(.standard(elevation: .realistic))
                } else {
                    ContentUnavailableView(
                        "No Map Location",
                        systemImage: "map",
                        description: Text("This location does not have GPS coordinates yet.")
                    )
                }
            }
            .navigationTitle(location.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
