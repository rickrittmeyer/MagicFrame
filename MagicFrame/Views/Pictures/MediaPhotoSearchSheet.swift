import SwiftUI

struct MediaPhotoSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialQuery: MediaSearchQuery
    var showsCancelButton: Bool
    var embedsNavigationStack: Bool
    var navigationTitle: String
    var dismissesAfterSearch: Bool
    var onSearch: (MediaSearchQuery, MediaPhotoSearchReport) -> Void

    @State private var matchMode: MediaSearchMatchMode
    @State private var criteria: [MediaSearchCriterion]
    @State private var isSearching = false
    @State private var statusMessage: String?
    @State private var people: [PeopleRepository.PersonRecord] = []
    @State private var holidays: [HolidayDefinition] = []
    @State private var birthdayPeople: [PeopleRepository.PersonBirthdayRecord] = []
    @State private var savedSearches: [MediaSavedSearch] = []
    @State private var selectedSavedSearchId: Int?
    @State private var saveNameDraft: String = ""
    @State private var showingSaveAlert = false
    @State private var suggestionsByCriterionId: [UUID: [String]] = [:]

    private let database: any MagicFrameDatabase

    private enum AnyYearPreset: Hashable {
        case custom
        case holiday(Int)
        case birthday(Int)
    }

    private enum SavedSearchPickerItem: Hashable {
        case newSearch
        case saved(Int)
    }

    init(
        initialQuery: MediaSearchQuery = .empty(),
        showsCancelButton: Bool = true,
        embedsNavigationStack: Bool = true,
        navigationTitle: String = "Search Pictures",
        dismissesAfterSearch: Bool = true,
        database: any MagicFrameDatabase = AppDependencies.database,
        onSearch: @escaping (MediaSearchQuery, MediaPhotoSearchReport) -> Void
    ) {
        self.initialQuery = initialQuery
        self.showsCancelButton = showsCancelButton
        self.embedsNavigationStack = embedsNavigationStack
        self.navigationTitle = navigationTitle
        self.dismissesAfterSearch = dismissesAfterSearch
        self.database = database
        self.onSearch = onSearch
        _matchMode = State(initialValue: initialQuery.matchMode)
        _criteria = State(initialValue: initialQuery.criteria.isEmpty ? [MediaSearchCriterion()] : initialQuery.criteria)
    }

    private var draftQuery: MediaSearchQuery {
        MediaSearchQuery(matchMode: matchMode, criteria: criteria)
    }

    var body: some View {
        if embedsNavigationStack {
            NavigationStack {
                formContent
            }
        } else {
            formContent
        }
    }

    private var formContent: some View {
        List {
            Section {
                Picker(
                    "Saved search",
                    selection: Binding(
                        get: {
                            if let selectedSavedSearchId {
                                return SavedSearchPickerItem.saved(selectedSavedSearchId)
                            }
                            return .newSearch
                        },
                        set: { item in
                            switch item {
                            case .newSearch:
                                selectedSavedSearchId = nil
                                matchMode = .all
                                criteria = [MediaSearchCriterion()]
                            case .saved(let id):
                                loadSavedSearch(id: id)
                            }
                        }
                    )
                ) {
                    Text("New search").tag(SavedSearchPickerItem.newSearch)
                    ForEach(savedSearches) { search in
                        if let id = search.mediaSavedSearchId {
                            Text(search.name).tag(SavedSearchPickerItem.saved(id))
                        }
                    }
                }

                Button("Save search…") {
                    saveNameDraft = savedSearches.first(where: { $0.mediaSavedSearchId == selectedSavedSearchId })?.name
                        ?? ""
                    showingSaveAlert = true
                }
                .disabled(!draftQuery.isValid)
            }

            Section {
                Picker("Default join", selection: $matchMode) {
                    ForEach(MediaSearchMatchMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New conditions join with \(matchMode.shortTitle). Change AND/OR between rows, and use ( ) to group.")
                    if !draftQuery.expressionPreview.isEmpty {
                        Text(draftQuery.expressionPreview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if draftQuery.criteria.contains(where: \.isValid),
                       !MediaSearchQuery.parenthesesAreBalanced(draftQuery.criteria.filter(\.isValid)) {
                        Text("Parentheses are unbalanced.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Conditions") {
                ForEach(Array(criteria.enumerated()), id: \.element.id) { index, _ in
                    criterionEditor(at: index)
                }
                .onDelete(perform: deleteCriteria)

                Button {
                    criteria.append(
                        MediaSearchCriterion(leadingJoin: matchMode)
                    )
                } label: {
                    Label("Add condition", systemImage: "plus.circle")
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancelButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    runSearch()
                } label: {
                    if isSearching {
                        ProgressView()
                    } else {
                        Text("Search")
                    }
                }
                .disabled(!draftQuery.isValid || isSearching)
            }
        }
        .alert("Save search", isPresented: $showingSaveAlert) {
            TextField("Name", text: $saveNameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                saveCurrentSearch()
            }
        } message: {
            Text("Name this search to reuse it later.")
        }
        .task {
            people = database.fetchAllPeople()
            holidays = database.fetchAllEnabledHolidays()
            birthdayPeople = database.fetchPeopleWithBirthDates()
            reloadSavedSearches()
        }
    }

    private func reloadSavedSearches() {
        database.migratePictureSearchesToMediaSavedSearchesIfNeeded()
        savedSearches = database.fetchAllMediaSavedSearches(enabledOnly: false)
    }

    private func loadSavedSearch(id: Int) {
        guard let search = database.fetchMediaSavedSearch(id: id) else { return }
        selectedSavedSearchId = id
        matchMode = search.query.matchMode
        criteria = search.query.criteria.isEmpty ? [MediaSearchCriterion()] : search.query.criteria
        statusMessage = "Loaded “\(search.name)”"
    }

    private func saveCurrentSearch() {
        let name = saveNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, draftQuery.isValid else { return }
        var search = MediaSavedSearch(
            mediaSavedSearchId: selectedSavedSearchId,
            name: name,
            targetTagCategory: "",
            targetTagValue: "",
            query: draftQuery,
            isEnabled: true,
            performFaceDetect: false
        )
        if let existing = database.fetchAllMediaSavedSearches(enabledOnly: false)
            .first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            search.mediaSavedSearchId = existing.mediaSavedSearchId
            search.targetTagCategory = existing.targetTagCategory
            search.targetTagValue = existing.targetTagValue
            search.performFaceDetect = existing.performFaceDetect
            search.legacyPictureSearchId = existing.legacyPictureSearchId
        }
        let id = database.saveMediaSavedSearch(search)
        reloadSavedSearches()
        selectedSavedSearchId = id > 0 ? id : selectedSavedSearchId
        statusMessage = "Saved “\(name)”"
    }

    @ViewBuilder
    private func criterionEditor(at index: Int) -> some View {
        let criterion = criteria[index]
        VStack(alignment: .leading, spacing: 10) {
            if index > 0 {
                Picker("Join", selection: binding(at: index, keyPath: \.leadingJoin)) {
                    ForEach(MediaSearchMatchMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 6) {
                parenControls(
                    label: "(",
                    count: criterion.openGroups,
                    onIncrement: { criteria[index].openGroups += 1 },
                    onDecrement: {
                        criteria[index].openGroups = max(0, criteria[index].openGroups - 1)
                    }
                )

                Toggle(isOn: binding(at: index, keyPath: \.isNegated)) {
                    Text("NOT")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.button)
                .tint(criterion.isNegated ? Color.red.opacity(0.85) : Color.secondary)

                Spacer(minLength: 0)

                parenControls(
                    label: ")",
                    count: criterion.closeGroups,
                    onIncrement: { criteria[index].closeGroups += 1 },
                    onDecrement: {
                        criteria[index].closeGroups = max(0, criteria[index].closeGroups - 1)
                    }
                )

                if criteria.count > 1 {
                    Button(role: .destructive) {
                        criteria.remove(at: index)
                        suggestionsByCriterionId[criterion.id] = nil
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attribute")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker("Attribute", selection: binding(at: index, keyPath: \.field)) {
                        ForEach(MediaSearchField.allCases) { field in
                            Text(field.title).tag(field)
                        }
                    }
                    .labelsHidden()
                }

                if criterion.field.allowedOperators.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Operator")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Picker("Operator", selection: binding(at: index, keyPath: \.op)) {
                            ForEach(criterion.field.allowedOperators) { op in
                                Text(op.title).tag(op)
                            }
                        }
                        .labelsHidden()
                    }
                    .frame(maxWidth: 160, alignment: .leading)
                }
            }

            valueEditor(at: index)
        }
        .padding(.vertical, 4)
        .onChange(of: criteria[index].field) { _, newField in
            var updated = criteria[index]
            updated.op = newField.defaultOperator
            updated.personId = nil
            updated.holidayId = nil
            updated.secondaryValue = ""
            updated.daysBefore = 0
            updated.daysAfter = 0
            updated.minConfidence = MediaSearchCriterion.defaultVisionMinConfidence
            switch newField.valueEditor {
            case .choice(let values):
                updated.value = values.first ?? ""
            case .date, .number:
                updated.value = ""
            default:
                break
            }
            criteria[index] = updated
            refreshSuggestions(for: index)
        }
        .onChange(of: criteria[index].op) { oldOp, newOp in
            guard criteria[index].field == .dateTaken, oldOp != newOp else { return }
            var updated = criteria[index]
            updated.secondaryValue = ""
            updated.holidayId = nil
            updated.personId = nil
            switch newOp {
            case .inMonth:
                updated.value = MediaSearchCriterion.normalizedMonth(updated.value) ?? "12"
                updated.daysBefore = 0
                updated.daysAfter = 0
            case .anyYear:
                if MediaSearchCriterion.normalizedMonthDay(updated.value) == nil {
                    updated.value = ""
                }
            default:
                if MediaSearchCriterion.normalizedMonthDay(updated.value) != nil
                    || MediaSearchCriterion.normalizedMonth(updated.value) != nil {
                    updated.value = ""
                }
                updated.daysBefore = 0
                updated.daysAfter = 0
            }
            criteria[index] = updated
        }
        .onChange(of: criteria[index].value) { _, _ in
            refreshSuggestions(for: index)
        }
    }

    private func parenControls(
        label: String,
        count: Int,
        onIncrement: @escaping () -> Void,
        onDecrement: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 2) {
            Button(label, action: onIncrement)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            if count > 0 {
                Text(String(repeating: label, count: count))
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)
                Button {
                    onDecrement()
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func valueEditor(at index: Int) -> some View {
        let criterion = criteria[index]
        switch criterion.field.valueEditor {
        case .person:
            personValueEditor(at: index)
        case .choice(let values):
            Picker("Value", selection: binding(at: index, keyPath: \.value)) {
                ForEach(values, id: \.self) { option in
                    Text(criterion.field.choiceLabel?(option) ?? option.capitalized)
                        .tag(option)
                }
            }
            .pickerStyle(.segmented)
        case .date:
            dateValueEditor(at: index)
        case .number:
            TextField(criterion.field.placeholder, text: binding(at: index, keyPath: \.value))
                .keyboardType(.numberPad)
        case .text:
            textValueEditor(at: index)
        }
    }

    @ViewBuilder
    private func dateValueEditor(at index: Int) -> some View {
        let criterion = criteria[index]
        switch criterion.op {
        case .inMonth:
            Picker(
                "Month",
                selection: Binding(
                    get: {
                        MediaSearchCriterion.normalizedMonth(criteria[index].value) ?? "12"
                    },
                    set: { criteria[index].value = $0 }
                )
            ) {
                ForEach(1...12, id: \.self) { month in
                    Text(Self.monthNames[month - 1])
                        .tag(String(format: "%02d", month))
                }
            }
            Text("Matches that month in any year")
                .font(.caption2)
                .foregroundStyle(.tertiary)

        case .anyYear:
            anyYearValueEditor(at: index)

        default:
            HStack {
                TextField("Start YYYY-MM-DD", text: binding(at: index, keyPath: \.value))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                if criterion.op == .between {
                    Text("to")
                        .foregroundStyle(.secondary)
                    TextField("End YYYY-MM-DD", text: binding(at: index, keyPath: \.secondaryValue))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                }
            }
            Text("Use ISO dates like 2019-07-04")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func anyYearValueEditor(at index: Int) -> some View {
        let criterion = criteria[index]
        Menu {
            Button("Custom date") {
                applyAnyYearPreset(.custom, at: index)
            }
            if !holidays.isEmpty {
                Section("Holidays") {
                    ForEach(holidays) { holiday in
                        if let holidayId = holiday.holidayId {
                            Button(holiday.name) {
                                applyAnyYearPreset(.holiday(holidayId), at: index)
                            }
                        }
                    }
                }
            }
            if !birthdayPeople.isEmpty {
                Section("Birthdays") {
                    ForEach(birthdayPeople, id: \.personId) { person in
                        Button(MilestonePictureSearchDefaults.personBirthdayTagValue(displayName: person.name)) {
                            applyAnyYearPreset(.birthday(person.personId), at: index)
                        }
                    }
                }
            }
        } label: {
            HStack {
                Text(anyYearPresetTitle(for: criterion))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if anyYearPreset(for: criterion) == .custom {
            TextField("MM-DD", text: binding(at: index, keyPath: \.value))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
        }

        Stepper(
            "Days before: \(criterion.daysBefore)",
            value: binding(at: index, keyPath: \.daysBefore),
            in: 0...MediaSearchCriterion.maxDayWindow
        )
        Stepper(
            "Days after: \(criterion.daysAfter)",
            value: binding(at: index, keyPath: \.daysAfter),
            in: 0...MediaSearchCriterion.maxDayWindow
        )
        Toggle(
            "Weekends before",
            isOn: binding(at: index, keyPath: \.includeWeekendsBefore)
        )
        Toggle(
            "Weekends after",
            isOn: binding(at: index, keyPath: \.includeWeekendsAfter)
        )
        Text(anyYearCaption(for: criterion))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private static let monthNames = Calendar.current.monthSymbols

    private func anyYearPreset(for criterion: MediaSearchCriterion) -> AnyYearPreset {
        if let holidayId = criterion.holidayId {
            return .holiday(holidayId)
        }
        if let personId = criterion.personId {
            return .birthday(personId)
        }
        return .custom
    }

    private func anyYearPresetTitle(for criterion: MediaSearchCriterion) -> String {
        switch anyYearPreset(for: criterion) {
        case .custom:
            if let monthDay = MediaSearchCriterion.normalizedMonthDay(criterion.value) {
                return "Custom · \(monthDay)"
            }
            return "Choose holiday or birthday"
        case .holiday(let holidayId):
            return holidays.first(where: { $0.holidayId == holidayId })?.name ?? criterion.value
        case .birthday(let personId):
            if let person = birthdayPeople.first(where: { $0.personId == personId }) {
                return MilestonePictureSearchDefaults.personBirthdayTagValue(displayName: person.name)
            }
            return criterion.value.isEmpty ? "Birthday" : criterion.value
        }
    }

    private func applyAnyYearPreset(_ preset: AnyYearPreset, at index: Int) {
        var updated = criteria[index]
        switch preset {
        case .custom:
            updated.holidayId = nil
            updated.personId = nil
            if MediaSearchCriterion.normalizedMonthDay(updated.value) == nil {
                updated.value = ""
            }
        case .holiday(let holidayId):
            updated.holidayId = holidayId
            updated.personId = nil
            if let holiday = holidays.first(where: { $0.holidayId == holidayId }) {
                updated.value = holiday.fixedMonthDay ?? holiday.name
                if holiday.includeWeekendsBefore, updated.daysBefore == 0 {
                    updated.daysBefore = 2
                }
            }
        case .birthday(let personId):
            updated.holidayId = nil
            updated.personId = personId
            if let person = birthdayPeople.first(where: { $0.personId == personId }),
               let monthDay = MilestonePictureSearchDefaults.monthDay(fromBirthDateISO: person.birthDateISO) {
                updated.value = monthDay
                updated.daysBefore = MilestonePictureSearchDefaults.birthdayDaysBefore
                updated.daysAfter = MilestonePictureSearchDefaults.birthdayDaysAfter
            }
        }
        criteria[index] = updated
    }

    private func anyYearCaption(for criterion: MediaSearchCriterion) -> String {
        let label: String
        switch anyYearPreset(for: criterion) {
        case .custom:
            label = MediaSearchCriterion.normalizedMonthDay(criterion.value) ?? "MM-DD"
        case .holiday(let holidayId):
            label = holidays.first(where: { $0.holidayId == holidayId })?.name
                ?? criterion.value
        case .birthday(let personId):
            if let person = birthdayPeople.first(where: { $0.personId == personId }) {
                label = MilestonePictureSearchDefaults.personBirthdayTagValue(displayName: person.name)
            } else {
                label = criterion.value
            }
        }
        let before = criterion.daysBefore
        let after = criterion.daysAfter
        if before == 0, after == 0 {
            return "\(label) · any year"
        }
        return "\(label) · any year, −\(before) … +\(after) days"
    }

    @ViewBuilder
    private func textValueEditor(at index: Int) -> some View {
        let criterion = criteria[index]
        TextField(criterion.field.placeholder, text: binding(at: index, keyPath: \.value))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

        if criterion.field == .visionTag {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Min confidence")
                    Spacer()
                    Text("\(Int((criterion.minConfidence * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
                Slider(
                    value: binding(at: index, keyPath: \.minConfidence),
                    in: 0.01...0.95,
                    step: 0.01
                )
            }
        }

        if let suggestions = suggestionsByCriterionId[criterion.id], !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            criteria[index].value = suggestion
                            if criteria[index].field == .visionTag
                                || criteria[index].field == .eventTagCategory {
                                criteria[index].op = .is
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func personValueEditor(at index: Int) -> some View {
        let criterion = criteria[index]
        let selectedName = people.first(where: { $0.personId == criterion.personId })?.displayName

        Menu {
            Button("Clear") {
                criteria[index].personId = nil
                criteria[index].value = ""
            }
            ForEach(filteredPeople(for: criterion.value)) { person in
                Button(person.displayName) {
                    criteria[index].personId = person.personId
                    criteria[index].value = person.displayName
                    criteria[index].op = .is
                }
            }
        } label: {
            HStack {
                Text(selectedName ?? (criterion.value.isEmpty ? "Choose person" : criterion.value))
                    .foregroundStyle(selectedName == nil && criterion.value.isEmpty ? .secondary : .primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        TextField("Filter people", text: binding(at: index, keyPath: \.value))
            .textInputAutocapitalization(.words)
            .onChange(of: criteria[index].value) { _, newValue in
                if let selected = people.first(where: { $0.personId == criteria[index].personId }),
                   selected.displayName != newValue {
                    criteria[index].personId = nil
                }
            }
    }

    private func filteredPeople(for query: String) -> [PeopleRepository.PersonRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return Array(people.prefix(40)) }
        return people
            .filter { $0.displayName.lowercased().contains(needle) }
            .prefix(40)
            .map { $0 }
    }

    private func binding<T>(
        at index: Int,
        keyPath: WritableKeyPath<MediaSearchCriterion, T>
    ) -> Binding<T> {
        Binding(
            get: { criteria[index][keyPath: keyPath] },
            set: { criteria[index][keyPath: keyPath] = $0 }
        )
    }

    private func deleteCriteria(at offsets: IndexSet) {
        for index in offsets {
            suggestionsByCriterionId[criteria[index].id] = nil
        }
        criteria.remove(atOffsets: offsets)
        if criteria.isEmpty {
            criteria = [MediaSearchCriterion()]
        }
    }

    private func refreshSuggestions(for index: Int) {
        guard criteria.indices.contains(index) else { return }
        let criterion = criteria[index]
        switch criterion.field {
        case .albumName, .visionTag, .locationNickname, .locationPlaceName,
             .locationCity, .locationState, .eventTag, .eventTagCategory, .camera:
            let values = database.mediaSearchSuggestionValues(
                field: criterion.field,
                query: criterion.value,
                limit: 20
            )
            suggestionsByCriterionId[criterion.id] = values
        default:
            suggestionsByCriterionId[criterion.id] = nil
        }
    }

    private func runSearch() {
        let query = draftQuery
        guard query.isValid else { return }
        isSearching = true
        statusMessage = nil

        Task {
            let report = await Task.detached(priority: .userInitiated) { [database] in
                database.searchPhotos(matching: query)
            }.value

            await MainActor.run {
                isSearching = false
                if report.matchCount == 0 {
                    statusMessage = "No pictures match."
                    return
                }
                onSearch(query, report)
                if dismissesAfterSearch {
                    dismiss()
                }
            }
        }
    }
}
