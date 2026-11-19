import SwiftUI

struct LocationsView: View {

    @StateObject private var vm = LocationsViewModel()
    @EnvironmentObject private var libraryVM: LibraryViewModel

    var body: some View {
        Group {
            if vm.filteredLocations.isEmpty {
                if vm.searchText.isEmpty {
                    ContentUnavailableView(
                        "No Locations",
                        systemImage: "mappin.and.ellipse",
                        description: Text(
                            "Locations appear after geotagged photos are indexed and grouped into events. "
                            + "If the home screen is empty, open Developer → Index Photos, then Sync Events."
                        )
                    )
                } else {
                    ContentUnavailableView.search(text: vm.searchText)
                }
            } else {
                List(vm.filteredLocations) { location in
                    locationRow(location)
                }
            }
        }
        .navigationTitle("Locations")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $vm.searchText, prompt: "Search locations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text(vm.listStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            libraryVM.setMainTabChromeMode(.landing)
            vm.onAppear()
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
        .alert("Rename Location", isPresented: $vm.isRenamingLocation) {
            TextField("Your name", text: $vm.renameText)
            Button("Save") {
                vm.saveRenamedLocation()
            }
            Button("Clear", role: .destructive) {
                vm.renameText = ""
                vm.saveRenamedLocation()
            }
            Button("Cancel", role: .cancel) {
                vm.isRenamingLocation = false
            }
        } message: {
            Text("Give this place a name you'll recognize on the frame.")
        }
    }

    @ViewBuilder
    private func locationRow(_ location: ManagedLocation) -> some View {
        HStack(alignment: .top, spacing: 12) {

            NavigationLink {
                LocationDetailView(locationId: location.locationId)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(location.displayTitle)
                                .font(.headline)

                            if location.isCurrentHome {
                                Text("Current Home")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .clipShape(Capsule())
                            } else if location.isFormerHome {
                                Text("Former Home")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }

                        if let occupancy = location.homeOccupancySummary {
                            Text(occupancy)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if let subtitle = location.detailSubtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Text("\(location.eventCount) events")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    typeMenu(for: location)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                vm.toggleLocationFavorite(locationId: location.locationId)
            } label: {
                Image(
                    systemName: location.isFavorite
                        ? "star.fill"
                        : "star"
                )
                .foregroundStyle(location.isFavorite ? .yellow : .secondary)
                .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                location.isFavorite
                    ? "Favorite location"
                    : "Mark location as favorite"
            )
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Rename location") {
                vm.beginRenaming(location: location)
            }
        }
    }

    @ViewBuilder
    private func typeMenu(for location: ManagedLocation) -> some View {
        Menu {
            Button("Unset type") {
                vm.setLocationType(locationId: location.locationId, type: nil)
            }

            Divider()

            ForEach(vm.typeOptions, id: \.self) { type in
                Button(type) {
                    vm.setLocationType(
                        locationId: location.locationId,
                        type: type
                    )
                }
            }

            Divider()

            Button("Add type...") {
                vm.beginAddingType()
            }
        } label: {
            HStack(spacing: 6) {
                Text("Type:")
                    .foregroundStyle(.secondary)
                Text(location.locationType ?? "Unset")
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}
