import SwiftUI

struct IdentifyEventTypesView: View {

    /// When set (e.g. Christmas Picture Search), load/ensure that saved search on appear.
    let preferredSearchName: String?

    @State private var draft: PictureSearchDefinition
    @State private var savedSearches: [PictureSearchDefinition] = []
    @State private var people: [PeopleRepository.PersonRecord] = []
    @State private var allVisionTags: [VisionTagName] = []
    @State private var floatingHolidays: [FloatingHolidayDefinition] = []
    @State private var visionTagDraft = ""
    @State private var locationTermDraft = ""
    @State private var statusMessage: String?
    @State private var isRunning = false
    @State private var runReport: PictureSearchRunReport?
    @State private var showResults = false
    @State private var showAddFloatingHoliday = false
    @State private var newFloatingHolidayName = ""
    @State private var newFloatingMonth = 1
    @State private var newFloatingWeekday = 1
    @State private var newFloatingOrdinal = 1
    @FocusState private var isVisionTagFocused: Bool

    init(preferredSearchName: String? = nil) {
        self.preferredSearchName = preferredSearchName
        if let preferredSearchName,
           let tagValue = Self.holidayTagValue(fromPictureSearchName: preferredSearchName),
           let holidayDefault = PictureSearchDefinition.holidayDefault(tagValue: tagValue) {
            _draft = State(initialValue: holidayDefault)
        } else if preferredSearchName?.compare(
            AppViewCatalog.christmasPictureSearchName,
            options: .caseInsensitive
        ) == .orderedSame {
            _draft = State(initialValue: .christmasDefault())
        } else {
            _draft = State(initialValue: .weddingDefault())
        }
    }

    private static func holidayTagValue(fromPictureSearchName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            trimmed,
            {
                let suffix = " Picture Search"
                guard trimmed.count > suffix.count,
                      trimmed.suffix(suffix.count).compare(suffix, options: .caseInsensitive) == .orderedSame
                else {
                    return nil as String?
                }
                return String(trimmed.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }(),
        ].compactMap { $0 }.filter { !$0.isEmpty }

        for tagValue in candidates {
            if let match = HolidayPictureSearchDefaults.allBuiltInTagValues.first(where: {
                $0.compare(tagValue, options: .caseInsensitive) == .orderedSame
            }) {
                return match
            }
        }
        return nil
    }

    /// Matches “{Name} Birthday” (or legacy “… Birthday Picture Search”) to a people record.
    private static func ensurePersonBirthdayPictureSearchIfNeeded(
        preferredSearchName: String
    ) -> PictureSearchDefinition? {
        let trimmed = preferredSearchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [" Birthday Picture Search", " Birthday"]
        var personName: String?
        for suffix in suffixes {
            guard trimmed.count > suffix.count,
                  trimmed.suffix(suffix.count).compare(suffix, options: .caseInsensitive) == .orderedSame
            else {
                continue
            }
            personName = String(trimmed.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        guard let personName, !personName.isEmpty else { return nil }
        guard let person = AppDependencies.database.fetchPeopleWithBirthDates().first(where: {
            $0.name.compare(personName, options: .caseInsensitive) == .orderedSame
        }) else {
            return nil
        }
        return AppDependencies.database.ensurePersonBirthdayPictureSearch(person: person)
    }

    var body: some View {
        Form {
            if !savedSearches.isEmpty {
                Section("Saved picture searches") {
                    ForEach(savedSearches) { search in
                        Button {
                            draft = search
                            statusMessage = "Loaded “\(search.name)”."
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(search.name)
                                Text(
                                    "\(search.targetAttributeField.menuTitle) · \(search.targetEventType)"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Picture search") {
                TextField("Search name", text: $draft.name)

                Picker("Event Type", selection: eventTypeCategoryBinding) {
                    ForEach(EventAttributeField.pictureSearchCategoryCases) { field in
                        Text(field.menuTitle).tag(field.tagCategory)
                    }
                }

                Picker("Event Category", selection: $draft.targetEventType) {
                    ForEach(eventCategoryValueOptions, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
                .disabled(eventCategoryValueOptions.isEmpty)

                Toggle("Detect faces on search results", isOn: $draft.performFaceDetect)
                Text(
                    "When on, running this search queues face detect + embed for matching photos only (not the whole library)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            visionTagsSection
            dateSearchSection
            locationSection
            peopleSection

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Save Picture Search") {
                    saveDraft()
                }

                Button {
                    runSearch()
                } label: {
                    if isRunning {
                        HStack {
                            ProgressView()
                            Text("Running…")
                        }
                    } else {
                        Text("Run Picture Search")
                    }
                }
                .disabled(isRunning)
            }
        }
        .navigationTitle("Picture Search")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showResults) {
            if let runReport {
                PictureSearchResultsView(
                    title: draft.name,
                    definition: draft,
                    report: runReport
                )
            }
        }
        .onAppear(perform: reloadSupportingData)
        .alert("Add Floating Holiday", isPresented: $showAddFloatingHoliday) {
            TextField("Name", text: $newFloatingHolidayName)
            TextField("Month (1-12)", value: $newFloatingMonth, format: .number)
            TextField("Weekday (1=Sun…7=Sat)", value: $newFloatingWeekday, format: .number)
            TextField("Week ordinal (1-4 or -1 last)", value: $newFloatingOrdinal, format: .number)
            Button("Add") { addFloatingHoliday() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates an nth-weekday-of-month holiday for moving-holiday searches.")
        }
    }

    // MARK: - Target category / value

    /// Event Type picker → `event_tags.tagCategory` (holiday, milestoneType, …).
    private var eventTypeCategoryBinding: Binding<String> {
        Binding(
            get: {
                let stored = draft.targetTagCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                if !stored.isEmpty,
                   EventAttributeField.fromTagCategory(stored) != nil {
                    return stored
                }
                return draft.targetAttributeField.tagCategory
            },
            set: { newCategory in
                guard draft.targetTagCategory != newCategory else { return }
                draft.targetTagCategory = newCategory
                let options = tagValueOptions(forCategory: newCategory)
                let current = draft.targetEventType.trimmingCharacters(in: .whitespacesAndNewlines)
                let stillValid = options.contains {
                    $0.compare(current, options: .caseInsensitive) == .orderedSame
                }
                if !stillValid {
                    draft.targetEventType = options.first ?? current
                }
            }
        )
    }

    /// Event Category picker → `event_tags.tagValue` options for the selected category.
    private var eventCategoryValueOptions: [String] {
        tagValueOptions(forCategory: eventTypeCategoryBinding.wrappedValue)
    }

    private func tagValueOptions(forCategory category: String) -> [String] {
        let field = EventAttributeField.fromTagCategory(category)
            ?? EventAttributeField.pictureSearchCategory(forTargetValue: draft.targetEventType)
        var options = field.builtInOptions
        let current = draft.targetEventType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty,
           !options.contains(where: {
               $0.compare(current, options: .caseInsensitive) == .orderedSame
           }) {
            options.insert(current, at: 0)
        }
        return options
    }

    // MARK: - Vision tags

    private var visionTagsSection: some View {
        Section("Apple Vision Tags") {
            if !draft.visionTagSearch.tags.isEmpty {
                ForEach($draft.visionTagSearch.tags) { $tag in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(tag.objectKey)
                            Spacer()
                            Button(role: .destructive) {
                                draft.visionTagSearch.tags.removeAll { $0.objectKey == tag.objectKey }
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
                    }
                }
            }

            TextField("Add vision tag", text: $visionTagDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isVisionTagFocused)
                .onSubmit { addVisionTagFromDraft() }

            if isVisionTagFocused || !visionTagDraft.isEmpty {
                ForEach(filteredVisionTags) { tag in
                    Button {
                        addVisionTag(tag.objectKey)
                    } label: {
                        HStack {
                            Text(tag.objectKey)
                            Spacer()
                            Text("\(tag.photoCount)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                if filteredVisionTags.isEmpty, !visionTagDraft.isEmpty {
                    Text("No stored tags match. You can still add this exact text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Add “\(visionTagDraft.trimmingCharacters(in: .whitespacesAndNewlines))”") {
                        addVisionTagFromDraft()
                    }
                }
            }

            Text(
                "Type-ahead uses tags already stored from Vision scans. Defaults: Wedding Cake, Wedding Dress, Tuxedo at 12% min confidence. Photos only match a tag when stored confidence is at or above that tag’s slider."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Date

    private var dateSearchSection: some View {
        Section("Search date type") {
            Picker("Date type", selection: $draft.dateSearch.dateSearchType) {
                ForEach(PictureDateSearchType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

            switch draft.dateSearch.dateSearchType {
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
                Button("Add Floating Holiday") {
                    showAddFloatingHoliday = true
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
                Text("No date filter — all years and days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dateWindowExpanders: some View {
        Group {
            Toggle("Search Friday and Saturday Before", isOn: $draft.dateSearch.includeWeekendsBefore)
            Toggle("Search Friday and Saturday After Event Date", isOn: $draft.dateSearch.includeWeekendsAfter)

            Toggle("Include All Days X Before", isOn: $draft.dateSearch.includeDaysBefore)
            if draft.dateSearch.includeDaysBefore {
                Stepper(
                    "Days before: \(draft.dateSearch.includeXDaysBefore ?? 1)",
                    value: Binding(
                        get: { draft.dateSearch.includeXDaysBefore ?? 1 },
                        set: { draft.dateSearch.includeXDaysBefore = $0 }
                    ),
                    in: 1...60
                )
            }

            Toggle("Include All Days Y After", isOn: $draft.dateSearch.includeDaysAfter)
            if draft.dateSearch.includeDaysAfter {
                Stepper(
                    "Days after: \(draft.dateSearch.includeYDaysAfter ?? 1)",
                    value: Binding(
                        get: { draft.dateSearch.includeYDaysAfter ?? 1 },
                        set: { draft.dateSearch.includeYDaysAfter = $0 }
                    ),
                    in: 1...60
                )
            }
        }
    }

    // MARK: - Location / people

    private var locationSection: some View {
        Section("Search by location") {
            if let term = draft.locationSearch.searchTerms.first, !term.isEmpty {
                HStack {
                    Text(term)
                    Spacer()
                    Button("Clear", role: .destructive) {
                        draft.locationSearch.searchTerms = []
                        locationTermDraft = ""
                    }
                }
            }

            TextField("Location search term", text: $locationTermDraft)
                .textInputAutocapitalization(.words)
                .onSubmit {
                    let trimmed = locationTermDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.locationSearch.searchTerms = trimmed.isEmpty ? [] : [trimmed]
                }
                .onChange(of: locationTermDraft) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.locationSearch.searchTerms = trimmed.isEmpty ? [] : [trimmed]
                }

            Text("Matches event/location city, state, place name, or nickname.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var peopleSection: some View {
        Section("Search by people") {
            if people.isEmpty {
                Text("No people yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(people) { person in
                    Toggle(person.name, isOn: personSelectionBinding(person.personId))
                }
            }
        }
    }

    // MARK: - Bindings

    private var sameDateBinding: Binding<String> {
        Binding(
            get: {
                displayMonthDay(draft.dateSearch.sameDateSearchDate) ?? ""
            },
            set: { newValue in
                draft.dateSearch.sameDateSearchDate = PhotoVisionTagQuery.normalizedMonthDay(newValue)
            }
        )
    }

    private var rangeStartBinding: Binding<String> {
        Binding(
            get: { displayMonthDay(draft.dateSearch.rangeStartMonthDay) ?? "" },
            set: { draft.dateSearch.rangeStartMonthDay = PhotoVisionTagQuery.normalizedMonthDay($0) }
        )
    }

    private var rangeEndBinding: Binding<String> {
        Binding(
            get: { displayMonthDay(draft.dateSearch.rangeEndMonthDay) ?? "" },
            set: { draft.dateSearch.rangeEndMonthDay = PhotoVisionTagQuery.normalizedMonthDay($0) }
        )
    }

    private var absoluteStartBinding: Binding<String> {
        Binding(
            get: { draft.dateSearch.absoluteStartDate ?? "" },
            set: { draft.dateSearch.absoluteStartDate = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    private var absoluteEndBinding: Binding<String> {
        Binding(
            get: { draft.dateSearch.absoluteEndDate ?? "" },
            set: { draft.dateSearch.absoluteEndDate = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    private var movingHolidayBinding: Binding<String?> {
        Binding(
            get: {
                if let holidayId = draft.dateSearch.holidayId {
                    return "floating:\(holidayId)"
                }
                if let floatingId = draft.dateSearch.floatingHolidayId {
                    return "floating:\(floatingId)"
                }
                return draft.dateSearch.movingHolidayKey
            },
            set: { newValue in
                if let newValue, newValue.hasPrefix("floating:"),
                   let id = Int(newValue.dropFirst("floating:".count)) {
                    draft.dateSearch.holidayId = id
                    draft.dateSearch.floatingHolidayId = nil
                    draft.dateSearch.movingHolidayKey = nil
                } else {
                    draft.dateSearch.holidayId = nil
                    draft.dateSearch.floatingHolidayId = nil
                    draft.dateSearch.movingHolidayKey = newValue
                }
            }
        )
    }

    private func personSelectionBinding(_ personId: Int) -> Binding<Bool> {
        Binding(
            get: { draft.peopleSearch.personIds.contains(personId) },
            set: { isOn in
                if isOn {
                    if !draft.peopleSearch.personIds.contains(personId) {
                        draft.peopleSearch.personIds.append(personId)
                    }
                } else {
                    draft.peopleSearch.personIds.removeAll { $0 == personId }
                }
            }
        )
    }

    private var filteredVisionTags: [VisionTagName] {
        let needle = VisionTagName.normalized(visionTagDraft)
        let selected = Set(draft.visionTagSearch.tags.map { VisionTagName.normalized($0.objectKey) })
        let available = allVisionTags.filter { !selected.contains($0.normalized) }
        guard !needle.isEmpty else {
            return Array(available.prefix(12))
        }
        let prefix = available.filter { $0.normalized.hasPrefix(needle) }
        let prefixKeys = Set(prefix.map(\.objectKey))
        let contains = available.filter {
            !prefixKeys.contains($0.objectKey) && $0.normalized.contains(needle)
        }
        return Array((prefix + contains).prefix(12))
    }

    // MARK: - Actions

    private func reloadSupportingData() {
        people = AppDependencies.database.fetchAllPeople()
        allVisionTags = AppDependencies.database.fetchDistinctVisionTagNames()
        floatingHolidays = AppDependencies.database.fetchFloatingHolidays()
        savedSearches = AppDependencies.database.fetchAllPictureSearches()

        if let preferredSearchName {
            let preferred: PictureSearchDefinition
            if let existing = savedSearches.first(where: {
                $0.name.compare(preferredSearchName, options: .caseInsensitive) == .orderedSame
            }) {
                preferred = existing
            } else if let ensuredBirthday = Self.ensurePersonBirthdayPictureSearchIfNeeded(
                preferredSearchName: preferredSearchName
            ) {
                preferred = ensuredBirthday
            } else if let tagValue = Self.holidayTagValue(fromPictureSearchName: preferredSearchName),
                      let ensured = AppDependencies.database.ensureHolidayPictureSearch(
                        tagValue: tagValue
                      ) {
                preferred = ensured
            } else if preferredSearchName.compare(
                AppViewCatalog.christmasPictureSearchName,
                options: .caseInsensitive
            ) == .orderedSame {
                preferred = AppDependencies.database.ensureChristmasPictureSearch()
            } else {
                preferred = draft
            }
            draft = preferred
            statusMessage = "Loaded “\(preferred.name)”."
            savedSearches = AppDependencies.database.fetchAllPictureSearches()
        }

        if let term = draft.locationSearch.searchTerms.first {
            locationTermDraft = term
        }
    }

    private func addVisionTagFromDraft() {
        let trimmed = visionTagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addVisionTag(trimmed)
    }

    private func addVisionTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !draft.visionTagSearch.tags.contains(where: {
            $0.objectKey.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            draft.visionTagSearch.tags.append(
                VisionTagCriterion(objectKey: trimmed)
            )
        }
        visionTagDraft = ""
    }

    private func saveDraft() {
        normalizeDraftBeforePersist()
        let id = AppDependencies.database.savePictureSearch(draft)
        if let saved = AppDependencies.database.fetchPictureSearch(pictureSearchId: id) {
            draft = saved
        }
        savedSearches = AppDependencies.database.fetchAllPictureSearches()
        statusMessage = "Saved “\(draft.name)”."
    }

    private func runSearch() {
        normalizeDraftBeforePersist()
        isRunning = true
        statusMessage = "Searching pictures…"

        Task {
            let definition = draft
            let report = await Task.detached(priority: .utility) {
                AppDependencies.database.runPictureSearch(definition)
            }.value

            await MainActor.run {
                if let saved = AppDependencies.database.fetchPictureSearch(
                    pictureSearchId: report.pictureSearchId
                ) {
                    draft = saved
                }
                savedSearches = AppDependencies.database.fetchAllPictureSearches()
                runReport = report
                isRunning = false
                statusMessage = report.summaryLine
                showResults = true
                print("Picture search “\(draft.name)”: \(report.summaryLine)")
            }
        }
    }

    private func normalizeDraftBeforePersist() {
        if draft.dateSearch.includeDaysBefore, draft.dateSearch.includeXDaysBefore == nil {
            draft.dateSearch.includeXDaysBefore = 1
        }
        if !draft.dateSearch.includeDaysBefore {
            draft.dateSearch.includeXDaysBefore = nil
        }
        if draft.dateSearch.includeDaysAfter, draft.dateSearch.includeYDaysAfter == nil {
            draft.dateSearch.includeYDaysAfter = 1
        }
        if !draft.dateSearch.includeDaysAfter {
            draft.dateSearch.includeYDaysAfter = nil
        }

        let trimmedLocation = locationTermDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.locationSearch.searchTerms = trimmedLocation.isEmpty ? [] : [trimmedLocation]
    }

    private func addFloatingHoliday() {
        let name = newFloatingHolidayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              (1...12).contains(newFloatingMonth),
              (1...7).contains(newFloatingWeekday) else {
            statusMessage = "Floating holiday needs a name, month 1–12, weekday 1–7."
            return
        }

        let holiday = FloatingHolidayDefinition(
            floatingHolidayId: nil,
            name: name,
            ruleKind: "nthWeekdayOfMonth",
            month: newFloatingMonth,
            weekday: newFloatingWeekday,
            weekOrdinal: newFloatingOrdinal == 0 ? 1 : newFloatingOrdinal,
            isEnabled: true
        )
        let id = AppDependencies.database.upsertFloatingHoliday(holiday)
        floatingHolidays = AppDependencies.database.fetchFloatingHolidays()
        draft.dateSearch.dateSearchType = .movingHoliday
        draft.dateSearch.holidayId = id
        draft.dateSearch.floatingHolidayId = nil
        draft.dateSearch.movingHolidayKey = nil
        statusMessage = "Added floating holiday “\(name)”."
        newFloatingHolidayName = ""
    }

    private func displayMonthDay(_ value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.split(separator: "-")
        guard parts.count == 2,
              let month = Int(parts[0]),
              let day = Int(parts[1]) else {
            return value
        }
        return "\(month)/\(day)"
    }
}
