//
//  DeveloperView.swift
//  MagicFrame
//

import SwiftUI

struct DeveloperView: View {

    @ObservedObject var vm: LibraryViewModel
    @State private var isConfirmingRebuild = false
    @State private var visionResetHolidays: [HolidayVisionLandingConfig] = []

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

            Section("Occasion scoring (holidays)") {
                NavigationLink("Edit occasions") {
                    OccasionsDeveloperView()
                }

                Button("Score Holiday Occasions (all events)") {
                    vm.scoreHolidayOccasionsTapped()
                }
                .disabled(vm.isMaintainingEvents || vm.isSyncingEvents)

                if visionResetHolidays.isEmpty {
                    Text("No holidays with object scoring rules yet.")
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

                Button("Show Occasion Scoring Counts") {
                    vm.showOccasionScoringCountsTapped()
                }

                Button("Show Top 25 Holiday Scores") {
                    vm.showTopHolidayOccasionScoresTapped()
                }

                NavigationLink("Vision label inspector") {
                    VisionClassificationDebugView(vm: vm)
                }

                Text(
                    "Edit date windows per occasion (e.g. Christmas ±10 days). Then re-score. Trip parents and day events are both included."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(
                    "Reset clears scan completion, per-photo scan records, and object detections for holiday-tagged events, then re-scores tags — without running Vision. Works for holidays with object scoring rules (Christmas, Halloween, …). Expand a year in that holiday collection to trigger landing scans."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(
                    "Re-scan Christmas clears object-scan completion on every Holiday: Christmas event, runs Vision on all photos, re-scores, and reports elapsed seconds. Use after changing Christmas object rules or thresholds."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(
                    "Vision label inspector logs the top Apple Vision classifications for a photo to the Xcode console and shows which Christmas object rules would match."
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
        } message: {
            Text("Re-groups all photos using current home and trip rules. Location nicknames and home dates are kept. Custom event names will be lost.")
        }
    }
}

private struct OccasionsDeveloperView: View {

    @State private var occasions: [EditableOccasion] = []
    @State private var objectRulesByOccasionId: [Int: [EditableObjectScoringRule]] = [:]
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                Text(
                    "Date scoring uses each occasion’s anchor day from occasion_dates, "
                    + "plus days before/after. Christmas can instead start N days after US Thanksgiving and end N days after Christmas. Re-run holiday scoring after saving."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if occasions.isEmpty {
                Section {
                    Text("No occasions in the database.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach($occasions) { $occasion in
                    Section(occasion.occasionKey) {
                        TextField("Display name", text: $occasion.name)

                        Text(occasion.occasionType)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if occasion.occasionKey == "christmas" {
                            Toggle(
                                "Window starts after Thanksgiving",
                                isOn: $occasion.usesThanksgivingRelativeStart
                            )

                            if occasion.usesThanksgivingRelativeStart {
                                Stepper(
                                    "Days after Thanksgiving: \(occasion.windowDaysAfterThanksgiving)",
                                    value: $occasion.windowDaysAfterThanksgiving,
                                    in: 0...30
                                )
                                Stepper(
                                    "Days after Christmas (end): \(occasion.windowDaysAfter)",
                                    value: $occasion.windowDaysAfter,
                                    in: 0...60
                                )
                            } else {
                                Stepper(
                                    "Days before anchor: \(occasion.windowDaysBefore)",
                                    value: $occasion.windowDaysBefore,
                                    in: 0...60
                                )
                                Stepper(
                                    "Days after anchor: \(occasion.windowDaysAfter)",
                                    value: $occasion.windowDaysAfter,
                                    in: 0...60
                                )
                            }
                        } else {
                            Stepper(
                                "Days before: \(occasion.windowDaysBefore)",
                                value: $occasion.windowDaysBefore,
                                in: 0...60
                            )
                            Stepper(
                                "Days after: \(occasion.windowDaysAfter)",
                                value: $occasion.windowDaysAfter,
                                in: 0...60
                            )
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            TextField(
                                "Weekend boost (0–0.5)",
                                value: $occasion.weekendBoost,
                                format: .number.precision(.fractionLength(2))
                            )
                            .keyboardType(.decimalPad)
                            Text("Fri / Sat / Sun in the event date range adds this to total score.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Toggle("Enabled", isOn: $occasion.isEnabled)

                        if occasion.occasionType == "holiday" {
                            Divider()

                            Text("Object scoring")
                                .font(.caption.weight(.semibold))

                            OccasionObjectRulesEditor(
                                occasionId: occasion.id,
                                rules: bindingForObjectRules(occasionId: occasion.id),
                                onSave: { rules in
                                    objectRulesByOccasionId[occasion.id] = rules
                                    saveObjectRules(for: occasion.id)
                                }
                            )
                        }
                    }
                }
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
                    AppDependencies.database.saveEditableOccasions(occasions)
                    statusMessage = "Saved. Run Score Holiday Occasions to apply new windows."
                    reload()
                }

                Button("Reload") {
                    reload()
                    statusMessage = "Reloaded from database."
                }

                Button("Apply Christmas defaults (−35 / +10 days)") {
                    applyChristmasAnchorRelativeDefaults()
                }

                Button("Apply Thanksgiving-relative Christmas window") {
                    applyChristmasThanksgivingDefaults()
                }
            }
        }
        .navigationTitle("Occasions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reload()
        }
    }

    private func reload() {
        occasions = AppDependencies.database.fetchEditableOccasions()
        var objectRules: [Int: [EditableObjectScoringRule]] = [:]
        for occasion in occasions where occasion.occasionType == "holiday" {
            objectRules[occasion.id] = AppDependencies.database.fetchObjectScoringRules(
                occasionId: occasion.id
            )
        }
        objectRulesByOccasionId = objectRules
    }

    private func bindingForObjectRules(occasionId: Int) -> Binding<[EditableObjectScoringRule]> {
        Binding(
            get: { objectRulesByOccasionId[occasionId] ?? [] },
            set: { objectRulesByOccasionId[occasionId] = $0 }
        )
    }

    private func saveObjectRules(for occasionId: Int) {
        let rules = objectRulesByOccasionId[occasionId] ?? []
        let candidateCount = AppDependencies.database.saveObjectScoringRules(
            occasionId: occasionId,
            rules: rules
        )
        if candidateCount > 0 {
            statusMessage =
                "Saved object rules. \(candidateCount) candidate "
                + "\(candidateCount == 1 ? "event" : "events") will re-scan on next open."
        } else {
            statusMessage = "Saved object rules for occasion \(occasionId)."
        }
        reload()
    }

    private func applyChristmasAnchorRelativeDefaults() {
        guard let index = occasions.firstIndex(where: { $0.occasionKey == "christmas" }) else {
            statusMessage = "No christmas occasion row found."
            return
        }
        occasions[index].usesThanksgivingRelativeStart = false
        occasions[index].windowDaysBefore = OccasionRepository.christmasWindowDaysBefore
        occasions[index].windowDaysAfter = OccasionRepository.christmasWindowDaysAfter
        occasions[index].windowDaysAfterThanksgiving = OccasionRepository.christmasDefaultDaysAfterThanksgiving
        occasions[index].weekendBoost = OccasionRepository.defaultHolidayWeekendBoost
        statusMessage = "Christmas set to −35 / +10 days and 0.10 weekend boost. Tap Save to persist."
    }

    private func applyChristmasThanksgivingDefaults() {
        guard let index = occasions.firstIndex(where: { $0.occasionKey == "christmas" }) else {
            statusMessage = "No christmas occasion row found."
            return
        }
        occasions[index].usesThanksgivingRelativeStart = true
        occasions[index].windowDaysAfterThanksgiving = OccasionRepository.christmasDefaultDaysAfterThanksgiving
        occasions[index].windowDaysAfter = OccasionRepository.christmasWindowDaysAfter
        occasions[index].weekendBoost = OccasionRepository.defaultHolidayWeekendBoost
        statusMessage =
            "Christmas set to Thanksgiving +\(OccasionRepository.christmasDefaultDaysAfterThanksgiving) "
            + "/ Christmas +\(OccasionRepository.christmasWindowDaysAfter) days. Tap Save to persist."
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

            Section("Holiday AI tags") {
                tuningField(
                    "Pre-object min total score",
                    value: $settings.holidayTagPreObjectMinTotalScore,
                    hint: "Before object recognition on the event"
                )
                tuningField(
                    "Post-object min total score",
                    value: $settings.holidayTagPostObjectMinTotalScore,
                    hint: "After object scan; requires scorable object detections"
                )
                Text(
                    "Pre-object (metadata/date): total ≥ \(String(format: "%.2f", settings.holidayTagPreObjectMinTotalScore)), "
                        + "confidence ≥ \(settings.holidayTagPreObjectMinConfidence). "
                        + "Post-object: scan must find objects, then total ≥ \(String(format: "%.2f", settings.holidayTagPostObjectMinTotalScore)), "
                        + "confidence ≥ \(settings.holidayTagPostObjectMinConfidence). "
                        + "No objects after scan removes the AI tag. Re-run Score Holiday Occasions after changing."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
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
