import SwiftUI

/// Editable scoring weights for candidate wedding (or target-type) events from a picture search.
struct WeddingEventScoreCardView: View {

    let title: String
    let definition: PictureSearchDefinition
    let report: PictureSearchRunReport

    @State private var settings: PictureSearchEventScoreCardSettings
    @State private var people: [PeopleRepository.PersonRecord] = []
    @State private var floatingHolidays: [FloatingHolidayDefinition] = []
    @State private var locationDraft = ""
    @State private var isScoring = false
    @State private var statusMessage: String?
    @State private var checkReport: PictureSearchEventTypeCheckReport?

    init(
        title: String,
        definition: PictureSearchDefinition,
        report: PictureSearchRunReport,
        settings: PictureSearchEventScoreCardSettings
    ) {
        self.title = title
        self.definition = definition
        self.report = report
        _settings = State(initialValue: settings)
    }

    var body: some View {
        Form {
            Section {
                Text("\(settings.targetTagCategory) · \(settings.targetEventType)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Score Card")
                    .font(.headline)
                Text("Rules that score events and write AI tags. Independent from the Picture Search photo query.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            visionSection
            dateSection
            peopleSection
            locationSection
            aiThresholdSection

            Section {
                Button {
                    saveSettings()
                } label: {
                    Text("Save Score Card")
                }
                .disabled(isScoring)
            }

            Section {
                Text("Picture Search run")
                    .font(.headline)
                Text(
                    "\(report.candidateEventIds.count) candidate "
                        + (report.candidateEventIds.count == 1 ? "event" : "events")
                        + " from photo query “\(definition.name)”."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Button {
                    Task { await runScoring() }
                } label: {
                    if isScoring {
                        HStack {
                            ProgressView()
                            Text("Scoring…")
                        }
                    } else {
                        Text("Score Candidate Events")
                    }
                }
                .disabled(isScoring || report.candidateEventIds.isEmpty)
            }

            if let statusMessage {
                Section {
                    HStack(spacing: 8) {
                        if isScoring { ProgressView() }
                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let checkReport, !checkReport.eventScores.isEmpty {
                Section("\(checkReport.targetEventType) scores") {
                    ForEach(checkReport.eventScores.prefix(40)) { score in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Event \(score.eventId)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(String(format: "%.2f", score.totalScore))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Text(
                                String(
                                    format: "V %.2f · D %.2f · L %.2f · P %.2f",
                                    score.visionScore,
                                    score.dateScore,
                                    score.locationScore,
                                    score.peopleScore
                                )
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                            if score.likelyGroom != nil || score.likelyBride != nil {
                                Text(
                                    [
                                        score.likelyGroom.map { "Groom: \($0)" },
                                        score.likelyBride.map { "Bride: \($0)" }
                                    ]
                                    .compactMap { $0 }
                                    .joined(separator: " · ")
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reloadSupportingData()
            loadPersistedSettingsIfNeeded()
        }
    }

    private var aiThresholdSection: some View {
        Section("AI trigger") {
            HStack {
                Text("Minimum event score")
                Spacer()
                TextField(
                    "0",
                    value: $settings.minimumScoreForAI,
                    format: .number.precision(.fractionLength(0...2))
                )
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
            }
            Text(
                "AI event tags write only when total score meets this value. "
                    + "Use 0 to keep the default (any positive score)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sections

    private var visionSection: some View {
        Section("Apple Vision Tags") {
            if settings.visionTags.isEmpty {
                Text("Add vision tags to score object evidence on the event.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach($settings.visionTags) { $tag in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(tag.objectKey)
                        Spacer()
                        Button(role: .destructive) {
                            settings.visionTags.removeAll { $0.objectKey == tag.objectKey }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack {
                        Text("Min confidence")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int((tag.minConfidence * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $tag.minConfidence, in: 0.01...0.95, step: 0.01)

                    HStack {
                        Text("Points")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField(
                            "pts",
                            value: $tag.points,
                            format: .number.precision(.fractionLength(0...2))
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    }
                }
            }

            Text("Score adds points × tag confidence for each matching photo in the event.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dateSection: some View {
        Section("Date") {
            Text("Score Card calendar gate / date points (not the Picture Search photo window).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Date type", selection: $settings.dateSearch.dateSearchType) {
                ForEach(PictureDateSearchType.allCases) { type in
                    Text(type.scoreCardDisplayName).tag(type)
                }
            }

            switch settings.dateSearch.dateSearchType {
            case .sameDateEveryYear:
                TextField("Month/day (6/15)", text: sameDateBinding)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                dateWindowExpanders
            case .movingHoliday:
                Picker("Holiday", selection: movingHolidayBinding) {
                    Text("Select holiday").tag(String?.none)
                    ForEach(PictureMovingHolidayKey.allCases) { holiday in
                        Text(holiday.displayName).tag(Optional(holiday.rawValue))
                    }
                    ForEach(floatingHolidays) { holiday in
                        Text(holiday.name).tag(Optional("floating:\(holiday.floatingHolidayId ?? 0)"))
                    }
                }
                dateWindowExpanders
            case .sameDateRangeEveryYear:
                HStack {
                    TextField("Start 12/1", text: rangeStartBinding)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("–")
                    TextField("End 12/31", text: rangeEndBinding)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Text("Anchor for scoring is the range start month/day each year.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .absoluteRange:
                TextField("Start YYYY-MM-DD", text: absoluteStartBinding)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("End YYYY-MM-DD", text: absoluteEndBinding)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Anchor for scoring is the absolute start date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .allDates:
                Text("No date scoring while all dates is selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.dateSearch.dateSearchType != .allDates {
                HStack {
                    Text("On-date points")
                    Spacer()
                    TextField(
                        "pts",
                        value: $settings.onDatePoints,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                }

                HStack {
                    Text("Points per day from anchor")
                    Spacer()
                    TextField(
                        "pts",
                        value: $settings.pointsPerDayFromAnchor,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                }

                Text(
                    "On the anchor day: on-date points. Each day away adds “points per day” (default −1)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var dateWindowExpanders: some View {
        Group {
            Toggle("Include Fri/Sat before", isOn: $settings.dateSearch.includeWeekendsBefore)
            Toggle("Include Fri/Sat after", isOn: $settings.dateSearch.includeWeekendsAfter)
            Toggle("Include days before", isOn: $settings.dateSearch.includeDaysBefore)
            if settings.dateSearch.includeDaysBefore {
                Stepper(
                    "Days before: \(settings.dateSearch.includeXDaysBefore ?? 1)",
                    value: Binding(
                        get: { settings.dateSearch.includeXDaysBefore ?? 1 },
                        set: { settings.dateSearch.includeXDaysBefore = $0 }
                    ),
                    in: 1...60
                )
            }
            Toggle("Include days after", isOn: $settings.dateSearch.includeDaysAfter)
            if settings.dateSearch.includeDaysAfter {
                Stepper(
                    "Days after: \(settings.dateSearch.includeYDaysAfter ?? 1)",
                    value: Binding(
                        get: { settings.dateSearch.includeYDaysAfter ?? 1 },
                        set: { settings.dateSearch.includeYDaysAfter = $0 }
                    ),
                    in: 1...60
                )
            }
        }
    }

    private var peopleSection: some View {
        Section("People") {
            if people.isEmpty {
                Text("No people yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(people) { person in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(person.name, isOn: personSelectedBinding(person))
                        if let index = settings.people.firstIndex(where: { $0.personId == person.personId }) {
                            HStack {
                                Text("Points")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                TextField(
                                    "pts",
                                    value: personPointsBinding(at: index),
                                    format: .number.precision(.fractionLength(0...2))
                                )
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                            }
                        }
                    }
                }
            }

            Text("Adds that person’s points when they appear in the event’s photos.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var locationSection: some View {
        Section("Locations") {
            ForEach($settings.locations) { $location in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(location.searchTerm)
                        Spacer()
                        Button(role: .destructive) {
                            settings.locations.removeAll {
                                $0.searchTerm.compare(
                                    location.searchTerm,
                                    options: .caseInsensitive
                                ) == .orderedSame
                            }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack {
                        Text("Points")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField(
                            "pts",
                            value: $location.points,
                            format: .number.precision(.fractionLength(0...2))
                        )
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    }
                }
            }

            TextField("Add location term", text: $locationDraft)
                .textInputAutocapitalization(.words)
                .onSubmit { addLocationFromDraft() }

            Button("Add location") { addLocationFromDraft() }
                .disabled(locationDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Text("Adds points when the event/location city, state, place, or nickname contains the term.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private var sameDateBinding: Binding<String> {
        Binding(
            get: { displayMonthDay(settings.dateSearch.sameDateSearchDate) ?? "" },
            set: { settings.dateSearch.sameDateSearchDate = PhotoVisionTagQuery.normalizedMonthDay($0) }
        )
    }

    private var rangeStartBinding: Binding<String> {
        Binding(
            get: { displayMonthDay(settings.dateSearch.rangeStartMonthDay) ?? "" },
            set: { settings.dateSearch.rangeStartMonthDay = PhotoVisionTagQuery.normalizedMonthDay($0) }
        )
    }

    private var rangeEndBinding: Binding<String> {
        Binding(
            get: { displayMonthDay(settings.dateSearch.rangeEndMonthDay) ?? "" },
            set: { settings.dateSearch.rangeEndMonthDay = PhotoVisionTagQuery.normalizedMonthDay($0) }
        )
    }

    private var absoluteStartBinding: Binding<String> {
        Binding(
            get: { settings.dateSearch.absoluteStartDate ?? "" },
            set: {
                settings.dateSearch.absoluteStartDate = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
    }

    private var absoluteEndBinding: Binding<String> {
        Binding(
            get: { settings.dateSearch.absoluteEndDate ?? "" },
            set: {
                settings.dateSearch.absoluteEndDate = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
    }

    private var movingHolidayBinding: Binding<String?> {
        Binding(
            get: {
                if let holidayId = settings.dateSearch.holidayId {
                    return "floating:\(holidayId)"
                }
                if let floatingId = settings.dateSearch.floatingHolidayId {
                    return "floating:\(floatingId)"
                }
                return settings.dateSearch.movingHolidayKey
            },
            set: { newValue in
                if let newValue, newValue.hasPrefix("floating:"),
                   let id = Int(newValue.dropFirst("floating:".count)) {
                    settings.dateSearch.holidayId = id
                    settings.dateSearch.floatingHolidayId = nil
                    settings.dateSearch.movingHolidayKey = nil
                } else {
                    settings.dateSearch.holidayId = nil
                    settings.dateSearch.floatingHolidayId = nil
                    settings.dateSearch.movingHolidayKey = newValue
                }
            }
        )
    }

    private func personSelectedBinding(_ person: PeopleRepository.PersonRecord) -> Binding<Bool> {
        Binding(
            get: { settings.people.contains { $0.personId == person.personId } },
            set: { isOn in
                if isOn {
                    if !settings.people.contains(where: { $0.personId == person.personId }) {
                        settings.people.append(
                            .init(personId: person.personId, name: person.name, points: 5)
                        )
                    }
                } else {
                    settings.people.removeAll { $0.personId == person.personId }
                }
            }
        )
    }

    private func personPointsBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: { settings.people[index].points },
            set: { settings.people[index].points = $0 }
        )
    }

    // MARK: - Actions

    private func reloadSupportingData() {
        people = AppDependencies.database.fetchAllPeople()
        floatingHolidays = AppDependencies.database.fetchFloatingHolidays()
    }

    private func loadPersistedSettingsIfNeeded() {
        let loaded = AppDependencies.database.ensureEventScoreCardSettings(
            for: definition,
            personNamesById: Dictionary(uniqueKeysWithValues: people.map { ($0.personId, $0.name) })
        )
        settings = loaded
    }

    private func saveSettings() {
        settings = AppDependencies.database.saveEventScoreCardSettings(settings)
        statusMessage = "Saved score card “\(settings.name)”."
    }

    private func addLocationFromDraft() {
        let trimmed = locationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !settings.locations.contains(where: {
            $0.searchTerm.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            settings.locations.append(.init(searchTerm: trimmed, points: 5))
        }
        locationDraft = ""
    }

    private func displayMonthDay(_ stored: String?) -> String? {
        guard let stored, stored.count >= 5 else { return stored }
        // stored as MM-DD
        let parts = stored.split(separator: "-")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]) else {
            return stored
        }
        return "\(month)/\(day)"
    }

    @MainActor
    private func runScoring() async {
        let eventCount = report.candidateEventIds.count
        guard eventCount > 0 else {
            statusMessage = "No candidate events to score."
            return
        }

        isScoring = true
        statusMessage = "Scoring \(eventCount) events…"
        checkReport = nil

        let savedSettings = AppDependencies.database.saveEventScoreCardSettings(settings)
        settings = savedSettings

        let localReport = report
        let localDefinition = definition
        let localSettings = savedSettings

        let result = await Task.detached(priority: .utility) {
            AppDependencies.database.checkPictureSearchEventTypes(
                runReport: localReport,
                definition: localDefinition,
                scoreCard: localSettings,
                progress: nil
            )
        }.value

        checkReport = result
        isScoring = false
        statusMessage = result.summaryLine
    }
}
