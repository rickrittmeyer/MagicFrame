//
//  DeveloperView.swift
//  MagicFrame
//

import SwiftUI

struct DeveloperView: View {

    @ObservedObject var vm: LibraryViewModel
    @State private var isConfirmingRebuild = false

    var body: some View {
        List {
            Section("Library") {
                Button("Index Photos") {
                    Task {
                        await vm.indexPhotosFromLibrary()
                    }
                }
                .disabled(vm.isIndexingPhotos)

                Button("Sync Events") {
                    vm.syncEventsTapped()
                }
                .disabled(vm.isSyncingEvents || vm.isIndexingPhotos)

                Button("Rebuild Events", role: .destructive) {
                    isConfirmingRebuild = true
                }
                .disabled(vm.isSyncingEvents || vm.isIndexingPhotos)

                Button("Build Covers") {
                    vm.buildCoversTapped()
                }

                Button("Geocode Recent Locations (40)") {
                    vm.geocodeNextLocationsBatch()
                }

                Button("Deduplicate Locations") {
                    vm.deduplicateLocationsTapped()
                }
                .disabled(vm.isMaintainingEvents || vm.isSyncingEvents)

                Button("Stop Background Work", role: .destructive) {
                    vm.stopAllBackgroundWork()
                }
            }

            Section("Event tuning") {
                NavigationLink("Matching & merge settings") {
                    EventTuningDeveloperView()
                }
            }

            Section("Browse") {
                Button("Show Events") {
                    vm.showEventsTapped()
                }

                Button("Show Recent Photos") {
                    vm.showRecentPhotosTapped(limit: 100)
                }

                NavigationLink("Locations") {
                    LocationsView()
                }

                NavigationLink("Archive Photos") {
                    ArchiveBatchesView(
                        vm: ArchiveBatchesViewModel(libraryViewModel: vm)
                    )
                }
            }

            Section("Danger zone") {
                Button("Dev Reset DB", role: .destructive) {
                    vm.events = []
                    vm.eventSections = []
                    vm.recentPhotos = []
                    vm.statusText = "Resetting database (dev)..."

                    AppDependencies.database.resetDatabaseForDevelopmentOnly()
                    vm.refreshLibraryCounts()

                    vm.statusText = "Dev reset complete"
                }
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Rebuild all events?",
            isPresented: $isConfirmingRebuild,
            titleVisibility: .visible
        ) {
            Button("Rebuild Events", role: .destructive) {
                vm.rebuildEventsTapped()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Re-groups all photos using current home and trip rules. Location nicknames and home dates are kept. Custom event names will be lost.")
        }
    }
}

private struct EventTuningDeveloperView: View {

    @State private var settings = EventTuningSettings.defaults
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Adjust how photos are grouped into events. Rebuild events after changing values.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Photo → event matching") {
                tuningField(
                    "Local match radius (mi)",
                    value: $settings.localEventMatchMiles,
                    hint: "Near home: max distance to join an existing event"
                )
                tuningField(
                    "Trip match radius (mi)",
                    value: $settings.tripEventMatchMiles,
                    hint: "Away from home: metro-area grouping radius"
                )
                tuningField(
                    "Away from home (mi)",
                    value: $settings.awayFromHomeMiles,
                    hint: "Beyond this distance from home uses trip rules"
                )
                tuningField(
                    "Match time window (hours)",
                    value: $settings.eventMatchMaxGapHours,
                    hint: "How far in time to search for a matching event"
                )
                tuningField(
                    "Distance weight in score",
                    value: $settings.eventMatchDistanceWeight,
                    hint: "Higher = distance matters more vs. time gap"
                )
            }

            Section("Post-sync merges") {
                tuningField(
                    "Same-day merge radius (mi)",
                    value: $settings.sameDayEventMergeMiles,
                    hint: "Merge nearby local events on the same day"
                )
                tuningField(
                    "Trip merge max gap (hours)",
                    value: $settings.tripMergeMaxGapHours,
                    hint: "Max time between away events in one trip"
                )
                tuningField(
                    "Trip sub-event radius (mi)",
                    value: $settings.tripSubEventMatchMiles,
                    hint: "Stops within a trip day"
                )
                tuningField(
                    "Trip sub-event max gap (hours)",
                    value: $settings.tripSubEventMaxGapHours,
                    hint: "Time gap for same trip-day segment"
                )
            }

            Section("Locations") {
                tuningField(
                    "Location snap radius (mi)",
                    value: $settings.locationMatchMiles,
                    hint: "GPS points merged into one location row"
                )
                tuningField(
                    "Curated location radius (mi)",
                    value: $settings.curatedLocationMatchMiles,
                    hint: "Tighter snap for named/favorite places"
                )
                tuningField(
                    "Same place name merge (mi)",
                    value: $settings.samePlaceNameMergeMiles,
                    hint: "Merge locations with matching place names"
                )
                tuningField(
                    "Address dedup radius (mi)",
                    value: $settings.addressDeduplicationMaxMiles,
                    hint: "Merge rows with same geocoded address"
                )
                tuningField(
                    "Frequent place merge (mi)",
                    value: $settings.frequentPlaceMergeMiles,
                    hint: "Radius for repeat-visit location merge"
                )
                tuningIntField(
                    "Frequent place min events",
                    value: $settings.frequentPlaceMinEvents,
                    hint: "Minimum events to treat a place as frequent"
                )
                tuningField(
                    "Home location merge (mi)",
                    value: $settings.homeLocationMergeMiles,
                    hint: "GPS drift allowed for home locations"
                )
                tuningField(
                    "Home event snap (mi)",
                    value: $settings.homeEventSnapMiles,
                    hint: "Snap nearby events to designated home"
                )
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Save") {
                    AppDependencies.database.saveEventTuningSettings(settings)
                    statusMessage = "Saved. Rebuild events to apply."
                }

                Button("Reset to defaults") {
                    settings = .defaults
                    AppDependencies.database.resetEventTuningSettings()
                    statusMessage = "Reset to defaults."
                }
            }
        }
        .navigationTitle("Event Tuning")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            settings = AppDependencies.database.getEventTuningSettings()
        }
    }

    private func tuningField(
        _ title: String,
        value: Binding<Double>,
        hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, value: value, format: .number)
                .keyboardType(.decimalPad)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tuningIntField(
        _ title: String,
        value: Binding<Int>,
        hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
