import SwiftUI

/// Editable scorecard settings without requiring a Picture Search run.
struct EventScoreCardEditorView: View {

    @State private var settings: PictureSearchEventScoreCardSettings
    @State private var people: [PeopleRepository.PersonRecord] = []
    @State private var floatingHolidays: [FloatingHolidayDefinition] = []
    @State private var locationDraft = ""
    @State private var visionDraft = ""
    @State private var statusMessage: String?

    init(settings: PictureSearchEventScoreCardSettings) {
        _settings = State(initialValue: settings)
    }

    var body: some View {
        Form {
            Section {
                Text("\(settings.targetTagCategory) · \(settings.targetEventType)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Event Score Card rules only. Picture Search photo queries are edited separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            visionSection
            dateSection
            peopleSection
            locationSection
            aiThresholdSection

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Save Score Card") {
                    saveSettings()
                }
            }
        }
        .navigationTitle(settings.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            people = AppDependencies.database.fetchAllPeople()
            floatingHolidays = AppDependencies.database.fetchFloatingHolidays()
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

    private var visionSection: some View {
        Section("Apple Vision Tags") {
            if settings.visionTags.isEmpty {
                Text("Add vision tags to score object evidence.")
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

            TextField("Add vision tag (object key)", text: $visionDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { addVisionFromDraft() }

            Button("Add vision tag") { addVisionFromDraft() }
                .disabled(visionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Text("Score adds points × tag confidence for each matching photo in the event.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var isHolidayScoreCard: Bool {
        settings.targetTagCategory.compare(
            EventAttributeField.holidayType.tagCategory,
            options: .caseInsensitive
        ) == .orderedSame
    }

    private var isBirthdayScoreCard: Bool {
        settings.targetTagCategory.compare(
            EventAttributeField.milestoneType.tagCategory,
            options: .caseInsensitive
        ) == .orderedSame
            && MilestonePictureSearchDefaults.isPersonBirthdayTagValue(settings.targetEventType)
    }

    private var usesCalendarDateGate: Bool {
        isHolidayScoreCard || isBirthdayScoreCard
    }

    private var dateSection: some View {
        Section(usesCalendarDateGate ? "Date (include / exclude)" : "Date") {
            if isHolidayScoreCard {
                Text(
                    "Holiday date is a filter, not points. Exact holiday date auto-includes the event. Outside the holiday window the event is skipped. Inside the window, score uses vision, people, and location only."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if isBirthdayScoreCard {
                Text(
                    "Birthday date is a filter, not points. Exact birth month/day auto-tags \(settings.targetEventType) and sets event main person. Outside 7 days before / 3 days after is skipped. Inside the window, score uses vision, people, and location only."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

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
            case .absoluteRange:
                TextField("Start YYYY-MM-DD", text: absoluteStartBinding)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("End YYYY-MM-DD", text: absoluteEndBinding)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case .allDates:
                Text(
                    usesCalendarDateGate
                        ? "All dates: no calendar window filter (every event can be scored)."
                        : "No date scoring while all dates is selected."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !usesCalendarDateGate, settings.dateSearch.dateSearchType != .allDates {
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
        }
    }

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

    private func addVisionFromDraft() {
        let trimmed = visionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !settings.visionTags.contains(where: {
            $0.objectKey.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            settings.visionTags.append(
                .init(objectKey: trimmed, minConfidence: 0.12, points: 1)
            )
        }
        visionDraft = ""
    }

    private func displayMonthDay(_ stored: String?) -> String? {
        guard let stored, stored.count >= 5 else { return stored }
        let parts = stored.split(separator: "-")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]) else {
            return stored
        }
        return "\(month)/\(day)"
    }
}
