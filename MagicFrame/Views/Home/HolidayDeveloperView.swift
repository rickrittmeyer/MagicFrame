import SwiftUI

/// Developer tools scoped to a holiday while browsing that topic.
struct HolidayDeveloperView: View {

    let tagValue: String
    @ObservedObject var vm: LibraryViewModel

    @State private var isPreparingScorer = false
    @State private var statusMessage: String?
    @State private var scoreCardPayload: HolidayScoreCardPayload?
    @State private var showAddHoliday = false
    @State private var holidayNameOptions: [String] = []
    @State private var selectedHolidayName = ""
    @State private var showAddCustomHolidayName = false
    @State private var customHolidayNameDraft = ""
    @State private var newHolidayKind: HolidayKind = .fixed
    @State private var newFixedMonth = 1
    @State private var newFixedDay = 1
    @State private var newFloatingMonth = 1
    @State private var newFloatingWeekday = 1
    @State private var newFloatingOrdinal = 1
    @State private var newIncludeWeekendsBefore = true

    private static let addNewHolidayNameSentinel = "__add_new_holiday_name__"

    private var pictureSearchName: String {
        HolidayPictureSearchDefaults.pictureSearchName(forTagValue: tagValue)
    }

    private var holidayNamePickerBinding: Binding<String> {
        Binding(
            get: { selectedHolidayName },
            set: { newValue in
                if newValue == Self.addNewHolidayNameSentinel {
                    customHolidayNameDraft = ""
                    showAddCustomHolidayName = true
                    return
                }
                selectedHolidayName = newValue
            }
        )
    }

    var body: some View {
        List {
            Section {
                Text(tagValue)
                    .font(.title2.weight(.bold))
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            Section("Holidays catalog") {
                Button("Add Holiday") {
                    prepareAddHolidaySheet()
                    showAddHoliday = true
                }
                Text("Adds a fixed or floating holiday to the shared holidays table (with year anchors).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Picture search") {
                NavigationLink {
                    MediaSavedSearchesView(preferredSearchName: pictureSearchName)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Picture Search")
                        Text("Opens Media Saved Searches with \(tagValue) preferred.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Event scoring") {
                Button {
                    Task { await openHolidayEventScorer() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(tagValue) Event Scorer")
                            Text("Runs \(tagValue) Picture Search, then opens the score card.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isPreparingScorer {
                            ProgressView()
                        }
                    }
                }
                .disabled(isPreparingScorer)

                NavigationLink {
                    HolidayEventsEntryView(tagValue: tagValue, vm: vm)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Find Potential \(tagValue) Events")
                        Text("Picture search → score candidates → Possible \(tagValue) Events list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Full developer console") {
                NavigationLink("All Developer Tools") {
                    DeveloperView(vm: vm)
                }
            }
        }
        .navigationTitle(tagValue)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddHoliday) {
            NavigationStack {
                Form {
                    Section("Holiday") {
                        Picker("Name", selection: holidayNamePickerBinding) {
                            Text("Select holiday").tag("")
                            ForEach(holidayNameOptions, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            Text("Add new…").tag(Self.addNewHolidayNameSentinel)
                        }
                        Picker("Kind", selection: $newHolidayKind) {
                            Text("Fixed date").tag(HolidayKind.fixed)
                            Text("Floating (nth weekday)").tag(HolidayKind.floating)
                        }
                        Toggle("Include Fri/Sat before", isOn: $newIncludeWeekendsBefore)
                    }

                    if newHolidayKind == .fixed {
                        Section("Fixed date") {
                            TextField("Month (1-12)", value: $newFixedMonth, format: .number)
                                .keyboardType(.numberPad)
                            TextField("Day (1-31)", value: $newFixedDay, format: .number)
                                .keyboardType(.numberPad)
                        }
                    } else {
                        Section("Floating rule") {
                            TextField("Month (1-12)", value: $newFloatingMonth, format: .number)
                                .keyboardType(.numberPad)
                            TextField("Weekday (1=Sun…7=Sat)", value: $newFloatingWeekday, format: .number)
                                .keyboardType(.numberPad)
                            TextField("Week ordinal (1-4 or -1 last)", value: $newFloatingOrdinal, format: .number)
                                .keyboardType(.numbersAndPunctuation)
                        }
                    }
                }
                .navigationTitle("Add Holiday")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showAddHoliday = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { saveNewHoliday() }
                            .disabled(selectedHolidayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .alert("Add Holiday Name", isPresented: $showAddCustomHolidayName) {
                    TextField("Holiday name", text: $customHolidayNameDraft)
                    Button("Add") { addCustomHolidayName() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(EventAttributeField.holidayType.addCustomPrompt)
                }
            }
        }
        .navigationDestination(item: $scoreCardPayload) { payload in
            WeddingEventScoreCardView(
                title: "\(tagValue) Event Score Card",
                definition: payload.definition,
                report: payload.report,
                settings: AppDependencies.database.ensureEventScoreCardSettings(
                    for: payload.definition,
                    personNamesById: Dictionary(
                        uniqueKeysWithValues: AppDependencies.database.fetchAllPeople()
                            .map { ($0.personId, $0.name) }
                    )
                )
            )
        }
    }

    private func prepareAddHolidaySheet() {
        reloadHolidayNameOptions()
        selectedHolidayName = holidayNameOptions.contains(tagValue) ? tagValue : (holidayNameOptions.first ?? "")
        newHolidayKind = .fixed
        newFixedMonth = 1
        newFixedDay = 1
        newFloatingMonth = 1
        newFloatingWeekday = 1
        newFloatingOrdinal = 1
        newIncludeWeekendsBefore = true
        customHolidayNameDraft = ""
    }

    private func reloadHolidayNameOptions() {
        holidayNameOptions = AppDependencies.database
            .getEventAttributeOptions(for: .holidayType)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func addCustomHolidayName() {
        let trimmed = customHolidayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AppDependencies.database.addCustomEventAttributeOption(trimmed, for: .holidayType)
        reloadHolidayNameOptions()
        selectedHolidayName = holidayNameOptions.first {
            $0.compare(trimmed, options: .caseInsensitive) == .orderedSame
        } ?? trimmed
        customHolidayNameDraft = ""
    }

    private func saveNewHoliday() {
        let name = selectedHolidayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            statusMessage = "Holiday name is required."
            return
        }

        let holiday: HolidayDefinition
        switch newHolidayKind {
        case .fixed:
            guard (1...12).contains(newFixedMonth), (1...31).contains(newFixedDay) else {
                statusMessage = "Fixed holiday needs month 1–12 and day 1–31."
                return
            }
            holiday = HolidayDefinition(
                holidayId: nil,
                name: name,
                kind: .fixed,
                fixedMonth: newFixedMonth,
                fixedDay: newFixedDay,
                ruleKind: nil,
                month: nil,
                weekday: nil,
                weekOrdinal: nil,
                includeWeekendsBefore: newIncludeWeekendsBefore,
                isBuiltIn: false,
                isEnabled: true,
                sortIndex: 1000
            )
        case .floating:
            guard (1...12).contains(newFloatingMonth),
                  (1...7).contains(newFloatingWeekday),
                  newFloatingOrdinal == -1 || (1...5).contains(newFloatingOrdinal) else {
                statusMessage = "Floating holiday needs month 1–12, weekday 1–7, ordinal 1–5 or -1."
                return
            }
            holiday = HolidayDefinition(
                holidayId: nil,
                name: name,
                kind: .floating,
                fixedMonth: nil,
                fixedDay: nil,
                ruleKind: "nthWeekdayOfMonth",
                month: newFloatingMonth,
                weekday: newFloatingWeekday,
                weekOrdinal: newFloatingOrdinal == 0 ? 1 : newFloatingOrdinal,
                includeWeekendsBefore: newIncludeWeekendsBefore,
                isBuiltIn: false,
                isEnabled: true,
                sortIndex: 1000
            )
        case .computed:
            statusMessage = "Computed holidays (e.g. Easter) aren’t added from this sheet."
            return
        }

        let id = AppDependencies.database.upsertHoliday(holiday)
        showAddHoliday = false
        guard id > 0 else {
            statusMessage = "Failed to save holiday “\(name)”."
            return
        }
        statusMessage = "Saved holiday “\(name)” (id \(id)). It will appear on Holidays after refresh."
        vm.scheduleHolidayLandingRefresh()
    }

    @MainActor
    private func openHolidayEventScorer() async {
        isPreparingScorer = true
        defer { isPreparingScorer = false }
        statusMessage = "Running \(tagValue) Picture Search…"

        let result = await Task.detached(priority: .utility) {
            AppDependencies.database.runHolidayPictureSearch(tagValue: tagValue)
        }.value

        guard let result else {
            statusMessage = "No Picture Search defaults for \(tagValue)."
            return
        }

        statusMessage = result.report.summaryLine
        guard !result.report.candidateEventIds.isEmpty else {
            statusMessage = "\(result.report.summaryLine). No candidate events to score yet."
            return
        }

        scoreCardPayload = HolidayScoreCardPayload(
            definition: result.definition,
            report: result.report
        )
    }
}

private struct HolidayScoreCardPayload: Identifiable, Hashable {
    let definition: PictureSearchDefinition
    let report: PictureSearchRunReport

    var id: Int { report.pictureSearchRunId }

    static func == (lhs: HolidayScoreCardPayload, rhs: HolidayScoreCardPayload) -> Bool {
        lhs.report.pictureSearchRunId == rhs.report.pictureSearchRunId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(report.pictureSearchRunId)
    }
}
