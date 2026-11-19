//
//  DeveloperView.swift
//  MagicFrame
//

import SwiftUI

struct DeveloperView: View {

    @ObservedObject var vm: LibraryViewModel
    @State private var isConfirmingRebuild = false
    @State private var isConfirmingDevReset = false
    @State private var visionResetHolidays: [HolidayVisionLandingConfig] = []
    @State private var visionTagRangeStart = "12/1"
    @State private var visionTagRangeEnd = "12/31"
    @State private var isPreparingDatabaseExport = false
    @State private var databaseExportURL: URL?
    @State private var showDatabaseExportShare = false

    var body: some View {
        VStack(spacing: 0) {
            Text(vm.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

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

                Button {
                    Task {
                        isPreparingDatabaseExport = true
                        defer { isPreparingDatabaseExport = false }
                        if let url = await vm.exportDatabaseForSharing() {
                            databaseExportURL = url
                            showDatabaseExportShare = true
                        }
                    }
                } label: {
                    if isPreparingDatabaseExport {
                        HStack {
                            ProgressView()
                            Text("Preparing Export…")
                        }
                    } else {
                        Text("Export Database")
                    }
                }
                .disabled(isPreparingDatabaseExport || vm.isIndexingPhotos || vm.isSyncingEvents)

                Text(
                    "Creates a consistent MagicFrame-*.sqlite snapshot and opens Share. AirDrop to your Mac (works over wireless), then save to Desktop."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

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

                Button("Relink Event Locations") {
                    vm.relinkEventLocationsTapped()
                }
                .disabled(vm.isMaintainingEvents || vm.isSyncingEvents)

                Text(
                    "Assigns locationId from GPS photos without rebuilding events. Then run Geocode Recent Locations so city/state names fill in."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button("Stop Background Work", role: .destructive) {
                    vm.stopAllBackgroundWork()
                }
            }

            Section("Event dates") {
                Button("Show Event Date Diagnostics") {
                    vm.showEventDateDiagnosticsTapped()
                }

                Button("Repair Event Dates (Year Grouping)") {
                    vm.repairEventDatesTapped()
                }
                .disabled(vm.isMaintainingEvents || vm.isSyncingEvents)

                Text(
                    "Unknown Year happens when an event has no parseable start date — often trip containers after photos moved to day events. Repair recomputes dates from linked photos without rebuilding events."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Metadata (Phase B)") {
                Button("Run No-GPS Photo Assignment") {
                    vm.runMetadataAssignmentTapped()
                }
                .disabled(vm.isMaintainingEvents || vm.isSyncingEvents)

                Button("Show Metadata Assignment Counts") {
                    vm.showMetadataAssignmentCountsTapped()
                }

                Text(
                    "First tries metadata attach to GPS-backed events; then assigns remaining no-GPS photos into date/time-only events. Stops if a batch attaches nothing."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Face recognition") {
                NavigationLink("People (rebuild / name / merge)") {
                    PeopleLandingView(vm: vm)
                }

                NavigationLink("Picture Search (face-detect flag)") {
                    MediaSavedSearchesView()
                }

                Text(
                    "Face detect+embed is seeded from Picture Search results (when “Detect faces on search results” is on) and when opening events. Rebuild clusters and name/merge on the People page."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Vision tags") {
                HStack {
                    TextField("12/1", text: $visionTagRangeStart)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("–")
                        .foregroundStyle(.secondary)
                    TextField("12/31", text: $visionTagRangeEnd)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Button("Tag Photos with Vision Tag") {
                    vm.tagPhotosWithVisionTagTapped(
                        startMonthDay: visionTagRangeStart,
                        endMonthDay: visionTagRangeEnd
                    )
                }
                .disabled(vm.isMaintainingEvents || vm.isSyncingEvents || vm.isIndexingPhotos)

                NavigationLink("Search Vision Tag") {
                    VisionTagSearchResultsView()
                }

                NavigationLink("Picture Search") {
                    MediaSavedSearchesView()
                }

                NavigationLink("Event Tag Rules") {
                    EventTagRulesDeveloperView()
                }

                NavigationLink("Event Score Cards") {
                    EventScoreCardBrowserView()
                }

                NavigationLink("Event Tag Tools") {
                    EventTagToolsDeveloperView()
                }

                Text(
                    "Queries indexed photos in that month-day range for every year (e.g. 8/1–8/31 → all Augusts), newest first. Runs Apple Vision scene labels (not faces), writes every label to photo_object_tags, and sets photos.visionAnalyzed. Already analyzed photos are skipped. Stop Background Work cancels."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(
                    "Search Vision Tag type-ahead uses stored Vision labels. Pick a tag to see matching photos in a grid."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(
                    "Picture Search opens Media Saved Searches: edit name / enabled / face-detect, refine the query, and Run to show matching pictures. Candidate event IDs feed score cards."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(
                    "Event Tag Rules edits similar_event_tags (remove-AI alternatives) and event_name_templates (suggested names)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(
                    "Event Score Cards picks a tag category/value (like Event Detail), then shows or creates the date / vision / people / location scorecard AI Assist uses."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(
                    "Event Tag Tools hard-clears a tagCategory + tagValue on an event (user, AI, and rejected tombstones) for retesting AI Assist."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Holiday Vision") {
                if visionResetHolidays.isEmpty {
                    Text("No holidays with Vision object keys configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visionResetHolidays, id: \.tagValue) { holiday in
                        Button("Reset \(holiday.displayName) Vision scan state") {
                            vm.resetHolidayObjectRecognitionTapped(tagValue: holiday.tagValue)
                        }
                        .disabled(vm.isMaintainingEvents || vm.isSyncingEvents)

                        Button("Re-scan \(holiday.displayName) object recognition (all tagged)") {
                            vm.rescanHolidayObjectRecognitionTapped(tagValue: holiday.tagValue)
                        }
                        .disabled(vm.isMaintainingEvents || vm.isSyncingEvents)
                    }
                }

                NavigationLink("Vision label inspector") {
                    VisionClassificationDebugView(vm: vm)
                }

                Text(
                    "Reset clears scan completion and object detections for holiday-tagged events without running Vision. "
                        + "Re-scan runs Vision on tagged events. Expand a year in a holiday collection to trigger landing scans."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Metadata (Phase A)") {
                Button("Refresh Metadata (Albums + Filenames)") {
                    vm.refreshMetadataEnrichmentTapped()
                }
                .disabled(vm.isIndexingPhotos || vm.isRefreshingMetadata)

                Button("Show Metadata Counts") {
                    vm.showMetadataCountsTapped()
                }
                .disabled(vm.isRefreshingMetadata)

                Text(
                    "Imports PhotoKit albums and original filenames for indexed photos. Does not re-index photos or rebuild events. Counts also print in the Xcode console."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text(
                    "Dev Reset deletes the entire local database file (people names, event tags, home, searches) and recreates an empty schema. Not needed for normal upgrades."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button("Dev Reset DB (wipe all data)", role: .destructive) {
                    isConfirmingDevReset = true
                }
            }
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            visionResetHolidays = vm.holidayVisionLandingConfigs()
        }
        .confirmationDialog(
            "Rebuild all events?",
            isPresented: $isConfirmingRebuild,
            titleVisibility: .visible
        ) {
            Button("Rebuild Events", role: .destructive) {
                vm.rebuildEventsTapped()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Wipe the entire local database?",
            isPresented: $isConfirmingDevReset,
            titleVisibility: .visible
        ) {
            Button("Delete All Local Data", role: .destructive) {
                vm.events = []
                vm.eventSections = []
                vm.recentPhotos = []
                vm.statusText = "Resetting database (dev)…"
                AppDependencies.database.resetDatabaseForDevelopmentOnly()
                vm.refreshLibraryCounts()
                vm.statusText = "Dev reset complete — empty database"
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Re-groups all photos using current home and trip rules. Location nicknames and home dates are kept. Custom event names will be lost.")
        }
        .sheet(isPresented: $showDatabaseExportShare, onDismiss: {
            if let databaseExportURL {
                try? FileManager.default.removeItem(at: databaseExportURL)
            }
            databaseExportURL = nil
        }) {
            if let databaseExportURL {
                ActivityShareSheet(items: [databaseExportURL])
            }
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


            Section("No-GPS attachment (Phase B)") {
                tuningField(
                    "Metadata match window (hours)",
                    value: $settings.metadataAttachMaxGapHours,
                    hint: "How far in time to search events for no-GPS photos"
                )
                tuningField(
                    "Min confidence",
                    value: $settings.metadataAttachMinConfidence,
                    hint: "Below this, photo stays unassigned"
                )
                tuningField(
                    "Review below confidence",
                    value: $settings.metadataAttachReviewConfidence,
                    hint: "Attached photos below this are flagged for review"
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
