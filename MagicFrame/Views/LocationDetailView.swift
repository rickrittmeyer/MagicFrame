import SwiftUI
import MapKit

struct LocationDetailView: View {

    @StateObject private var vm: LocationDetailViewModel
    @State private var mapPosition: MapCameraPosition = .automatic

    private let onLocationUpdated: (() -> Void)?

    init(locationId: Int, onLocationUpdated: (() -> Void)? = nil) {
        self.onLocationUpdated = onLocationUpdated
        _vm = StateObject(wrappedValue: LocationDetailViewModel(locationId: locationId))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                mapSection

                nameSection

                if let location = vm.location {
                    homeSection
                    locationAddressSection(location)
                    locationMetaSection(location)
                }

                eventsSection
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(vm.location?.displayTitle ?? "Location")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            vm.load()
            updateMapPosition()
        }
        .onDisappear {
            vm.saveNickname()
            vm.saveHomeDesignation()
            onLocationUpdated?()
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

    @ViewBuilder
    private var mapSection: some View {
        if let coordinate = vm.location?.mapCoordinate {
            Map(position: $mapPosition) {
                Marker(
                    vm.location?.displayTitle ?? "Location",
                    coordinate: CLLocationCoordinate2D(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                )
            }
            .mapStyle(.standard(elevation: .realistic))
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
            .padding(.top, 8)
        } else {
            ContentUnavailableView(
                "No Map Location",
                systemImage: "map",
                description: Text("This location does not have GPS coordinates yet.")
            )
            .frame(height: 200)
            .padding(.horizontal)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your name")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            TextField("e.g. Home, Beach house, Mom's", text: $vm.userName)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .padding(.horizontal)
                .onSubmit {
                    vm.saveNickname()
                }
        }
    }

    private var homeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Home designation")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Picker("Home designation", selection: $vm.homeRole) {
                ForEach(LocationHomeRole.allCases) { role in
                    Text(role.label).tag(role)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if vm.homeRole == .current {
                DatePicker(
                    "Moved in",
                    selection: $vm.homeStartDate,
                    displayedComponents: .date
                )
                .padding(.horizontal)

                Text("Only one location can be your Current Home. Setting this replaces any other current home.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            if vm.homeRole == .former {
                DatePicker(
                    "Moved in",
                    selection: $vm.homeStartDate,
                    displayedComponents: .date
                )
                .padding(.horizontal)

                DatePicker(
                    "Moved out",
                    selection: $vm.homeEndDate,
                    in: vm.homeStartDate...,
                    displayedComponents: .date
                )
                .padding(.horizontal)

                Text("Photos from this date range use this home for trip and local grouping.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func locationAddressSection(_ location: ManagedLocation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let placeName = location.placeName, !placeName.isEmpty {
                Text(placeName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let cityState = location.cityStateLine {
                Text(cityState)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func locationMetaSection(_ location: ManagedLocation) -> some View {
        HStack {
            Button {
                vm.toggleFavorite()
            } label: {
                Label(
                    location.isFavorite ? "Favorited" : "Favorite",
                    systemImage: location.isFavorite ? "star.fill" : "star"
                )
                .foregroundStyle(location.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)

            Spacer()

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
                .font(.caption)
            }
        }
        .padding(.horizontal)

        Text("\(location.eventCount) events")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
    }

    @ViewBuilder
    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Events")
                .font(.headline)
                .padding(.horizontal)

            if vm.eventItems.isEmpty {
                Text("No events at this location.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(vm.eventItems) { item in
                        NavigationLink {
                            EventDetailView(
                                event: item.event,
                                onEventUpdated: { eventId in
                                    vm.refreshEvent(eventId: eventId)
                                },
                                onEventHidden: { eventId in
                                    vm.hideEvent(eventId: eventId)
                                },
                                onEventUnhidden: { eventId in
                                    vm.unhideEvent(eventId: eventId)
                                }
                            )
                        } label: {
                            EventLibraryRowView(
                                event: item.event,
                                slideshowPhotoIds: item.slideshowPhotoIds,
                                onHide: { vm.hideEvent(eventId: item.event.eventId) }
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }
                }
            }
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
