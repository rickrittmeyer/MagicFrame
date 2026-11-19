import SwiftUI

/// Lists Media Saved Searches for developer management (query edit, toggles, run → results / score cards).
struct MediaSavedSearchesView: View {

    /// When set (e.g. Christmas / person birthday), ensure and surface that search.
    let preferredSearchName: String?

    @State private var searches: [MediaSavedSearch] = []
    @State private var queryEditorTarget: QueryEditorTarget?
    @State private var runResults: MediaSavedSearchRunResults?
    @State private var runningSearchId: Int?
    @State private var statusMessage: String?
    @State private var highlightedSearchId: Int?

    init(preferredSearchName: String? = nil) {
        self.preferredSearchName = preferredSearchName
    }

    var body: some View {
        List {
            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if searches.isEmpty {
                    Text("No media saved searches yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(searches) { search in
                        searchRow(search)
                    }
                }
            } footer: {
                Text(
                    "Tap Edit Query to change criteria. Toggle Enabled / Detect faces, then Run to open matching pictures and score cards."
                )
            }
        }
        .navigationTitle("Media Saved Searches")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $queryEditorTarget) { target in
            queryEditorDestination(searchId: target.searchId)
        }
        .navigationDestination(item: $runResults) { results in
            PictureSearchResultsView(
                title: results.definition.name,
                definition: results.definition,
                report: results.report
            )
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func searchRow(_ search: MediaSavedSearch) -> some View {
        let searchId = search.mediaSavedSearchId
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                "Name",
                text: nameBinding(for: search)
            )
            .font(.body.weight(highlightedSearchId == searchId ? .semibold : .regular))

            Toggle("Enabled", isOn: enabledBinding(for: search))
            Toggle("Detect faces on search results", isOn: faceDetectBinding(for: search))

            HStack(spacing: 12) {
                Button("Edit Query") {
                    if let searchId {
                        queryEditorTarget = QueryEditorTarget(searchId: searchId)
                    }
                }
                .disabled(searchId == nil)

                Spacer()

                Button {
                    runSearch(search)
                } label: {
                    if runningSearchId == searchId {
                        ProgressView()
                    } else {
                        Text("Run")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(runningSearchId != nil || searchId == nil)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(
            highlightedSearchId == searchId
                ? Color.accentColor.opacity(0.08)
                : Color.clear
        )
    }

    @ViewBuilder
    private func queryEditorDestination(searchId: Int) -> some View {
        let search = AppDependencies.database.fetchMediaSavedSearch(id: searchId)
        MediaPhotoSearchSheet(
            initialQuery: search?.query ?? .empty(),
            showsCancelButton: false,
            embedsNavigationStack: false,
            navigationTitle: search?.name ?? "Edit Query",
            dismissesAfterSearch: false,
            onSearch: { query, _ in
                guard var updated = AppDependencies.database.fetchMediaSavedSearch(id: searchId) else {
                    return
                }
                updated.query = query
                _ = AppDependencies.database.saveMediaSavedSearch(updated)
                reloadSearchesOnly()
                statusMessage = "Updated query for “\(updated.name)”."
            }
        )
    }

    // MARK: - Bindings

    private func nameBinding(for search: MediaSavedSearch) -> Binding<String> {
        Binding(
            get: {
                searches.first(where: { $0.mediaSavedSearchId == search.mediaSavedSearchId })?.name
                    ?? search.name
            },
            set: { newName in
                guard let id = search.mediaSavedSearchId,
                      var updated = AppDependencies.database.fetchMediaSavedSearch(id: id) else {
                    return
                }
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                updated.name = trimmed
                _ = AppDependencies.database.saveMediaSavedSearch(updated)
                reloadSearchesOnly()
            }
        )
    }

    private func enabledBinding(for search: MediaSavedSearch) -> Binding<Bool> {
        Binding(
            get: {
                searches.first(where: { $0.mediaSavedSearchId == search.mediaSavedSearchId })?.isEnabled
                    ?? search.isEnabled
            },
            set: { newValue in
                persistToggle(search: search) { $0.isEnabled = newValue }
            }
        )
    }

    private func faceDetectBinding(for search: MediaSavedSearch) -> Binding<Bool> {
        Binding(
            get: {
                searches.first(where: { $0.mediaSavedSearchId == search.mediaSavedSearchId })?.performFaceDetect
                    ?? search.performFaceDetect
            },
            set: { newValue in
                persistToggle(search: search) { $0.performFaceDetect = newValue }
            }
        )
    }

    private func persistToggle(search: MediaSavedSearch, mutate: (inout MediaSavedSearch) -> Void) {
        guard let id = search.mediaSavedSearchId,
              var updated = AppDependencies.database.fetchMediaSavedSearch(id: id) else {
            return
        }
        mutate(&updated)
        _ = AppDependencies.database.saveMediaSavedSearch(updated)
        reloadSearchesOnly()
    }

    // MARK: - Actions

    private func reload() {
        AppDependencies.database.migratePictureSearchesToMediaSavedSearchesIfNeeded()
        ensurePreferredIfNeeded()
        reloadSearchesOnly()
        if let preferredSearchName {
            if let match = searches.first(where: {
                $0.name.compare(preferredSearchName, options: .caseInsensitive) == .orderedSame
            }) {
                highlightedSearchId = match.mediaSavedSearchId
                statusMessage = "Loaded “\(match.name)”."
            } else {
                statusMessage = "Preferred search “\(preferredSearchName)” not found yet."
            }
        }
    }

    private func reloadSearchesOnly() {
        var all = AppDependencies.database.fetchAllMediaSavedSearches(enabledOnly: false)
        if let preferredSearchName {
            all.sort { lhs, rhs in
                let l = lhs.name.compare(preferredSearchName, options: .caseInsensitive) == .orderedSame
                let r = rhs.name.compare(preferredSearchName, options: .caseInsensitive) == .orderedSame
                if l != r { return l && !r }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        } else {
            all.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        searches = all
    }

    /// Ensures holiday / birthday preferred searches exist via legacy pipelines (upserts media rows).
    private func ensurePreferredIfNeeded() {
        guard let preferredSearchName else { return }
        let trimmed = preferredSearchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let existingMedia = AppDependencies.database.fetchAllMediaSavedSearches(enabledOnly: false)
        if existingMedia.contains(where: {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            return
        }

        if let fromLegacy = AppDependencies.database.fetchAllPictureSearches().first(where: {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            _ = AppDependencies.database.upsertMediaSavedSearch(from: fromLegacy)
            return
        }

        if let birthday = Self.ensurePersonBirthdayPictureSearchIfNeeded(preferredSearchName: trimmed) {
            _ = AppDependencies.database.upsertMediaSavedSearch(from: birthday)
            return
        }

        if let tagValue = Self.holidayTagValue(fromPictureSearchName: trimmed),
           let ensured = AppDependencies.database.ensureHolidayPictureSearch(tagValue: tagValue) {
            _ = AppDependencies.database.upsertMediaSavedSearch(from: ensured)
            return
        }

        if trimmed.compare(
            HolidayPictureSearchDefaults.pictureSearchName(forTagValue: "Christmas"),
            options: .caseInsensitive
        ) == .orderedSame {
            let ensured = AppDependencies.database.ensureChristmasPictureSearch()
            _ = AppDependencies.database.upsertMediaSavedSearch(from: ensured)
        }
    }

    private func runSearch(_ search: MediaSavedSearch) {
        guard let searchId = search.mediaSavedSearchId else { return }
        runningSearchId = searchId
        statusMessage = "Running “\(search.name)”…"

        Task {
            let latest = AppDependencies.database.fetchMediaSavedSearch(id: searchId) ?? search
            let report = await Task.detached(priority: .utility) {
                AppDependencies.database.runMediaSavedSearch(latest)
            }.value

            await MainActor.run {
                let definition = Self.pictureDefinition(for: latest)
                runResults = MediaSavedSearchRunResults(definition: definition, report: report)
                runningSearchId = nil
                statusMessage = report.summaryLine
                print("Media saved search “\(latest.name)”: \(report.summaryLine)")
            }
        }
    }

    /// Score-card path still uses `PictureSearchDefinition`; prefer linked legacy row.
    private static func pictureDefinition(for search: MediaSavedSearch) -> PictureSearchDefinition {
        if let legacyId = search.legacyPictureSearchId,
           let definition = AppDependencies.database.fetchPictureSearch(pictureSearchId: legacyId) {
            return definition
        }
        return PictureSearchDefinition(
            pictureSearchId: search.legacyPictureSearchId,
            name: search.name,
            targetTagCategory: search.targetTagCategory,
            targetEventType: search.targetTagValue,
            dateSearch: .weddingDefault(),
            visionTagSearch: VisionTagSearchDefinition(
                visionTagSearchId: nil,
                name: nil,
                matchMode: "any",
                tags: []
            ),
            locationSearch: .empty(),
            peopleSearch: .empty(),
            isEnabled: search.isEnabled,
            performFaceDetect: search.performFaceDetect
        )
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

    private static func ensurePersonBirthdayPictureSearchIfNeeded(
        preferredSearchName: String
    ) -> PictureSearchDefinition? {
        let trimmed = preferredSearchName.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [
            "'s Birthday Picture Search",
            "'s Birthday",
            " Birthday Picture Search",
            " Birthday",
        ]
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
}

private struct QueryEditorTarget: Identifiable, Hashable {
    let searchId: Int
    var id: Int { searchId }
}

private struct MediaSavedSearchRunResults: Identifiable, Hashable {
    let definition: PictureSearchDefinition
    let report: PictureSearchRunReport

    var id: Int { report.pictureSearchRunId }

    static func == (lhs: MediaSavedSearchRunResults, rhs: MediaSavedSearchRunResults) -> Bool {
        lhs.report.pictureSearchRunId == rhs.report.pictureSearchRunId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(report.pictureSearchRunId)
    }
}
